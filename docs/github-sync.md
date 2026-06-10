# Set up the GitHub Issues + Projects sync

An optional layer that mirrors each project's BMad artifacts to GitHub. Enable it during setup, or copy the skill's `templates/.github` workflows into the metarepo's `.github/workflows/` later (replace the `__SKILLS_DIR__` placeholder in `sync-issues.yml` with your tool's skills dir, e.g. `.claude/skills`).

Prerequisites: a generated metarepo, a GitHub account or org to host issues and boards, and the `gh` CLI authenticated.

## What you get

Each project gets a private GitHub Project board and two label-separated issue trees:

- **Delivery** (`bmad-delivery`): a `Delivery` root → Feature issues (one per PRD) → Epic issues → Story sub-issues. Epics/stories are driven by the `development_status:` map in BMad's `sprint-status.yaml`; features come from the PRD run folders (`prds/prd-*/prd.md`), with the newest PRD holding the epics (BMad generates `epics.md` from it). Native sub-issue progress bars give per-epic and per-feature rollups for free; superseded PRDs close automatically. Issues are created in the metarepo by default; set `repo:` in a project's `github-sync.yaml` to keep its issues next to the code instead (step 1 below).
- **Planning** (`bmad-planning`, always in the metarepo): one `Planning: <project>` checklist issue tracking which planning artifacts (brief, PRD, UX, architecture, epics) exist. This is the PM/architect view, separate from the engineering board.

## Setup, per project

1. Push the metarepo to GitHub (issues live there by default; optionally set `repo:` in `projects/<name>/github-sync.yaml` to use the project's source repo; any org or personal account works). Boards can live under any owner too: the bootstrap asks where (saveable as `project_owner:` in the metarepo-root `github-sync.yaml`, overridable per project).
2. Run `bash .claude/skills/meta-router/scripts/bmad-github-bootstrap.sh <name>` to create the private board, labels, and org issue types. On first run it offers to set up an org project template (name it whatever you like; the default is "BMad Project Template"): you build the views (Backlog, Epic Progress, Features, Planning; GitHub has no API for views) exactly once and every future board is copied from the template with views included. Views are visual-only: the script warns if the Backlog view is missing but never blocks on them, so add or change them anytime. The chosen name is saved as `template:` in a metarepo-root `github-sync.yaml` (override per run with `BMAD_TEMPLATE_NAME`), alongside an auto-managed `template_id:`; lookups go by that immutable ID first, so renaming the template later can't break the flow. Without a template (or on user accounts, where templates aren't supported) each board gets a printed view checklist instead.
3. Add a `BMAD_PROJECT_TOKEN` secret: PAT with **Projects read/write** + **Issues read/write** + **Pull requests read**. The default `GITHUB_TOKEN` cannot access Projects v2. If everything lives under one org, a fine-grained PAT works; if repos/boards span multiple orgs or your personal account, use a classic PAT (`project` + `repo` scopes; fine-grained PATs are single-owner) or a GitHub App installed per org.
4. Install `.claude/skills/meta-router/templates/.github/workflows/bmad-pr-ping.yml` (bundled with the skill) into each source repo so story PRs update the board immediately (the nightly reconcile covers anything missed).

## One board across all projects (optional)

Per-project boards answer "how is this project going?"; the portfolio board answers "what is everyone doing?". Run

```bash
bash .claude/skills/meta-router/scripts/bmad-github-bootstrap.sh --portfolio
```

to create one org-wide board that aggregates every project's delivery and planning issues. It gets the same Status options plus a **Project** single-select field with one option per BMad project, so views can group or filter by project (the bootstrap prints suggested views). The board number is saved as `portfolio:` (+ `portfolio_owner:`) in the metarepo-root `github-sync.yaml`; from then on every sync adds each issue to both its project board and the portfolio, sets Status on both, and stamps the Project field. New projects get their Project option appended automatically on first sync. Remove the `portfolio:` key to turn the fan-out off — per-project boards are unaffected. Re-running `--portfolio` repairs an existing board (Status options, missing Project field) instead of creating a duplicate. Mind GitHub's ~1,200 active items per board: archive Done items on the portfolio as it grows.

## How the sync behaves

The sync is the single writer of issue state and board Status:

- BMad statuses map to `Backlog / Ready / In Progress / In Review / Done`; `done` closes the issue.
- An open PR on a `story/<story-key>` branch in any `repos.yaml` repo forces `In Review`. Story PRs (one per affected repo) are linked onto the story issue automatically: a maintained **Pull Requests** section lists each PR with its repo and state (open/merged/closed). The scan covers the project's `repos.yaml` repos, plus its issues repo only when `repo:` is set explicitly — the defaulted metarepo holds every project's issues but no story branches. If two projects share a source repo, give their stories distinct slugs: a `story/<key>` branch can't tell which project's identical key it belongs to.
- Stories that vanish after renumbering are closed as not-planned with a `bmad-orphaned` label, never deleted.
- Re-runs update rather than duplicate; each issue carries a hidden `<!-- bmad-sync:key:project -->` marker.
- Rate-limited API calls are retried with backoff and mutations are lightly spaced; `sync --all` keeps going past a broken project and reports the failures at the end (exit 1, so the Action run still flags it). Tunables are in the [reference](reference.md#issue-sync-cli).

## Run it locally

```bash
python .claude/skills/meta-router/scripts/bmad-issues.py sync --dry-run
```

The [reference](reference.md#issue-sync-cli) lists all flags.
