# bmad-router

A multi-project context switcher for [BMAD Method](https://github.com/bmad-code-org/BMAD-METHOD) metarepos.

BMAD assumes one project per repo. If you're running multiple projects that share the same agents, workflows, and conventions, you end up duplicating `_bmad/` everywhere or doing awkward copy-paste between repos. This tool lets you keep a single BMAD core and switch between isolated project contexts with a symlink swap.

## Browse a live example

Every push to `main` regenerates a full example metarepo and publishes it to the [`example` branch](../../tree/example). Browse it to see the layout without running setup yourself: two projects (a multi-repo `alpha` and a single-repo `beta`), each project's `repos.yaml`, sample PRD/epic/sprint-status artifacts, a full-stack story (`STORY-001`) with an `## Affected Repos` section, and the BMAD worktree customization under `_bmad/custom/`.

## The problem

You want one repo with shared BMAD infrastructure but separate planning artifacts per project. Each project needs its own PRD, architecture doc, epics, stories, sprint status, docs, and agent skills — but they all use the same agents and workflows.

BMAD doesn't support this natively. There's been [discussion about monorepo support](https://github.com/bmad-code-org/BMAD-METHOD/issues/980) and [submodule approaches](https://github.com/bmad-code-org/BMAD-METHOD/issues/1113), but nothing shipped. bmad-router fills that gap with symlinks and a shell script.

## What it does

When you run `bmad-router switch food-inventory`, three symlinks at the repo root get repointed:

- `features/` → `projects/food-inventory/features/` (BMAD output: PRDs, epics, stories)
- `docs/` → `projects/food-inventory/docs/` (project knowledge: ADRs, specs)
- `.agents/skills/project/` → `projects/food-inventory/.agents/skills/` (project-specific agent skills)

BMAD's workflows read and write through the symlinks without knowing they're there. The folder names come from your BMAD `config.yaml` — `output_folder` and `project_knowledge` — so if you've customized those, the router picks them up automatically.

## Setup

Requirements: Node.js (for BMAD), git, bash.

```
git clone <this-repo> bmad-router
mkdir my-metarepo && cd my-metarepo
bash /path/to/bmad-router/setup.sh .
```

The target directory — the folder the metarepo is set up in — is the first argument (`.` above). The setup script walks you through three questions: what to call the output folder (default: `features`), what to call the docs folder (default: `docs`), and which projects to create.

### Scripted / non-interactive setup

Set `BMAD_SETUP_NONINTERACTIVE=1` to skip all prompts and source answers from the environment — useful for CI. The target directory can be defined with `BMAD_SETUP_TARGET` instead of the positional argument (the positional argument still wins if both are given):

```bash
BMAD_SETUP_NONINTERACTIVE=1 \
  BMAD_SETUP_TARGET=my-metarepo \
  BMAD_OUTPUT_FOLDER=features \
  BMAD_DOCS_FOLDER=docs \
  BMAD_SETUP_PROJECTS=alpha,beta \
  BMAD_SETUP_ISSUES_SYNC=y \
  bash /path/to/bmad-router/setup.sh
```

![Setup](docs/images/01-setup.png)

It installs BMAD if it isn't already there, writes the folder names into `config.yaml`, creates the directory structure, scaffolds your projects, and installs a CI workflow (`.github/workflows/ci.yml`) that runs the bmad-router tests and shellcheck.

## What you get

![File structure](docs/images/02-tree.png)

The important parts:

- `_bmad/` is the shared BMAD core. Agents, workflows, tasks. Installed once, used by all projects.
- `projects/<name>/features/` is where BMAD writes artifacts for that project. PRD, architecture, epics, stories, sprint status, project-context.md.
- `projects/<name>/docs/` is project-specific knowledge that BMAD agents read as `project_knowledge`.
- `projects/<name>/.agents/skills/` holds agent skills that only activate when that project is switched in.
- `.agents/knowledge/` is shared documentation that's always available regardless of active project. Org standards, coding conventions, review checklists.
- `.agents/skills/<name>/` holds always-active skills (like bmad-router itself), each a directory with a `SKILL.md`. The active project's skills are exposed via the `.agents/skills/project` symlink.
- `projects/<name>/repos.yaml` is a tracked manifest of the project's source repos. `projects/<name>/repos/` holds their git clones and `projects/<name>/implementation/` holds per-story git worktrees — both gitignored. See [Source repos and story worktrees](#source-repos-and-story-worktrees).
- `AGENTS.md` is the context file for AI agents. Named `AGENTS.md` rather than `CLAUDE.md` so it works with Claude Code, Copilot, Cursor, or anything else that reads a root markdown file.

## Usage

```
bash scripts/bmad-router.sh <command>
```

![Listing and switching](docs/images/03-list-switch.png)

`list` shows all projects with the active one marked. `switch` swaps all three symlinks, writes `active-project.txt`, and prints an artifact inventory so you can see where the project stands.

![Current state and config](docs/images/04-current-config.png)

`current` shows what's active and where the symlinks point. `config` shows where the folder names came from (env var, config.yaml, or default).

![Validate](docs/images/05-validate.png)

`validate` checks that the symlinks are healthy, `AGENTS.md` exists, the `.agents/` directory is set up, and the active project has all the expected artifact directories.

Other commands: `init <name>` creates and switches to a new project. `help` prints the full reference.

## How the folder names work

The output folder defaults to `features`. The docs folder defaults to `docs`. Both are configurable three ways:

1. **Environment variable** — `BMAD_OUTPUT_FOLDER=specs bmad-router init my-project`
2. **BMAD config** — `output_folder` and `project_knowledge` in `_bmad/bmm/config.yaml`
3. **Default** — `features` and `docs`

The setup script writes your choices into config.yaml, so the router reads them automatically after that.

## Project-specific skills

Each project can have its own agent skills at `projects/<name>/.agents/skills/<skill-name>/SKILL.md`. They activate when you switch to that project and deactivate when you switch away. If your food-inventory project needs a custom recipe-parsing skill but your camera app doesn't, this keeps them separate.

Always-active skills at `.agents/skills/<name>/` (like bmad-router) are available regardless of the active project.

## Source repos and story worktrees

The metarepo tracks planning artifacts, not source code — but it does know where each project's source lives and gives BMAD stories an isolated place to be implemented.

Each project declares its source repos in a tracked `projects/<name>/repos.yaml`:

```yaml
repos:
  - name: web
    url: git@github.com:you/web.git
    branch: main
  - name: api
    url: git@github.com:you/api.git
    branch: main
```

`clone` pulls those into the gitignored `projects/<name>/repos/`:

```
bash scripts/bmad-router.sh clone          # all repos in repos.yaml
bash scripts/bmad-router.sh clone web      # just one
bash scripts/bmad-router.sh repos          # list configured repos + clone status
```

When you implement a story, create a git worktree per repo it touches. A single full-stack story can span several repos at once — a web app, a GraphQL aggregator, a backend service — and each gets its own worktree on a shared `story/<story-id>` branch:

```
bash scripts/bmad-router.sh worktree STORY-001 web api   # one worktree per repo
bash scripts/bmad-router.sh worktree STORY-001 --all     # every configured repo
bash scripts/bmad-router.sh worktree STORY-001           # the sole repo, if only one
bash scripts/bmad-router.sh worktree list                # active per-story worktrees
bash scripts/bmad-router.sh worktree-rm STORY-001        # tear them all down
```

This lays out worktrees as `projects/<name>/implementation/<story-id>/<repo>/`, gitignored, each checked out on `story/<story-id>`. Like `features`/`docs`, the active project's `repos/` and `implementation/` are also exposed as root-level symlinks, so you (and BMAD agents) can use `repos/<name>/` and `implementation/<story-id>/<repo>/` from the metarepo root without naming the active project.

### Driven by BMAD, not by hand

You don't have to remember to run these commands. The setup installs two BMAD customization overrides into `_bmad/custom/` ([BMAD's supported override mechanism](https://docs.bmad-method.org/how-to/customize-bmad/)):

- `bmad-create-story.toml` tells the Scrum Master agent to add a structured `## Affected Repos` section to every story, listing which `repos.yaml` repos it touches.
- `bmad-dev-story.toml` tells the Dev agent to read that section and run `clone`/`worktree` before implementing, then work inside the per-story worktrees. The full procedure lives in `_bmad/custom/worktree-workflow.md`.

So the story's own context decides how many worktrees get created. Edit or extend those files (or add personal `*.user.toml` variants) to fit your workflow.

## Known limitations and opinions

- **Symlinks on Windows.** Git on Windows needs `core.symlinks=true` and you may need to run your terminal as admin. WSL works fine. This was a deliberate tradeoff — symlinks are the simplest mechanism that lets BMAD workflows work unmodified.

- **No partial switching.** You can't have output pointing to one project and docs pointing to another. All three symlinks move together. This is intentional — split-brain state between projects would be a debugging nightmare.

- **Source code is gitignored.** The metarepo tracks planning artifacts, BMAD config, and each project's `repos.yaml` manifest — not source code. Clones (`projects/*/repos/`) and per-story worktrees (`projects/*/implementation/`) are gitignored. If you want to track source in the metarepo too, remove those lines from `.gitignore`.

- **Single BMAD install.** All projects share one `_bmad/` — same agents, same workflows, same version. If two projects need different BMAD versions, they should be in separate repos.

- **The default is `features`, not `_bmad-output`.** BMAD's default is `_bmad-output`. We changed it because in a metarepo context, the folder shows up a lot in navigation and conversation, and `features` reads better than `_bmad-output` when you're talking about PRDs and epics. You can change it back during setup or anytime via config.yaml.

## Tests

90 tests total: 67 for the router (init, switch, list, current, validate, config, docs routing, skills isolation, custom folder names, source repos, multi-repo worktrees, edge cases) and 23 for the issue sync (story collection, marker parsing, status classification, writeback, file reading).

```
pip install pytest pyyaml
pytest tests/ -v
```

## GitHub Issues sync (optional)

If you want BMAD stories to become GitHub Issues automatically, there's an optional sync layer built on top of the router. It's entirely separate — the router works fine without it.

### How it works

`sprint-status.yaml` is the trigger. When the BMAD scrum master agent finalizes sprint planning, stories move from `draft` to `ready`. A GitHub Action watches for changes to that file and syncs ready stories as issues to the project's source repo.

The sync is idempotent — each issue gets a hidden HTML marker in its body (`<!-- bmad-sync:STORY-001:food-inventory -->`) so the action knows which issues it owns. Re-running the sync updates existing issues instead of creating duplicates. Issue numbers get written back into `sprint-status.yaml` and committed to the branch, so the planning artifacts always have backlinks.

### Setup

1. Create a `github-sync.yaml` in each project that should sync:

```yaml
# projects/food-inventory/github-sync.yaml
repo: your-username/food-inventory
labels:
  epic: epic
  story: story
  bug: bug
milestone_prefix: Sprint
```

2. Copy the workflow into your metarepo:

```bash
cp -r templates/.github .github
```

3. Create the labels (`epic`, `story`, `bug`) in the target repo if they don't exist.

4. If the target repo is different from the metarepo, create a PAT with `repo` scope and add it as a secret named `BMAD_ISSUES_TOKEN` in the metarepo. If issues go in the same repo, the default `GITHUB_TOKEN` works.

### Status mapping

| sprint-status.yaml | GitHub Issue |
|---|---|
| `draft`, `backlog`, `deferred` | Skipped (no issue created) |
| `ready`, `todo`, `planned`, `in-progress` | Open |
| `done`, `complete`, `shipped`, `cancelled` | Closed |

### Local usage

The sync script is also runnable locally for debugging:

```bash
# Preview what would happen
python scripts/bmad-issues.py --dry-run

# Show sync state for active project
python scripts/bmad-issues.py status

# Sync a specific project
python scripts/bmad-issues.py sync --project food-inventory
```

Requires the `gh` CLI authenticated (`gh auth login`).

### What it deliberately doesn't do

- No bidirectional sync. If someone edits an issue body on GitHub, the markdown doesn't update. Markdown is the spec; the issue is the tracker.
- No automatic issue closure from PRs. GitHub already does that with `fixes #12` in commit messages.
- No GitHub Projects board integration. The Projects API is GraphQL-only and complex. Start with issues; add Projects manually if you need a board.

## File manifest

```
bmad-router/
├── setup.sh                        # Bootstrap a new metarepo
├── scripts/
│   ├── bmad-router.sh              # Context switcher (copied into metarepo)
│   └── bmad-issues.py              # GitHub Issues sync (optional)
├── templates/
│   ├── .github/workflows/
│   │   ├── ci.yml                  # Metarepo CI (pytest + shellcheck), installed into each metarepo
│   │   └── sync-issues.yml         # GitHub Action (optional)
│   ├── bmad-custom/                # BMAD overrides → _bmad/custom/
│   │   ├── bmad-dev-story.toml     #   create per-story worktrees on implement
│   │   ├── bmad-create-story.toml  #   add "## Affected Repos" to stories
│   │   └── worktree-workflow.md    #   the worktree procedure (loaded as context)
│   └── github-sync.yaml            # Per-project sync config template
├── examples/seed/                  # Seed content overlaid onto the example branch
├── .github/workflows/
│   ├── ci.yml                      # pytest + shellcheck
│   └── generate-example.yml        # Publishes the example branch on push to main
├── SKILL.md                        # Agent skill definition
├── tests/
│   ├── test_bmad_router.py         # Router tests (67)
│   └── test_bmad_issues.py         # Issue sync tests (23)
├── docs/images/                    # README screenshots
└── README.md
```
