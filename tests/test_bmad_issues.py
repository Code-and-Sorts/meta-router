"""
Tests for bmad-issues.py — BMad v6 artifact parsing and sync derivation.

Covers the pure logic: development_status classification, epics.md joins,
status mapping, planning checklist, orphan detection, and marker parsing.
Does NOT test GitHub API calls (those need gh CLI auth).
"""

from pathlib import Path

import sys
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "skills" / "meta-router" / "scripts"))
import importlib
bmad_issues = importlib.import_module("bmad-issues")


SPRINT_MAP = {
    "epic-1": "in-progress",
    "1-1-user-authentication": "done",
    "1-2-account-management": "ready-for-dev",
    "epic-1-retrospective": "optional",
    "epic-2": "backlog",
    "2-1-personality-system": "drafted",
    "2-2-chat-interface": "backlog",
    "epic-2-retrospective": "optional",
}

EPICS_MD = """\
# Plant App - Epic Breakdown

## Epic List

## Epic 1: User Accounts
Users can register and manage accounts.

### Story 1.1: User Authentication
As a user, I want to log in, so that my data is private.

**Acceptance Criteria:**
**Given** a registered user **When** they log in **Then** they see their data.

### Story 1.2: Account Management
As a user, I want to edit my profile.

## Epic 2: Personality
Chat personality for plants.

### Story 2.1: Personality System
As a plant owner, I want my plant to have a personality.
"""


class TestClassifyDevelopmentStatus:
    def test_splits_epics_stories_and_skips_retrospectives(self):
        epics, stories = bmad_issues.classify_development_status(SPRINT_MAP)
        assert sorted(epics) == [1, 2]
        assert epics[1] == {"key": "epic-1", "status": "in-progress"}
        keys = [s["key"] for s in stories]
        assert "epic-1-retrospective" not in keys
        assert len(stories) == 4

    def test_story_epic_join_numbers(self):
        _, stories = bmad_issues.classify_development_status(SPRINT_MAP)
        by_key = {s["key"]: s for s in stories}
        assert by_key["1-2-account-management"]["epic"] == 1
        assert by_key["1-2-account-management"]["story"] == 2
        assert by_key["2-1-personality-system"]["epic"] == 2

    def test_nonconforming_key_treated_as_epicless_story(self):
        epics, stories = bmad_issues.classify_development_status(
            {"hotfix-login": "in-progress"}
        )
        assert epics == {}
        assert stories[0]["epic"] is None

    def test_empty_input(self):
        assert bmad_issues.classify_development_status({}) == ({}, [])
        assert bmad_issues.classify_development_status(None) == ({}, [])


class TestParseEpicsDoc:
    def test_titles_and_goals(self):
        epics, _ = bmad_issues.parse_epics_doc(EPICS_MD)
        assert epics[1]["title"] == "User Accounts"
        assert "register and manage accounts" in epics[1]["goal"]
        assert "Story 1.1" not in epics[1]["goal"]

    def test_story_titles_and_bodies(self):
        _, stories = bmad_issues.parse_epics_doc(EPICS_MD)
        assert stories[(1, 1)]["title"] == "User Authentication"
        assert "Acceptance Criteria" in stories[(1, 1)]["body"]
        assert "Account Management" not in stories[(1, 1)]["body"]
        assert "Epic 2" not in stories[(1, 2)]["body"]

    def test_empty_doc(self):
        assert bmad_issues.parse_epics_doc(None) == ({}, {})
        assert bmad_issues.parse_epics_doc("") == ({}, {})


class TestStatusMapping:
    def test_sprint_statuses_map_to_board_columns(self):
        cases = {
            "backlog": "Backlog",
            "ready-for-dev": "Ready",
            "drafted": "Ready",
            "in-progress": "In Progress",
            "contexted": "In Progress",
            "review": "In Review",
            "done": "Done",
        }
        for sprint, expected in cases.items():
            assert bmad_issues.effective_story_status(sprint, "1-1-x", {}) == expected

    def test_open_pr_forces_in_review(self):
        open_keys = {"1-2-account-management"}
        assert (
            bmad_issues.effective_story_status(
                "in-progress", "1-2-account-management", open_keys
            )
            == "In Review"
        )

    def test_done_wins_over_open_pr(self):
        assert bmad_issues.effective_story_status("done", "1-1-x", {"1-1-x"}) == "Done"

    def test_unknown_status_falls_back_to_backlog(self):
        assert bmad_issues.effective_story_status("weird", "1-1-x", set()) == "Backlog"


class TestPrLinking:
    PRS = [
        {"url": "https://github.com/o/web/pull/12", "repo": "o/web", "number": 12, "state": "open"},
        {"url": "https://github.com/o/api/pull/7", "repo": "o/api", "number": 7, "state": "merged"},
    ]

    def test_pr_section_lists_all_prs_sorted_by_repo(self):
        section = bmad_issues.build_pr_section(self.PRS)
        assert "## Pull Requests" in section
        assert section.index("o/api#7") < section.index("o/web#12")
        assert "(https://github.com/o/web/pull/12)" in section
        assert "merged" in section and "open" in section

    def test_empty_prs_add_no_section(self):
        assert bmad_issues.build_pr_section([]) == ""

    def test_open_pr_key_derivation(self):
        prs_by_key = {
            "1-1-a": [{"state": "merged"}, {"state": "open"}],
            "1-2-b": [{"state": "merged"}],
            "1-3-c": [{"state": "closed"}],
        }
        assert bmad_issues.keys_with_open_prs(prs_by_key) == {"1-1-a"}


class TestPlanning:
    def test_checklist_body(self):
        docs = [("PRD", True, True), ("UX Spec", False, False)]
        body = bmad_issues.build_planning_body("alpha", docs)
        assert "- [x] PRD" in body
        assert "- [ ] UX Spec _(optional)_" in body

    def test_status_progression(self):
        none = [("PRD", False, True), ("Architecture", False, True)]
        some = [("PRD", True, True), ("Architecture", False, True)]
        done = [("PRD", True, True), ("Architecture", True, True)]
        assert bmad_issues.planning_status(none, False) == ("Backlog", False)
        assert bmad_issues.planning_status(some, False) == ("In Progress", False)
        assert bmad_issues.planning_status(some, True) == ("In Review", False)
        assert bmad_issues.planning_status(done, False) == ("Done", True)

    def test_detect_planning_docs(self, tmp_path):
        (tmp_path / "prds" / "prd-app-2026").mkdir(parents=True)
        (tmp_path / "prds" / "prd-app-2026" / "prd.md").write_text("# PRD")
        (tmp_path / "epics.md").write_text("# Epics")
        docs = {name: exists for name, exists, _ in bmad_issues.detect_planning_docs(tmp_path)}
        assert docs["PRD"] is True
        assert docs["Epic & Story breakdown"] is True
        assert docs["Architecture"] is False

    def test_detect_handles_missing_dir(self, tmp_path):
        docs = bmad_issues.detect_planning_docs(tmp_path / "nope")
        assert all(exists is False for _, exists, _ in docs)


class TestFeatures:
    def make_prd(self, planning_dir, folder, title, status):
        run_dir = planning_dir / "prds" / folder
        run_dir.mkdir(parents=True)
        (run_dir / "prd.md").write_text(
            f"---\ntitle: {title}\nstatus: {status}\n---\n# {title}\n"
        )

    def test_one_feature_per_prd_with_newest_current(self, tmp_path):
        planning = tmp_path / "features" / "planning-artifacts"
        self.make_prd(planning, "prd-app-2026-01-10", "Inventory v1", "final")
        self.make_prd(planning, "prd-app-2026-05-02", "Inventory v2", "draft")
        prds = bmad_issues.find_prds(planning)
        assert len(prds) == 2
        assert prds[0]["title"] == "Inventory v1"
        assert prds[0]["current"] is False
        assert prds[1]["title"] == "Inventory v2"
        assert prds[1]["current"] is True
        assert prds[1]["key"] == "feature-prd-app-2026-05-02"
        assert prds[1]["status"] == "draft"

    def test_date_outranks_name_for_current_prd(self, tmp_path):
        # Alphabetically "prd-zebra-..." sorts last, but "prd-app-..." is newer.
        planning = tmp_path / "features" / "planning-artifacts"
        self.make_prd(planning, "prd-zebra-2026-01-10", "Zebra", "final")
        self.make_prd(planning, "prd-app-2026-05-02", "App", "draft")
        prds = bmad_issues.find_prds(planning)
        assert [p["title"] for p in prds] == ["Zebra", "App"]
        assert prds[1]["current"] is True

    def test_compact_date_suffix(self, tmp_path):
        planning = tmp_path / "features" / "planning-artifacts"
        self.make_prd(planning, "prd-zebra-20260110", "Zebra", "final")
        self.make_prd(planning, "prd-app-2026-05-02", "App", "draft")
        prds = bmad_issues.find_prds(planning)
        assert prds[-1]["title"] == "App"
        assert prds[-1]["current"] is True

    def test_undated_folders_sort_before_dated(self, tmp_path):
        planning = tmp_path / "features" / "planning-artifacts"
        self.make_prd(planning, "prd-scratch", "Scratch", "draft")
        self.make_prd(planning, "prd-app-2026-01-10", "App", "final")
        prds = bmad_issues.find_prds(planning)
        assert prds[-1]["title"] == "App"
        assert prds[-1]["current"] is True

    def test_prd_sort_key(self):
        assert bmad_issues.prd_sort_key("prd-app-2026-05-02") == (True, "2026-05-02", "prd-app-2026-05-02")
        assert bmad_issues.prd_sort_key("prd-app-20260502")[1] == "2026-05-02"
        assert bmad_issues.prd_sort_key("prd-app") == (False, "", "prd-app")

    def test_bare_prd_file_fallback(self, tmp_path):
        planning = tmp_path / "features" / "planning-artifacts"
        planning.mkdir(parents=True)
        (planning / "PRD.md").write_text("# Untitled PRD\n")
        prds = bmad_issues.find_prds(planning)
        assert len(prds) == 1
        assert prds[0]["current"] is True
        assert prds[0]["key"] == "feature-prd"
        assert prds[0]["status"] == "draft"

    def test_no_prds(self, tmp_path):
        assert bmad_issues.find_prds(tmp_path / "missing") == []

    def test_frontmatter_parsing(self):
        assert bmad_issues.parse_frontmatter("---\ntitle: X\n---\nbody")["title"] == "X"
        assert bmad_issues.parse_frontmatter("no frontmatter") == {}
        assert bmad_issues.parse_frontmatter("---\n: bad: [yaml\n---\n") == {}


class TestMarkers:
    def test_marker_roundtrip(self):
        marker = bmad_issues.build_marker("1-2-account-management", "alpha")
        match = bmad_issues.MARKER_RE.search(f"prefix\n{marker}\nbody")
        assert match.group(1) == "1-2-account-management"
        assert match.group(2) == "alpha"


class TestHelpers:
    def test_humanize_key(self):
        assert bmad_issues.humanize_key("1-2-account-management") == "Account Management"
        assert bmad_issues.humanize_key("hotfix") == "Hotfix"

    def test_repo_slug_from_url(self):
        cases = {
            "git@github.com:org/repo.git": "org/repo",
            "https://github.com/org/repo": "org/repo",
            "https://github.com/org/repo.git": "org/repo",
            "not-a-url": None,
        }
        for url, expected in cases.items():
            assert bmad_issues.repo_slug_from_url(url) == expected

    def test_strip_project_root(self):
        assert bmad_issues.strip_project_root('"{project-root}/features"') == "features"
        assert bmad_issues.strip_project_root("docs") == "docs"


class TestOrphanDetection:
    def test_vanished_key_is_not_in_live_set(self):
        epics, stories = bmad_issues.classify_development_status(
            {"epic-1": "backlog", "1-1-new-name": "backlog"}
        )
        live = {bmad_issues.DELIVERY_ROOT_KEY}
        live.update(e["key"] for e in epics.values())
        live.update(s["key"] for s in stories)
        assert "1-1-old-name" not in live
        assert "1-1-new-name" in live
        assert "epic-1" in live


class TestSourceRepoScoping:
    REPOS_YAML = """\
repos:
  - name: web
    url: git@github.com:org/web.git
  - name: api
    url: https://github.com/org/api
"""

    def test_defaulted_issues_repo_is_not_scanned(self, tmp_path):
        (tmp_path / "repos.yaml").write_text(self.REPOS_YAML)
        config = {"repo": "org/metarepo", "repo_explicit": False}
        assert bmad_issues.load_source_repos(tmp_path, config) == ["org/web", "org/api"]

    def test_explicit_issues_repo_is_scanned(self, tmp_path):
        (tmp_path / "repos.yaml").write_text(self.REPOS_YAML)
        config = {"repo": "org/web-issues", "repo_explicit": True}
        assert bmad_issues.load_source_repos(tmp_path, config) == [
            "org/web", "org/api", "org/web-issues",
        ]

    def test_explicit_repo_already_in_repos_yaml_not_duplicated(self, tmp_path):
        (tmp_path / "repos.yaml").write_text(self.REPOS_YAML)
        config = {"repo": "org/web", "repo_explicit": True}
        assert bmad_issues.load_source_repos(tmp_path, config) == ["org/web", "org/api"]

    def test_no_repos_yaml_and_defaulted_repo_scans_nothing(self, tmp_path):
        config = {"repo": "org/metarepo", "repo_explicit": False}
        assert bmad_issues.load_source_repos(tmp_path, config) == []


class TestFindEpicsDoc:
    def test_prefers_whole_doc(self, tmp_path):
        (tmp_path / "epics.md").write_text("# Whole")
        (tmp_path / "epics").mkdir()
        (tmp_path / "epics" / "index.md").write_text("# Sharded")
        assert "Whole" in bmad_issues.find_epics_doc(tmp_path)

    def test_sharded_fallback(self, tmp_path):
        (tmp_path / "epics").mkdir()
        (tmp_path / "epics" / "index.md").write_text("# Index")
        (tmp_path / "epics" / "epic-1.md").write_text("## Epic 1: One")
        text = bmad_issues.find_epics_doc(tmp_path)
        assert "Index" in text and "Epic 1" in text

    def test_missing_dir(self, tmp_path):
        assert bmad_issues.find_epics_doc(tmp_path / "nope") is None
