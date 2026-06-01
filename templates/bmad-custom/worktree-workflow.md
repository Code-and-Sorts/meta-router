# Story worktree workflow

This file is loaded as a persistent fact by the `bmad-dev-story` skill (via
`_bmad/custom/bmad-dev-story.toml`). It defines how source repositories and
per-story git worktrees are managed in a bmad-router metarepo. Follow it when
implementing any BMAD story.

## Layout

For the active project (`bash scripts/bmad-router.sh current`):

```
projects/<active>/
├── repos.yaml                          # tracked manifest of source repos
├── repos/                              # git clones (gitignored)
│   ├── web/
│   ├── gql-aggregator/
│   └── api/
└── implementation/                     # per-story worktrees (gitignored)
    └── <story-id>/
        ├── web/                        # worktree on branch story/<story-id>
        ├── gql-aggregator/             # worktree on branch story/<story-id>
        └── api/                        # worktree on branch story/<story-id>
```

- `repos.yaml` is the source of truth for which repos the project owns. Each
  entry has `name`, `url`, and `branch`.
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
   listed names match `repos.yaml` entries.
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
   `projects/<active>/implementation/<story-id>/<repo>/`. Commit on the
   `story/<story-id>` branch in each repo. Do not edit `repos/<repo>/` directly.
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

- Worktrees and clones are gitignored — the metarepo tracks planning artifacts
  and `repos.yaml`, not source code.
- The branch name is always `story/<story-id>`; re-running `worktree` for an
  existing worktree is a no-op (it is skipped, not recreated).
