---
name: meta-router
description: >
  Set up and operate a multi-workspace BMad metarepo. Use this skill whenever the user wants to
  create a metarepo (run setup.sh), switch the active BMad workspace, list workspaces, check or fix
  symlinks, clone source repos, create per-story worktrees, or set up the GitHub Issues + Projects
  sync (boards, labels, issue trees). Trigger phrases: "meta router", "meta-router", "switch
  workspace", "switch to <workspace>", "change workspace context", "list workspaces", "which workspace",
  "active workspace", "set up a metarepo", "bootstrap github projects", "sync issues". Also trigger
  when a BMad workflow targets the wrong workspace or a symlink is missing/broken.
license: MIT
---

# meta-router

Sets up and operates a BMad metarepo: one shared `_bmad/` core, several
workspaces, one active at a time. Switching routes five symlinks to the active
workspace (output folder, docs, source-repo clones `repos/`, per-story worktrees
`implementation/`, and workspace skills). Optionally mirrors BMad artifacts to
GitHub Issues + Projects.

## Setting up a metarepo

The setup script ships inside this skill:

```bash
bash <skill-dir>/scripts/setup.sh <target-dir>
```

(`<skill-dir>` is wherever this skill is installed, e.g.
`~/.claude/skills/meta-router` or a clone's `skills/meta-router`.)

Interactive prompts cover output/docs folder names, BMad skill level, agent
tool (`claude-code` | `github-copilot` | `codex`), workspaces to create, and
whether to enable GitHub sync. It then installs BMad and scaffolds the layout
below. Non-interactive: set `BMAD_SETUP_NONINTERACTIVE=1` and answer via
`BMAD_OUTPUT_FOLDER`, `BMAD_DOCS_FOLDER`, `BMAD_SETUP_SKILL_LEVEL`,
`BMAD_SETUP_TOOL`, `BMAD_SETUP_WORKSPACES`, `BMAD_SETUP_GITHUB_SYNC`.

## Architecture

```
metarepo/
├── _bmad/                              # Shared core
├── features -> workspaces/X/features             # Output symlink (committed; records active workspace)
├── docs -> workspaces/X/docs                     # Docs symlink (committed; configurable name)
├── repos -> workspaces/X/repos                   # Source repo clones (active workspace)
├── implementation -> workspaces/X/implementation  # Per-story worktrees (active workspace)
├── .claude/                            # Agent tool home — tool-specific dir (see below)
│   ├── skills/
│   │   ├── meta-router/                # This skill: SKILL.md + scripts/ + templates/
│   │   └── workspace -> ...              # Per-workspace skills symlink
│   └── knowledge/                      # Shared docs (all workspaces)
│       └── shared-context.md           # Overall shared context (all workspaces)
├── workspaces/
│   ├── workspace-a/
│   │   ├── features/                   # BMad output artifacts
│   │   │   ├── planning-artifacts/
│   │   │   │   ├── PRD.md
│   │   │   │   ├── architecture.md
│   │   │   │   └── epics/
│   │   │   ├── implementation-artifacts/
│   │   │   └── workspace-context.md
│   │   ├── docs/                       # Project knowledge
│   │   ├── .claude/skills/             # Workspace-specific skills (tool dir)
│   │   ├── repos.yaml                  # Source repo manifest (tracked)
│   │   ├── repos/                      # Git clones of source repos (gitignored)
│   │   └── implementation/             # Per-story worktrees (gitignored)
│   │       └── <story-id>/<repo>/      #   branch story/<story-id>
│   └── workspace-b/
│       └── ...
└── AGENTS.md
```

## Config Resolution

| Setting | Env var | config.yaml key | Default |
|---|---|---|---|
| Output folder | `BMAD_OUTPUT_FOLDER` | `output_folder` | `features` |
| Docs folder | `BMAD_DOCS_FOLDER` | `project_knowledge` | `docs` |
| Agent tool | `BMAD_AGENT_TOOL` | `agent_tool` | `claude-code` |

Resolution order: env var → `_bmad/bmm/config.yaml` → `_bmad/config.toml` → default.

The agent tool determines its home directory, under which both agent skills
(`skills/`) and shared knowledge (`knowledge/`) live, since each tool reads them
from its own conventional location:

| Agent tool | Home dir | Skills | Shared knowledge |
|---|---|---|---|
| `claude-code` | `.claude/` | `.claude/skills/` | `.claude/knowledge/` |
| `github-copilot` | `.github/` | `.github/skills/` | `.github/knowledge/` |
| `codex` | `.codex/` | `.codex/skills/` | `.codex/knowledge/` |

An unrecognized tool falls back to the tool-agnostic `.agents/` home.

## Commands

The scripts ship inside this skill. All run from the metarepo root:
`bash <tool-home>/skills/meta-router/scripts/meta-router.sh <command>`
(`<tool-home>` is `.claude`, `.github`, or `.codex` — see Config Resolution).

| Command | Description |
|---|---|
| `switch <name>` | Switch all five symlinks to the named workspace |
| `list` | Show all workspaces with skill counts |
| `current` | Show active workspace and symlink targets |
| `init <name>` | Scaffold a new workspace and switch to it |
| `config` | Show resolved folder names and their sources |
| `validate` | Health check (symlinks, AGENTS.md, artifact dirs) |
| `repos` | List the active workspace's source repos (from repos.yaml) |
| `clone [repo]` | Clone repos.yaml entries into `repos/` |
| `worktree <story> [repo...]` | Create a per-story worktree per repo (`--all` for every repo) |
| `worktree list` | List active per-story worktrees |
| `worktree-rm <story>` | Remove all worktrees for a story |

## Workspace Skills

Skills live in the active agent tool's skills directory (`.claude/skills/` for
Claude Code by default — see Config Resolution). Each workspace can have its own
agent skills at `workspaces/<name>/<skills-dir>/`. When the router switches to a
workspace, `<skills-dir>/workspace` symlinks to that workspace's skills directory.
Always-active skills (like `meta-router`) live directly at
`<skills-dir>/<name>/` and are available regardless of the active workspace.

## Shared Knowledge

The agent tool's `knowledge/` directory (`.claude/knowledge/` for Claude Code by
default — see Config Resolution) contains documentation that applies across all
workspaces (org standards, shared patterns, review checklists). Always available.

Its `shared-context.md` is the **overall shared context** — a first-class,
org-wide context file that applies to every workspace, symmetric in role to a
workspace's `workspace-context.md`. Agents read it before every workflow alongside
the active workspace's `workspace-context.md`; workspace context overrides shared
context on conflict. BMad loads it deterministically via a `persistent_facts`
`file:` reference in `_bmad/custom/bmad-dev-story.toml` and
`bmad-create-story.toml` (the same mechanism that loads `worktree-workflow.md`).

## Source Repos and Worktrees

Each workspace lists its source repos in a tracked `workspaces/<name>/repos.yaml`.
`clone` pulls them into the gitignored `repos/`. When implementing a story,
`worktree <story-id> [repo...]` creates one git worktree per affected repo under
`implementation/<story-id>/<repo>/`, each on branch `story/<story-id>`. A
full-stack story can span several repos at once.

This is wired through BMad's customization at `_bmad/custom/bmad-dev-story.toml`
(and `bmad-create-story.toml`): the Scrum Master adds a `## Affected Repos`
section to each story, and the Dev agent reads it to create the right worktrees
before implementing. See `_bmad/custom/worktree-workflow.md`.

## GitHub Issues + Projects sync

Optional. Mirrors each workspace's BMad artifacts to a private GitHub Project
board and two label-separated issue trees (`bmad-delivery`: Feature → Epic →
Story sub-issues driven by `sprint-status.yaml` and the PRDs; `bmad-planning`:
one planning checklist issue per workspace). Setup, per workspace, in a metarepo
pushed to GitHub:

1. `bash <tool-home>/skills/meta-router/scripts/bmad-github-bootstrap.sh <workspace>`
   creates the private board, labels, and issue types (first run can save an
   org-level view template so later boards copy their views). Optionally run it
   with `--portfolio` to also create one org-wide board aggregating every
   workspace, sliced by a Project field.
2. Add a `BMAD_PROJECT_TOKEN` secret: PAT with Projects read/write, Issues
   read/write, Pull requests read. The default `GITHUB_TOKEN` cannot access
   Projects v2.
3. Install the skill's `templates/.github/workflows/bmad-pr-ping.yml` into each
   source repo so story PRs update the board immediately.

Run the sync locally with
`python <tool-home>/skills/meta-router/scripts/bmad-issues.py sync --dry-run`
(`--all` for every configured workspace; needs `gh` authenticated). The sync is
the single writer of issue state: BMad statuses map to Backlog / Ready /
In Progress / In Review / Done, an open PR on a `story/<key>` branch forces
In Review, and re-runs are idempotent (hidden `<!-- bmad-sync -->` markers).

## Behavior Rules

1. Before any BMad workflow, verify the output symlink points to the right workspace.
2. When the user mentions a different workspace by name, ask before switching.
3. Never delete workspace artifacts — `switch` only changes symlinks.
4. Router commands must run from the metarepo root (detected by `_bmad/` directory).
5. Before implementing a story, create its worktrees with `worktree <story-id>`
   for the repos in its `## Affected Repos` section; implement inside those
   worktrees, never directly in `repos/`.
6. When running the issue sync, prefer `--dry-run` first and show the user what
   would change before a real run.
