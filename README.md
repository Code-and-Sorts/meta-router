# bmad-router

A multi-project context switcher for [BMAD Method](https://github.com/bmad-code-org/BMAD-METHOD) metarepos.

BMAD assumes one project per repo. If you're running multiple projects that share the same agents, workflows, and conventions, you end up duplicating `_bmad/` everywhere or doing awkward copy-paste between repos. This tool lets you keep a single BMAD core and switch between isolated project contexts with a symlink swap.

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

The setup script walks you through three questions: what to call the output folder (default: `features`), what to call the docs folder (default: `docs`), and which projects to create.

![Setup](docs/images/01-setup.png)

It installs BMAD if it isn't already there, writes the folder names into `config.yaml`, creates the directory structure, and scaffolds your projects.

## What you get

![File structure](docs/images/02-tree.png)

The important parts:

- `_bmad/` is the shared BMAD core. Agents, workflows, tasks. Installed once, used by all projects.
- `projects/<name>/features/` is where BMAD writes artifacts for that project. PRD, architecture, epics, stories, sprint status, project-context.md.
- `projects/<name>/docs/` is project-specific knowledge that BMAD agents read as `project_knowledge`.
- `projects/<name>/.agents/skills/` holds agent skills that only activate when that project is switched in.
- `.agents/knowledge/` is shared documentation that's always available regardless of active project. Org standards, coding conventions, review checklists.
- `.agents/skills/shared/` is for skills that are always active (like bmad-router itself).
- `projects/<name>/src/` is gitignored by default. Each project's source code is expected to be managed independently — its own repo, a submodule, whatever fits your setup.
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

Shared skills at `.agents/skills/shared/` are always active.

## Known limitations and opinions

- **Symlinks on Windows.** Git on Windows needs `core.symlinks=true` and you may need to run your terminal as admin. WSL works fine. This was a deliberate tradeoff — symlinks are the simplest mechanism that lets BMAD workflows work unmodified.

- **No partial switching.** You can't have output pointing to one project and docs pointing to another. All three symlinks move together. This is intentional — split-brain state between projects would be a debugging nightmare.

- **Source code is gitignored.** The metarepo tracks planning artifacts and BMAD config, not source code. If you want to track source in the metarepo too, remove the `projects/*/src/` line from `.gitignore`.

- **Single BMAD install.** All projects share one `_bmad/` — same agents, same workflows, same version. If two projects need different BMAD versions, they should be in separate repos.

- **The default is `features`, not `_bmad-output`.** BMAD's default is `_bmad-output`. We changed it because in a metarepo context, the folder shows up a lot in navigation and conversation, and `features` reads better than `_bmad-output` when you're talking about PRDs and epics. You can change it back during setup or anytime via config.yaml.

## Tests

78 tests total: 55 for the router (init, switch, list, current, validate, config, docs routing, skills isolation, custom folder names, edge cases) and 23 for the issue sync (story collection, marker parsing, status classification, writeback, file reading).

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
│   │   └── sync-issues.yml         # GitHub Action (optional)
│   └── github-sync.yaml            # Per-project sync config template
├── SKILL.md                        # Agent skill definition
├── tests/
│   ├── test_bmad_router.py         # Router tests (55)
│   └── test_bmad_issues.py         # Issue sync tests (23)
├── docs/images/                    # README screenshots
└── README.md
```
