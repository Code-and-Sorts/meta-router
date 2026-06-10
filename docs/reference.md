# Reference

Commands, configuration, and environment variables. Run router commands from the metarepo root. The scripts ship inside the meta-router skill; paths below use the Claude Code tool home (`.claude`), so substitute `.github` or `.codex` if that's your agent tool.

## Commands

```bash
bash .claude/skills/meta-router/scripts/meta-router.sh <command>
```

| Command | Does |
| --- | --- |
| `init <name>` | scaffold and switch to a new project |
| `switch <name>` | change the active project |
| `list` | list projects (active marked, with skill counts) |
| `current` | show active project and symlink targets |
| `config` | show resolved folders, agent tool, and where each came from |
| `validate` | check symlinks, `AGENTS.md`, artifact dirs |
| `repos` / `clone [repo]` | list / clone the project's source repos |
| `worktree <story> [repo...]` | create per-story git worktree(s) |
| `worktree list` | list story worktrees |
| `worktree-rm <story>` | remove a story's worktrees |

`list` marks the active project and counts each project's skills; `current` shows where the active project's symlinks point:

```text
$ bash .claude/skills/meta-router/scripts/meta-router.sh list
Projects:  (output: features, docs: docs)
  ○ camera-app
  ● food-inventory (active)

$ bash .claude/skills/meta-router/scripts/meta-router.sh current
● Active project: food-inventory
  output: features -> projects/food-inventory/features
  docs:   docs -> projects/food-inventory/docs
  repos:  repos -> projects/food-inventory/repos
  impl:   implementation -> projects/food-inventory/implementation
  skills: .claude/skills/project (0 skill(s))
```

`validate` checks the symlinks, agent home, and the active project's artifact dirs:

```text
$ bash .claude/skills/meta-router/scripts/meta-router.sh validate
Validating BMad metarepo...
  output: features | docs: docs | tool: claude-code (skills: .claude/skills/)

✓ _bmad/
✓ projects/
✓ .claude/ (agent tool home)
✓ AGENTS.md
✓ .claude/knowledge/ (shared)
✓ .claude/knowledge/shared-context.md (shared context)
✓ features symlink → projects/food-inventory/features (valid)
✓ docs symlink → projects/food-inventory/docs (valid)
✓ repos symlink → projects/food-inventory/repos (valid)
✓ implementation symlink → projects/food-inventory/implementation (valid)
✓ .claude/skills/project symlink (valid)
✓ active-project.txt → food-inventory
...
✓ All checks passed.
```

## Configuration

Folder names and the agent tool resolve in order: **env var → `_bmad/bmm/config.yaml` → `_bmad/config.toml` → default**. Setup writes your choices into `config.yaml`, so the router picks them up afterward.

| Setting | Env var | config.yaml key | Default |
| --- | --- | --- | --- |
| Output folder | `BMAD_OUTPUT_FOLDER` | `output_folder` | `features` |
| Docs folder | `BMAD_DOCS_FOLDER` | `project_knowledge` | `docs` |
| Agent tool | `BMAD_AGENT_TOOL` | `agent_tool` | `claude-code` |

The agent tool sets where skills and shared knowledge live: `.claude/` (Claude Code), `.github/` (Copilot), `.codex/` (Codex). Setup also points BMad's `planning_artifacts` / `implementation_artifacts` at your output folder.

## Setup environment variables

Set `BMAD_SETUP_NONINTERACTIVE=1` to skip every prompt and answer from the environment:

```bash
BMAD_SETUP_NONINTERACTIVE=1 \
  BMAD_OUTPUT_FOLDER=features BMAD_DOCS_FOLDER=docs \
  BMAD_SETUP_TOOL=claude-code BMAD_SETUP_PROJECTS=alpha,beta \
  bash meta-router/skills/meta-router/scripts/setup.sh my-metarepo
```

| Variable | Effect | Default |
| --- | --- | --- |
| `BMAD_SETUP_TARGET` | directory to set up in (a positional arg still wins) | current dir |
| `BMAD_OUTPUT_FOLDER` | output folder name | `features` |
| `BMAD_DOCS_FOLDER` | docs folder name | `docs` |
| `BMAD_SETUP_SKILL_LEVEL` | `beginner`, `intermediate`, or `expert` | `intermediate` |
| `BMAD_SETUP_TOOL` | `claude-code`, `github-copilot`, or `codex` | `claude-code` |
| `BMAD_SETUP_PROJECTS` | comma-separated projects to create | none |
| `BMAD_SETUP_GITHUB_SYNC` | `y`/`n`, enable the GitHub sync (`BMAD_SETUP_ISSUES_SYNC` is also honored) | `n` |
| `BMAD_SETUP_VERBOSE` | `1` streams the BMad installer output | hidden, logged to a temp file |

`BMAD_INSTALL_MODULES` and `BMAD_INSTALL_TOOLS` override the BMad installer's module and tool selection.

## Issue sync CLI

```bash
python .claude/skills/meta-router/scripts/bmad-issues.py [sync|status] [--project NAME] [--all] [--dry-run]
```

| Flag | Does |
| --- | --- |
| `sync` (default) / `status` | write issue state, or report it without writing |
| `--project NAME`, `-p` | target a project (default: the active one) |
| `--all` | every configured project; one project's failure no longer stops the rest — failures are summarized at the end and the run exits 1 |
| `--dry-run`, `-n` | print actions without writing |

For example, `python .claude/skills/meta-router/scripts/bmad-issues.py sync --all --dry-run` previews the sync for every configured project.

Sync tuning environment variables:

| Variable | Effect | Default |
| --- | --- | --- |
| `BMAD_SYNC_THROTTLE` | pause after each issue creation (seconds) | `1.0` |
| `BMAD_SYNC_WRITE_THROTTLE` | minimum spacing between any two API mutations (seconds, `0` disables) | `0.25` |
| `BMAD_SYNC_RETRIES` | retries for rate-limited API calls (10/30/60s backoff) | `3` |

Needs `gh` authenticated. Setup and behavior live in [GitHub sync](github-sync.md).

## File manifest

The meta-router repo itself, not a generated metarepo:

```text
meta-router/
├── skills/
│   └── meta-router/                # The agent skill (gh skill install); self-contained:
│       ├── SKILL.md                #   skill definition
│       ├── scripts/
│       │   ├── setup.sh            #   bootstrap a new metarepo
│       │   ├── meta-router.sh      #   context switcher
│       │   ├── bmad-issues.py      #   GitHub Issues sync (optional)
│       │   └── bmad-github-bootstrap.sh  # board/label/template/portfolio setup (optional)
│       └── templates/
│           ├── .github/workflows/
│           │   ├── ci.yml          #   metarepo CI (shellcheck), installed into each metarepo
│           │   ├── sync-issues.yml #   GitHub Action (optional)
│           │   └── bmad-pr-ping.yml  # installed into source repos; pings the sync on story PRs
│           ├── bmad-custom/        #   BMad overrides → _bmad/custom/
│           │   ├── bmad-dev-story.toml     # create per-story worktrees on implement
│           │   ├── bmad-create-story.toml  # add "## Affected Repos" to stories
│           │   └── worktree-workflow.md    # the worktree procedure (loaded as context)
│           └── github-sync.yaml    #   per-project sync config template
├── examples/seed/                  # Seed content overlaid onto the example branch
├── .github/workflows/
│   ├── ci.yml                      # pytest + shellcheck + skill validation (this repo)
│   └── generate-example.yml        # Publishes the example branch on push to main
├── tests/                          # Router + issue-sync test suites
└── docs/                           # This documentation + banner image
```

Setup copies the whole skill directory into the metarepo at `<tool-home>/skills/meta-router/`, so a generated metarepo runs everything from there; it has no separate `scripts/` directory.
