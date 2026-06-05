#!/usr/bin/env python3
"""
bmad-issues.py — Sync BMAD sprint stories to GitHub Issues.

Reads sprint-status.yaml from the active (or specified) project, creates
or updates GitHub Issues in the configured target repo, and writes issue
numbers back into sprint-status.yaml.

Uses the `gh` CLI for all GitHub interaction — no tokens to manage if
you're authenticated locally, and `gh` is pre-installed on GitHub Actions
runners.

Usage:
    python scripts/bmad-issues.py                    # sync active project
    python scripts/bmad-issues.py --project food-inventory
    python scripts/bmad-issues.py --dry-run           # show what would happen
    python scripts/bmad-issues.py --status            # show sync state
"""

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

import yaml

# ── Paths ────────────────────────────────────────────────────────────────────

REPO_ROOT = Path(__file__).resolve().parent.parent
PROJECTS_DIR = REPO_ROOT / "projects"
ACTIVE_FILE = REPO_ROOT / "active-project.txt"

MARKER_PREFIX = "<!-- bmad-sync"
MARKER_RE = re.compile(r"<!-- bmad-sync:([^:]+):([^ ]+) -->")

# Status values that mean "create/keep an issue open"
OPEN_STATUSES = {"ready", "todo", "in-progress", "in_progress", "active", "planned"}
CLOSE_STATUSES = {"done", "complete", "completed", "shipped", "cancelled", "canceled"}
SKIP_STATUSES = {"draft", "backlog", "deferred"}

# ── Helpers ──────────────────────────────────────────────────────────────────


def die(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def info(msg):
    print(f"  → {msg}")


def ok(msg):
    print(f"  ✓ {msg}")


def warn(msg):
    print(f"  ⚠ {msg}")


def run_gh(*args, check=True):
    """Run a gh CLI command and return parsed JSON or raw stdout."""
    cmd = ["gh", *args]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if check and result.returncode != 0:
        die(f"gh {' '.join(args[:3])}... failed:\n{result.stderr.strip()}")
    return result


def gh_json(*args):
    """Run gh command expecting JSON output."""
    result = run_gh(*args)
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return None


def get_active_project():
    if ACTIVE_FILE.exists():
        return ACTIVE_FILE.read_text().strip()
    return None


def read_yaml_file(path):
    if not path.exists():
        return None
    with open(path) as f:
        return yaml.safe_load(f)


def write_yaml_file(path, data):
    with open(path, "w") as f:
        yaml.dump(data, f, default_flow_style=False, sort_keys=False, allow_unicode=True)


def read_story_file(project_dir, file_path):
    """Read a story markdown file, strip frontmatter, return body."""
    full_path = project_dir / file_path
    if not full_path.exists():
        # Try relative to the output folder
        for candidate in project_dir.glob(f"**/{Path(file_path).name}"):
            full_path = candidate
            break
        else:
            return None

    text = full_path.read_text()

    # Strip YAML frontmatter if present
    if text.startswith("---"):
        end = text.find("---", 3)
        if end != -1:
            text = text[end + 3 :].strip()

    return text


def build_marker(project_name, story_id):
    return f"<!-- bmad-sync:{story_id}:{project_name} -->"


def find_existing_issue(repo, project_name, story_id):
    """Search for an issue with our sync marker."""
    marker = build_marker(project_name, story_id)
    # gh issue list can search body text
    result = run_gh(
        "issue",
        "list",
        "--repo",
        repo,
        "--search",
        f"bmad-sync:{story_id}:{project_name} in:body",
        "--json",
        "number,title,state,body",
        "--limit",
        "5",
        check=False,
    )
    if result.returncode != 0:
        return None

    try:
        issues = json.loads(result.stdout)
    except json.JSONDecodeError:
        return None

    for issue in issues:
        if marker in (issue.get("body") or ""):
            return issue

    return None


# ── Sync logic ───────────────────────────────────────────────────────────────


def resolve_output_folder(project_dir):
    """Figure out which subfolder holds sprint-status.yaml."""
    # Check common locations
    for candidate in ["features", "_bmad-output", "docs"]:
        path = project_dir / candidate / "implementation-artifacts" / "sprint-status.yaml"
        if path.exists():
            return candidate

    # Brute search
    for path in project_dir.rglob("sprint-status.yaml"):
        return str(path.parent.parent.relative_to(project_dir))

    return None


def collect_stories(sprint_data):
    """Extract a flat list of stories from sprint-status.yaml."""
    stories = []

    if not sprint_data:
        return stories

    current_sprint = sprint_data.get("current_sprint")

    # Handle epics → stories nesting
    for epic in sprint_data.get("epics", []):
        epic_id = epic.get("id", "unknown-epic")
        epic_title = epic.get("title", epic_id)
        epic_status = str(epic.get("status", "")).lower()

        # Collect the epic itself as a syncable item
        stories.append(
            {
                "id": epic_id,
                "title": epic_title,
                "status": epic_status,
                "type": "epic",
                "file": epic.get("file"),
                "sprint": current_sprint,
                "github_issue": epic.get("github_issue"),
                "children": [],
            }
        )

        epic_index = len(stories) - 1

        for story in epic.get("stories", []):
            story_id = story.get("id", "unknown-story")
            story_status = str(story.get("status", "")).lower()

            entry = {
                "id": story_id,
                "title": story.get("title", story_id),
                "status": story_status,
                "type": story.get("type", "story"),
                "file": story.get("file"),
                "sprint": current_sprint,
                "epic_id": epic_id,
                "github_issue": story.get("github_issue"),
            }
            stories.append(entry)
            stories[epic_index]["children"].append(story_id)

    # Handle flat stories list (no epics)
    for story in sprint_data.get("stories", []):
        story_id = story.get("id", "unknown-story")
        story_status = str(story.get("status", "")).lower()

        stories.append(
            {
                "id": story_id,
                "title": story.get("title", story_id),
                "status": story_status,
                "type": story.get("type", "story"),
                "file": story.get("file"),
                "sprint": current_sprint,
                "github_issue": story.get("github_issue"),
            }
        )

    return stories


def sync_story(story, project_name, project_dir, config, dry_run=False, epic_issue_map=None):
    """Sync a single story/epic to a GitHub Issue. Returns issue number or None."""
    repo = config["repo"]
    story_id = story["id"]
    title = story["title"]
    status = story["status"]
    item_type = story.get("type", "story")
    existing_number = story.get("github_issue")

    # Skip drafts
    if status in SKIP_STATUSES:
        return None

    # Determine labels
    labels_config = config.get("labels", {})
    label = labels_config.get(item_type, item_type)

    # Build issue body
    marker = build_marker(project_name, story_id)
    body_parts = [marker, ""]

    # Link to epic if this is a story with a parent epic issue
    epic_id = story.get("epic_id")
    if epic_id and epic_issue_map and epic_id in epic_issue_map:
        body_parts.append(f"**Epic:** #{epic_issue_map[epic_id]}")
        body_parts.append("")

    # Read story file content
    if story.get("file"):
        content = read_story_file(project_dir, story["file"])
        if content:
            body_parts.append(content)
        else:
            body_parts.append(f"*Story file not found: `{story['file']}`*")
    else:
        body_parts.append(f"*No story file linked for {story_id}.*")

    body = "\n".join(body_parts)

    # Determine milestone
    milestone = None
    sprint = story.get("sprint")
    if sprint and config.get("milestone_prefix"):
        milestone = f"{config['milestone_prefix']} {sprint}"

    # Check for existing issue
    existing = None
    if existing_number:
        # Verify it still exists
        result = run_gh(
            "issue", "view", str(existing_number), "--repo", repo,
            "--json", "number,state", check=False,
        )
        if result.returncode == 0:
            existing = json.loads(result.stdout)

    if not existing:
        existing = find_existing_issue(repo, project_name, story_id)

    # Should this issue be closed?
    should_close = status in CLOSE_STATUSES

    if existing:
        issue_num = existing.get("number", existing_number)
        issue_state = existing.get("state", "OPEN").upper()

        if dry_run:
            if should_close and issue_state == "OPEN":
                info(f"[dry-run] Would close #{issue_num}: {title}")
            elif not should_close and issue_state == "CLOSED":
                info(f"[dry-run] Would reopen #{issue_num}: {title}")
            else:
                info(f"[dry-run] Would update #{issue_num}: {title}")
            return issue_num

        # Update body
        run_gh("issue", "edit", str(issue_num), "--repo", repo, "--body", body)

        # Close or reopen based on status
        if should_close and issue_state == "OPEN":
            run_gh("issue", "close", str(issue_num), "--repo", repo)
            ok(f"Closed #{issue_num}: {title}")
        elif not should_close and issue_state == "CLOSED":
            run_gh("issue", "reopen", str(issue_num), "--repo", repo)
            ok(f"Reopened #{issue_num}: {title}")
        else:
            ok(f"Updated #{issue_num}: {title}")

        return issue_num

    else:
        # Create new issue
        if should_close:
            # Don't create an issue just to close it
            return None

        if dry_run:
            info(f"[dry-run] Would create issue: [{label}] {title}")
            return None

        create_args = [
            "issue", "create",
            "--repo", repo,
            "--title", title,
            "--body", body,
            "--label", label,
        ]

        if milestone:
            create_args.extend(["--milestone", milestone])

        result = run_gh(*create_args, check=False)

        if result.returncode != 0:
            stderr = result.stderr.strip()
            # Milestone might not exist — retry without it
            if "milestone" in stderr.lower() and milestone:
                warn(f"Milestone '{milestone}' not found, creating without it")
                try:
                    idx = create_args.index("--milestone")
                    del create_args[idx:idx + 2]
                except ValueError:
                    pass
                result = run_gh(*create_args)
            else:
                warn(f"Failed to create issue for {story_id}: {stderr}")
                return None

        # Parse issue URL to get number
        url = result.stdout.strip()
        match = re.search(r"/issues/(\d+)", url)
        if match:
            issue_num = int(match.group(1))
            ok(f"Created #{issue_num}: {title} ({url})")
            return issue_num
        else:
            ok(f"Created: {title} ({url})")
            return None


def write_back_issues(sprint_yaml_path, sprint_data, issue_map):
    """Write github_issue numbers back into sprint-status.yaml."""
    modified = False

    for epic in sprint_data.get("epics", []):
        epic_id = epic.get("id")
        if epic_id in issue_map and epic.get("github_issue") != issue_map[epic_id]:
            epic["github_issue"] = issue_map[epic_id]
            modified = True

        for story in epic.get("stories", []):
            sid = story.get("id")
            if sid in issue_map and story.get("github_issue") != issue_map[sid]:
                story["github_issue"] = issue_map[sid]
                modified = True

    for story in sprint_data.get("stories", []):
        sid = story.get("id")
        if sid in issue_map and story.get("github_issue") != issue_map[sid]:
            story["github_issue"] = issue_map[sid]
            modified = True

    if modified:
        write_yaml_file(sprint_yaml_path, sprint_data)
        return True
    return False


# ── Commands ─────────────────────────────────────────────────────────────────


def cmd_sync(project_name, dry_run=False):
    project_dir = PROJECTS_DIR / project_name

    # Load project sync config
    config_path = project_dir / "github-sync.yaml"
    if not config_path.exists():
        die(
            f"No github-sync.yaml found for project '{project_name}'.\n"
            f"Create {config_path} with at minimum:\n\n"
            f"  repo: owner/repo-name\n"
        )

    config = read_yaml_file(config_path)
    if not config or "repo" not in config:
        die(f"github-sync.yaml must contain a 'repo' field (e.g., repo: owner/repo-name)")

    repo = config["repo"]
    config.setdefault("labels", {"epic": "epic", "story": "story", "bug": "bug"})
    config.setdefault("milestone_prefix", "Sprint")

    # Find sprint-status.yaml
    output_folder = resolve_output_folder(project_dir)
    if not output_folder:
        die(f"No sprint-status.yaml found in project '{project_name}'")

    sprint_yaml_path = project_dir / output_folder / "implementation-artifacts" / "sprint-status.yaml"
    sprint_data = read_yaml_file(sprint_yaml_path)
    if not sprint_data:
        die(f"sprint-status.yaml is empty or invalid")

    current_sprint = sprint_data.get("current_sprint")
    print(f"\nSyncing: {project_name} → {repo}")
    if current_sprint:
        print(f"Sprint:  {current_sprint}")
    if dry_run:
        print("Mode:    DRY RUN\n")
    else:
        print()

    # Verify gh auth
    auth = run_gh("auth", "status", check=False)
    if auth.returncode != 0:
        die("gh CLI not authenticated. Run: gh auth login")

    # Collect all stories
    stories = collect_stories(sprint_data)
    if not stories:
        warn("No stories found in sprint-status.yaml")
        return

    # Sync epics first to build the issue map
    epic_issue_map = {}
    story_issue_map = {}

    # Pass 1: epics
    for story in stories:
        if story["type"] == "epic":
            issue_num = sync_story(
                story, project_name, project_dir, config,
                dry_run=dry_run, epic_issue_map=epic_issue_map,
            )
            if issue_num:
                epic_issue_map[story["id"]] = issue_num
                story_issue_map[story["id"]] = issue_num

    # Pass 2: stories (with epic references)
    for story in stories:
        if story["type"] != "epic":
            issue_num = sync_story(
                story, project_name, project_dir, config,
                dry_run=dry_run, epic_issue_map=epic_issue_map,
            )
            if issue_num:
                story_issue_map[story["id"]] = issue_num

    # Write back issue numbers
    if not dry_run and story_issue_map:
        if write_back_issues(sprint_yaml_path, sprint_data, story_issue_map):
            ok(f"Updated {sprint_yaml_path.relative_to(REPO_ROOT)} with issue numbers")

    # Summary
    synced = len(story_issue_map)
    skipped = len([s for s in stories if s["status"] in SKIP_STATUSES])
    print(f"\n  Synced: {synced}  Skipped (draft): {skipped}")


def cmd_status(project_name):
    project_dir = PROJECTS_DIR / project_name

    output_folder = resolve_output_folder(project_dir)
    if not output_folder:
        die(f"No sprint-status.yaml found for '{project_name}'")

    sprint_yaml_path = project_dir / output_folder / "implementation-artifacts" / "sprint-status.yaml"
    sprint_data = read_yaml_file(sprint_yaml_path)
    if not sprint_data:
        die("sprint-status.yaml is empty")

    # Check for config
    config_path = project_dir / "github-sync.yaml"
    has_config = config_path.exists()

    print(f"\nProject: {project_name}")
    print(f"Config:  {'✓ ' + str(config_path.relative_to(REPO_ROOT)) if has_config else '✗ no github-sync.yaml'}")

    if has_config:
        config = read_yaml_file(config_path)
        print(f"Repo:    {config.get('repo', '(not set)')}")

    current_sprint = sprint_data.get("current_sprint")
    if current_sprint:
        print(f"Sprint:  {current_sprint}")

    stories = collect_stories(sprint_data)
    if not stories:
        print("\nNo stories in sprint-status.yaml")
        return

    print(f"\nStories: {len(stories)}\n")

    for story in stories:
        status = story["status"]
        issue = story.get("github_issue")
        stype = story.get("type", "story")
        indent = "  " if stype != "epic" else ""

        if status in SKIP_STATUSES:
            marker = "○"
        elif issue:
            marker = "✓"
        else:
            marker = "●"

        issue_str = f" → #{issue}" if issue else ""
        print(f"  {indent}{marker} [{stype}] {story['id']}: {story['title']}  ({status}){issue_str}")


# ── Main ─────────────────────────────────────────────────────────────────────


def main():
    parser = argparse.ArgumentParser(description="Sync BMAD sprint stories to GitHub Issues")
    parser.add_argument("command", nargs="?", default="sync", choices=["sync", "status"])
    parser.add_argument("--project", "-p", help="Project name (default: active project)")
    parser.add_argument("--dry-run", "-n", action="store_true", help="Show what would happen")
    args = parser.parse_args()

    project = args.project or get_active_project()
    if not project:
        die("No active project. Run: bmad-router switch <project>  or pass --project")

    project_dir = PROJECTS_DIR / project
    if not project_dir.is_dir():
        die(f"Project '{project}' not found at {project_dir}")

    if args.command == "status":
        cmd_status(project)
    else:
        cmd_sync(project, dry_run=args.dry_run)


if __name__ == "__main__":
    main()
