# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

### Added

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
- **Setup repoints BMAD artifact dirs** — setup now writes `planning_artifacts` and `implementation_artifacts` in `_bmad/bmm/config.yaml` to the chosen output folder, so BMAD commands land in the right place without manual config.
- **Output folder default is `features`** — the default output folder is `features` rather than BMAD's built-in `_bmad-output`, which reads better in a metarepo context.
- **`repos/` and `implementation/` symlinks added to root** — the symlink table now includes `repos/` and `implementation/` alongside `features/` and `docs/`.
