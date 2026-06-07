# Reference

Commands, configuration, and environment variables. Run router commands from the metarepo root.

## Commands

```bash
bash scripts/meta-router.sh <command>
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

![Listing and switching](images/03-list-switch.png)
![Current state and config](images/04-current-config.png)
![Validate](images/05-validate.png)

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
  bash meta-router/setup.sh my-metarepo
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
python scripts/bmad-issues.py [sync|status] [--project NAME] [--all] [--dry-run]
```

| Flag | Does |
| --- | --- |
| `sync` (default) / `status` | write issue state, or report it without writing |
| `--project NAME`, `-p` | target a project (default: the active one) |
| `--all` | every configured project |
| `--dry-run`, `-n` | print actions without writing |

For example, `python scripts/bmad-issues.py sync --all --dry-run` previews the sync for every configured project.

Needs `gh` authenticated. Setup and behavior live in [GitHub sync](github-sync.md).

## File manifest

The meta-router repo itself, not a generated metarepo:

```text
meta-router/
├── setup.sh                        # Bootstrap a new metarepo
├── scripts/
│   ├── meta-router.sh              # Context switcher (copied into metarepo)
│   ├── bmad-issues.py              # GitHub Issues sync (optional)
│   └── bmad-github-bootstrap.sh    # Per-project board/label/template setup (optional)
├── templates/
│   ├── .github/workflows/
│   │   ├── ci.yml                  # Metarepo CI (shellcheck), installed into each metarepo
│   │   ├── sync-issues.yml         # GitHub Action (optional)
│   │   └── bmad-pr-ping.yml        # Installed into source repos; pings the sync on story PRs
│   ├── bmad-custom/                # BMad overrides → _bmad/custom/
│   │   ├── bmad-dev-story.toml     #   create per-story worktrees on implement
│   │   ├── bmad-create-story.toml  #   add "## Affected Repos" to stories
│   │   └── worktree-workflow.md    #   the worktree procedure (loaded as context)
│   └── github-sync.yaml            # Per-project sync config template
├── examples/seed/                  # Seed content overlaid onto the example branch
├── .github/workflows/
│   ├── ci.yml                      # pytest + shellcheck (this repo)
│   └── generate-example.yml        # Publishes the example branch on push to main
├── skills/
│   └── meta-router/                # Agent skill (gh skill install)
├── tests/                          # Router + issue-sync test suites
└── docs/                           # This documentation + README screenshots
```
