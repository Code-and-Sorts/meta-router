# Story worktree workflow

This file is loaded as a persistent fact by the `bmad-dev-story` skill (via
`_bmad/custom/bmad-dev-story.toml`). It defines how source repositories and
per-story git worktrees are managed in a meta-router metarepo. Follow it when
implementing any BMad story.

## Layout

meta-router routes the **active** workspace through root-level symlinks, so you work
from repo-root-relative paths and never need the `workspaces/<name>/` path:

```
<metarepo root>/
├── repos.yaml -> workspaces/<active>/repos.yaml is NOT symlinked; use
│                 `bash .claude/skills/meta-router/scripts/meta-router.sh repos` to list configured repos
├── repos/            -> workspaces/<active>/repos/            (git clones, gitignored)
│   ├── web/
│   ├── gql-aggregator/
│   └── api/
└── implementation/   -> workspaces/<active>/implementation/   (worktrees, gitignored)
    └── <story-id>/
        ├── web/              # worktree on branch story/<story-id>
        ├── gql-aggregator/   # worktree on branch story/<story-id>
        └── api/              # worktree on branch story/<story-id>
```

- The workspace's repo manifest is `repos.yaml`; list it with
  `bash .claude/skills/meta-router/scripts/meta-router.sh repos`. Each entry has `name`, `url`, `branch`.
- `repos/<name>/` is a full clone, created by `clone`. Never edit code here.
- `implementation/<story-id>/<name>/` is an isolated worktree off the matching
  clone, checked out on branch `story/<story-id>`. Implement story code here.
- `<story-id>` is ALWAYS the story's `development_status` key from
  sprint-status.yaml (e.g. `1-2-account-management`) — the same key names the
  story file. The GitHub sync derives "In Review" status from open PRs on
  `story/<story-id>` branches, so this exact format is load-bearing.

## Why worktrees per repo

A single story can span several repositories — a full-stack story might change a
web app, a GraphQL aggregator, and a backend microservice at once. Each repo gets
its own worktree on a shared `story/<story-id>` branch name, so the changes for
one story stay isolated from other in-flight work and map cleanly to one PR per
repo.

## Procedure

1. **Identify affected repos.** Read the story's `## Affected Repos` section. The
   listed names match the output of `bash .claude/skills/meta-router/scripts/meta-router.sh repos`.
2. **Ensure clones exist.** For each affected repo not yet under `repos/`, run:
   ```bash
   bash .claude/skills/meta-router/scripts/meta-router.sh clone <repo>
   ```
3. **Create the worktrees.** One command creates a worktree per affected repo:
   ```bash
   bash .claude/skills/meta-router/scripts/meta-router.sh worktree <story-id> <repo> [<repo> ...]
   # or, to target every configured repo:
   bash .claude/skills/meta-router/scripts/meta-router.sh worktree <story-id> --all
   ```
4. **Implement inside the worktrees.** Make all changes under
   `implementation/<story-id>/<repo>/`. Commit on the `story/<story-id>` branch in
   each repo. Do not edit `repos/<repo>/` directly.
5. **Review the worktrees.** List active ones any time with:
   ```bash
   bash .claude/skills/meta-router/scripts/meta-router.sh worktree list
   ```
6. **Clean up after merge.** Once the story's branches are merged, remove all of
   its worktrees:
   ```bash
   bash .claude/skills/meta-router/scripts/meta-router.sh worktree-rm <story-id>
   ```

## Notes

- `repos/` and `implementation/` are root symlinks to the active workspace; they
  repoint automatically when you `bash .claude/skills/meta-router/scripts/meta-router.sh switch <workspace>`.
- Worktrees and clones are gitignored — the metarepo tracks planning artifacts
  and `repos.yaml`, not source code.
- The branch name is always `story/<story-id>`; re-running `worktree` for an
  existing worktree is a no-op (it is skipped, not recreated).
