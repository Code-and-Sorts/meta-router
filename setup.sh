#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# setup.sh — Bootstrap a BMAD multi-project metarepo
# ─────────────────────────────────────────────────────────────────────────────

SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

die() { echo -e "${RED}error:${NC} $*" >&2; exit 1; }
info() { echo -e "${CYAN}→${NC} $*"; }
ok() { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
step() { echo -e "\n${BOLD}[$1/$TOTAL_STEPS] $2${NC}"; }

TOTAL_STEPS=9

# Map an agent tool to its home directory (relative to the metarepo root). Skills
# and shared knowledge live under it (skills/ and knowledge/). Kept in sync with
# tool_dir_for_tool in scripts/bmad-router.sh.
tool_dir_for_tool() {
  case "$1" in
    claude-code)    echo ".claude" ;;
    github-copilot) echo ".github" ;;
    codex)          echo ".codex" ;;
    *)              echo ".agents" ;;
  esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Parse args
# ─────────────────────────────────────────────────────────────────────────────

NONINTERACTIVE="${BMAD_SETUP_NONINTERACTIVE:-0}"

echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║          BMAD Metarepo Setup                                ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"

# Resolve the target directory — the run's output, i.e. the folder the metarepo
# is set up in. Precedence:
#   positional arg  >  BMAD_SETUP_TARGET env  >  interactive prompt  >  current dir
TARGET_INPUT="${1:-${BMAD_SETUP_TARGET:-}}"
if [[ -z "$TARGET_INPUT" && "$NONINTERACTIVE" != 1 ]]; then
  read -rp "  Directory to set up the metarepo in [.]: " TARGET_INPUT
fi
TARGET_INPUT="${TARGET_INPUT:-.}"
if [[ "$TARGET_INPUT" != "." ]]; then mkdir -p "$TARGET_INPUT"; fi
TARGET="$(cd "$TARGET_INPUT" && pwd)"

echo -e "  ${DIM}Target: $TARGET${NC}"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Gather preferences
# ─────────────────────────────────────────────────────────────────────────────

step 1 "Configuration"

# Non-interactive mode for CI / scripted installs. When BMAD_SETUP_NONINTERACTIVE=1,
# every prompt is skipped and answers are sourced from environment variables:
#   BMAD_SETUP_TARGET      directory to set up in  (default: current dir; the
#                          positional arg, if given, still takes precedence)
#   BMAD_OUTPUT_FOLDER     output folder name      (default: features)
#   BMAD_DOCS_FOLDER       docs folder name        (default: docs)
#   BMAD_SETUP_TOOL        agent tool              (claude-code|github-copilot|codex; default: claude-code)
#   BMAD_SETUP_PROJECTS    comma-separated projects (default: none)
#   BMAD_SETUP_ISSUES_SYNC y/n to enable sync       (default: n)
if [[ "$NONINTERACTIVE" == 1 ]]; then
  info "Non-interactive mode (BMAD_SETUP_NONINTERACTIVE=1)"
fi

# Output folder name
if [[ "$NONINTERACTIVE" == 1 ]]; then
  USER_OUTPUT_FOLDER="${BMAD_OUTPUT_FOLDER:-features}"
else
  echo -e "  What should the output folder be called?"
  echo -e "  This is where PRDs, epics, stories, and architecture docs live."
  echo -e "  ${DIM}(BMAD default: _bmad-output)${NC}"
  echo ""
  read -rp "  Output folder name [features]: " USER_OUTPUT_FOLDER
  USER_OUTPUT_FOLDER="${USER_OUTPUT_FOLDER:-features}"
fi

# Validate folder name
if [[ ! "$USER_OUTPUT_FOLDER" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  die "Folder name must contain only letters, numbers, dots, hyphens, and underscores."
fi

echo ""
ok "Output folder: ${BOLD}$USER_OUTPUT_FOLDER${NC}"

# Docs folder name
if [[ "$NONINTERACTIVE" == 1 ]]; then
  USER_DOCS_FOLDER="${BMAD_DOCS_FOLDER:-docs}"
else
  echo ""
  echo -e "  What should the docs folder be called?"
  echo -e "  This is project_knowledge — ADRs, specs, domain docs."
  echo ""
  read -rp "  Docs folder name [docs]: " USER_DOCS_FOLDER
  USER_DOCS_FOLDER="${USER_DOCS_FOLDER:-docs}"
fi

if [[ ! "$USER_DOCS_FOLDER" =~ ^[a-zA-Z0-9._-]+$ ]]; then
  die "Folder name must contain only letters, numbers, dots, hyphens, and underscores."
fi

ok "Docs folder: ${BOLD}$USER_DOCS_FOLDER${NC}"

# Agent tool — determines which IDE/agent BMAD integrates with and, in turn,
# where agent skills live (each tool reads them from its own directory).
if [[ "$NONINTERACTIVE" == 1 ]]; then
  AGENT_TOOL="${BMAD_SETUP_TOOL:-claude-code}"
else
  echo ""
  echo -e "  Which agent tool are you setting up for?"
  echo -e "  ${DIM}This selects the BMAD integration and where agent skills live.${NC}"
  echo ""
  echo -e "    1) Claude Code     ${DIM}(skills in .claude/skills/)${NC}"
  echo -e "    2) GitHub Copilot  ${DIM}(skills in .github/skills/)${NC}"
  echo -e "    3) Codex           ${DIM}(skills in .codex/skills/)${NC}"
  echo ""
  read -rp "  Tool [1]: " TOOL_CHOICE
  case "$TOOL_CHOICE" in
    2|github-copilot|copilot) AGENT_TOOL="github-copilot" ;;
    3|codex)                  AGENT_TOOL="codex" ;;
    *)                        AGENT_TOOL="claude-code" ;;
  esac
fi

case "$AGENT_TOOL" in
  claude-code|github-copilot|codex) ;;
  *) die "Unsupported agent tool: '$AGENT_TOOL' (expected claude-code, github-copilot, or codex)" ;;
esac
TOOL_DIR="$(tool_dir_for_tool "$AGENT_TOOL")"
SKILLS_BASE="$TOOL_DIR/skills"
KNOWLEDGE_BASE="$TOOL_DIR/knowledge"
ok "Agent tool: ${BOLD}$AGENT_TOOL${NC} ${DIM}(skills: $SKILLS_BASE/, knowledge: $KNOWLEDGE_BASE/)${NC}"

# Initial projects
if [[ "$NONINTERACTIVE" == 1 ]]; then
  USER_PROJECTS="${BMAD_SETUP_PROJECTS:-}"
else
  echo ""
  echo -e "  Projects to create (comma-separated, or leave blank to skip):"
  echo -e "  ${DIM}Example: food-inventory, film-camera-app, diy-camera${NC}"
  echo ""
  read -rp "  Projects: " USER_PROJECTS
  echo ""
fi

# Parse and validate project names
PROJECTS=()
if [[ -n "$USER_PROJECTS" ]]; then
  IFS=',' read -ra RAW_PROJECTS <<< "$USER_PROJECTS"
  for p in "${RAW_PROJECTS[@]}"; do
    p="$(echo "$p" | xargs)" # trim whitespace
    if [[ -z "$p" ]]; then continue; fi
    if [[ ! "$p" =~ ^[a-zA-Z0-9_-]+$ ]]; then
      die "Invalid project name: '$p' (only letters, numbers, hyphens, underscores)"
    fi
    PROJECTS+=("$p")
  done
  ok "Projects: ${BOLD}${PROJECTS[*]}${NC}"
else
  info "No initial projects — you can create them later with bmad-router init"
fi

# GitHub Issues sync
if [[ "$NONINTERACTIVE" == 1 ]]; then
  USER_ISSUES_SYNC="${BMAD_SETUP_ISSUES_SYNC:-n}"
else
  echo ""
  echo -e "  Enable GitHub Issues sync? This adds a GitHub Action that"
  echo -e "  creates issues from sprint-status.yaml when stories are ready."
  echo -e "  ${DIM}(Requires gh CLI and a GitHub repo per project)${NC}"
  echo ""
  read -rp "  Enable issues sync? [y/N]: " USER_ISSUES_SYNC
fi
ENABLE_ISSUES=false
if [[ "${USER_ISSUES_SYNC,,}" == "y" || "${USER_ISSUES_SYNC,,}" == "yes" ]]; then
  ENABLE_ISSUES=true
  ok "GitHub Issues sync: enabled"
else
  info "GitHub Issues sync: skipped (you can add it later)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Check prerequisites
# ─────────────────────────────────────────────────────────────────────────────

step 2 "Checking prerequisites"

if command -v node &>/dev/null; then
  ok "Node.js $(node --version)"
else
  warn "Node.js not found — BMAD install requires it"
  die "Install from https://nodejs.org or via your package manager"
fi

if command -v npx &>/dev/null; then
  ok "npx available"
else
  die "npx not found (should come with Node.js)"
fi

if command -v git &>/dev/null; then
  ok "git $(git --version | cut -d' ' -f3)"
else
  warn "git not found — repo won't be initialized"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Initialize git repo if needed
# ─────────────────────────────────────────────────────────────────────────────

step 3 "Initializing repository"
cd "$TARGET"

if [[ -d ".git" ]]; then
  ok "Git repo already initialized"
else
  if command -v git &>/dev/null; then
    git init -q
    ok "Initialized git repo"
  else
    warn "Skipping git init"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Install BMAD if not present
# ─────────────────────────────────────────────────────────────────────────────

step 4 "Checking BMAD installation"

if [[ -d "_bmad" ]]; then
  ok "BMAD core already installed"
else
  info "Installing BMAD Method..."
  # Non-interactive install (BMAD v6): --yes skips prompts where possible,
  # --directory pins the target (the installer otherwise prompts for it on a TTY
  # and stalls on non-TTY stdin), --modules picks the module set (core auto-added),
  # --tools targets the IDE/agent integration (required for fresh --yes installs).
  # Override the module/tool selection via BMAD_INSTALL_MODULES / BMAD_INSTALL_TOOLS.
  BMAD_INSTALL_MODULES="${BMAD_INSTALL_MODULES:-bmm}"
  BMAD_INSTALL_TOOLS="${BMAD_INSTALL_TOOLS:-$AGENT_TOOL}"
  if npx bmad-method install --yes --directory . \
       --modules "$BMAD_INSTALL_MODULES" --tools "$BMAD_INSTALL_TOOLS" </dev/null; then
    ok "BMAD installed"
  else
    warn "BMAD auto-install failed — creating minimal skeleton"
    mkdir -p _bmad/bmm/agents _bmad/core/tasks _bmad/custom
  fi
fi

# Write output_folder and project_knowledge into config.yaml
YAML_CFG="_bmad/bmm/config.yaml"
if [[ -f "$YAML_CFG" ]]; then
  # Update existing config — replace or append
  # `sed -i.bak` is portable across GNU (Linux/CI) and BSD (macOS) sed.
  if grep -qE '^\s*output_folder\s*:' "$YAML_CFG" 2>/dev/null; then
    sed -i.bak "s|^\(\s*output_folder\s*:\).*|\1 \"{project-root}/$USER_OUTPUT_FOLDER\"|" "$YAML_CFG" && rm -f "$YAML_CFG.bak"
  else
    echo "output_folder: \"{project-root}/$USER_OUTPUT_FOLDER\"" >> "$YAML_CFG"
  fi
  # BMAD's planning_artifacts / implementation_artifacts keys point into the
  # output folder (they default to the {project-root}/_bmad-output/* paths), so
  # repoint them at the chosen output folder too — otherwise BMAD writes those
  # artifacts to _bmad-output/ while the router routes the renamed folder.
  if grep -qE '^\s*planning_artifacts\s*:' "$YAML_CFG" 2>/dev/null; then
    sed -i.bak "s|^\(\s*planning_artifacts\s*:\).*|\1 \"{project-root}/$USER_OUTPUT_FOLDER/planning-artifacts\"|" "$YAML_CFG" && rm -f "$YAML_CFG.bak"
  else
    echo "planning_artifacts: \"{project-root}/$USER_OUTPUT_FOLDER/planning-artifacts\"" >> "$YAML_CFG"
  fi
  if grep -qE '^\s*implementation_artifacts\s*:' "$YAML_CFG" 2>/dev/null; then
    sed -i.bak "s|^\(\s*implementation_artifacts\s*:\).*|\1 \"{project-root}/$USER_OUTPUT_FOLDER/implementation-artifacts\"|" "$YAML_CFG" && rm -f "$YAML_CFG.bak"
  else
    echo "implementation_artifacts: \"{project-root}/$USER_OUTPUT_FOLDER/implementation-artifacts\"" >> "$YAML_CFG"
  fi
  if grep -qE '^\s*project_knowledge\s*:' "$YAML_CFG" 2>/dev/null; then
    sed -i.bak "s|^\(\s*project_knowledge\s*:\).*|\1 \"{project-root}/$USER_DOCS_FOLDER\"|" "$YAML_CFG" && rm -f "$YAML_CFG.bak"
  else
    echo "project_knowledge: \"{project-root}/$USER_DOCS_FOLDER\"" >> "$YAML_CFG"
  fi
  if grep -qE '^\s*agent_tool\s*:' "$YAML_CFG" 2>/dev/null; then
    sed -i.bak "s|^\(\s*agent_tool\s*:\).*|\1 \"$AGENT_TOOL\"|" "$YAML_CFG" && rm -f "$YAML_CFG.bak"
  else
    echo "agent_tool: \"$AGENT_TOOL\"" >> "$YAML_CFG"
  fi
  ok "Updated config.yaml: output_folder=$USER_OUTPUT_FOLDER, project_knowledge=$USER_DOCS_FOLDER, agent_tool=$AGENT_TOOL"
else
  mkdir -p "$(dirname "$YAML_CFG")"
  cat > "$YAML_CFG" << YAML
output_folder: "{project-root}/$USER_OUTPUT_FOLDER"
planning_artifacts: "{project-root}/$USER_OUTPUT_FOLDER/planning-artifacts"
implementation_artifacts: "{project-root}/$USER_OUTPUT_FOLDER/implementation-artifacts"
project_knowledge: "{project-root}/$USER_DOCS_FOLDER"
agent_tool: "$AGENT_TOOL"
YAML
  ok "Created config.yaml with custom folder names"
fi

# Remove installer-created output dir if present (router manages it as symlink).
# The installer scaffolds _bmad-output/{planning,implementation}-artifacts/ as
# empty dirs; since we repoint those artifact paths at the chosen output folder,
# that skeleton is orphaned. Match on files only (-type f) so a tree of empty
# dirs still counts as removable.
for candidate in _bmad-output "$USER_OUTPUT_FOLDER"; do
  if [[ -d "$candidate" && ! -L "$candidate" ]]; then
    local_files=$(find "$candidate" -type f -not -name '.gitkeep' | head -1)
    if [[ -z "$local_files" ]]; then
      rm -rf "$candidate"
      info "Removed empty $candidate/ (router will manage as symlink)"
    fi
  fi
done

# Same for docs
if [[ -d "$USER_DOCS_FOLDER" && ! -L "$USER_DOCS_FOLDER" ]]; then
  local_files=$(find "$USER_DOCS_FOLDER" -type f -not -name '.gitkeep' | head -1)
  if [[ -z "$local_files" ]]; then
    rm -rf "$USER_DOCS_FOLDER"
    info "Removed empty $USER_DOCS_FOLDER/ (router will manage as symlink)"
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: Create directory structure
# ─────────────────────────────────────────────────────────────────────────────

step 5 "Creating directory structure"

mkdir -p projects
mkdir -p scripts
mkdir -p "$SKILLS_BASE/router-project-switch"
mkdir -p "$KNOWLEDGE_BASE"

ok "projects/"
ok "scripts/"
ok "$SKILLS_BASE/ (always-active skills)"
ok "$KNOWLEDGE_BASE/ (shared across all projects)"

# ─────────────────────────────────────────────────────────────────────────────
# Step 6: Copy bmad-router files
# ─────────────────────────────────────────────────────────────────────────────

step 6 "Installing bmad-router"

if [[ -f "$SETUP_DIR/scripts/bmad-router.sh" ]]; then
  cp "$SETUP_DIR/scripts/bmad-router.sh" scripts/bmad-router.sh
  chmod +x scripts/bmad-router.sh
  ok "scripts/bmad-router.sh"
else
  die "Cannot find scripts/bmad-router.sh relative to setup.sh"
fi

if [[ -f "$SETUP_DIR/SKILL.md" ]]; then
  cp "$SETUP_DIR/SKILL.md" "$SKILLS_BASE/router-project-switch/SKILL.md"
  ok "$SKILLS_BASE/router-project-switch/SKILL.md"
fi

# Install CI workflow so the metarepo lints its bundled shell script.
if [[ -f "$SETUP_DIR/templates/.github/workflows/ci.yml" ]]; then
  mkdir -p .github/workflows
  cp "$SETUP_DIR/templates/.github/workflows/ci.yml" .github/workflows/ci.yml
  ok ".github/workflows/ci.yml"
fi

# Seed shared knowledge README
if [[ ! -f "$KNOWLEDGE_BASE/README.md" ]]; then
  cat > "$KNOWLEDGE_BASE/README.md" << 'KNOWLEDGEMD'
# Shared Knowledge

Documentation and conventions that apply across all projects in this metarepo.
BMAD agents can reference these files regardless of which project is active.

Examples:
  - org-standards.md — Coding standards and conventions
  - architecture-patterns.md — Approved patterns and anti-patterns
  - review-checklist.md — PR review requirements
KNOWLEDGEMD
  ok "$KNOWLEDGE_BASE/README.md"
fi

# Install BMAD customization overrides that drive per-story git worktrees.
# These hook the bmad-dev-story / bmad-create-story skills via _bmad/custom/.
if [[ -d "$SETUP_DIR/templates/bmad-custom" && -d "_bmad" ]]; then
  mkdir -p _bmad/custom
  for f in bmad-dev-story.toml bmad-create-story.toml worktree-workflow.md; do
    if [[ -f "$SETUP_DIR/templates/bmad-custom/$f" && ! -f "_bmad/custom/$f" ]]; then
      cp "$SETUP_DIR/templates/bmad-custom/$f" "_bmad/custom/$f"
      ok "_bmad/custom/$f"
    fi
  done
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 7: Install GitHub Issues sync (optional)
# ─────────────────────────────────────────────────────────────────────────────

step 7 "GitHub Issues sync"

if [[ "$ENABLE_ISSUES" == true ]]; then
  # Copy sync script
  if [[ -f "$SETUP_DIR/scripts/bmad-issues.py" ]]; then
    cp "$SETUP_DIR/scripts/bmad-issues.py" scripts/bmad-issues.py
    ok "scripts/bmad-issues.py"
  fi

  # Copy workflow
  if [[ -d "$SETUP_DIR/templates/.github" ]]; then
    mkdir -p .github/workflows
    cp "$SETUP_DIR/templates/.github/workflows/sync-issues.yml" .github/workflows/
    ok ".github/workflows/sync-issues.yml"
  fi

  # Copy sync config template into each project
  if [[ -f "$SETUP_DIR/templates/github-sync.yaml" ]]; then
    for project in "${PROJECTS[@]}"; do
      if [[ -d "projects/$project" && ! -f "projects/$project/github-sync.yaml" ]]; then
        cp "$SETUP_DIR/templates/github-sync.yaml" "projects/$project/github-sync.yaml"
        ok "projects/$project/github-sync.yaml (edit repo field)"
      fi
    done
  fi

  echo ""
  info "To complete issues sync setup:"
  echo -e "  1. Edit each project's github-sync.yaml with the target repo"
  echo -e "  2. Create 'epic', 'story', 'bug' labels in each target repo"
  echo -e "  3. If target repos differ from this one, add a BMAD_ISSUES_TOKEN secret"
else
  info "Skipped — run setup again or copy templates/ manually to enable later"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 8: Generate AGENT.md and .gitignore
# ─────────────────────────────────────────────────────────────────────────────

step 8 "Generating AGENTS.md and .gitignore"

if [[ -f "AGENTS.md" ]]; then
  warn "AGENTS.md already exists — skipping"
elif [[ -f "AGENT.md" ]]; then
  warn "AGENT.md exists — rename to AGENTS.md for cross-agent compatibility"
else
  cat > AGENTS.md << AGENTMD
# AGENTS.md

This is a BMAD Method multi-project metarepo. Read this file before doing anything.

## BMAD Method

This repo uses the [BMAD Method](https://github.com/bmad-code-org/BMAD-METHOD) — an
agent-driven development workflow with specialized roles. The shared BMAD core lives
at \`_bmad/\` and contains agents, workflows, and tasks.

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

Use BMAD slash commands or skill references depending on your IDE:
- Claude Code: \`/pm\`, \`/sm\`, \`/architect\`, \`/dev\`, \`/bmad-help\`
- Other IDEs: reference the skill files in \`$SKILLS_BASE/\`

If you're unsure what to do next, ask \`bmad-help\`.

### Key BMAD files

| File | Purpose |
|---|---|
| \`_bmad/bmm/config.yaml\` | Module config (output folder, project knowledge, user level) |
| \`$USER_OUTPUT_FOLDER/project-context.md\` | Project conventions, tech stack, implementation rules |
| \`$USER_OUTPUT_FOLDER/planning-artifacts/PRD.md\` | Product requirements document |
| \`$USER_OUTPUT_FOLDER/planning-artifacts/architecture.md\` | Technical architecture |
| \`$USER_OUTPUT_FOLDER/planning-artifacts/epics/\` | Epic and story files |
| \`$USER_OUTPUT_FOLDER/implementation-artifacts/sprint-status.yaml\` | Sprint planning state |

## Multi-project routing

This metarepo hosts multiple projects that share the same BMAD core. Each project
has isolated artifacts, docs, and agent skills. Three symlinks at the repo root
point to the active project:

| Root symlink | Points to | Contains |
|---|---|---|
| \`$USER_OUTPUT_FOLDER/\` | \`projects/<active>/$USER_OUTPUT_FOLDER/\` | PRDs, epics, stories, sprint status |
| \`$USER_DOCS_FOLDER/\` | \`projects/<active>/$USER_DOCS_FOLDER/\` | Project knowledge (ADRs, specs) |
| \`$SKILLS_BASE/project/\` | \`projects/<active>/$SKILLS_BASE/\` | Project-specific agent skills |

### Before starting any work

1. Check which project is active: \`bash scripts/bmad-router.sh current\`
2. Switch if needed: \`bash scripts/bmad-router.sh switch <project-name>\`
3. Read the project context: \`$USER_OUTPUT_FOLDER/project-context.md\`
4. Never write BMAD output to a project that isn't active.

### Switching projects

\`\`\`bash
bash scripts/bmad-router.sh list              # see all projects
bash scripts/bmad-router.sh switch <name>     # switch context
bash scripts/bmad-router.sh init <name>       # create new project
bash scripts/bmad-router.sh validate          # health check
\`\`\`

## Agent skills

This metarepo targets the **$AGENT_TOOL** agent tool, so agent skills live in
\`$SKILLS_BASE/\`. Skills are organized by scope:

- \`$SKILLS_BASE/<name>/\` — always-available skills (each is a directory with a
  \`SKILL.md\`). Includes \`router-project-switch\` and any org-wide skills.
- \`$SKILLS_BASE/project/\` — symlink to the active project's skills.
  Only available when that project is switched in.
- \`$KNOWLEDGE_BASE/\` — shared documentation available to all projects.
  Org standards, coding conventions, architecture patterns.

When resolving a skill reference, check the always-available skills first, then
the active project's \`project/\` skills.

## Rules

- Always verify the active project before running any BMAD workflow.
- If a user mentions a project that isn't active, ask before switching.
- Follow the workflow phases in order: don't skip from brief to implementation.
- Read \`project-context.md\` before writing any implementation code.
- Source repos are declared in \`projects/<name>/repos.yaml\` (tracked). Clones live
  in \`projects/<name>/repos/\` and per-story git worktrees in
  \`projects/<name>/implementation/<story-id>/<repo>/\` — both gitignored. The
  per-story worktree workflow is wired through BMAD's customization at
  \`_bmad/custom/bmad-dev-story.toml\` (see \`_bmad/custom/worktree-workflow.md\`);
  do not duplicate those steps here.
- Each project's \`$USER_DOCS_FOLDER/\` is its \`project_knowledge\` directory.
  Shared knowledge lives in \`$KNOWLEDGE_BASE/\`.
AGENTMD
  ok "AGENTS.md"
fi

# .gitignore
if [[ -f ".gitignore" ]]; then
  if grep -q "# bmad-router" .gitignore 2>/dev/null; then
    info ".gitignore already has bmad-router rules"
  else
    cat >> .gitignore << GITIGNORE

# ── bmad-router managed ─────────────────────────────────────────────────────
# Output + docs symlinks at the repo root (recreated on switch). Anchored with a
# leading slash so the per-project projects/*/$USER_OUTPUT_FOLDER artifacts stay tracked.
/$USER_OUTPUT_FOLDER
/$USER_DOCS_FOLDER
# Root repos/implementation symlinks (recreated on switch)
/repos
/implementation
# Source repo clones + per-story worktrees (managed independently)
projects/*/repos/
projects/*/implementation/
# Project skills symlink
$SKILLS_BASE/project
# Personal BMAD customization overrides
_bmad/custom/*.user.toml
GITIGNORE
    ok "Appended bmad-router rules to .gitignore"
  fi
else
  cat > .gitignore << GITIGNORE
# ── BMAD Metarepo ────────────────────────────────────────────────────────────

# Output + docs symlinks at the repo root (recreated on switch). Anchored with a
# leading slash so the per-project projects/*/<folder> artifacts stay tracked.
/$USER_OUTPUT_FOLDER
/$USER_DOCS_FOLDER

# Root repos/implementation symlinks (recreated on switch)
/repos
/implementation

# Source repo clones + per-story worktrees (each managed independently)
projects/*/repos/
projects/*/implementation/

# Project skills symlink (managed by bmad-router)
$SKILLS_BASE/project

# Personal BMAD customization overrides (team overrides are committed)
_bmad/custom/*.user.toml

# Node / BMAD installer
node_modules/

# Python
__pycache__/
.pytest_cache/
*.pyc

# OS / editor
.DS_Store
Thumbs.db
*.swp
*~
.idea/
.vscode/
GITIGNORE
  ok ".gitignore"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 8: Create initial projects
# ─────────────────────────────────────────────────────────────────────────────

step 9 "Creating projects"

if [[ ${#PROJECTS[@]} -eq 0 ]]; then
  info "No projects to create. Run: bash scripts/bmad-router.sh init <name>"
else
  for project in "${PROJECTS[@]}"; do
    bash scripts/bmad-router.sh init "$project"
  done
  echo ""
  ok "Created ${#PROJECTS[@]} project(s), active: ${BOLD}${PROJECTS[-1]}${NC}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║  Setup complete                                             ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${DIM}Output folder: $USER_OUTPUT_FOLDER${NC}"
echo -e "  ${DIM}Docs folder:   $USER_DOCS_FOLDER${NC}"
echo -e "  ${DIM}Agent tool:    $AGENT_TOOL (skills: $SKILLS_BASE/)${NC}"
if [[ ${#PROJECTS[@]} -gt 0 ]]; then
  echo -e "  ${DIM}Projects:      ${PROJECTS[*]}${NC}"
fi
echo ""
echo -e "  ${BOLD}Quick start:${NC}"
echo -e "    ${CYAN}bash scripts/bmad-router.sh list${NC}"
echo -e "    ${CYAN}bash scripts/bmad-router.sh switch <project>${NC}"
echo ""
