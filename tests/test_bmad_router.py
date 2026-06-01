"""
Tests for bmad-router.sh — multi-project context switcher for BMAD metarepos.
Default output folder: "features". Default docs folder: "docs".
"""

import os
import shutil
import subprocess
from pathlib import Path

import pytest

SCRIPT_REL = Path("scripts") / "bmad-router.sh"


@pytest.fixture()
def metarepo(tmp_path: Path) -> Path:
    (tmp_path / "_bmad" / "bmm" / "agents").mkdir(parents=True)
    (tmp_path / "_bmad" / "core" / "tasks").mkdir(parents=True)
    (tmp_path / "projects").mkdir()
    (tmp_path / ".agents" / "skills" / "shared").mkdir(parents=True)
    (tmp_path / ".agents" / "knowledge").mkdir(parents=True)

    scripts_dir = tmp_path / "scripts"
    scripts_dir.mkdir()
    src_script = Path(__file__).resolve().parent.parent / "scripts" / "bmad-router.sh"
    (scripts_dir / "bmad-router.sh").write_text(src_script.read_text())
    (scripts_dir / "bmad-router.sh").chmod(0o755)
    (tmp_path / "AGENTS.md").write_text("# Test metarepo\n")

    return tmp_path


def run(metarepo, *args, expect_fail=False, env=None):
    run_env = os.environ.copy()
    if env:
        run_env.update(env)
    result = subprocess.run(
        ["bash", str(metarepo / SCRIPT_REL), *args],
        cwd=metarepo, capture_output=True, text=True, env=run_env,
    )
    if not expect_fail:
        assert result.returncode == 0, (
            f"bmad-router {' '.join(args)} failed (rc={result.returncode}):\n"
            f"stdout: {result.stdout}\nstderr: {result.stderr}"
        )
    return result


def add_project_skill(metarepo, project, skill_name):
    skill_dir = metarepo / "projects" / project / ".agents" / "skills" / skill_name
    skill_dir.mkdir(parents=True, exist_ok=True)
    (skill_dir / "SKILL.md").write_text(f"# {skill_name}\n")
    return skill_dir


GIT_ENV = {
    "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t",
    "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
}


def make_source_repo(tmp_path, name):
    """Create a real local git repo to act as a cloneable source remote."""
    src = tmp_path / f"source-{name}"
    src.mkdir()
    env = {**os.environ, **GIT_ENV}
    subprocess.run(["git", "init", "-q", "-b", "main"], cwd=src, check=True, env=env)
    (src / "README.md").write_text(f"# {name}\n")
    subprocess.run(["git", "add", "."], cwd=src, check=True, env=env)
    subprocess.run(["git", "commit", "-qm", "init"], cwd=src, check=True, env=env)
    return src


def write_repos_yaml(metarepo, project, repos):
    """repos: list of (name, source_path) tuples."""
    lines = ["repos:"]
    for name, src in repos:
        lines += [
            f"  - name: {name}",
            f"    url: file://{src}",
            "    branch: main",
        ]
    (metarepo / "projects" / project / "repos.yaml").write_text("\n".join(lines) + "\n")


def git_branch(path):
    return subprocess.run(
        ["git", "rev-parse", "--abbrev-ref", "HEAD"],
        cwd=path, capture_output=True, text=True,
    ).stdout.strip()


# ── Init ─────────────────────────────────────────────────────────────────────

class TestInit:
    def test_creates_project_directory(self, metarepo):
        run(metarepo, "init", "alpha")
        project = metarepo / "projects" / "alpha"
        assert (project / "repos").is_dir()
        assert (project / "implementation").is_dir()
        assert (project / "repos.yaml").is_file()
        assert not (project / "src").exists()

    def test_scaffolds_features_folder(self, metarepo):
        """Default output folder is 'features'."""
        run(metarepo, "init", "alpha")
        out = metarepo / "projects" / "alpha" / "features"
        assert (out / "planning-artifacts" / "epics").is_dir()
        assert (out / "implementation-artifacts").is_dir()

    def test_scaffolds_docs_folder(self, metarepo):
        run(metarepo, "init", "alpha")
        assert (metarepo / "projects" / "alpha" / "docs").is_dir()
        assert (metarepo / "projects" / "alpha" / "docs" / "README.md").is_file()

    def test_scaffolds_skills_dir(self, metarepo):
        run(metarepo, "init", "alpha")
        assert (metarepo / "projects" / "alpha" / ".agents" / "skills").is_dir()

    def test_seeds_project_context(self, metarepo):
        run(metarepo, "init", "alpha")
        ctx = metarepo / "projects" / "alpha" / "features" / "project-context.md"
        assert ctx.is_file()
        assert "REPLACE_ME" in ctx.read_text()

    def test_auto_switches(self, metarepo):
        run(metarepo, "init", "alpha")
        assert (metarepo / "active-project.txt").read_text().strip() == "alpha"
        assert (metarepo / "features").is_symlink()
        assert (metarepo / "docs").is_symlink()

    def test_duplicate_init_switches(self, metarepo):
        run(metarepo, "init", "alpha")
        run(metarepo, "init", "beta")
        result = run(metarepo, "init", "alpha")
        assert "already exists" in result.stdout

    def test_rejects_invalid_name(self, metarepo):
        result = run(metarepo, "init", "bad name!", expect_fail=True)
        assert result.returncode != 0

    def test_no_name_fails(self, metarepo):
        result = run(metarepo, "init", expect_fail=True)
        assert result.returncode != 0


# ── Repos + worktrees ────────────────────────────────────────────────────────

class TestRepos:
    def test_init_scaffolds_repos_yaml(self, metarepo):
        run(metarepo, "init", "alpha")
        repos_yaml = metarepo / "projects" / "alpha" / "repos.yaml"
        assert repos_yaml.is_file()
        assert "repos:" in repos_yaml.read_text()

    def test_init_creates_repos_and_implementation_dirs(self, metarepo):
        run(metarepo, "init", "alpha")
        assert (metarepo / "projects" / "alpha" / "repos").is_dir()
        assert (metarepo / "projects" / "alpha" / "implementation").is_dir()

    def test_repos_command_empty_on_fresh_project(self, metarepo):
        run(metarepo, "init", "alpha")
        result = run(metarepo, "repos")
        assert "No repos configured" in result.stdout

    def test_repos_lists_configured(self, metarepo, tmp_path):
        run(metarepo, "init", "alpha")
        web = make_source_repo(tmp_path, "web")
        write_repos_yaml(metarepo, "alpha", [("web", web)])
        result = run(metarepo, "repos")
        assert "web" in result.stdout
        assert "not cloned" in result.stdout

    def test_clone_populates_repos_dir(self, metarepo, tmp_path):
        run(metarepo, "init", "alpha")
        web = make_source_repo(tmp_path, "web")
        write_repos_yaml(metarepo, "alpha", [("web", web)])
        run(metarepo, "clone")
        assert (metarepo / "projects" / "alpha" / "repos" / "web" / ".git").exists()

    def test_worktree_default_sole_repo(self, metarepo, tmp_path):
        run(metarepo, "init", "alpha")
        web = make_source_repo(tmp_path, "web")
        write_repos_yaml(metarepo, "alpha", [("web", web)])
        run(metarepo, "clone")
        run(metarepo, "worktree", "STORY-1")
        wt = metarepo / "projects" / "alpha" / "implementation" / "STORY-1" / "web"
        assert (wt / ".git").exists()
        assert git_branch(wt) == "story/STORY-1"

    def test_worktree_multi_repo(self, metarepo, tmp_path):
        run(metarepo, "init", "alpha")
        web = make_source_repo(tmp_path, "web")
        api = make_source_repo(tmp_path, "api")
        write_repos_yaml(metarepo, "alpha", [("web", web), ("api", api)])
        run(metarepo, "clone")
        run(metarepo, "worktree", "STORY-1", "web", "api")
        impl = metarepo / "projects" / "alpha" / "implementation" / "STORY-1"
        assert (impl / "web" / ".git").exists()
        assert (impl / "api" / ".git").exists()
        assert git_branch(impl / "web") == "story/STORY-1"
        assert git_branch(impl / "api") == "story/STORY-1"

    def test_worktree_all_flag(self, metarepo, tmp_path):
        run(metarepo, "init", "alpha")
        web = make_source_repo(tmp_path, "web")
        api = make_source_repo(tmp_path, "api")
        write_repos_yaml(metarepo, "alpha", [("web", web), ("api", api)])
        run(metarepo, "clone")
        run(metarepo, "worktree", "STORY-2", "--all")
        impl = metarepo / "projects" / "alpha" / "implementation" / "STORY-2"
        assert (impl / "web").is_dir()
        assert (impl / "api").is_dir()

    def test_worktree_requires_repo_when_multiple(self, metarepo, tmp_path):
        run(metarepo, "init", "alpha")
        web = make_source_repo(tmp_path, "web")
        api = make_source_repo(tmp_path, "api")
        write_repos_yaml(metarepo, "alpha", [("web", web), ("api", api)])
        run(metarepo, "clone")
        result = run(metarepo, "worktree", "STORY-3", expect_fail=True)
        assert result.returncode != 0
        assert "specify which" in result.stderr.lower()

    def test_worktree_rejects_unknown_repo(self, metarepo, tmp_path):
        run(metarepo, "init", "alpha")
        web = make_source_repo(tmp_path, "web")
        write_repos_yaml(metarepo, "alpha", [("web", web)])
        run(metarepo, "clone")
        result = run(metarepo, "worktree", "STORY-4", "ghost", expect_fail=True)
        assert result.returncode != 0

    def test_worktree_rm_removes(self, metarepo, tmp_path):
        run(metarepo, "init", "alpha")
        web = make_source_repo(tmp_path, "web")
        api = make_source_repo(tmp_path, "api")
        write_repos_yaml(metarepo, "alpha", [("web", web), ("api", api)])
        run(metarepo, "clone")
        run(metarepo, "worktree", "STORY-5", "--all")
        run(metarepo, "worktree-rm", "STORY-5")
        assert not (metarepo / "projects" / "alpha" / "implementation" / "STORY-5").exists()

    def test_worktree_list(self, metarepo, tmp_path):
        run(metarepo, "init", "alpha")
        web = make_source_repo(tmp_path, "web")
        write_repos_yaml(metarepo, "alpha", [("web", web)])
        run(metarepo, "clone")
        run(metarepo, "worktree", "STORY-6")
        result = run(metarepo, "worktree", "list")
        assert "STORY-6" in result.stdout


# ── Switch ───────────────────────────────────────────────────────────────────

class TestSwitch:
    def test_creates_output_symlink(self, metarepo):
        run(metarepo, "init", "alpha")
        link = metarepo / "features"
        assert link.is_symlink()
        assert os.readlink(link) == "projects/alpha/features"

    def test_creates_docs_symlink(self, metarepo):
        run(metarepo, "init", "alpha")
        link = metarepo / "docs"
        assert link.is_symlink()
        assert os.readlink(link) == "projects/alpha/docs"

    def test_creates_skills_symlink(self, metarepo):
        run(metarepo, "init", "alpha")
        link = metarepo / ".agents" / "skills" / "project"
        assert link.is_symlink()

    def test_switches_all_three_symlinks(self, metarepo):
        run(metarepo, "init", "alpha")
        run(metarepo, "init", "beta")
        run(metarepo, "switch", "alpha")
        assert os.readlink(metarepo / "features") == "projects/alpha/features"
        assert os.readlink(metarepo / "docs") == "projects/alpha/docs"
        assert "alpha" in os.readlink(metarepo / ".agents" / "skills" / "project")

    def test_updates_active_project_file(self, metarepo):
        run(metarepo, "init", "alpha")
        run(metarepo, "init", "beta")
        run(metarepo, "switch", "alpha")
        assert (metarepo / "active-project.txt").read_text().strip() == "alpha"

    def test_nonexistent_fails(self, metarepo):
        result = run(metarepo, "switch", "ghost", expect_fail=True)
        assert result.returncode != 0

    def test_artifact_inventory(self, metarepo):
        run(metarepo, "init", "alpha")
        (metarepo / "projects" / "alpha" / "features" / "planning-artifacts" / "PRD.md").write_text("# PRD")
        result = run(metarepo, "switch", "alpha")
        assert "PRD.md" in result.stdout

    def test_epic_count(self, metarepo):
        run(metarepo, "init", "alpha")
        epics = metarepo / "projects" / "alpha" / "features" / "planning-artifacts" / "epics"
        (epics / "e1.md").write_text("# E1")
        (epics / "e2.md").write_text("# E2")
        result = run(metarepo, "switch", "alpha")
        assert "2 epic file(s)" in result.stdout

    def test_real_directory_blocks(self, metarepo):
        run(metarepo, "init", "alpha")
        run(metarepo, "init", "beta")
        os.remove(metarepo / "features")
        (metarepo / "features").mkdir()
        result = run(metarepo, "switch", "alpha", expect_fail=True)
        assert result.returncode != 0
        assert "NOT a symlink" in result.stderr

    def test_auto_scaffolds(self, metarepo):
        (metarepo / "projects" / "bare").mkdir()
        run(metarepo, "switch", "bare")
        assert (metarepo / "projects" / "bare" / "features" / "planning-artifacts").is_dir()
        assert (metarepo / "projects" / "bare" / "docs").is_dir()


# ── Docs routing ─────────────────────────────────────────────────────────────

class TestDocsRouting:
    def test_docs_isolation(self, metarepo):
        """Docs from one project don't bleed into another."""
        run(metarepo, "init", "alpha")
        (metarepo / "projects" / "alpha" / "docs" / "api.md").write_text("# Alpha API")
        run(metarepo, "init", "beta")
        (metarepo / "projects" / "beta" / "docs" / "schema.md").write_text("# Beta Schema")

        run(metarepo, "switch", "alpha")
        assert (metarepo / "docs" / "api.md").exists()
        assert not (metarepo / "docs" / "schema.md").exists()

        run(metarepo, "switch", "beta")
        assert (metarepo / "docs" / "schema.md").exists()
        assert not (metarepo / "docs" / "api.md").exists()

    def test_docs_count_in_switch(self, metarepo):
        run(metarepo, "init", "alpha")
        (metarepo / "projects" / "alpha" / "docs" / "spec.md").write_text("# Spec")
        result = run(metarepo, "switch", "alpha")
        assert "1 doc file(s)" in result.stdout

    def test_current_shows_docs_symlink(self, metarepo):
        run(metarepo, "init", "alpha")
        result = run(metarepo, "current")
        assert "docs" in result.stdout

    def test_custom_docs_folder_via_config(self, metarepo):
        (metarepo / "_bmad" / "bmm" / "config.yaml").write_text(
            'project_knowledge: "{project-root}/knowledge"\n'
        )
        run(metarepo, "init", "alpha")
        assert (metarepo / "projects" / "alpha" / "knowledge").is_dir()
        assert (metarepo / "knowledge").is_symlink()
        assert not (metarepo / "docs").exists()

    def test_custom_docs_folder_via_env(self, metarepo):
        run(metarepo, "init", "alpha", env={"BMAD_DOCS_FOLDER": "reference"})
        assert (metarepo / "projects" / "alpha" / "reference").is_dir()
        assert (metarepo / "reference").is_symlink()


# ── Skills routing ───────────────────────────────────────────────────────────

class TestSkillsRouting:
    def test_project_skills_isolated(self, metarepo):
        run(metarepo, "init", "alpha")
        add_project_skill(metarepo, "alpha", "alpha-api")
        run(metarepo, "init", "beta")
        add_project_skill(metarepo, "beta", "beta-db")

        run(metarepo, "switch", "alpha")
        link = metarepo / ".agents" / "skills" / "project"
        assert (link / "alpha-api" / "SKILL.md").exists()
        assert not (link / "beta-db").exists()

        run(metarepo, "switch", "beta")
        assert (link / "beta-db" / "SKILL.md").exists()
        assert not (link / "alpha-api").exists()

    def test_skill_count_reported(self, metarepo):
        run(metarepo, "init", "alpha")
        add_project_skill(metarepo, "alpha", "s1")
        add_project_skill(metarepo, "alpha", "s2")
        result = run(metarepo, "switch", "alpha")
        assert "2 project skill(s)" in result.stdout

    def test_shared_skills_unaffected(self, metarepo):
        shared = metarepo / ".agents" / "skills" / "shared" / "test" / "SKILL.md"
        shared.parent.mkdir(parents=True, exist_ok=True)
        shared.write_text("# Shared")
        run(metarepo, "init", "alpha")
        run(metarepo, "init", "beta")
        assert shared.exists()

    def test_list_shows_skill_counts(self, metarepo):
        run(metarepo, "init", "alpha")
        add_project_skill(metarepo, "alpha", "s1")
        run(metarepo, "init", "beta")
        result = run(metarepo, "list")
        assert "1 skill(s)" in result.stdout


# ── List / Current ───────────────────────────────────────────────────────────

class TestList:
    def test_empty(self, metarepo):
        result = run(metarepo, "list")
        assert "No projects found" in result.stdout

    def test_marks_active(self, metarepo):
        run(metarepo, "init", "alpha")
        run(metarepo, "init", "beta")
        run(metarepo, "switch", "alpha")
        result = run(metarepo, "list")
        for line in result.stdout.splitlines():
            if "alpha" in line:
                assert "active" in line
            if "beta" in line:
                assert "active" not in line

    def test_shows_folder_names(self, metarepo):
        run(metarepo, "init", "alpha")
        result = run(metarepo, "list")
        assert "features" in result.stdout
        assert "docs" in result.stdout


class TestCurrent:
    def test_shows_active(self, metarepo):
        run(metarepo, "init", "alpha")
        result = run(metarepo, "current")
        assert "alpha" in result.stdout

    def test_no_active(self, metarepo):
        result = run(metarepo, "current")
        assert "No active project" in result.stdout

    def test_detects_mismatch(self, metarepo):
        run(metarepo, "init", "alpha")
        run(metarepo, "init", "beta")
        (metarepo / "active-project.txt").write_text("alpha")
        result = run(metarepo, "current")
        assert "Mismatch" in result.stdout


# ── Validate ─────────────────────────────────────────────────────────────────

class TestValidate:
    def test_healthy_repo(self, metarepo):
        run(metarepo, "init", "alpha")
        result = run(metarepo, "validate")
        assert "All checks passed" in result.stdout

    def test_checks_docs_symlink(self, metarepo):
        run(metarepo, "init", "alpha")
        result = run(metarepo, "validate")
        assert "docs symlink" in result.stdout

    def test_checks_agents_dir(self, metarepo):
        run(metarepo, "init", "alpha")
        result = run(metarepo, "validate")
        assert ".agents/" in result.stdout

    def test_checks_agent_md(self, metarepo):
        os.remove(metarepo / "AGENTS.md")
        run(metarepo, "init", "alpha")
        result = run(metarepo, "validate", expect_fail=True)
        assert "AGENTS.md missing" in result.stdout

    def test_missing_symlink(self, metarepo):
        result = run(metarepo, "validate", expect_fail=True)
        assert "symlink missing" in result.stdout

    def test_broken_output_symlink(self, metarepo):
        run(metarepo, "init", "alpha")
        shutil.rmtree(metarepo / "projects" / "alpha" / "features")
        result = run(metarepo, "validate", expect_fail=True)
        assert "BROKEN" in result.stdout


# ── Config command ───────────────────────────────────────────────────────────

class TestConfig:
    def test_shows_defaults(self, metarepo):
        result = run(metarepo, "config")
        assert "features" in result.stdout
        assert "docs" in result.stdout
        assert "default" in result.stdout

    def test_shows_yaml_source(self, metarepo):
        (metarepo / "_bmad" / "bmm" / "config.yaml").write_text(
            'output_folder: "{project-root}/specs"\n'
        )
        result = run(metarepo, "config")
        assert "specs" in result.stdout
        assert "config.yaml" in result.stdout


# ── Custom output folder ─────────────────────────────────────────────────────

class TestCustomOutputFolder:
    def test_yaml_config(self, metarepo):
        (metarepo / "_bmad" / "bmm" / "config.yaml").write_text(
            'output_folder: "{project-root}/specs"\n'
        )
        run(metarepo, "init", "alpha")
        assert (metarepo / "specs").is_symlink()
        assert (metarepo / "projects" / "alpha" / "specs" / "planning-artifacts").is_dir()

    def test_env_override(self, metarepo):
        run(metarepo, "init", "alpha", env={"BMAD_OUTPUT_FOLDER": "artifacts"})
        assert (metarepo / "artifacts").is_symlink()

    def test_env_beats_yaml(self, metarepo):
        (metarepo / "_bmad" / "bmm" / "config.yaml").write_text(
            'output_folder: "{project-root}/specs"\n'
        )
        run(metarepo, "init", "alpha", env={"BMAD_OUTPUT_FOLDER": "artifacts"})
        assert (metarepo / "artifacts").is_symlink()
        assert not (metarepo / "specs").exists()

    def test_bare_name(self, metarepo):
        (metarepo / "_bmad" / "bmm" / "config.yaml").write_text(
            "output_folder: planning\n"
        )
        run(metarepo, "init", "alpha")
        assert (metarepo / "planning").is_symlink()

    def test_toml_fallback(self, metarepo):
        (metarepo / "_bmad" / "config.toml").write_text(
            'output_folder = "toml-out"\n'
        )
        run(metarepo, "init", "alpha")
        assert (metarepo / "toml-out").is_symlink()

    def test_yaml_beats_toml(self, metarepo):
        (metarepo / "_bmad" / "bmm" / "config.yaml").write_text(
            'output_folder: "from-yaml"\n'
        )
        (metarepo / "_bmad" / "config.toml").write_text(
            'output_folder = "from-toml"\n'
        )
        run(metarepo, "init", "alpha")
        assert (metarepo / "from-yaml").is_symlink()
        assert not (metarepo / "from-toml").exists()


# ── Edge cases ───────────────────────────────────────────────────────────────

class TestEdgeCases:
    def test_not_a_metarepo(self, tmp_path):
        script = Path(__file__).resolve().parent.parent / "scripts" / "bmad-router.sh"
        scripts_dir = tmp_path / "scripts"
        scripts_dir.mkdir()
        (scripts_dir / "bmad-router.sh").write_text(script.read_text())
        result = subprocess.run(
            ["bash", str(scripts_dir / "bmad-router.sh"), "list"],
            cwd=tmp_path, capture_output=True, text=True,
        )
        assert result.returncode != 0

    def test_unknown_command(self, metarepo):
        result = run(metarepo, "frobnicate", expect_fail=True)
        assert result.returncode != 0

    def test_help(self, metarepo):
        result = run(metarepo, "help")
        assert "USAGE" in result.stdout
        assert "SYMLINKS MANAGED" in result.stdout

    def test_idempotent_switch(self, metarepo):
        run(metarepo, "init", "alpha")
        run(metarepo, "switch", "alpha")
        run(metarepo, "switch", "alpha")
        assert os.readlink(metarepo / "features") == "projects/alpha/features"

    def test_context_not_overwritten(self, metarepo):
        run(metarepo, "init", "alpha")
        ctx = metarepo / "projects" / "alpha" / "features" / "project-context.md"
        ctx.write_text("Custom content")
        run(metarepo, "init", "beta")
        run(metarepo, "switch", "alpha")
        assert "Custom content" in ctx.read_text()

    def test_all_symlinks_relative(self, metarepo):
        run(metarepo, "init", "alpha")
        for link in [metarepo / "features", metarepo / "docs", metarepo / ".agents" / "skills" / "project"]:
            assert not os.path.isabs(os.readlink(link)), f"{link} should be relative"

    def test_many_projects(self, metarepo):
        names = [f"proj-{i}" for i in range(10)]
        for name in names:
            run(metarepo, "init", name)
        result = run(metarepo, "list")
        for name in names:
            assert name in result.stdout
