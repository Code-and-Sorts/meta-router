# How it works

Meta Router keeps several BMad workspaces in one repo by sharing a single `_bmad/` core and swapping which workspace the agent sees. This page covers the swap, the two context tiers, and the resulting layout.

## The symlink swap

`switch <workspace>` repoints symlinks at the repo root. BMad reads and writes through them unchanged; nothing is copied or deleted.

The output symlink's target *is* the record of which workspace is active — `current`, `validate`, and the issue sync all read the active workspace from it, so there's no separate state file to drift out of sync. The output and docs symlinks are committed (their targets are tracked), so a fresh clone already knows the active workspace; switching lands as a tracked change.

| Symlink | points to |
| --- | --- |
| `features/` | `workspaces/<workspace>/features/` |
| `docs/` | `workspaces/<workspace>/docs/` |
| `<tool-home>/skills/workspace/` | `workspaces/<workspace>/<tool-home>/skills/` |
| `repos/` | `workspaces/<workspace>/repos/` |
| `implementation/` | `workspaces/<workspace>/implementation/` |

All symlinks move together, so there's no split-brain where output and docs point at different workspaces.

`<tool-home>` follows your agent tool: `.claude` for Claude Code, `.github` for Copilot, `.codex` for Codex, `.agents` as a fallback.

## Two context tiers

**Overall shared context** (`<tool-home>/knowledge/shared-context.md`) holds org-wide standards that apply to every workspace and is global (it does *not* change on switch). Each workspace's **`workspace-context.md`** holds its own conventions and overrides the shared context on conflict. Agents read both before every workflow (BMad loads the shared one via `_bmad/custom/` `persistent_facts`).

## Layout

```text
my-metarepo/
├── _bmad/                          # shared BMad core
├── features -> workspaces/food-inventory/features      # active workspace's symlinks
├── docs -> workspaces/food-inventory/docs
├── repos -> workspaces/food-inventory/repos
├── implementation -> workspaces/food-inventory/implementation
├── .claude/                        # agent tool home (.github / .codex for other tools)
│   ├── skills/meta-router/         # the skill: SKILL.md + scripts/ + templates/
│   └── knowledge/shared-context.md # overall shared context (all workspaces)
├── workspaces/
│   ├── food-inventory/             # active
│   │   ├── features/               # PRD, architecture, epics, sprint status, workspace-context.md
│   │   ├── docs/                   # project knowledge
│   │   ├── .claude/skills/         # workspace-specific skills
│   │   ├── repos.yaml              # source-repo manifest (tracked)
│   │   ├── repos/                  # clones (gitignored)
│   │   └── implementation/         # per-story worktrees (gitignored)
│   └── camera-app/
└── AGENTS.md
```

- `_bmad/`: shared BMad core (agents, workflows, tasks), installed once.
- `workspaces/<name>/features/`: that workspace's BMad output, meaning PRD, architecture, epics, stories, sprint status, `workspace-context.md`.
- `workspaces/<name>/docs/`: that workspace's `project_knowledge`.
- `workspaces/<name>/<tool-home>/skills/`: agent skills that activate only when the workspace is switched in.
- `<tool-home>/skills/meta-router/`: the meta-router skill itself, self-contained with its `scripts/` (router, GitHub bootstrap, issue sync) and `templates/`.
- `<tool-home>/skills/<name>/`: other always-active skills.
- `<tool-home>/knowledge/`: shared docs available to every workspace.
- `<tool-home>/knowledge/shared-context.md`: overall shared context (org-wide standards) loaded for every workspace, alongside each workspace's `workspace-context.md`.
- `workspaces/<name>/repos.yaml`: manifest of the workspace's source repos (tracked). Clones and worktrees are gitignored.
- `AGENTS.md`: root context file for the agent.

## Design notes

- One BMad version serves all workspaces, since they share `_bmad/`.
- The metarepo tracks planning artifacts, not source. Clones (`workspaces/*/repos/`) and worktrees (`workspaces/*/implementation/`) are gitignored; see [worktrees](worktrees.md).
- The default output folder is `features`, not BMad's `_bmad-output`; it reads better in a metarepo. Change it during setup or in `config.yaml` (see [configuration](reference.md#configuration)).
