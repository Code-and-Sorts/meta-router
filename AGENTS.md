# AGENTS.md

This is a BMad Method multi-workspace metarepo. Read this file before doing anything.

## BMad Method

This repo uses the [BMad Method](https://github.com/bmad-code-org/BMad-METHOD) — an
agent-driven development workflow with specialized roles. The shared BMad core lives
at `_bmad/` and contains agents, workflows, and tasks.

### Workflow phases

Work flows through four phases. Each phase has a primary agent.

1. **Analysis** — The Product Owner (PO/Brainstorming agent) explores the problem space,
   gathers requirements, and produces a product brief.
2. **Planning** — The Product Manager (PM) transforms the brief into a PRD with functional
   requirements, NFRs, and success criteria.
3. **Solutioning** — The Architect designs the technical solution: system architecture,
   data models, API contracts, tech stack decisions. Output: architecture doc.
4. **Implementation** — The Scrum Master (SM) breaks the architecture into epics and
   sprint-ready stories with full implementation context. The Dev agent implements them.

### How to invoke agents

Use BMad slash commands or skill references depending on your IDE:
- Claude Code: `/pm`, `/sm`, `/architect`, `/dev`, `/bmad-help`
- Other IDEs: reference the skill files in `.claude/skills/`

If you're unsure what to do next, ask `bmad-help`.

### Key BMad files

| File | Purpose |
|---|---|
| `_bmad/bmm/config.yaml` | Module config (output folder, project knowledge, user level) |
| `.claude/knowledge/shared-context.md` | Overall shared context — org-wide standards for ALL workspaces |
| `features/workspace-context.md` | Workspace conventions, tech stack, implementation rules |
| `features/planning-artifacts/PRD.md` | Product requirements document |
| `features/planning-artifacts/architecture.md` | Technical architecture |
| `features/planning-artifacts/epics/` | Epic and story files |
| `features/implementation-artifacts/sprint-status.yaml` | Sprint planning state |

## Multi-workspace routing

This metarepo hosts multiple workspaces that share the same BMad core. Each workspace
has isolated artifacts, docs, and agent skills. Five symlinks at the repo root
point to the active workspace:

| Root symlink | Points to | Contains |
|---|---|---|
| `features/` | `workspaces/<active>/features/` | PRDs, epics, stories, sprint status |
| `docs/` | `workspaces/<active>/docs/` | Project knowledge (ADRs, specs) |
| `.claude/skills/workspace/` | `workspaces/<active>/.claude/skills/` | Workspace-specific agent skills |
| `repos/` | `workspaces/<active>/repos/` | Cloned source repos for the active workspace |
| `implementation/` | `workspaces/<active>/implementation/` | Per-story git worktrees |

### Before starting any work

1. Check which workspace is active: `bash .claude/skills/meta-router/scripts/meta-router.sh current`
2. Switch if needed: `bash .claude/skills/meta-router/scripts/meta-router.sh switch <workspace-name>`
3. Read the overall shared context (`.claude/knowledge/shared-context.md`) and the
   active workspace's context (`features/workspace-context.md`). Workspace
   context overrides shared context on conflict.
4. Never write BMad output to a workspace that isn't active.

### Switching workspaces

```bash
bash .claude/skills/meta-router/scripts/meta-router.sh list              # see all workspaces
bash .claude/skills/meta-router/scripts/meta-router.sh switch <name>     # switch context
bash .claude/skills/meta-router/scripts/meta-router.sh init <name>       # create new workspace
bash .claude/skills/meta-router/scripts/meta-router.sh validate          # health check
```

## Agent skills

This metarepo targets the **claude-code** agent tool, so agent skills live in
`.claude/skills/`. Skills are organized by scope:

- `.claude/skills/<name>/` — always-available skills (each is a directory with a
  `SKILL.md`). Includes `meta-router` and any org-wide skills.
- `.claude/skills/workspace/` — symlink to the active workspace's skills.
  Only available when that workspace is switched in.
- `.claude/knowledge/` — shared documentation available to all workspaces.
  Org standards, coding conventions, architecture patterns. Its
  `shared-context.md` is the overall shared context loaded before every workflow.

When resolving a skill reference, check the always-available skills first, then
the active workspace's `workspace/` skills.

## Rules

- Always verify the active workspace before running any BMad workflow.
- If a user mentions a workspace that isn't active, ask before switching.
- Follow the workflow phases in order: don't skip from brief to implementation.
- Read the overall shared context (`.claude/knowledge/shared-context.md`, org-wide)
  and the active workspace's `workspace-context.md` before any workflow; workspace
  context wins on conflict.
- Source repos are declared in `workspaces/<name>/repos.yaml` (tracked). Clones live
  in `workspaces/<name>/repos/` and per-story git worktrees in
  `workspaces/<name>/implementation/<story-id>/<repo>/` — both gitignored. The
  per-story worktree workflow is wired through BMad's customization at
  `_bmad/custom/bmad-dev-story.toml` (see `_bmad/custom/worktree-workflow.md`);
  do not duplicate those steps here.
- Each workspace's `docs/` is its `project_knowledge` directory.
  Shared knowledge lives in `.claude/knowledge/`, with org-wide context that
  applies to every workspace in `.claude/knowledge/shared-context.md`.
