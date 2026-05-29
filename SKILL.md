---
name: bmad-router
description: >
  Switch the active BMAD project context in a multi-project metarepo. Use this skill whenever the
  user says "switch project", "switch to <project>", "bmad-router", "change project context",
  "list projects", "which project", "active project", "current project", or references working on
  a different project within the metarepo. Also trigger when a BMAD workflow targets the wrong
  project or a symlink is missing/broken. Manages three symlinks: output folder (features by
  default), docs folder, and project-specific agent skills.
---

# bmad-router

Manages multi-project context switching in a BMAD metarepo by routing three
symlinks to the active project: output folder, docs, and agent skills.

## Architecture

```
metarepo/
├── _bmad/                              # Shared core
├── features -> projects/X/features     # Output symlink (configurable name)
├── docs -> projects/X/docs             # Docs symlink (configurable name)
├── active-project.txt
├── .agents/
│   ├── skills/
│   │   ├── shared/                     # Always-active skills
│   │   │   └── bmad-router/
│   │   └── project -> ...              # Per-project skills symlink
│   └── knowledge/                      # Shared docs (all projects)
├── projects/
│   ├── project-a/
│   │   ├── features/                   # BMAD output artifacts
│   │   │   ├── planning-artifacts/
│   │   │   │   ├── PRD.md
│   │   │   │   ├── architecture.md
│   │   │   │   └── epics/
│   │   │   ├── implementation-artifacts/
│   │   │   └── project-context.md
│   │   ├── docs/                       # Project knowledge
│   │   ├── .agents/skills/             # Project-specific skills
│   │   └── src/                        # Source code (gitignored)
│   └── project-b/
│       └── ...
└── AGENTS.md
```

## Config Resolution

| Setting | Env var | config.yaml key | Default |
|---|---|---|---|
| Output folder | `BMAD_OUTPUT_FOLDER` | `output_folder` | `features` |
| Docs folder | `BMAD_DOCS_FOLDER` | `project_knowledge` | `docs` |

Resolution order: env var → `_bmad/bmm/config.yaml` → `_bmad/config.toml` → default.

## Commands

| Command | Description |
|---|---|
| `switch <name>` | Switch all three symlinks to the named project |
| `list` | Show all projects with skill counts |
| `current` | Show active project and symlink targets |
| `init <name>` | Scaffold a new project and switch to it |
| `config` | Show resolved folder names and their sources |
| `validate` | Health check (symlinks, AGENTS.md, artifact dirs) |

## Project Skills

Each project can have agent skills at `projects/<name>/.agents/skills/`.
When the router switches to a project, `.agents/skills/project` symlinks
to that project's skills directory. Skills in `.agents/skills/shared/`
are always available regardless of the active project.

## Shared Knowledge

`.agents/knowledge/` contains documentation that applies across all projects
(org standards, shared patterns, review checklists). Always available.

## Behavior Rules

1. Before any BMAD workflow, verify the output symlink points to the right project.
2. When the user mentions a different project by name, ask before switching.
3. Never delete project artifacts — `switch` only changes symlinks.
4. Must be run from the metarepo root (detected by `_bmad/` directory).
