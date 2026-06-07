# Work on source repos with per-story worktrees

The metarepo tracks planning artifacts, not source. Each project declares its source repos in `repos.yaml`; the router clones them and cuts per-story git worktrees, so a full-stack story can span several repos at once.

Prerequisites: a generated metarepo with a project switched in (see the [quick start](../README.md#quick-start)) and git access to the repos you declare.

1. Declare the project's repos in `projects/<name>/repos.yaml`:

   ```yaml
   repos:
     - name: web
       url: git@github.com:you/web.git
       branch: main
     - name: api
       url: git@github.com:you/api.git
       branch: main
   ```

2. Clone them:

   ```bash
   bash scripts/meta-router.sh clone        # every repo in repos.yaml
   bash scripts/meta-router.sh clone web    # one repo
   ```

   Clones land at `projects/<name>/repos/` and are gitignored.

3. Create worktrees for a story:

   ```bash
   bash scripts/meta-router.sh worktree 1-2-account-management web api  # one worktree per repo
   bash scripts/meta-router.sh worktree 1-2-account-management --all    # every repo
   ```

   Worktrees land at `projects/<name>/implementation/<story-id>/<repo>/` (gitignored), each on branch `story/<story-id>`. The story id is the story's `development_status` key from `sprint-status.yaml`; the [GitHub sync](github-sync.md) keys PR detection off that branch name.

4. Tear down when the story merges:

   ```bash
   bash scripts/meta-router.sh worktree-rm 1-2-account-management
   ```

   `worktree list` shows what's still active.

## How BMad drives this

Setup wires the flow into BMad through `_bmad/custom/`: the scrum master adds an `## Affected Repos` section to each story, and the dev agent reads it to create the worktrees before implementing. See `_bmad/custom/worktree-workflow.md` in a generated metarepo.

Clones and worktrees stay out of git. Remove the `projects/*/repos/` and `projects/*/implementation/` lines from `.gitignore` if you want them tracked.
