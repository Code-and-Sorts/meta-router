---
name: router-project-switch
description: >
  Switch the active BMad project context in a multi-project metarepo. Use this skill whenever the
  user says "switch project", "switch to <project>", "bmad-router", "change project context",
  "list projects", "which project", "active project", "current project", or references working on
  a different project within the metarepo. Also trigger when a BMad workflow targets the wrong
  project or a symlink is missing/broken. Manages five symlinks: output folder (features by
  default), docs folder, source-repo clones (`repos/`), per-story worktrees (`implementation/`), and project-specific agent skills.
---

# router-project-switch

Manages multi-project context switching in a BMad metarepo by routing five
symlinks to the active project: output folder, docs, source-repo clones
(`repos/`), per-story worktrees (`implementation/`), and agent skills.

## Architecture

```
metarepo/
├── _bmad/                              # Shared core
├── features -> projects/X/features             # Output symlink (configurable name)
├── docs -> projects/X/docs                     # Docs symlink (configurable name)
├── repos -> projects/X/repos                   # Source repo clones (active project)
├── implementation -> projects/X/implementation  # Per-story worktrees (active project)
├── active-project.txt
├── .claude/                            # Agent tool home — tool-specific dir (see below)
│   ├── skills/
│   │   ├── router-project-switch/      # Always-active skill (flat, not nested)
│   │   └── project -> ...              # Per-project skills symlink
│   └── knowledge/                      # Shared docs (all projects)
│       └── shared-context.md           # Overall shared context (all projects)
├── projects/
│   ├── project-a/
│   │   ├── features/                   # BMad output artifacts
│   │   │   ├── planning-artifacts/
│   │   │   │   ├── PRD.md
│   │   │   │   ├── architecture.md
│   │   │   │   └── epics/
│   │   │   ├── implementation-artifacts/
│   │   │   └── project-context.md
│   │   ├── docs/                       # Project knowledge
│   │   ├── .claude/skills/             # Project-specific skills (tool dir)
│   │   ├── repos.yaml                  # Source repo manifest (tracked)
│   │   ├── repos/                      # Git clones of source repos (gitignored)
│   │   └── implementation/             # Per-story worktrees (gitignored)
│   │       └── <story-id>/<repo>/      #   branch story/<story-id>
│   └── project-b/
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

| Command | Description |
|---|---|
| `switch <name>` | Switch all five symlinks to the named project |
| `list` | Show all projects with skill counts |
| `current` | Show active project and symlink targets |
| `init <name>` | Scaffold a new project and switch to it |
| `config` | Show resolved folder names and their sources |
| `validate` | Health check (symlinks, AGENTS.md, artifact dirs) |
| `repos` | List the active project's source repos (from repos.yaml) |
| `clone [repo]` | Clone repos.yaml entries into `repos/` |
| `worktree <story> [repo...]` | Create a per-story worktree per repo (`--all` for every repo) |
| `worktree list` | List active per-story worktrees |
| `worktree-rm <story>` | Remove all worktrees for a story |

## Project Skills

Skills live in the active agent tool's skills directory (`.claude/skills/` for
Claude Code by default — see Config Resolution). Each project can have its own
agent skills at `projects/<name>/<skills-dir>/`. When the router switches to a
project, `<skills-dir>/project` symlinks to that project's skills directory.
Always-active skills (like `router-project-switch`) live directly at
`<skills-dir>/<name>/` and are available regardless of the active project.

## Shared Knowledge

The agent tool's `knowledge/` directory (`.claude/knowledge/` for Claude Code by
default — see Config Resolution) contains documentation that applies across all
projects (org standards, shared patterns, review checklists). Always available.

Its `shared-context.md` is the **overall shared context** — a first-class,
org-wide context file that applies to every project, symmetric in role to a
project's `project-context.md`. Agents read it before every workflow alongside
the active project's `project-context.md`; project context overrides shared
context on conflict. BMad loads it deterministically via a `persistent_facts`
`file:` reference in `_bmad/custom/bmad-dev-story.toml` and
`bmad-create-story.toml` (the same mechanism that loads `worktree-workflow.md`).

## Source Repos and Worktrees

Each project lists its source repos in a tracked `projects/<name>/repos.yaml`.
`clone` pulls them into the gitignored `repos/`. When implementing a story,
`worktree <story-id> [repo...]` creates one git worktree per affected repo under
`implementation/<story-id>/<repo>/`, each on branch `story/<story-id>`. A
full-stack story can span several repos at once.

This is wired through BMad's customization at `_bmad/custom/bmad-dev-story.toml`
(and `bmad-create-story.toml`): the Scrum Master adds a `## Affected Repos`
section to each story, and the Dev agent reads it to create the right worktrees
before implementing. See `_bmad/custom/worktree-workflow.md`.

## Behavior Rules

1. Before any BMad workflow, verify the output symlink points to the right project.
2. When the user mentions a different project by name, ask before switching.
3. Never delete project artifacts — `switch` only changes symlinks.
4. Must be run from the metarepo root (detected by `_bmad/` directory).
5. Before implementing a story, create its worktrees with `worktree <story-id>`
   for the repos in its `## Affected Repos` section; implement inside those
   worktrees, never directly in `repos/`.
