#!/usr/bin/env python3
"""
bmad-issues.py — Sync BMad v6 artifacts to GitHub Issues + Projects.

Reads the active (or specified) project's BMad artifacts and mirrors them to
GitHub as two label-separated issue trees, then updates a GitHub Project board:

  Delivery tree (label bmad-delivery, in the project's source repo):
      Delivery root  →  Epic issues  →  Story sub-issues
    driven by the flat `development_status:` map in sprint-status.yaml.

  Planning checklist (label bmad-planning, in the metarepo):
      one "Planning: <project>" issue whose checklist tracks which planning
      artifacts (brief, PRD, UX, architecture, epics) exist.

Design rules (see review that shaped them):
  - This script is the ONLY writer of issue state and Project Status. "In
    Review" is derived here from open story/<key> PRs across the project's
    repos.yaml repos — no per-repo workflow writes status.
  - No committed state file: the story-key → issue mapping is rebuilt every
    run from `<!-- bmad-sync:key:project -->` body markers via one paginated
    issue list per repo (consistent, unlike search).
  - sprint-status.yaml is never written. BMad owns it.
  - Orphans (keys that vanished after renumbering) are closed as not-planned
    and labeled bmad-orphaned — never deleted, never silently duplicated.
  - Epic issues close when all their story sub-issues are closed and are never
    reopened from the epic key's status (epic→done is manual in BMad).

Uses the `gh` CLI for all GitHub interaction. Requires a token that can write
issues in the target repos and the Project (the default Actions GITHUB_TOKEN
cannot access Projects v2 — use a fine-grained PAT via BMAD_PROJECT_TOKEN).

Run from the metarepo root. This script ships inside the meta-router skill, so
its path follows the agent tool's home dir (.claude / .github / .codex); the
examples below use Claude Code.

Usage:
    SKILL=.claude/skills/meta-router/scripts
    python $SKILL/bmad-issues.py                     # sync active project
    python $SKILL/bmad-issues.py --project food-inventory
    python $SKILL/bmad-issues.py --all               # every configured project
    python $SKILL/bmad-issues.py --dry-run
    python $SKILL/bmad-issues.py status --project food-inventory
"""

import argparse
import fnmatch
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

import yaml

# This script ships inside the meta-router skill (<tool-home>/skills/meta-router/
# scripts/), so its own location no longer marks the metarepo root. Run it from
# the metarepo root — matching meta-router.sh / bmad-github-bootstrap.sh, and how
# the sync workflow invokes it.
REPO_ROOT = Path.cwd()
PROJECTS_DIR = REPO_ROOT / "projects"
ACTIVE_FILE = REPO_ROOT / "active-project.txt"

MARKER_RE = re.compile(r"<!-- bmad-sync:([^:]+):([^ ]+) -->")

DELIVERY_LABEL = "bmad-delivery"
PLANNING_LABEL = "bmad-planning"
ORPHAN_LABEL = "bmad-orphaned"

DELIVERY_ROOT_KEY = "delivery-root"
PLANNING_ROOT_KEY = "planning-root"

STORY_KEY_RE = re.compile(r"^(\d+)-(\d+)-[a-z0-9-]+$")
EPIC_KEY_RE = re.compile(r"^epic-(\d+)$")

EPIC_HEADER_RE = re.compile(r"^##\s+Epic\s+(\d+)\s*:\s*(.+?)\s*$", re.MULTILINE)
STORY_HEADER_RE = re.compile(r"^###\s+Story\s+(\d+)\.(\d+)\s*:\s*(.+?)\s*$", re.MULTILINE)

SPRINT_TO_PROJECT_STATUS = {
    "backlog": "Backlog",
    "ready-for-dev": "Ready",
    "drafted": "Ready",
    "in-progress": "In Progress",
    "contexted": "In Progress",
    "review": "In Review",
    "done": "Done",
}

PLANNING_DOCS = [
    ("Product Brief", ["*brief*.md"], False),
    ("PRD", ["prds/**/prd.md", "*prd*.md"], True),
    ("UX Spec", ["*ux*.md"], False),
    ("Architecture", ["*architect*.md"], True),
    ("Epic & Story breakdown", ["*epic*.md", "epics/index.md"], True),
]

CREATE_THROTTLE_SECONDS = float(os.environ.get("BMAD_SYNC_THROTTLE", "1.0"))


def die(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def info(msg):
    print(f"  → {msg}")


def ok(msg):
    print(f"  ✓ {msg}")


def warn(msg):
    print(f"  ⚠ {msg}")


# ── gh CLI layer ─────────────────────────────────────────────────────────────


def run_gh(*args, check=True, input_text=None):
    try:
        result = subprocess.run(
            ["gh", *args], capture_output=True, text=True, input=input_text
        )
    except FileNotFoundError:
        die("gh CLI not found — install it from https://cli.github.com and run: gh auth login")
    if check and result.returncode != 0:
        die(f"gh {' '.join(str(a) for a in args[:4])}... failed:\n{result.stderr.strip()}")
    return result


def gh_rest(path, method="GET", check=True, **fields):
    args = ["api", path, "-X", method]
    for key, value in fields.items():
        if isinstance(value, bool):
            args += ["-F", f"{key}={'true' if value else 'false'}"]
        elif isinstance(value, int):
            args += ["-F", f"{key}={value}"]
        elif isinstance(value, list):
            for item in value:
                args += ["-f", f"{key}[]={item}"]
        else:
            args += ["-f", f"{key}={value}"]
    result = run_gh(*args, check=check)
    if result.returncode != 0:
        return None
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return None


def gh_rest_paginated(path):
    result = run_gh("api", path, "--paginate", check=False)
    if result.returncode != 0:
        warn(f"gh api {path.split('?')[0]} failed: {result.stderr.strip().splitlines()[0] if result.stderr else 'unknown error'}")
        return []
    try:
        items = json.loads(result.stdout)
        if isinstance(items, list):
            return items
        return [items]
    except json.JSONDecodeError:
        # --paginate concatenates arrays as ][ between pages on old gh versions
        merged = re.sub(r"\]\s*\[", ",", result.stdout)
        return json.loads(merged)


def gh_graphql(query, check=True, **variables):
    args = ["api", "graphql", "-f", f"query={query}"]
    for key, value in variables.items():
        if isinstance(value, int):
            args += ["-F", f"{key}={value}"]
        else:
            args += ["-f", f"{key}={value}"]
    result = run_gh(*args, check=check)
    if result.returncode != 0:
        return None
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return None


# ── Metarepo + project resolution ────────────────────────────────────────────


def get_active_project():
    if ACTIVE_FILE.exists():
        return ACTIVE_FILE.read_text().strip()
    return None


def read_yaml_file(path):
    if not path.exists():
        return None
    with open(path) as f:
        return yaml.safe_load(f)


def strip_project_root(value):
    value = str(value).strip().strip('"').strip("'")
    return re.sub(r"^\{project-root\}/", "", value)


def resolve_output_folder(project_dir):
    """Resolve the project's output folder name from BMad config, mirroring
    the resolution order in the meta-router skill's meta-router.sh."""
    env_value = os.environ.get("BMAD_OUTPUT_FOLDER")
    if env_value:
        return env_value

    bmm_config = read_yaml_file(REPO_ROOT / "_bmad" / "bmm" / "config.yaml")
    if bmm_config and bmm_config.get("output_folder"):
        return strip_project_root(bmm_config["output_folder"])

    for path in sorted(project_dir.rglob("sprint-status.yaml")):
        return path.parent.parent.relative_to(project_dir).parts[0]

    return "features"


def get_metarepo_slug():
    env_repo = os.environ.get("BMAD_METAREPO_SLUG") or os.environ.get("GITHUB_REPOSITORY")
    if env_repo:
        return env_repo
    result = run_gh("repo", "view", "--json", "nameWithOwner", check=False)
    if result.returncode == 0:
        try:
            return json.loads(result.stdout)["nameWithOwner"]
        except (json.JSONDecodeError, KeyError):
            pass
    return None


def load_sync_config(project_dir, metarepo_slug):
    """Load github-sync.yaml. `repo:` is optional — delivery issues default to
    the metarepo (the project-management home); set repo: to keep a project's
    issues next to its code instead."""
    config = read_yaml_file(project_dir / "github-sync.yaml")
    if config is None:
        return None
    repo = str(config.get("repo") or "")
    explicit = bool(repo) and not repo.startswith("OWNER/")
    if not explicit:
        repo = metarepo_slug or ""
    if not repo:
        return None
    config["repo"] = repo
    config["repo_explicit"] = explicit
    config.setdefault("labels", {})
    config["labels"].setdefault("feature", "feature")
    config["labels"].setdefault("epic", "epic")
    config["labels"].setdefault("story", "story")
    config.setdefault("planning", True)
    if config.get("project") and not config.get("project_owner"):
        config["project_owner"] = repo.split("/")[0]
    return config


def repo_slug_from_url(url):
    match = re.search(r"github\.com[:/]([^/]+/[^/.]+?)(?:\.git)?/?$", str(url).strip())
    return match.group(1) if match else None


def load_source_repos(project_dir, config):
    """Every repo where this project's story branches can live: the repos.yaml
    clones, plus the issues repo only when it was set explicitly. A defaulted
    issues repo is the shared metarepo — story branches never live there, and
    scanning it would cross-match other projects' story/<key> branches."""
    slugs = []
    repos_config = read_yaml_file(project_dir / "repos.yaml")
    for entry in (repos_config or {}).get("repos", []) or []:
        slug = repo_slug_from_url(entry.get("url", ""))
        if slug:
            slugs.append(slug)
    if config.get("repo_explicit") and config["repo"] not in slugs:
        slugs.append(config["repo"])
    return slugs


# ── BMad v6 artifact parsing ─────────────────────────────────────────────────


def classify_development_status(dev_map):
    """Split the flat development_status map into epics and stories.

    Key rules (from BMad's bmad-sprint-status skill): keys ending
    -retrospective are retrospectives (not synced); keys matching epic-N are
    epics; everything else is a story, joined to its epic by the leading
    `<epic>-<story>-` numbers."""
    epics, stories = {}, []
    for key, status in (dev_map or {}).items():
        key = str(key)
        status = str(status).lower()
        if key.endswith("-retrospective"):
            continue
        epic_match = EPIC_KEY_RE.match(key)
        if epic_match:
            epics[int(epic_match.group(1))] = {"key": key, "status": status}
            continue
        story_match = STORY_KEY_RE.match(key)
        epic_num = int(story_match.group(1)) if story_match else None
        story_num = int(story_match.group(2)) if story_match else None
        stories.append(
            {"key": key, "status": status, "epic": epic_num, "story": story_num}
        )
    return epics, stories


def humanize_key(key):
    slug = re.sub(r"^\d+-\d+-", "", key)
    return slug.replace("-", " ").strip().title() or key


def find_epics_doc(planning_dir):
    if not planning_dir.is_dir():
        return None
    whole = sorted(p for p in planning_dir.glob("*epic*.md") if p.is_file())
    if whole:
        return whole[0].read_text()
    index = planning_dir / "epics" / "index.md"
    if index.exists():
        parts = [index.read_text()]
        parts += [p.read_text() for p in sorted((planning_dir / "epics").glob("epic-*.md"))]
        return "\n\n".join(parts)
    return None


def parse_epics_doc(text):
    """Extract epic titles/goals and story titles/bodies from epics.md
    headers (## Epic N: ... / ### Story N.M: ...)."""
    epics, stories = {}, {}
    if not text:
        return epics, stories

    epic_matches = list(EPIC_HEADER_RE.finditer(text))
    for i, match in enumerate(epic_matches):
        section_end = epic_matches[i + 1].start() if i + 1 < len(epic_matches) else len(text)
        section = text[match.end():section_end]
        first_story = STORY_HEADER_RE.search(section)
        goal = section[: first_story.start()] if first_story else section
        epics[int(match.group(1))] = {
            "title": match.group(2),
            "goal": goal.strip(),
        }

    story_matches = list(STORY_HEADER_RE.finditer(text))
    for i, match in enumerate(story_matches):
        section_end = len(text)
        if i + 1 < len(story_matches):
            section_end = story_matches[i + 1].start()
        next_epic = EPIC_HEADER_RE.search(text, match.end())
        if next_epic and next_epic.start() < section_end:
            section_end = next_epic.start()
        stories[(int(match.group(1)), int(match.group(2)))] = {
            "title": match.group(3),
            "body": text[match.end():section_end].strip(),
        }
    return epics, stories


def read_story_file(implementation_dir, story_key):
    story_path = implementation_dir / f"{story_key}.md"
    if not story_path.exists():
        return None
    text = story_path.read_text()
    if text.startswith("---"):
        end = text.find("---", 3)
        if end != -1:
            text = text[end + 3:].strip()
    return text


def parse_frontmatter(text):
    if not text.startswith("---"):
        return {}
    end = text.find("---", 3)
    if end == -1:
        return {}
    try:
        data = yaml.safe_load(text[3:end])
        return data if isinstance(data, dict) else {}
    except yaml.YAMLError:
        return {}


PRD_DATE_RE = re.compile(r"-(\d{4})-?(\d{2})-?(\d{2})$")


def prd_sort_key(folder_name):
    """Order PRD run folders by their trailing date (prd-<name>-<date>), not
    alphabetically — otherwise the PRD's name outranks its date and the wrong
    PRD becomes current. Undated folders sort first; the folder name breaks
    ties deterministically (mtime is clone time in CI, so it can't)."""
    match = PRD_DATE_RE.search(folder_name)
    date = "-".join(match.groups()) if match else ""
    return (bool(match), date, folder_name)


def find_prds(planning_dir):
    """Each PRD is a Feature. BMad v6 writes one run folder per PRD
    (prds/prd-<name>-<date>/prd.md); the folder with the newest date suffix
    is the current feature — epics.md is generated from it, so its epics nest
    under that feature issue."""
    prd_paths = []
    if planning_dir.is_dir():
        prd_paths = sorted(
            planning_dir.glob("prds/*/prd.md"),
            key=lambda p: prd_sort_key(p.parent.name),
        )
    if not prd_paths and planning_dir.is_dir():
        prd_paths = sorted(
            p for p in planning_dir.iterdir()
            if p.is_file() and p.suffix == ".md"
            and "prd" in p.name.lower() and "epic" not in p.name.lower()
        )

    prds = []
    for path in prd_paths:
        front = parse_frontmatter(path.read_text())
        key_source = path.parent.name if path.name == "prd.md" else path.stem
        key = "feature-" + re.sub(r"[^a-z0-9]+", "-", key_source.lower()).strip("-")
        prds.append(
            {
                "key": key,
                "title": str(front.get("title") or key_source),
                "status": str(front.get("status", "draft")).lower(),
                "path": str(path.relative_to(planning_dir.parent.parent)),
                "current": False,
            }
        )
    if prds:
        prds[-1]["current"] = True
    return prds


def detect_planning_docs(planning_dir):
    """Return [(doc_name, exists, required)] for the planning checklist.
    Top-level patterns match case-insensitively (PRD.md, Architecture.md)."""
    results = []
    for name, patterns, required in PLANNING_DOCS:
        exists = False
        if planning_dir.is_dir():
            for pattern in patterns:
                if "/" in pattern:
                    found = any(p.is_file() for p in planning_dir.glob(pattern))
                else:
                    found = any(
                        p.is_file() and fnmatch.fnmatch(p.name.lower(), pattern)
                        for p in planning_dir.iterdir()
                    )
                if found:
                    exists = True
                    break
        results.append((name, exists, required))
    return results


# ── GitHub state (rebuilt every run from markers) ────────────────────────────


def build_marker(key, project_name):
    return f"<!-- bmad-sync:{key}:{project_name} -->"


def list_synced_issues(repo, label, project_name):
    """One paginated list per repo rebuilds the key→issue mapping from body
    markers — no committed state file, no search-index lag."""
    issues = gh_rest_paginated(
        f"repos/{repo}/issues?labels={label}&state=all&per_page=100"
    )
    mapping = {}
    for issue in issues:
        if "pull_request" in issue:
            continue
        match = MARKER_RE.search(issue.get("body") or "")
        if match and match.group(2) == project_name:
            mapping[match.group(1)] = issue
    return mapping


def ensure_labels(repo, labels, dry_run):
    existing = {
        label["name"]
        for label in gh_rest_paginated(f"repos/{repo}/labels?per_page=100")
    }
    for name, color in labels:
        if name in existing:
            continue
        if dry_run:
            info(f"[dry-run] Would create label '{name}' in {repo}")
            continue
        gh_rest(f"repos/{repo}/labels", method="POST", check=False, name=name, color=color)


def get_issue_type_ids(org):
    types = gh_rest(f"orgs/{org}/issue-types", check=False)
    if not isinstance(types, list):
        return {}
    return {t["name"].lower(): t["name"] for t in types}


PR_STATE_ICONS = {"open": "🔄", "merged": "🟣", "closed": "⚪"}


def list_story_branch_prs(repo_slugs):
    """Map story_key → PRs on story/<key> branches across the project's repos.

    Open PRs are fetched fully; merged/closed ones come from the newest 100
    per repo — stories are short-lived, so a story's merged PRs are recent."""
    prs_by_key = {}
    for slug in repo_slugs:
        open_pulls = gh_rest_paginated(f"repos/{slug}/pulls?state=open&per_page=100")
        closed_pulls = gh_rest(f"repos/{slug}/pulls?state=closed&per_page=100", check=False) or []
        for pull in list(open_pulls) + list(closed_pulls):
            branch = pull.get("head", {}).get("ref", "")
            if not branch.startswith("story/"):
                continue
            state = "merged" if pull.get("merged_at") else str(pull.get("state", "open"))
            prs_by_key.setdefault(branch[len("story/"):], []).append(
                {
                    "url": pull["html_url"],
                    "repo": slug,
                    "number": pull["number"],
                    "state": state,
                }
            )
    return prs_by_key


def keys_with_open_prs(prs_by_key):
    return {
        key for key, prs in prs_by_key.items()
        if any(pr["state"] == "open" for pr in prs)
    }


def build_pr_section(prs):
    """Markdown section linking a story's PRs (one per affected repo) onto its
    issue. Referencing the PR URLs also makes GitHub cross-link them on the
    PR side."""
    if not prs:
        return ""
    lines = ["", "", "## Pull Requests", ""]
    for pr in sorted(prs, key=lambda p: (p["repo"], p["number"])):
        icon = PR_STATE_ICONS.get(pr["state"], "")
        lines.append(f"- {icon} [{pr['repo']}#{pr['number']}]({pr['url']}) — {pr['state']}")
    return "\n".join(lines)


def list_open_planning_prs(metarepo_slug, project_name, limit=20):
    """First open PR touching the project's planning artifacts, checking the
    `limit` most recently updated PRs (one bounded list call, not a full
    pagination)."""
    pulls = gh_rest(
        f"repos/{metarepo_slug}/pulls?state=open&sort=updated&direction=desc&per_page={limit}",
        check=False,
    ) or []
    prefix = f"projects/{project_name}/"
    for pull in pulls:
        files = gh_rest(
            f"repos/{metarepo_slug}/pulls/{pull['number']}/files?per_page=100",
            check=False,
        )
        for changed in files or []:
            if changed.get("filename", "").startswith(prefix) and "planning-artifacts" in changed.get("filename", ""):
                return pull["html_url"]
    return None


# ── GitHub Projects v2 ───────────────────────────────────────────────────────

PROJECT_QUERY = """
query($owner: String!, $number: Int!) {
  organization(login: $owner) {
    projectV2(number: $number) {
      id
      fields(first: 50) {
        nodes {
          ... on ProjectV2SingleSelectField { id name options { id name } }
        }
      }
    }
  }
}
"""

PROJECT_QUERY_USER = PROJECT_QUERY.replace("organization", "user")

PROJECT_ITEMS_QUERY = """
query($projectId: ID!, $cursor: String) {
  node(id: $projectId) {
    ... on ProjectV2 {
      items(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id
          content { ... on Issue { number repository { nameWithOwner } } }
          fieldValueByName(name: "Status") {
            ... on ProjectV2ItemFieldSingleSelectValue { name }
          }
        }
      }
    }
  }
}
"""


class ProjectBoard:
    """Runtime handle on one GitHub Project: IDs looked up fresh each run,
    current item statuses prefetched so unchanged items cost zero writes."""

    def __init__(self, owner, number, dry_run):
        self.dry_run = dry_run
        self.project_id = None
        self.status_field_id = None
        self.status_options = {}
        self.items = {}

        data = gh_graphql(PROJECT_QUERY, check=False, owner=owner, number=int(number))
        container = (data or {}).get("data", {}).get("organization")
        if not container or not container.get("projectV2"):
            data = gh_graphql(PROJECT_QUERY_USER, check=False, owner=owner, number=int(number))
            container = (data or {}).get("data", {}).get("user")
        project = (container or {}).get("projectV2")
        if not project:
            warn(
                f"GitHub Project #{number} not found for '{owner}' — issues will "
                f"sync without board updates. Run the skill's bmad-github-bootstrap.sh"
            )
            return

        self.project_id = project["id"]
        for field in project["fields"]["nodes"]:
            if field and field.get("name") == "Status":
                self.status_field_id = field["id"]
                self.status_options = {
                    option["name"]: option["id"] for option in field["options"]
                }
        self._fetch_items()

    def _fetch_items(self):
        cursor = ""
        while True:
            data = gh_graphql(
                PROJECT_ITEMS_QUERY, check=False,
                projectId=self.project_id, cursor=cursor,
            )
            items = (data or {}).get("data", {}).get("node", {}).get("items", {})
            for node in items.get("nodes", []):
                content = node.get("content") or {}
                if content.get("number"):
                    repo = content["repository"]["nameWithOwner"]
                    status = (node.get("fieldValueByName") or {}).get("name")
                    self.items[(repo, content["number"])] = {
                        "item_id": node["id"],
                        "status": status,
                    }
            page = items.get("pageInfo", {})
            if not page.get("hasNextPage"):
                break
            cursor = page["endCursor"]

    def set_status(self, repo, issue_number, issue_node_id, status_name):
        if not self.project_id:
            return
        if status_name not in self.status_options:
            warn(
                f"Project has no Status option '{status_name}' — add it in the "
                f"project settings (expected: Backlog, Ready, In Progress, In Review, Done)"
            )
            return

        item = self.items.get((repo, issue_number))
        if item and item["status"] == status_name:
            return

        if self.dry_run:
            info(f"[dry-run] Would set #{issue_number} → {status_name} on the board")
            return

        if not item:
            data = gh_graphql(
                """
                mutation($projectId: ID!, $contentId: ID!) {
                  addProjectV2ItemById(input: {projectId: $projectId, contentId: $contentId}) {
                    item { id }
                  }
                }
                """,
                check=False, projectId=self.project_id, contentId=issue_node_id,
            )
            item_id = (
                (data or {}).get("data", {})
                .get("addProjectV2ItemById", {})
                .get("item", {})
                .get("id")
            )
            if not item_id:
                warn(f"Could not add #{issue_number} to the project")
                return
            item = {"item_id": item_id, "status": None}
            self.items[(repo, issue_number)] = item

        gh_graphql(
            """
            mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
              updateProjectV2ItemFieldValue(input: {
                projectId: $projectId, itemId: $itemId, fieldId: $fieldId,
                value: {singleSelectOptionId: $optionId}
              }) { projectV2Item { id } }
            }
            """,
            check=False,
            projectId=self.project_id, itemId=item["item_id"],
            fieldId=self.status_field_id,
            optionId=self.status_options[status_name],
        )
        item["status"] = status_name


# ── Issue upsert ─────────────────────────────────────────────────────────────


def create_issue(repo, title, body, labels, issue_type, dry_run):
    if dry_run:
        info(f"[dry-run] Would create in {repo}: {title}")
        return None
    fields = {"title": title, "body": body, "labels": labels}
    if issue_type:
        fields["type"] = issue_type
    issue = gh_rest(f"repos/{repo}/issues", method="POST", check=False, **fields)
    if not issue and issue_type:
        issue = gh_rest(
            f"repos/{repo}/issues", method="POST", check=False,
            title=title, body=body, labels=labels,
        )
    if issue:
        ok(f"Created #{issue['number']}: {title}")
        time.sleep(CREATE_THROTTLE_SECONDS)
    else:
        warn(f"Failed to create issue: {title}")
    return issue


def update_issue_body(repo, issue, body, dry_run):
    if (issue.get("body") or "").strip() == body.strip():
        return
    if dry_run:
        info(f"[dry-run] Would update body of #{issue['number']}")
        return
    gh_rest(f"repos/{repo}/issues/{issue['number']}", method="PATCH", check=False, body=body)


def set_issue_state(repo, issue, should_close, dry_run, reason="completed"):
    is_closed = str(issue.get("state", "open")).lower() == "closed"
    if should_close and not is_closed:
        if dry_run:
            info(f"[dry-run] Would close #{issue['number']}")
        else:
            gh_rest(
                f"repos/{repo}/issues/{issue['number']}", method="PATCH",
                check=False, state="closed", state_reason=reason,
            )
            ok(f"Closed #{issue['number']}: {issue['title']}")
        issue["state"] = "closed"
    elif not should_close and is_closed:
        labels = {l["name"] for l in issue.get("labels", []) if isinstance(l, dict)}
        if ORPHAN_LABEL in labels:
            return
        if dry_run:
            info(f"[dry-run] Would reopen #{issue['number']}")
        else:
            gh_rest(
                f"repos/{repo}/issues/{issue['number']}", method="PATCH",
                check=False, state="open",
            )
            ok(f"Reopened #{issue['number']}: {issue['title']}")
        issue["state"] = "open"


def add_sub_issue(repo, parent_issue, child_issue, dry_run):
    # replace_parent moves the child if it is already linked under an older
    # parent (e.g. the epics moved to a newer PRD's feature issue); for an
    # unlinked child it behaves like a plain add.
    if dry_run or not parent_issue or not child_issue:
        return
    gh_rest(
        f"repos/{repo}/issues/{parent_issue['number']}/sub_issues",
        method="POST", check=False, sub_issue_id=int(child_issue["id"]),
        replace_parent=True,
    )


def upsert_issue(repo, key, project_name, title, body_content, labels, issue_type,
                 existing, parent, dry_run):
    """Create or update one synced issue; returns the issue dict (or None in
    dry-run create). Issues are (re-)linked under their parent on both create
    and update, so a parent change (newer PRD) reconciles the hierarchy."""
    body = f"{build_marker(key, project_name)}\n\n{body_content}".strip()
    issue = existing.get(key)
    if issue:
        update_issue_body(repo, issue, body, dry_run)
        add_sub_issue(repo, parent, issue, dry_run)
        return issue
    issue = create_issue(repo, title, body, labels, issue_type, dry_run)
    if issue:
        existing[key] = issue
        add_sub_issue(repo, parent, issue, dry_run)
    return issue


# ── Delivery sync ────────────────────────────────────────────────────────────


def effective_story_status(status, story_key, open_pr_keys):
    project_status = SPRINT_TO_PROJECT_STATUS.get(status, "Backlog")
    if status != "done" and story_key in open_pr_keys:
        return "In Review"
    return project_status


def sync_delivery(project_name, project_dir, config, board, dry_run):
    repo = config["repo"]
    output_folder = resolve_output_folder(project_dir)
    sprint_path = (
        project_dir / output_folder / "implementation-artifacts" / "sprint-status.yaml"
    )
    sprint_data = read_yaml_file(sprint_path)
    if not sprint_data or not sprint_data.get("development_status"):
        info("No development_status in sprint-status.yaml yet — skipping delivery sync")
        return

    planning_dir = project_dir / output_folder / "planning-artifacts"
    implementation_dir = project_dir / output_folder / "implementation-artifacts"
    epic_docs, story_docs = parse_epics_doc(find_epics_doc(planning_dir))
    epics, stories = classify_development_status(sprint_data["development_status"])

    project_title = sprint_data.get("project") or project_name
    feature_label = config["labels"]["feature"]
    epic_label = config["labels"]["epic"]
    story_label = config["labels"]["story"]

    ensure_labels(
        repo,
        [(DELIVERY_LABEL, "1D76DB"), (ORPHAN_LABEL, "D93F0B"),
         (feature_label, "8250DF"), (epic_label, "3E4B9E"), (story_label, "0E8A16")],
        dry_run,
    )

    org = repo.split("/")[0]
    issue_types = get_issue_type_ids(org)
    feature_type = issue_types.get("feature")
    epic_type = issue_types.get("epic")
    story_type = issue_types.get("story")
    if not issue_types:
        info("Org issue types unavailable — falling back to labels only")

    existing = list_synced_issues(repo, DELIVERY_LABEL, project_name)
    prs_by_key = list_story_branch_prs(load_source_repos(project_dir, config))
    # Shared source repos can carry other projects' story branches — only
    # this project's story keys matter here.
    story_keys = {story["key"] for story in stories}
    prs_by_key = {key: prs for key, prs in prs_by_key.items() if key in story_keys}
    open_pr_keys = keys_with_open_prs(prs_by_key)

    root = upsert_issue(
        repo, DELIVERY_ROOT_KEY, project_name,
        f"Delivery: {project_title}",
        f"Implementation progress for **{project_title}**, synced from "
        f"`projects/{project_name}` by bmad-issues. Feature, epic, and story "
        f"progress roll up automatically via sub-issues.",
        [DELIVERY_LABEL, epic_label], epic_type, existing, None, dry_run,
    )

    # One Feature issue per PRD; the current PRD's feature holds the epics
    # (epics.md is generated from it), so its progress bar = epics done.
    prds = find_prds(planning_dir)
    feature_issues = {}
    current_feature = None
    for prd in prds:
        role = (
            "Implementation progress rolls up from the epics nested below."
            if prd["current"]
            else "Superseded by a newer PRD."
        )
        issue = upsert_issue(
            repo, prd["key"], project_name,
            f"Feature: {prd['title']}",
            f"Mirrors the PRD at `{prd['path']}` (authoring status: {prd['status']}). {role}",
            [DELIVERY_LABEL, feature_label], feature_type, existing, root, dry_run,
        )
        feature_issues[prd["key"]] = issue
        if prd["current"]:
            current_feature = issue

    epic_parent = current_feature or root
    epic_issues = {}
    for epic_num in sorted(epics):
        epic = epics[epic_num]
        doc = epic_docs.get(epic_num, {})
        title = doc.get("title") or f"Epic {epic_num}"
        epic_issues[epic_num] = upsert_issue(
            repo, epic["key"], project_name,
            f"Epic {epic_num}: {title}",
            doc.get("goal") or f"_No epic goal found in epics.md for epic {epic_num}._",
            [DELIVERY_LABEL, epic_label], epic_type, existing, epic_parent, dry_run,
        )

    for story in stories:
        doc = story_docs.get((story["epic"], story["story"]), {})
        title = doc.get("title") or humanize_key(story["key"])
        story_id = (
            f"{story['epic']}.{story['story']}" if story["epic"] else story["key"]
        )
        body = (
            read_story_file(implementation_dir, story["key"])
            or doc.get("body")
            or f"_No story file yet for `{story['key']}` — created when bmad-create-story runs._"
        )
        body += build_pr_section(prs_by_key.get(story["key"], []))
        parent = epic_issues.get(story["epic"]) or root
        issue = upsert_issue(
            repo, story["key"], project_name,
            f"Story {story_id}: {title}",
            body, [DELIVERY_LABEL, story_label], story_type, existing, parent, dry_run,
        )
        if not issue:
            continue

        status = effective_story_status(story["status"], story["key"], open_pr_keys)
        set_issue_state(repo, issue, should_close=(story["status"] == "done"), dry_run=dry_run)
        board.set_status(repo, issue["number"], issue["node_id"], status)

    close_orphans(repo, existing, prds, epics, stories, project_name, dry_run, board)
    close_completed_epics(repo, epics, stories, epic_issues, board, dry_run)
    sync_feature_states(repo, prds, feature_issues, stories, board, dry_run)

    synced = len([s for s in stories if s["key"] in existing])
    ok(f"Delivery: {synced}/{len(stories)} stories, {len(epic_issues)} epics, {len(prds)} features → {repo}")


def close_orphans(repo, existing, prds, epics, stories, project_name, dry_run, board):
    """Keys that vanished from the artifacts (renumbered stories, removed PRD
    run folders) → close as not-planned + label, never delete."""
    live_keys = {DELIVERY_ROOT_KEY}
    live_keys.update(prd["key"] for prd in prds)
    live_keys.update(epic["key"] for epic in epics.values())
    live_keys.update(story["key"] for story in stories)

    for key, issue in existing.items():
        if key in live_keys:
            continue
        labels = {l["name"] for l in issue.get("labels", []) if isinstance(l, dict)}
        if ORPHAN_LABEL in labels and str(issue.get("state")).lower() == "closed":
            continue
        if dry_run:
            info(f"[dry-run] Would orphan #{issue['number']} (key '{key}' gone)")
            continue
        gh_rest(
            f"repos/{repo}/issues/{issue['number']}/labels",
            method="POST", check=False, labels=[ORPHAN_LABEL],
        )
        gh_rest(
            f"repos/{repo}/issues/{issue['number']}/comments",
            method="POST", check=False,
            body=f"`{key}` no longer exists in sprint-status.yaml (story renumbered "
                 f"or removed) — closing as not planned. A renumbered story gets a new issue.",
        )
        gh_rest(
            f"repos/{repo}/issues/{issue['number']}", method="PATCH",
            check=False, state="closed", state_reason="not_planned",
        )
        warn(f"Orphaned #{issue['number']}: {issue['title']} (key '{key}' gone)")


def sync_feature_states(repo, prds, feature_issues, stories, board, dry_run):
    """Current feature: open until every story under its epics is done, then
    closed (the implementation shipped). Superseded features (older PRD run
    folders) close as completed."""
    for prd in prds:
        issue = feature_issues.get(prd["key"])
        if not issue:
            continue
        if not prd["current"]:
            set_issue_state(repo, issue, should_close=True, dry_run=dry_run)
            board.set_status(repo, issue["number"], issue["node_id"], "Done")
            continue
        if stories and all(s["status"] == "done" for s in stories):
            set_issue_state(repo, issue, should_close=True, dry_run=dry_run)
            board.set_status(repo, issue["number"], issue["node_id"], "Done")
        else:
            set_issue_state(repo, issue, should_close=False, dry_run=dry_run)
            started = any(s["status"] != "backlog" for s in stories)
            status = "In Progress" if started else "Backlog"
            board.set_status(repo, issue["number"], issue["node_id"], status)


def close_completed_epics(repo, epics, stories, epic_issues, board, dry_run):
    """Epic issues close when every story under them is done. Never reopened
    from the epic key's status (epic→done is manual in BMad). An epic with no
    stories yet takes its board status from its own sprint status."""
    for epic_num, issue in epic_issues.items():
        if not issue:
            continue
        epic_stories = [s for s in stories if s["epic"] == epic_num]
        if not epic_stories:
            own_status = epics[epic_num]["status"]
            if own_status == "done":
                set_issue_state(repo, issue, should_close=True, dry_run=dry_run)
                board.set_status(repo, issue["number"], issue["node_id"], "Done")
            else:
                board.set_status(
                    repo, issue["number"], issue["node_id"],
                    SPRINT_TO_PROJECT_STATUS.get(own_status, "Backlog"),
                )
            continue
        if all(s["status"] == "done" for s in epic_stories):
            set_issue_state(repo, issue, should_close=True, dry_run=dry_run)
            board.set_status(repo, issue["number"], issue["node_id"], "Done")
        elif str(issue.get("state")).lower() == "open":
            done_count = len([s for s in epic_stories if s["status"] == "done"])
            status = "In Progress" if done_count else "Backlog"
            board.set_status(repo, issue["number"], issue["node_id"], status)


# ── Planning sync ────────────────────────────────────────────────────────────


def build_planning_body(project_name, docs):
    lines = [
        f"Planning artifact checklist for **{project_name}**, synced from "
        f"`projects/{project_name}/.../planning-artifacts/` by bmad-issues.",
        "",
    ]
    for name, exists, required in docs:
        checkbox = "x" if exists else " "
        suffix = "" if required else " _(optional)_"
        lines.append(f"- [{checkbox}] {name}{suffix}")
    return "\n".join(lines)


def planning_status(docs, has_open_pr):
    required = [(name, exists) for name, exists, req in docs if req]
    done = all(exists for _, exists in required)
    if done:
        return "Done", True
    if has_open_pr:
        return "In Review", False
    if any(exists for _, exists, _ in docs):
        return "In Progress", False
    return "Backlog", False


def sync_planning(project_name, project_dir, config, board, metarepo_slug, dry_run):
    if not config.get("planning", True):
        return
    if not metarepo_slug:
        warn("Cannot resolve the metarepo slug — skipping planning sync")
        return

    output_folder = resolve_output_folder(project_dir)
    planning_dir = project_dir / output_folder / "planning-artifacts"
    docs = detect_planning_docs(planning_dir)

    ensure_labels(metarepo_slug, [(PLANNING_LABEL, "BFD4F2"), (ORPHAN_LABEL, "D93F0B")], dry_run)

    existing = list_synced_issues(metarepo_slug, PLANNING_LABEL, project_name)
    issue = upsert_issue(
        metarepo_slug, PLANNING_ROOT_KEY, project_name,
        f"Planning: {project_name}",
        build_planning_body(project_name, docs),
        [PLANNING_LABEL], None, existing, None, dry_run,
    )
    if not issue:
        return

    open_pr = list_open_planning_prs(metarepo_slug, project_name)
    status, complete = planning_status(docs, bool(open_pr))
    set_issue_state(metarepo_slug, issue, should_close=complete, dry_run=dry_run)
    board.set_status(metarepo_slug, issue["number"], issue["node_id"], status)
    ok(f"Planning: {status} → {metarepo_slug}#{issue['number']}")


# ── Commands ─────────────────────────────────────────────────────────────────


def sync_project(project_name, dry_run):
    project_dir = PROJECTS_DIR / project_name
    if not project_dir.is_dir():
        die(f"Project '{project_name}' not found at {project_dir}")

    metarepo_slug = get_metarepo_slug()
    config = load_sync_config(project_dir, metarepo_slug)
    if not config:
        warn(
            f"{project_name}: cannot resolve an issues repo — skipping.\n"
            f"    Either push the metarepo to GitHub (issues default there), or set "
            f"repo: in projects/{project_name}/github-sync.yaml"
        )
        return

    print(f"\nSyncing: {project_name} → {config['repo']}" + (" [dry-run]" if dry_run else ""))

    if gh_rest(f"repos/{config['repo']}", check=False) is None:
        warn(
            f"Repo {config['repo']} is not accessible with this token — skipping "
            f"{project_name}. Check the repo: value in github-sync.yaml and token permissions."
        )
        return

    if not config.get("project"):
        warn(
            "No GitHub Project configured — issues sync without a board. "
            f"Run the skill's bmad-github-bootstrap.sh {project_name}"
        )
        board = ProjectBoard.__new__(ProjectBoard)
        board.dry_run = dry_run
        board.project_id = None
        board.items = {}
    else:
        board = ProjectBoard(config["project_owner"], config["project"], dry_run)

    sync_planning(project_name, project_dir, config, board, metarepo_slug, dry_run)
    sync_delivery(project_name, project_dir, config, board, dry_run)


def configured_projects():
    if not PROJECTS_DIR.is_dir():
        return []
    return sorted(
        p.name for p in PROJECTS_DIR.iterdir()
        if p.is_dir() and (p / "github-sync.yaml").exists()
    )


def cmd_status(project_name):
    project_dir = PROJECTS_DIR / project_name
    config = load_sync_config(project_dir, get_metarepo_slug())
    output_folder = resolve_output_folder(project_dir)
    sprint_data = read_yaml_file(
        project_dir / output_folder / "implementation-artifacts" / "sprint-status.yaml"
    )

    print(f"\nProject: {project_name}")
    print(f"Config:  {'✓ repo=' + config['repo'] if config else '✗ github-sync.yaml missing or unset'}")
    if config:
        print(f"Board:   {'✓ project #' + str(config['project']) if config.get('project') else '✗ not bootstrapped'}")

    epics, stories = classify_development_status(
        (sprint_data or {}).get("development_status")
    )
    if not stories and not epics:
        print("\nNo development_status entries yet (run bmad-sprint-planning)")
        return

    print(f"\nEpics: {len(epics)}  Stories: {len(stories)}\n")
    for epic_num in sorted(epics):
        epic = epics[epic_num]
        print(f"  [{epic['status']}] {epic['key']}")
        for story in stories:
            if story["epic"] == epic_num:
                print(f"      [{story['status']}] {story['key']}")
    for story in stories:
        if story["epic"] is None:
            print(f"  [{story['status']}] {story['key']} (no epic)")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    parser.add_argument("command", nargs="?", default="sync", choices=["sync", "status"])
    parser.add_argument("--project", "-p", help="Project name (default: active project)")
    parser.add_argument("--all", action="store_true", help="Sync every configured project")
    parser.add_argument("--dry-run", "-n", action="store_true")
    args = parser.parse_args()

    if args.command == "sync" and args.all:
        projects = configured_projects()
        if not projects:
            die("No projects with github-sync.yaml found")
        for project_name in projects:
            sync_project(project_name, args.dry_run)
        return

    project = args.project or get_active_project()
    if not project:
        die("No active project. Run: meta-router switch <project>  or pass --project")

    if args.command == "status":
        cmd_status(project)
    else:
        auth = run_gh("auth", "status", check=False)
        if auth.returncode != 0:
            die("gh CLI not authenticated. Run: gh auth login")
        sync_project(project, args.dry_run)


if __name__ == "__main__":
    main()
