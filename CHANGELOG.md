# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Added

- **GitHub Projects (v2) sync** — `scripts/bmad-issues.py` rewritten for the real BMad v6 artifact format (the flat `development_status:` map; the previous parser targeted a nested schema BMad never writes and synced nothing). Each project mirrors to a delivery issue tree (Delivery root → Features (one per PRD) → Epics → Story sub-issues, with native progress bars) plus a planning checklist issue, separated by `bmad-delivery` / `bmad-planning` labels for per-audience board views (Backlog, Epic Progress, Features, Planning). All issues are created in the metarepo by default; `repo:` in `github-sync.yaml` is an optional per-project override for keeping delivery issues next to the code. The sync is the single writer of issue state and board Status: an open PR on a `story/<story-key>` branch forces In Review, `done` closes, vanished keys are orphaned (closed as not-planned, never deleted), and the key→issue mapping is rebuilt from body markers each run — no state file. Story PRs across all of a project's repos are linked onto the story issue via a maintained "Pull Requests" section (repo, number, open/merged/closed state).
- **`scripts/bmad-github-bootstrap.sh`** — creates a private GitHub Project per BMad project (plus org issue types and labels) and writes the project number into `github-sync.yaml`. Boards are copied from an org project template when one exists (views included — `copyProjectV2`); if missing, the script walks you through creating it once — the template name is yours to choose (default "BMad Project Template") and is stored as `template:` in a metarepo-root `github-sync.yaml` for later runs (`BMAD_TEMPLATE_NAME` overrides), with the immutable node ID pinned as `template_id:` so renames can't break lookup — then marks it with `markProjectV2AsTemplate`. Views are treated as visual-only: a soft API check warns if the Backlog view is missing but never blocks. Falls back to direct creation + a printed view checklist on user accounts (templates are org-only) or when the template step is skipped. `--all` bootstraps every project missing a board; `--template` manages the template alone. Offers to run `gh auth refresh` in place when the token lacks the `project` scope. Owner-agnostic: boards/templates can live under any org or your personal account (asked interactively, saved as `project_owner:` in the metarepo-root `github-sync.yaml`, per-project override supported), and view filters use labels rather than org-only issue types so boards work with issues from personal repos too.
- **`templates/.github/workflows/bmad-pr-ping.yml`** — installs into source repos; pings the metarepo sync via `repository_dispatch` when a story PR opens/closes (trigger only — it never writes issue or board state).
- **`init` seeds `github-sync.yaml`** — new projects get the sync config scaffold automatically; `validate` reports its state.
- **Guided board setup in setup.sh** — enabling GitHub sync now ends with a walkthrough (step 10): setup asks for each project's source repo, writes it into `github-sync.yaml`, and offers to create the private board on the spot via the bootstrap script. Non-interactive runs print the manual steps instead.
- **Skill level setup option** — setup asks for the BMad `user_skill_level` (default `intermediate`; `BMAD_SETUP_SKILL_LEVEL` for non-interactive) and passes it to the installer.

### Fixed

- **BMad folder config is passed at install time** — setup now drives `--output-folder` / `--set bmm.*` installer flags instead of patching `config.yaml` afterwards; the installer bakes resolved paths into every generated skill file, so post-install edits left skills pointing at `_bmad-output/`. Pre-existing installs are repointed with `--action update`, which regenerates those files.
- **Sync workflow correctness** — `sync-issues.yml` gains a concurrency group, uses `github.event.before` for multi-commit pushes (was `HEAD~1`), requires `BMAD_PROJECT_TOKEN` (the default `GITHUB_TOKEN` cannot access Projects v2), and no longer commits back to the branch.

- **`agent_tool` config and setup prompt** — setup now asks which agent tool you use (Claude Code, GitHub Copilot, or Codex) and writes the choice into `_bmad/bmm/config.yaml` as `agent_tool`. The router resolves agent skill and knowledge paths from this value (`.claude/`, `.github/`, `.codex/`, or `.agents/` as a fallback).
- **Agent skills and shared knowledge under the agent tool's home dir** — project skills and shared knowledge are now installed under the selected agent's config directory so the right tool picks them up automatically.
- **Per-story git worktrees** — `worktree <story> [repo...]` creates a branch `story/<story-id>` and a worktree at `projects/<name>/implementation/<story>/<repo>/` for each listed repo. `worktree-rm <story>` tears them all down. Driven by `_bmad/custom/` overrides so the dev agent creates worktrees before implementing.
- **`worktree list` command** — lists all active story worktrees for the current project.
- **`repos` / `clone` commands** — list and clone project source repos defined in `repos.yaml`.
- **`config` command** — shows the resolved output folder, docs folder, and agent tool with the source of each value (env var, config file, or default).
- **Generated metarepos ship a shellcheck-only CI** — `templates/.github/workflows/ci.yml` is installed into every generated metarepo; the full pytest suite stays in this repo.
- **GitHub Issues sync** — optional layer (`scripts/bmad-issues.py`) that turns ready stories into GitHub Issues, with idempotent sync keyed on hidden HTML markers.
- **Non-interactive setup** — set `BMAD_SETUP_NONINTERACTIVE=1` with env vars to drive setup from CI or scripts.

### Changed

- **Project-switch skill renamed to `router-project-switch`** — the always-active skill that switches the active project is now named `router-project-switch` (previously `project-switch`) for clarity and to avoid name collisions.
- **Setup repoints BMad artifact dirs** — setup now writes `planning_artifacts` and `implementation_artifacts` in `_bmad/bmm/config.yaml` to the chosen output folder, so BMad commands land in the right place without manual config.
- **Output folder default is `features`** — the default output folder is `features` rather than BMad's built-in `_bmad-output`, which reads better in a metarepo context.
- **`repos/` and `implementation/` symlinks added to root** — the symlink table now includes `repos/` and `implementation/` alongside `features/` and `docs/`.
