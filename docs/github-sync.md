# Set up the GitHub Issues + Projects sync

An optional layer that mirrors each project's BMad artifacts to GitHub. Enable it during setup, or copy `templates/.github` into the metarepo later.

Prerequisites: a generated metarepo, a GitHub account or org to host issues and boards, and the `gh` CLI authenticated.

## What you get

Each project gets a private GitHub Project board and two label-separated issue trees:

- **Delivery** (`bmad-delivery`): a `Delivery` root → Feature issues (one per PRD) → Epic issues → Story sub-issues. Epics/stories are driven by the `development_status:` map in BMad's `sprint-status.yaml`; features come from the PRD run folders (`prds/prd-*/prd.md`), with the newest PRD holding the epics (BMad generates `epics.md` from it). Native sub-issue progress bars give per-epic and per-feature rollups for free; superseded PRDs close automatically. Issues are created in the metarepo by default; set `repo:` in a project's `github-sync.yaml` to keep its issues next to the code instead (step 1 below).
- **Planning** (`bmad-planning`, always in the metarepo): one `Planning: <project>` checklist issue tracking which planning artifacts (brief, PRD, UX, architecture, epics) exist. This is the PM/architect view, separate from the engineering board.

## Setup, per project

1. Push the metarepo to GitHub (issues live there by default; optionally set `repo:` in `projects/<name>/github-sync.yaml` to use the project's source repo; any org or personal account works). Boards can live under any owner too: the bootstrap asks where (saveable as `project_owner:` in the metarepo-root `github-sync.yaml`, overridable per project).
2. Run `bash scripts/bmad-github-bootstrap.sh <name>` to create the private board, labels, and org issue types. On first run it offers to set up an org project template (name it whatever you like; the default is "BMad Project Template"): you build the views (Backlog, Epic Progress, Features, Planning; GitHub has no API for views) exactly once and every future board is copied from the template with views included. Views are visual-only: the script warns if the Backlog view is missing but never blocks on them, so add or change them anytime. The chosen name is saved as `template:` in a metarepo-root `github-sync.yaml` (override per run with `BMAD_TEMPLATE_NAME`), alongside an auto-managed `template_id:`; lookups go by that immutable ID first, so renaming the template later can't break the flow. Without a template (or on user accounts, where templates aren't supported) each board gets a printed view checklist instead.
3. Add a `BMAD_PROJECT_TOKEN` secret: PAT with **Projects read/write** + **Issues read/write** + **Pull requests read**. The default `GITHUB_TOKEN` cannot access Projects v2. If everything lives under one org, a fine-grained PAT works; if repos/boards span multiple orgs or your personal account, use a classic PAT (`project` + `repo` scopes; fine-grained PATs are single-owner) or a GitHub App installed per org.
4. Install `templates/.github/workflows/bmad-pr-ping.yml` into each source repo so story PRs update the board immediately (the nightly reconcile covers anything missed).

## How the sync behaves

The sync is the single writer of issue state and board Status:

- BMad statuses map to `Backlog / Ready / In Progress / In Review / Done`; `done` closes the issue.
- An open PR on a `story/<story-key>` branch in any `repos.yaml` repo forces `In Review`. Story PRs (one per affected repo) are linked onto the story issue automatically: a maintained **Pull Requests** section lists each PR with its repo and state (open/merged/closed).
- Stories that vanish after renumbering are closed as not-planned with a `bmad-orphaned` label, never deleted.
- Re-runs update rather than duplicate; each issue carries a hidden `<!-- bmad-sync:key:project -->` marker.

## Run it locally

```bash
python scripts/bmad-issues.py sync --dry-run
```

The [reference](reference.md#issue-sync-cli) lists all flags.
