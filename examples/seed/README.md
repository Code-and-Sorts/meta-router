# examples/seed

Curated content overlaid onto a freshly generated metarepo to produce the
[`example` branch](../../../tree/example). The `generate-example` GitHub workflow
runs `setup.sh` (a real BMad install), then copies each `examples/seed/<project>/`
tree over the matching scaffolded `projects/<project>/` so the published example
has realistic artifacts.

- **alpha** — a full-stack, multi-repo project (`web` + `api`). Its `STORY-001`
  declares an `## Affected Repos` section listing both repos, showing how one
  story maps to a git worktree per repo.
- **beta** — a single-repo project, showing the default-sole-repo path where
  `worktree <story-id>` needs no repo argument.
- **knowledge/shared-context.md** — a filled-in overall shared context overlaid
  onto `.claude/knowledge/`, replacing the `REPLACE_ME` template setup seeds. It
  shows the org-wide standards every project inherits (loaded before every
  workflow, alongside each project's `project-context.md`).

The `repos/` and `implementation/` placeholder READMEs are normally gitignored;
the workflow force-adds them so the structure is visible on the example branch.
