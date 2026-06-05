"""
Tests for bmad-issues.py — sprint-to-issue sync logic.

Tests the parsing, collection, and writeback logic. Does NOT test
actual GitHub API calls (those need gh CLI auth).
"""

from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
import yaml

# Import the sync module
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))
import importlib
bmad_issues = importlib.import_module("bmad-issues")


# ── collect_stories ──────────────────────────────────────────────────────────


class TestCollectStories:
    def test_nested_epics_and_stories(self):
        data = {
            "current_sprint": 1,
            "epics": [
                {
                    "id": "epic-1",
                    "title": "Pantry CRUD",
                    "status": "in-progress",
                    "stories": [
                        {"id": "STORY-001", "title": "Create API", "status": "ready"},
                        {"id": "STORY-002", "title": "Delete API", "status": "draft"},
                    ],
                }
            ],
        }
        stories = bmad_issues.collect_stories(data)
        assert len(stories) == 3  # 1 epic + 2 stories
        assert stories[0]["type"] == "epic"
        assert stories[0]["id"] == "epic-1"
        assert stories[1]["id"] == "STORY-001"
        assert stories[1]["epic_id"] == "epic-1"
        assert stories[2]["status"] == "draft"

    def test_flat_stories(self):
        data = {
            "current_sprint": 2,
            "stories": [
                {"id": "BUG-001", "title": "Fix crash", "status": "ready", "type": "bug"},
            ],
        }
        stories = bmad_issues.collect_stories(data)
        assert len(stories) == 1
        assert stories[0]["type"] == "bug"
        assert stories[0]["sprint"] == 2

    def test_empty_data(self):
        assert bmad_issues.collect_stories({}) == []
        assert bmad_issues.collect_stories(None) == []

    def test_mixed_epics_and_flat(self):
        data = {
            "current_sprint": 1,
            "epics": [
                {
                    "id": "epic-1",
                    "title": "E1",
                    "status": "active",
                    "stories": [
                        {"id": "S-1", "title": "Story 1", "status": "ready"},
                    ],
                }
            ],
            "stories": [
                {"id": "S-2", "title": "Standalone", "status": "todo"},
            ],
        }
        stories = bmad_issues.collect_stories(data)
        assert len(stories) == 3  # epic + nested story + flat story

    def test_sprint_propagated(self):
        data = {"current_sprint": 5, "epics": [{"id": "e", "title": "E", "status": "x", "stories": []}]}
        stories = bmad_issues.collect_stories(data)
        assert stories[0]["sprint"] == 5

    def test_github_issue_preserved(self):
        data = {
            "epics": [
                {
                    "id": "epic-1",
                    "title": "E",
                    "status": "active",
                    "github_issue": 42,
                    "stories": [
                        {"id": "S-1", "title": "S", "status": "ready", "github_issue": 43},
                    ],
                }
            ]
        }
        stories = bmad_issues.collect_stories(data)
        assert stories[0]["github_issue"] == 42
        assert stories[1]["github_issue"] == 43


# ── Markers ──────────────────────────────────────────────────────────────────


class TestMarkers:
    def test_build_marker(self):
        m = bmad_issues.build_marker("food-inventory", "STORY-001")
        assert m == "<!-- bmad-sync:STORY-001:food-inventory -->"

    def test_marker_regex(self):
        text = "<!-- bmad-sync:STORY-001:food-inventory -->"
        match = bmad_issues.MARKER_RE.search(text)
        assert match
        assert match.group(1) == "STORY-001"
        assert match.group(2) == "food-inventory"

    def test_marker_in_body(self):
        body = "<!-- bmad-sync:BUG-005:my-app -->\n\n# Bug report\nSomething broke."
        match = bmad_issues.MARKER_RE.search(body)
        assert match.group(1) == "BUG-005"


# ── Status classification ────────────────────────────────────────────────────


class TestStatusClassification:
    def test_open_statuses(self):
        for s in ["ready", "todo", "in-progress", "in_progress", "active", "planned"]:
            assert s in bmad_issues.OPEN_STATUSES

    def test_close_statuses(self):
        for s in ["done", "complete", "completed", "shipped", "cancelled"]:
            assert s in bmad_issues.CLOSE_STATUSES

    def test_skip_statuses(self):
        for s in ["draft", "backlog", "deferred"]:
            assert s in bmad_issues.SKIP_STATUSES

    def test_no_overlap(self):
        assert not bmad_issues.OPEN_STATUSES & bmad_issues.CLOSE_STATUSES
        assert not bmad_issues.OPEN_STATUSES & bmad_issues.SKIP_STATUSES
        assert not bmad_issues.CLOSE_STATUSES & bmad_issues.SKIP_STATUSES


# ── write_back_issues ────────────────────────────────────────────────────────


class TestWriteBack:
    def test_writes_issue_numbers(self, tmp_path):
        data = {
            "epics": [
                {
                    "id": "epic-1",
                    "title": "E",
                    "status": "active",
                    "stories": [
                        {"id": "S-1", "title": "S1", "status": "ready"},
                        {"id": "S-2", "title": "S2", "status": "ready"},
                    ],
                }
            ]
        }
        yaml_path = tmp_path / "sprint-status.yaml"
        with open(yaml_path, "w") as f:
            yaml.dump(data, f)

        issue_map = {"epic-1": 10, "S-1": 11, "S-2": 12}
        modified = bmad_issues.write_back_issues(yaml_path, data, issue_map)

        assert modified
        assert data["epics"][0]["github_issue"] == 10
        assert data["epics"][0]["stories"][0]["github_issue"] == 11
        assert data["epics"][0]["stories"][1]["github_issue"] == 12

        # Verify file was written
        reloaded = yaml.safe_load(yaml_path.read_text())
        assert reloaded["epics"][0]["github_issue"] == 10

    def test_no_change_when_already_set(self, tmp_path):
        data = {
            "epics": [
                {
                    "id": "epic-1",
                    "title": "E",
                    "status": "active",
                    "github_issue": 10,
                    "stories": [],
                }
            ]
        }
        yaml_path = tmp_path / "sprint-status.yaml"
        with open(yaml_path, "w") as f:
            yaml.dump(data, f)

        modified = bmad_issues.write_back_issues(yaml_path, data, {"epic-1": 10})
        assert not modified

    def test_flat_stories_writeback(self, tmp_path):
        data = {
            "stories": [
                {"id": "S-1", "title": "S", "status": "ready"},
            ]
        }
        yaml_path = tmp_path / "sprint-status.yaml"
        with open(yaml_path, "w") as f:
            yaml.dump(data, f)

        modified = bmad_issues.write_back_issues(yaml_path, data, {"S-1": 99})
        assert modified
        assert data["stories"][0]["github_issue"] == 99


# ── read_story_file ──────────────────────────────────────────────────────────


class TestReadStoryFile:
    def test_reads_markdown(self, tmp_path):
        story = tmp_path / "STORY-001.md"
        story.write_text("# Story\n\nDo the thing.")
        result = bmad_issues.read_story_file(tmp_path, "STORY-001.md")
        assert "Do the thing" in result

    def test_strips_frontmatter(self, tmp_path):
        story = tmp_path / "STORY-001.md"
        story.write_text("---\ntitle: Test\n---\n# Story\n\nContent here.")
        result = bmad_issues.read_story_file(tmp_path, "STORY-001.md")
        assert "title: Test" not in result
        assert "Content here" in result

    def test_missing_file(self, tmp_path):
        result = bmad_issues.read_story_file(tmp_path, "nonexistent.md")
        assert result is None

    def test_nested_path(self, tmp_path):
        nested = tmp_path / "planning-artifacts" / "epics"
        nested.mkdir(parents=True)
        story = nested / "STORY-001.md"
        story.write_text("# Nested story")
        result = bmad_issues.read_story_file(tmp_path, "planning-artifacts/epics/STORY-001.md")
        assert "Nested story" in result


# ── resolve_output_folder ────────────────────────────────────────────────────


class TestResolveOutputFolder:
    def test_finds_features(self, tmp_path):
        (tmp_path / "features" / "implementation-artifacts").mkdir(parents=True)
        (tmp_path / "features" / "implementation-artifacts" / "sprint-status.yaml").write_text("x: 1")
        assert bmad_issues.resolve_output_folder(tmp_path) == "features"

    def test_finds_bmad_output(self, tmp_path):
        (tmp_path / "_bmad-output" / "implementation-artifacts").mkdir(parents=True)
        (tmp_path / "_bmad-output" / "implementation-artifacts" / "sprint-status.yaml").write_text("x: 1")
        assert bmad_issues.resolve_output_folder(tmp_path) == "_bmad-output"

    def test_returns_none_when_missing(self, tmp_path):
        assert bmad_issues.resolve_output_folder(tmp_path) is None


# ── sync_story milestone-strip regression ────────────────────────────────────


class TestSyncStoryMilestoneStrip:
    """Regression test for M1: milestone stripped by value equality.

    Before the fix, create_args was filtered with:
        [a for a in create_args if a != "--milestone" and a != milestone]

    If the story title equalled the milestone string, that filter also
    removed the "--title" value, leaving gh issue create without a title.

    After the fix the --milestone <value> PAIR is removed by index, so
    any other arg that happens to share the milestone's text is untouched.
    """

    def _make_story(self, title):
        return {
            "id": "STORY-001",
            "title": title,
            "status": "ready",
            "type": "story",
            "file": None,
            "sprint": 1,
            "github_issue": None,
        }

    def _make_config(self, milestone_prefix="Sprint"):
        return {
            "repo": "owner/repo",
            "labels": {"story": "story"},
            "milestone_prefix": milestone_prefix,
        }

    def test_milestone_pair_removed_but_title_survives_when_title_equals_milestone(
        self, tmp_path
    ):
        """The story title equals the milestone string.

        The first gh call (with --milestone) fails with a milestone error.
        The retry must NOT strip --title's value even though it equals the
        milestone string.
        """
        milestone_value = "Sprint 1"
        story = self._make_story(milestone_value)  # title == milestone
        config = self._make_config()

        milestone_error = SimpleNamespace(
            returncode=1,
            stdout="",
            stderr="could not find milestone 'Sprint 1'",
        )
        success_result = SimpleNamespace(
            returncode=0,
            stdout="https://github.com/owner/repo/issues/7\n",
            stderr="",
        )

        captured_retry_args = []

        def fake_run_gh(*args, check=True):
            # First call — the one that includes --milestone — should fail.
            if "--milestone" in args:
                return milestone_error
            # Subsequent calls (the retry) succeed; record what was passed.
            captured_retry_args.extend(args)
            return success_result

        with patch.object(bmad_issues, "run_gh", side_effect=fake_run_gh):
            # find_existing_issue must also be patched so we take the
            # create-new-issue branch rather than the update branch.
            with patch.object(bmad_issues, "find_existing_issue", return_value=None):
                issue_num = bmad_issues.sync_story(
                    story,
                    project_name="test-project",
                    project_dir=tmp_path,
                    config=config,
                )

        assert issue_num == 7, "Expected issue #7 from the retry call"

        # --milestone and its value must be absent from the retry args.
        assert "--milestone" not in captured_retry_args
        assert milestone_value not in captured_retry_args or (
            "--title" in captured_retry_args
            and captured_retry_args[captured_retry_args.index("--title") + 1]
            == milestone_value
        ), (
            "The title arg should survive even though it equals the milestone value"
        )

        # More direct assertion: --title followed by the milestone_value must
        # still be present in the retry args.
        assert "--title" in captured_retry_args
        title_pos = captured_retry_args.index("--title")
        assert captured_retry_args[title_pos + 1] == milestone_value
