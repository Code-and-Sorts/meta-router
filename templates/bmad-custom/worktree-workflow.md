# Story worktree workflow

This file is loaded as a persistent fact by the `bmad-dev-story` skill (via
`_bmad/custom/bmad-dev-story.toml`). It defines how source repositories and
per-story git worktrees are managed in a bmad-router metarepo. Follow it when
implementing any BMAD story.

## Layout

bmad-router routes the **active** project through root-level symlinks, so you work
from repo-root-relative paths and never need the `projects/<name>/` path:

```
<metarepo root>/
├── repos.yaml -> projects/<active>/repos.yaml is NOT symlinked; use
│                 `bash scripts/bmad-router.sh repos` to list configured repos
├── repos/            -> projects/<active>/repos/            (git clones, gitignored)
│   ├── web/
│   ├── gql-aggregator/
│   └── api/
└── implementation/   -> projects/<active>/implementation/   (worktrees, gitignored)
    └── <story-id>/
        ├── web/              # worktree on branch story/<story-id>
        ├── gql-aggregator/   # worktree on branch story/<story-id>
        └── api/              # worktree on branch story/<story-id>
```

- The project's repo manifest is `repos.yaml`; list it with
  `bash scripts/bmad-router.sh repos`. Each entry has `name`, `url`, `branch`.
- `repos/<name>/` is a full clone, created by `clone`. Never edit code here.
- `implementation/<story-id>/<name>/` is an isolated worktree off the matching
  clone, checked out on branch `story/<story-id>`. Implement story code here.

## Why worktrees per repo

A single story can span several repositories — a full-stack story might change a
web app, a GraphQL aggregator, and a backend microservice at once. Each repo gets
its own worktree on a shared `story/<story-id>` branch name, so the changes for
one story stay isolated from other in-flight work and map cleanly to one PR per
repo.

## Procedure

1. **Identify affected repos.** Read the story's `## Affected Repos` section. The
   listed names match the output of `bash scripts/bmad-router.sh repos`.
2. **Ensure clones exist.** For each affected repo not yet under `repos/`, run:
   ```bash
   bash scripts/bmad-router.sh clone <repo>
   ```
3. **Create the worktrees.** One command creates a worktree per affected repo:
   ```bash
   bash scripts/bmad-router.sh worktree <story-id> <repo> [<repo> ...]
   # or, to target every configured repo:
   bash scripts/bmad-router.sh worktree <story-id> --all
   ```
4. **Implement inside the worktrees.** Make all changes under
   `implementation/<story-id>/<repo>/`. Commit on the `story/<story-id>` branch in
   each repo. Do not edit `repos/<repo>/` directly.
5. **Review the worktrees.** List active ones any time with:
   ```bash
   bash scripts/bmad-router.sh worktree list
   ```
6. **Clean up after merge.** Once the story's branches are merged, remove all of
   its worktrees:
   ```bash
   bash scripts/bmad-router.sh worktree-rm <story-id>
   ```

## Notes

- `repos/` and `implementation/` are root symlinks to the active project; they
  repoint automatically when you `bash scripts/bmad-router.sh switch <project>`.
- Worktrees and clones are gitignored — the metarepo tracks planning artifacts
  and `repos.yaml`, not source code.
- The branch name is always `story/<story-id>`; re-running `worktree` for an
  existing worktree is a no-op (it is skipped, not recreated).
