# examples/seed

Curated content overlaid onto a freshly generated metarepo to produce the
[`example` branch](../../../tree/example). The `generate-example` GitHub workflow
runs `setup.sh` (a real BMad install), then copies each `examples/seed/<workspace>/`
tree over the matching scaffolded `workspaces/<workspace>/` so the published example
has realistic artifacts.

- **alpha** — a full-stack, multi-repo workspace (`web` + `api`). Its `1-1-create-a-task`
  declares an `## Affected Repos` section listing both repos, showing how one
  story maps to a git worktree per repo.
- **beta** — a single-repo workspace, showing the default-sole-repo path where
  `worktree <story-id>` needs no repo argument.
- **knowledge/shared-context.md** — a filled-in overall shared context overlaid
  onto `.claude/knowledge/`, replacing the `REPLACE_ME` template setup seeds. It
  shows the org-wide standards every workspace inherits (loaded before every
  workflow, alongside each workspace's `workspace-context.md`).

The `repos/` and `implementation/` placeholder READMEs are normally gitignored;
the workflow force-adds them so the structure is visible on the example branch.
