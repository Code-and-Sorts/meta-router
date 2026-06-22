# implementation/

Per-story git worktrees live here, laid out as `<story-id>/<repo>/`. Each is an
isolated working tree checked out on branch `story/<story-id>` from the matching
clone in `../repos/`. This folder is gitignored.

Create worktrees for a story (one per affected repo) with:

    bash .claude/skills/meta-router/scripts/meta-router.sh worktree <story-id> [repo...]

and tear them down with:

    bash .claude/skills/meta-router/scripts/meta-router.sh worktree-rm <story-id>
