"""
Tests for bmad-issues.py — the GitHub interaction layer, against a fake gh.

run_gh is the single choke point for every REST and GraphQL call, so FakeGh
replaces it with an in-memory GitHub: issues, labels, pulls, and Projects v2
boards. Every mutation is recorded in `fake.writes` so tests assert exactly
what would be written — no network, no gh binary.
"""

import json
import re
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "skills" / "meta-router" / "scripts"))
import importlib
bmad_issues = importlib.import_module("bmad-issues")


def completed(stdout="", returncode=0, stderr=""):
    return SimpleNamespace(returncode=returncode, stdout=stdout, stderr=stderr)


FIELD_VALUE_RE = re.compile(r'(?:(\w+):\s*)?fieldValueByName\(name: "([^"]+)"\)')
OPTION_NAME_RE = re.compile(r'\{(?:id: "([^"]*)", )?name: "([^"]+)"')


class FakeGh:
    """In-memory gh CLI. Routes run_gh(*args) calls onto dict state."""

    def __init__(self):
        self.issues = {}       # repo -> {number: issue dict}
        self.labels = {}       # repo -> {name}
        self.pulls = {}        # repo -> [pull dicts]
        self.issue_types = {}  # org -> [type names]
        self.comments = []     # (repo, number, body)
        self.parents = {}      # (repo, child number) -> parent number
        self.boards = {}       # (owner, number) -> board dict
        self.writes = []       # (kind, detail) for every mutation
        self.intercept = None  # callable(args) -> result | None, for overrides
        self._node_seq = 0

    # ── state builders ───────────────────────────────────────────────────────

    def add_board(self, owner="org", number=7, owner_type="organization", fields=None):
        fields = fields or {"Status": ["Backlog", "Ready", "In Progress", "In Review", "Done"]}
        board = {
            "owner": owner, "number": int(number), "owner_type": owner_type,
            "id": f"PVT_{owner}_{number}",
            "fields": {
                name: {
                    "id": f"FIELD_{owner}_{number}_{name.replace(' ', '_')}",
                    "options": {
                        opt: {"id": f"OPT_{name.replace(' ', '_')}_{i}", "color": "GRAY", "description": ""}
                        for i, opt in enumerate(options)
                    },
                }
                for name, options in fields.items()
            },
            "items": {},  # item_id -> {"repo", "number", "values": {field: option}}
        }
        self.boards[(owner, int(number))] = board
        return board

    def add_issue(self, repo, title, body, labels, state="open"):
        self._node_seq += 1
        number = 100 + self._node_seq
        issue = {
            "number": number,
            "id": 1000 + self._node_seq,
            "node_id": f"I_node{self._node_seq}",
            "title": title,
            "body": body,
            "state": state,
            "labels": [{"name": name} for name in labels],
        }
        self.issues.setdefault(repo, {})[number] = issue
        return issue

    def add_pull(self, repo, number, branch, state="open", merged=False, files=None):
        self.pulls.setdefault(repo, []).append({
            "number": number,
            "html_url": f"https://github.com/{repo}/pull/{number}",
            "head": {"ref": branch},
            "state": state,
            "merged_at": "2026-01-01T00:00:00Z" if merged else None,
            "_files": files or [],
        })

    # ── call routing ─────────────────────────────────────────────────────────

    def __call__(self, *args, check=True, input_text=None):
        if self.intercept:
            result = self.intercept(args)
            if result is not None:
                return result
        if args[0] == "auth":
            return completed()
        if args[0] == "api" and args[1] == "graphql":
            return self._graphql(args)
        if args[0] == "api":
            return self._rest(args)
        return completed()

    @staticmethod
    def _parse_kv(args):
        fields = {}
        for flag, pair in zip(args, args[1:]):
            if flag not in ("-f", "-F") or "=" not in pair:
                continue
            key, value = pair.split("=", 1)
            if key.endswith("[]"):
                fields.setdefault(key[:-2], []).append(value)
            else:
                fields[key] = value
        return fields

    def _rest(self, args):
        path = args[1]
        method = "GET"
        if "-X" in args:
            method = args[args.index("-X") + 1]
        fields = self._parse_kv(args)
        path, _, query = path.partition("?")
        params = dict(p.split("=", 1) for p in query.split("&") if "=" in p)
        parts = path.strip("/").split("/")

        if parts[0] == "orgs" and parts[2:] == ["issue-types"]:
            names = self.issue_types.get(parts[1])
            if names is None:
                return completed(stderr="HTTP 404", returncode=1)
            return completed(json.dumps([{"name": n} for n in names]))

        if parts[0] != "repos":
            return completed(stderr=f"unhandled path {path}", returncode=1)
        repo, rest = "/".join(parts[1:3]), parts[3:]

        if not rest:
            return completed(json.dumps({"full_name": repo}))

        if rest == ["labels"] and method == "GET":
            return completed(json.dumps([{"name": n} for n in self.labels.get(repo, set())]))
        if rest == ["labels"] and method == "POST":
            self.labels.setdefault(repo, set()).add(fields["name"])
            self.writes.append(("create-label", (repo, fields["name"])))
            return completed(json.dumps({"name": fields["name"]}))

        if rest == ["issues"] and method == "GET":
            label = params.get("labels")
            issues = [
                i for i in self.issues.get(repo, {}).values()
                if not label or label in {l["name"] for l in i["labels"]}
            ]
            return completed(json.dumps(issues))
        if rest == ["issues"] and method == "POST":
            labels = fields.get("labels") or []
            issue = self.add_issue(repo, fields["title"], fields.get("body", ""), labels)
            self.writes.append(("create-issue", (repo, issue["number"], fields["title"])))
            return completed(json.dumps(issue))

        if len(rest) >= 2 and rest[0] == "issues":
            number = int(rest[1])
            issue = self.issues.get(repo, {}).get(number)
            if issue is None:
                return completed(stderr="HTTP 404", returncode=1)
            if len(rest) == 2 and method == "PATCH":
                for key in ("body", "state", "title"):
                    if key in fields:
                        issue[key] = fields[key]
                self.writes.append(("patch-issue", (repo, number, sorted(fields))))
                return completed(json.dumps(issue))
            if rest[2:] == ["sub_issues"]:
                child_id = int(fields["sub_issue_id"])
                child = next(
                    i["number"] for i in self.issues.get(repo, {}).values()
                    if i["id"] == child_id
                )
                self.parents[(repo, child)] = number
                self.writes.append(("sub-issue", (repo, number, child)))
                return completed(json.dumps({}))
            if rest[2:] == ["labels"]:
                for name in fields.get("labels") or []:
                    issue["labels"].append({"name": name})
                self.writes.append(("add-labels", (repo, number, fields.get("labels"))))
                return completed(json.dumps(issue["labels"]))
            if rest[2:] == ["comments"]:
                self.comments.append((repo, number, fields.get("body", "")))
                self.writes.append(("comment", (repo, number)))
                return completed(json.dumps({}))

        if rest == ["pulls"] and method == "GET":
            state = params.get("state", "open")
            pulls = [p for p in self.pulls.get(repo, []) if p["state"] == state]
            return completed(json.dumps(pulls))
        if len(rest) == 3 and rest[0] == "pulls" and rest[2] == "files":
            number = int(rest[1])
            for pull in self.pulls.get(repo, []):
                if pull["number"] == number:
                    return completed(json.dumps([{"filename": f} for f in pull["_files"]]))
            return completed(json.dumps([]))

        return completed(stderr=f"unhandled path {path}", returncode=1)

    def _graphql(self, args):
        query = next(p.split("=", 1)[1] for p in args if isinstance(p, str) and p.startswith("query="))
        variables = {
            k: v for k, v in self._parse_kv(args).items() if k != "query"
        }

        if "projectV2(number" in query:
            owner_type = "organization" if "organization(login" in query else "user"
            board = self.boards.get((variables["owner"], int(variables["number"])))
            if not board or board["owner_type"] != owner_type:
                return completed(json.dumps({"data": {owner_type: None}}))
            field_nodes = [
                {
                    "id": field["id"], "name": name,
                    "options": [
                        {"id": opt["id"], "name": opt_name,
                         "color": opt["color"], "description": opt["description"]}
                        for opt_name, opt in field["options"].items()
                    ],
                }
                for name, field in board["fields"].items()
            ]
            payload = {"projectV2": {"id": board["id"], "fields": {"nodes": field_nodes}}}
            return completed(json.dumps({"data": {owner_type: payload}}))

        if "items(first" in query:
            board = self._board_by_id(variables["projectId"])
            nodes = []
            for item_id, item in board["items"].items():
                node = {
                    "id": item_id,
                    "content": {
                        "number": item["number"],
                        "repository": {"nameWithOwner": item["repo"]},
                    },
                }
                for alias, field_name in FIELD_VALUE_RE.findall(query):
                    value = item["values"].get(field_name)
                    node[alias or "fieldValueByName"] = {"name": value} if value else None
                nodes.append(node)
            items = {"pageInfo": {"hasNextPage": False, "endCursor": ""}, "nodes": nodes}
            return completed(json.dumps({"data": {"node": {"items": items}}}))

        if "addProjectV2ItemById" in query:
            board = self._board_by_id(variables["projectId"])
            issue = self._issue_by_node(variables["contentId"])
            if issue is None:
                return completed(json.dumps({"data": {"addProjectV2ItemById": None}}))
            repo, found = issue
            item_id = f"ITEM_{variables['contentId']}"
            board["items"][item_id] = {"repo": repo, "number": found["number"], "values": {}}
            self.writes.append(("board-add", (board["id"], repo, found["number"])))
            return completed(json.dumps(
                {"data": {"addProjectV2ItemById": {"item": {"id": item_id}}}}
            ))

        if "updateProjectV2ItemFieldValue" in query:
            board = self._board_by_id(variables["projectId"])
            item = board["items"][variables["itemId"]]
            field_name, option_name = self._field_option(board, variables["fieldId"], variables["optionId"])
            item["values"][field_name] = option_name
            self.writes.append(("board-set", (variables["itemId"], field_name, option_name)))
            return completed(json.dumps({"data": {"updateProjectV2ItemFieldValue": {}}}))

        if "updateProjectV2Field" in query:
            board, field = self._field_by_id(variables["fieldId"])
            new_options = {}
            for opt_id, name in OPTION_NAME_RE.findall(query):
                existing = field["options"].get(name)
                new_options[name] = existing or {
                    "id": f"OPT_NEW_{len(new_options)}", "color": "GRAY", "description": "",
                }
            field["options"] = new_options
            self.writes.append(("field-options", (variables["fieldId"], sorted(new_options))))
            options = [{"id": o["id"], "name": n} for n, o in new_options.items()]
            return completed(json.dumps(
                {"data": {"updateProjectV2Field": {"projectV2Field": {"id": variables["fieldId"], "options": options}}}}
            ))

        return completed(stderr=f"unhandled graphql {query[:60]}", returncode=1)

    def _issue_by_node(self, node_id):
        for repo, issues in self.issues.items():
            for issue in issues.values():
                if issue["node_id"] == node_id:
                    return repo, issue
        return None

    def _board_by_id(self, project_id):
        return next(b for b in self.boards.values() if b["id"] == project_id)

    def _field_by_id(self, field_id):
        for board in self.boards.values():
            for field in board["fields"].values():
                if field["id"] == field_id:
                    return board, field
        raise KeyError(field_id)

    def _field_option(self, board, field_id, option_id):
        for name, field in board["fields"].items():
            if field["id"] != field_id:
                continue
            for opt_name, opt in field["options"].items():
                if opt["id"] == option_id:
                    return name, opt_name
        raise KeyError((field_id, option_id))


@pytest.fixture
def fake(monkeypatch):
    fake_gh = FakeGh()
    monkeypatch.setattr(bmad_issues, "run_gh", fake_gh)
    monkeypatch.setattr(bmad_issues.time, "sleep", lambda seconds: None)
    return fake_gh


# ── gh layer ─────────────────────────────────────────────────────────────────


class TestGhLayer:
    def test_paginated_merges_old_gh_page_concatenation(self, fake):
        fake.intercept = lambda args: completed('[{"n": 1}][{"n": 2}]')
        assert bmad_issues.gh_rest_paginated("repos/o/r/issues") == [{"n": 1}, {"n": 2}]

    def test_paginated_failure_returns_empty(self, fake):
        fake.intercept = lambda args: completed(stderr="HTTP 500", returncode=1)
        assert bmad_issues.gh_rest_paginated("repos/o/r/issues") == []


# ── issue mapping + upserts ──────────────────────────────────────────────────


class TestListSyncedIssues:
    def test_filters_by_marker_project(self, fake):
        fake.add_issue("o/meta", "A", bmad_issues.build_marker("1-1-a", "alpha"), ["bmad-delivery"])
        fake.add_issue("o/meta", "B", bmad_issues.build_marker("1-1-a", "beta"), ["bmad-delivery"])
        fake.add_issue("o/meta", "C", "no marker", ["bmad-delivery"])
        mapping = bmad_issues.list_synced_issues("o/meta", "bmad-delivery", "alpha")
        assert list(mapping) == ["1-1-a"]
        assert mapping["1-1-a"]["title"] == "A"

    def test_skips_pull_requests(self, fake):
        issue = fake.add_issue("o/meta", "PR", bmad_issues.build_marker("k", "alpha"), ["bmad-delivery"])
        issue["pull_request"] = {"url": "x"}
        assert bmad_issues.list_synced_issues("o/meta", "bmad-delivery", "alpha") == {}


class TestUpsertIssue:
    def test_create_includes_marker_and_links_parent(self, fake):
        parent = fake.add_issue("o/meta", "Root", "", ["bmad-delivery"])
        existing = {}
        issue = bmad_issues.upsert_issue(
            "o/meta", "1-1-a", "alpha", "Story", "body", ["bmad-delivery"], None,
            existing, parent, dry_run=False,
        )
        assert bmad_issues.build_marker("1-1-a", "alpha") in issue["body"]
        assert existing["1-1-a"] is issue
        assert fake.parents[("o/meta", issue["number"])] == parent["number"]

    def test_update_patches_changed_body_only(self, fake):
        marker = bmad_issues.build_marker("1-1-a", "alpha")
        issue = fake.add_issue("o/meta", "Story", f"{marker}\n\nold", ["bmad-delivery"])
        bmad_issues.upsert_issue(
            "o/meta", "1-1-a", "alpha", "Story", "new", ["bmad-delivery"], None,
            {"1-1-a": issue}, None, dry_run=False,
        )
        assert ("patch-issue", ("o/meta", issue["number"], ["body"])) in fake.writes
        fake.writes.clear()
        bmad_issues.upsert_issue(
            "o/meta", "1-1-a", "alpha", "Story", "new", ["bmad-delivery"], None,
            {"1-1-a": issue}, None, dry_run=False,
        )
        assert not [w for w in fake.writes if w[0] == "patch-issue"]

    def test_dry_run_creates_nothing(self, fake):
        issue = bmad_issues.upsert_issue(
            "o/meta", "1-1-a", "alpha", "Story", "body", ["bmad-delivery"], None,
            {}, None, dry_run=True,
        )
        assert issue is None
        assert fake.writes == []


class TestIssueState:
    def test_close_and_reopen(self, fake):
        issue = fake.add_issue("o/meta", "S", "", ["bmad-delivery"])
        bmad_issues.set_issue_state("o/meta", issue, should_close=True, dry_run=False)
        assert issue["state"] == "closed"
        bmad_issues.set_issue_state("o/meta", issue, should_close=False, dry_run=False)
        assert issue["state"] == "open"

    def test_orphans_are_never_reopened(self, fake):
        issue = fake.add_issue("o/meta", "S", "", ["bmad-delivery", "bmad-orphaned"], state="closed")
        bmad_issues.set_issue_state("o/meta", issue, should_close=False, dry_run=False)
        assert issue["state"] == "closed"
        assert fake.writes == []


class TestCloseOrphans:
    def test_vanished_key_closed_labeled_commented(self, fake):
        issue = fake.add_issue(
            "o/meta", "Old", bmad_issues.build_marker("1-9-old", "alpha"), ["bmad-delivery"]
        )
        board = bmad_issues.ProjectBoard.__new__(bmad_issues.ProjectBoard)
        board.dry_run = False
        board.project_id = None
        board.items = {}
        bmad_issues.close_orphans(
            "o/meta", {"1-9-old": issue}, prds=[], epics={}, stories=[],
            project_name="alpha", dry_run=False, board=board,
        )
        assert issue["state"] == "closed"
        assert "bmad-orphaned" in {l["name"] for l in issue["labels"]}
        assert fake.comments and fake.comments[0][1] == issue["number"]

    def test_already_orphaned_closed_issue_untouched(self, fake):
        issue = fake.add_issue(
            "o/meta", "Old", bmad_issues.build_marker("1-9-old", "alpha"),
            ["bmad-delivery", "bmad-orphaned"], state="closed",
        )
        board = bmad_issues.ProjectBoard.__new__(bmad_issues.ProjectBoard)
        board.dry_run = False
        board.project_id = None
        board.items = {}
        bmad_issues.close_orphans(
            "o/meta", {"1-9-old": issue}, prds=[], epics={}, stories=[],
            project_name="alpha", dry_run=False, board=board,
        )
        assert fake.writes == []


# ── ProjectBoard ─────────────────────────────────────────────────────────────


class TestProjectBoard:
    def test_loads_org_board_and_status_options(self, fake):
        fake.add_board(owner="org", number=7)
        board = bmad_issues.ProjectBoard("org", 7, dry_run=False)
        assert board.project_id
        assert "In Review" in board.status_options

    def test_falls_back_to_user_owner(self, fake):
        fake.add_board(owner="me", number=3, owner_type="user")
        board = bmad_issues.ProjectBoard("me", 3, dry_run=False)
        assert board.project_id

    def test_missing_board_warns_and_disables(self, fake):
        board = bmad_issues.ProjectBoard("org", 99, dry_run=False)
        assert board.project_id is None
        board.set_status("o/meta", 1, "I_x", "Done")  # no crash, no writes
        assert fake.writes == []

    def test_set_status_adds_item_then_skips_unchanged(self, fake):
        fake.add_board(owner="org", number=7)
        issue = fake.add_issue("o/meta", "S", "", ["bmad-delivery"])
        board = bmad_issues.ProjectBoard("org", 7, dry_run=False)
        board.set_status("o/meta", issue["number"], issue["node_id"], "Ready")
        assert [w[0] for w in fake.writes] == ["board-add", "board-set"]
        fake.writes.clear()
        board.set_status("o/meta", issue["number"], issue["node_id"], "Ready")
        assert fake.writes == []

    def test_prefetched_status_skips_write(self, fake):
        board_state = fake.add_board(owner="org", number=7)
        issue = fake.add_issue("o/meta", "S", "", ["bmad-delivery"])
        board_state["items"]["ITEM_X"] = {
            "repo": "o/meta", "number": issue["number"], "values": {"Status": "Done"},
        }
        board = bmad_issues.ProjectBoard("org", 7, dry_run=False)
        board.set_status("o/meta", issue["number"], issue["node_id"], "Done")
        assert fake.writes == []

    def test_unknown_status_option_warns_without_write(self, fake):
        fake.add_board(owner="org", number=7, fields={"Status": ["Backlog", "Done"]})
        issue = fake.add_issue("o/meta", "S", "", ["bmad-delivery"])
        board = bmad_issues.ProjectBoard("org", 7, dry_run=False)
        board.set_status("o/meta", issue["number"], issue["node_id"], "In Review")
        assert fake.writes == []


# ── end-to-end sync against artifacts on disk ────────────────────────────────


SPRINT_YAML = """\
project: Alpha
development_status:
  epic-1: in-progress
  1-1-login: done
  1-2-profile: in-progress
  epic-2: backlog
"""

EPICS_MD = """\
## Epic 1: Accounts
Account management.

### Story 1.1: Login
Login story body.

### Story 1.2: Profile
Profile story body.

## Epic 2: Future
Placeholder epic with no stories yet.
"""


@pytest.fixture
def metarepo(fake, tmp_path, monkeypatch):
    """A minimal metarepo with one project (alpha) wired to a fake board."""
    monkeypatch.setattr(bmad_issues, "REPO_ROOT", tmp_path)
    monkeypatch.setattr(bmad_issues, "PROJECTS_DIR", tmp_path / "projects")
    monkeypatch.setattr(bmad_issues, "ACTIVE_FILE", tmp_path / "active-project.txt")
    monkeypatch.setenv("BMAD_METAREPO_SLUG", "org/meta")
    monkeypatch.setenv("BMAD_OUTPUT_FOLDER", "features")

    project = tmp_path / "projects" / "alpha"
    planning = project / "features" / "planning-artifacts"
    implementation = project / "features" / "implementation-artifacts"
    planning.mkdir(parents=True)
    implementation.mkdir(parents=True)
    (project / "github-sync.yaml").write_text("project: 7\nproject_owner: org\n")
    (project / "repos.yaml").write_text(
        "repos:\n  - name: web\n    url: git@github.com:org/web.git\n"
    )
    (implementation / "sprint-status.yaml").write_text(SPRINT_YAML)
    (planning / "epics.md").write_text(EPICS_MD)
    prd_dir = planning / "prds" / "prd-alpha-2026-01-10"
    prd_dir.mkdir(parents=True)
    (prd_dir / "prd.md").write_text("---\ntitle: Alpha MVP\nstatus: final\n---\n# PRD\n")

    fake.add_board(owner="org", number=7)
    return tmp_path


class TestSyncEndToEnd:
    def board_statuses(self, fake):
        board = fake.boards[("org", 7)]
        titles = {
            (i["repo"], i["number"]): i["values"].get("Status")
            for i in board["items"].values()
        }
        by_number = {n: issue["title"] for n, issue in fake.issues["org/meta"].items()}
        return {by_number[number]: status for (_, number), status in titles.items()}

    def test_full_sync_creates_tree_and_statuses(self, fake, metarepo):
        bmad_issues.sync_project("alpha", dry_run=False)

        titles = {i["title"] for i in fake.issues["org/meta"].values()}
        assert "Delivery: Alpha" in titles
        assert "Feature: Alpha MVP" in titles
        assert "Epic 1: Accounts" in titles
        assert "Epic 2: Future" in titles
        assert "Story 1.1: Login" in titles
        assert "Planning: alpha" in titles

        by_title = {i["title"]: i for i in fake.issues["org/meta"].values()}
        assert by_title["Story 1.1: Login"]["state"] == "closed"
        assert by_title["Story 1.2: Profile"]["state"] == "open"
        # Stories hang off their epic, epics off the current feature.
        story = by_title["Story 1.2: Profile"]
        epic = by_title["Epic 1: Accounts"]
        feature = by_title["Feature: Alpha MVP"]
        assert fake.parents[("org/meta", story["number"])] == epic["number"]
        assert fake.parents[("org/meta", epic["number"])] == feature["number"]

        statuses = self.board_statuses(fake)
        assert statuses["Story 1.1: Login"] == "Done"
        assert statuses["Story 1.2: Profile"] == "In Progress"
        assert statuses["Epic 2: Future"] == "Backlog"  # zero-story epic (bug 1c)
        assert statuses["Planning: alpha"] == "In Progress"

    def test_second_run_writes_nothing(self, fake, metarepo):
        bmad_issues.sync_project("alpha", dry_run=False)
        fake.writes.clear()
        bmad_issues.sync_project("alpha", dry_run=False)
        # Sub-issue re-links are idempotent server-side; everything else must
        # be silent on an unchanged second run.
        noisy = [w for w in fake.writes if w[0] != "sub-issue"]
        assert noisy == []

    def test_open_story_pr_forces_in_review_and_links(self, fake, metarepo):
        fake.add_pull("org/web", 12, "story/1-2-profile", state="open")
        bmad_issues.sync_project("alpha", dry_run=False)
        statuses = self.board_statuses(fake)
        assert statuses["Story 1.2: Profile"] == "In Review"
        by_title = {i["title"]: i for i in fake.issues["org/meta"].values()}
        assert "org/web#12" in by_title["Story 1.2: Profile"]["body"]

    def test_other_projects_story_branches_ignored(self, fake, metarepo):
        # A PR in the shared metarepo (defaulted issues repo) must not match.
        fake.add_pull("org/meta", 5, "story/1-2-profile", state="open")
        bmad_issues.sync_project("alpha", dry_run=False)
        assert self.board_statuses(fake)["Story 1.2: Profile"] == "In Progress"

    def test_dry_run_writes_nothing(self, fake, metarepo):
        bmad_issues.sync_project("alpha", dry_run=True)
        assert fake.writes == []
