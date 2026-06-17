#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# setup.sh — Bootstrap a BMad multi-project metarepo
# ─────────────────────────────────────────────────────────────────────────────

SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'
AMBER='\033[38;2;255;191;0m'
SPRING_GREEN='\033[38;2;0;255;111m'

die() { echo -e "${RED}error:${NC} $*" >&2; exit 1; }
info() { echo -e "${CYAN}→${NC} $*"; }
ok() { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}⚠${NC} $*"; }
step() { echo -e "\n${BOLD}[$1/$TOTAL_STEPS] $2${NC}"; }

TOTAL_STEPS=10

# Map an agent tool to its home directory (relative to the metarepo root). Skills
# and shared knowledge live under it (skills/ and knowledge/). Kept in sync with
# tool_dir_for_tool in skills/meta-router/scripts/meta-router.sh.
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

# printf/cat (not echo -e) so the art's backslashes aren't escape-processed;
# the quoted heredoc keeps the $$ runs from expanding.
echo ""
printf '%b' "$AMBER"
cat <<'ART'
 /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\
( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )
 > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <
 /\_/\                                                                                                                  /\_/\
( o.o )                                                                                                                ( o.o )
 > ^ <   $$\      $$\            $$\                     $$$$$$$\                        $$\                            > ^ <
 /\_/\   $$$\    $$$ |           $$ |                    $$  __$$\                       $$ |                           /\_/\
( o.o )  $$$$\  $$$$ | $$$$$$\ $$$$$$\    $$$$$$\        $$ |  $$ | $$$$$$\  $$\   $$\ $$$$$$\    $$$$$$\   $$$$$$\    ( o.o )
 > ^ <   $$\$$\$$ $$ |$$  __$$\\_$$  _|   \____$$\       $$$$$$$  |$$  __$$\ $$ |  $$ |\_$$  _|  $$  __$$\ $$  __$$\    > ^ <
 /\_/\   $$ \$$$  $$ |$$$$$$$$ | $$ |     $$$$$$$ |      $$  __$$< $$ /  $$ |$$ |  $$ |  $$ |    $$$$$$$$ |$$ |  \__|   /\_/\
( o.o )  $$ |\$  /$$ |$$   ____| $$ |$$\ $$  __$$ |      $$ |  $$ |$$ |  $$ |$$ |  $$ |  $$ |$$\ $$   ____|$$ |        ( o.o )
 > ^ <   $$ | \_/ $$ |\$$$$$$$\  \$$$$  |\$$$$$$$ |      $$ |  $$ |\$$$$$$  |\$$$$$$  |  \$$$$  |\$$$$$$$\ $$ |         > ^ <
 /\_/\   \__|     \__| \_______|  \____/  \_______|      \__|  \__| \______/  \______/    \____/  \_______|\__|         /\_/\
( o.o )                                                                                                                ( o.o )
 > ^ <                                                                                                                  > ^ <
 /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\
( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )
 > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <
ART
printf '%b' "$NC"

# Resolve the target directory — the run's output, i.e. the folder the metarepo
# is set up in. Precedence:
#   positional arg  >  BMAD_SETUP_TARGET env  >  interactive prompt  >  current dir
TARGET_INPUT="${1:-${BMAD_SETUP_TARGET:-}}"
if [[ -z "$TARGET_INPUT" && "$NONINTERACTIVE" != 1 ]]; then
  echo ""
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
#   BMAD_SETUP_SKILL_LEVEL user skill level        (beginner|intermediate|expert; default: intermediate)
#   BMAD_SETUP_TOOL        agent tool              (claude-code|github-copilot|codex; default: claude-code)
#   BMAD_SETUP_PROJECTS    comma-separated projects (default: none)
#   BMAD_SETUP_GITHUB_SYNC y/n to enable the GitHub Issues + Projects sync
#                          (default: n; BMAD_SETUP_ISSUES_SYNC still honored)
#   BMAD_SETUP_VERBOSE     1 to stream the BMad installer output (default: hidden)
if [[ "$NONINTERACTIVE" == 1 ]]; then
  info "Non-interactive mode (BMAD_SETUP_NONINTERACTIVE=1)"
fi

# Output folder name
if [[ "$NONINTERACTIVE" == 1 ]]; then
  USER_OUTPUT_FOLDER="${BMAD_OUTPUT_FOLDER:-features}"
else
  echo -e "  What should the output folder be called?"
  echo -e "  This is where PRDs, epics, stories, and architecture docs live."
  echo -e "  ${DIM}(BMad default: _bmad-output)${NC}"
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

# BMad user skill level — controls how much agents explain concepts in chat
if [[ "$NONINTERACTIVE" == 1 ]]; then
  USER_SKILL_LEVEL="${BMAD_SETUP_SKILL_LEVEL:-intermediate}"
else
  echo ""
  echo -e "  Your development experience level?"
  echo -e "  ${DIM}Affects how much BMad agents explain concepts in chat.${NC}"
  echo ""
  read -rp "  Skill level (beginner|intermediate|expert) [intermediate]: " USER_SKILL_LEVEL
  USER_SKILL_LEVEL="${USER_SKILL_LEVEL:-intermediate}"
fi

case "$USER_SKILL_LEVEL" in
  beginner|intermediate|expert) ;;
  *) die "Invalid skill level: '$USER_SKILL_LEVEL' (expected beginner, intermediate, or expert)" ;;
esac
ok "Skill level: ${BOLD}$USER_SKILL_LEVEL${NC}"

# Agent tool — determines which IDE/agent BMad integrates with and, in turn,
# where agent skills live (each tool reads them from its own directory).
if [[ "$NONINTERACTIVE" == 1 ]]; then
  AGENT_TOOL="${BMAD_SETUP_TOOL:-claude-code}"
else
  echo ""
  echo -e "  Which agent tool are you setting up for?"
  echo -e "  ${DIM}This selects the BMad integration and where agent skills live.${NC}"
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
# The skill ships its scripts and templates; everything in the metarepo runs
# them from the installed skill directory — there is no separate scripts/ copy.
# setup.sh lives inside the skill's scripts/ dir, so the skill root is one
# level up — works from a repo clone and from a gh-skill-installed copy alike.
SKILL_SRC="$(cd "$SETUP_DIR/.." && pwd)"
SKILL_HOME="$SKILLS_BASE/meta-router"
ROUTER_CMD="$SKILL_HOME/scripts/meta-router.sh"
BOOTSTRAP_CMD="$SKILL_HOME/scripts/bmad-github-bootstrap.sh"
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
  if [[ "$NONINTERACTIVE" == 1 ]]; then
    ok "Projects: ${BOLD}${PROJECTS[*]}${NC}"
  else
    # The read prompt already echoed the typed names — just confirm the count.
    ok "${#PROJECTS[@]} project(s) to create"
  fi
else
  info "No initial projects — you can create them later with meta-router init"
fi

# GitHub sync (Issues + Projects)
if [[ "$NONINTERACTIVE" == 1 ]]; then
  USER_GH_PROJECTS="${BMAD_SETUP_GITHUB_SYNC:-${BMAD_SETUP_ISSUES_SYNC:-n}}"
else
  echo ""
  echo -e "  Enable GitHub sync? For each project, this will:"
  echo -e "    - mirror BMad epics and stories to GitHub Issues, with native"
  echo -e "      sub-issue progress bars per epic"
  echo -e "    - create a ${BOLD}private${NC} GitHub Project board (Backlog / Epic Progress /"
  echo -e "      Planning views) that updates from sprint-status.yaml and story PRs"
  echo -e "    - add a planning checklist issue tracking PRD/architecture/epics docs"
  echo -e "  ${DIM}(Needs the gh CLI locally; boards are created at the end of setup)${NC}"
  echo ""
  read -rp "  Enable GitHub sync? [y/N]: " USER_GH_PROJECTS
fi
ENABLE_GH_PROJECTS=false
USER_GH_PROJECTS_LC="$(printf '%s' "$USER_GH_PROJECTS" | tr '[:upper:]' '[:lower:]')"
if [[ "$USER_GH_PROJECTS_LC" == "y" || "$USER_GH_PROJECTS_LC" == "yes" ]]; then
  ENABLE_GH_PROJECTS=true
  ok "GitHub sync: enabled"
else
  info "GitHub sync: skipped (you can add it later)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Check prerequisites
# ─────────────────────────────────────────────────────────────────────────────

step 2 "Checking prerequisites"

if command -v node &>/dev/null; then
  ok "Node.js $(node --version)"
else
  warn "Node.js not found — BMad install requires it"
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

# gh is only needed locally for bmad-github-bootstrap.sh and manual sync runs;
# the sync workflow itself runs on GitHub-hosted runners where gh is preinstalled.
if [[ "$ENABLE_GH_PROJECTS" == true ]]; then
  if command -v gh &>/dev/null; then
    ok "gh $(gh --version | head -n1 | cut -d' ' -f3)"
  else
    warn "gh CLI not found — needed locally for the skill's bmad-github-bootstrap.sh (https://cli.github.com)"
  fi
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
# Step 4: Install BMad if not present
# ─────────────────────────────────────────────────────────────────────────────

step 4 "Checking BMad installation"

YAML_CFG="_bmad/bmm/config.yaml"

# Read a bmm config value normalized for comparison: quotes and the
# {project-root}/ prefix stripped, so installer-written and hand-written
# forms compare equal.
bmm_config_value() {
  sed -n "s|^[[:space:]]*$1[[:space:]]*:[[:space:]]*||p" "$YAML_CFG" 2>/dev/null | head -n1 | tr -d '"' | sed 's|^{project-root}/||'
}

# The folder config MUST be passed to the installer (--output-folder / --set):
# it resolves those paths and bakes them into every generated skill file under
# the tool dir, so patching config.yaml afterwards leaves the skills pointing
# at the default _bmad-output/ and docs/ paths.
BMAD_CONFIG_FLAGS=(
  --output-folder "$USER_OUTPUT_FOLDER"
  --set "bmm.planning_artifacts={project-root}/$USER_OUTPUT_FOLDER/planning-artifacts"
  --set "bmm.implementation_artifacts={project-root}/$USER_OUTPUT_FOLDER/implementation-artifacts"
  --set "bmm.project_knowledge=$USER_DOCS_FOLDER"
  --set "bmm.user_skill_level=$USER_SKILL_LEVEL"
)

# The installer is chatty (npm warnings, banner boxes, per-skill lines), so its
# output goes to a log unless BMAD_SETUP_VERBOSE=1; the log tail is shown on
# failure so errors stay debuggable.
# Template must end in Xs — BSD mktemp (macOS) rejects suffixes after them.
BMAD_INSTALL_LOG="$(mktemp "${TMPDIR:-/tmp}/bmad-install.XXXXXX")"
run_bmad_installer() {
  if [[ "${BMAD_SETUP_VERBOSE:-0}" == 1 ]]; then
    npx bmad-method install "$@" </dev/null
  else
    npx bmad-method install "$@" </dev/null >"$BMAD_INSTALL_LOG" 2>&1
  fi
}
print_install_log_tail() {
  if [[ "${BMAD_SETUP_VERBOSE:-0}" != 1 && -s "$BMAD_INSTALL_LOG" ]]; then
    echo -e "  ${DIM}── last installer output ($BMAD_INSTALL_LOG) ──${NC}"
    tail -n 15 "$BMAD_INSTALL_LOG" | sed 's/^/    /'
  fi
}

if [[ ! -d "_bmad" ]]; then
  info "Installing BMad Method... ${DIM}(takes a minute — output hidden, set BMAD_SETUP_VERBOSE=1 to show)${NC}"
  # Non-interactive install (BMad v6): --yes skips prompts where possible,
  # --directory pins the target (the installer otherwise prompts for it on a TTY
  # and stalls on non-TTY stdin), --modules picks the module set (core auto-added),
  # --tools targets the IDE/agent integration (required for fresh --yes installs).
  # Override the module/tool selection via BMAD_INSTALL_MODULES / BMAD_INSTALL_TOOLS.
  BMAD_INSTALL_MODULES="${BMAD_INSTALL_MODULES:-bmm}"
  BMAD_INSTALL_TOOLS="${BMAD_INSTALL_TOOLS:-$AGENT_TOOL}"
  if run_bmad_installer --yes --directory . \
       --modules "$BMAD_INSTALL_MODULES" --tools "$BMAD_INSTALL_TOOLS" \
       "${BMAD_CONFIG_FLAGS[@]}"; then
    ok "BMad installed: output_folder=$USER_OUTPUT_FOLDER, project_knowledge=$USER_DOCS_FOLDER, user_skill_level=$USER_SKILL_LEVEL"
  else
    warn "BMad auto-install failed — creating minimal skeleton"
    print_install_log_tail
    mkdir -p _bmad/bmm/agents _bmad/core/tasks _bmad/custom
  fi
elif [[ "$(bmm_config_value output_folder)" == "$USER_OUTPUT_FOLDER" &&
        "$(bmm_config_value project_knowledge)" == "$USER_DOCS_FOLDER" &&
        "$(bmm_config_value user_skill_level)" == "$USER_SKILL_LEVEL" ]]; then
  ok "BMad core already installed with matching config"
else
  info "Repointing existing BMad install at the chosen folders... ${DIM}(output hidden, set BMAD_SETUP_VERBOSE=1 to show)${NC}"
  # --action update re-runs the installer over the existing install, which
  # regenerates config.yaml AND the skill files that embed the resolved paths.
  if run_bmad_installer --yes --directory . --action update \
       "${BMAD_CONFIG_FLAGS[@]}"; then
    ok "BMad config updated: output_folder=$USER_OUTPUT_FOLDER, project_knowledge=$USER_DOCS_FOLDER, user_skill_level=$USER_SKILL_LEVEL"
  else
    warn "BMad update failed — re-run setup or fix $YAML_CFG manually"
    print_install_log_tail
  fi
fi

# Fallback config for the skeleton path where the installer couldn't run.
if [[ ! -f "$YAML_CFG" ]]; then
  mkdir -p "$(dirname "$YAML_CFG")"
  cat > "$YAML_CFG" << YAML
output_folder: "{project-root}/$USER_OUTPUT_FOLDER"
planning_artifacts: "{project-root}/$USER_OUTPUT_FOLDER/planning-artifacts"
implementation_artifacts: "{project-root}/$USER_OUTPUT_FOLDER/implementation-artifacts"
project_knowledge: "{project-root}/$USER_DOCS_FOLDER"
user_skill_level: $USER_SKILL_LEVEL
YAML
  ok "Created config.yaml with custom folder names"
fi

# agent_tool is meta-router's own key — the BMad installer never writes it.
# `sed -i.bak` is portable across GNU (Linux/CI) and BSD (macOS) sed.
if grep -qE '^[[:space:]]*agent_tool[[:space:]]*:' "$YAML_CFG" 2>/dev/null; then
  sed -i.bak "s|^\([[:space:]]*agent_tool[[:space:]]*:\).*|\1 \"$AGENT_TOOL\"|" "$YAML_CFG" && rm -f "$YAML_CFG.bak"
else
  echo "agent_tool: \"$AGENT_TOOL\"" >> "$YAML_CFG"
fi
ok "agent_tool=$AGENT_TOOL"

# Remove installer-scaffolded output/docs dirs if empty (the router manages
# them as symlinks to the active project). The installer creates the output
# folder's artifact subdirs plus a docs/ dir even when project_knowledge points
# elsewhere; _bmad-output covers installs that predate the folder overrides.
# Match on files only (-type f) so a tree of empty dirs still counts as removable.
for candidate in _bmad-output docs "$USER_OUTPUT_FOLDER" "$USER_DOCS_FOLDER"; do
  if [[ -d "$candidate" && ! -L "$candidate" ]]; then
    local_files=$(find "$candidate" -type f -not -name '.gitkeep' | head -1)
    if [[ -z "$local_files" ]]; then
      rm -rf "$candidate"
      info "Removed empty $candidate/ (router will manage as symlink)"
    fi
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: Create directory structure
# ─────────────────────────────────────────────────────────────────────────────

step 5 "Creating directory structure"

mkdir -p projects
mkdir -p "$SKILLS_BASE/meta-router"
mkdir -p "$KNOWLEDGE_BASE"

ok "projects/"
ok "$SKILLS_BASE/ (always-active skills)"
ok "$KNOWLEDGE_BASE/ (shared across all projects)"

# ─────────────────────────────────────────────────────────────────────────────
# Step 6: Copy meta-router files
# ─────────────────────────────────────────────────────────────────────────────

step 6 "Installing meta-router"

# The whole skill ships into the metarepo: SKILL.md plus the scripts and the
# templates those scripts reference, so the skill directory is self-contained.
if [[ -f "$SKILL_SRC/scripts/meta-router.sh" ]]; then
  mkdir -p "$SKILL_HOME"
  cp -R "$SKILL_SRC/." "$SKILL_HOME/"
  chmod +x "$SKILL_HOME/scripts/"*.sh
  ok "$SKILL_HOME/ (skill, scripts, templates)"
else
  die "Cannot find meta-router.sh next to setup.sh (expected $SKILL_SRC/scripts/meta-router.sh)"
fi

# Install CI workflow so the metarepo lints its bundled shell scripts.
if [[ -f "$SKILL_SRC/templates/.github/workflows/ci.yml" ]]; then
  mkdir -p .github/workflows
  cp "$SKILL_SRC/templates/.github/workflows/ci.yml" .github/workflows/ci.yml
  ok ".github/workflows/ci.yml"
fi

# Seed shared knowledge README
if [[ ! -f "$KNOWLEDGE_BASE/README.md" ]]; then
  cat > "$KNOWLEDGE_BASE/README.md" << 'KNOWLEDGEMD'
# Shared Knowledge

Documentation and conventions that apply across all projects in this metarepo.
BMad agents can reference these files regardless of which project is active.

Examples:
  - org-standards.md — Coding standards and conventions
  - architecture-patterns.md — Approved patterns and anti-patterns
  - review-checklist.md — PR review requirements
KNOWLEDGEMD
  ok "$KNOWLEDGE_BASE/README.md"
fi

# Seed the overall shared context — org-wide standards that apply to ALL
# projects. Seeded once at metarepo creation (it's global, not per-project, so
# the router's per-project scaffold never touches it). Guarded so re-running
# setup never clobbers your edits.
if [[ ! -f "$KNOWLEDGE_BASE/shared-context.md" ]]; then
  cat > "$KNOWLEDGE_BASE/shared-context.md" << 'SHAREDCTX'
# Shared Context

<!-- Generated by meta-router. OVERALL shared context for ALL projects in this
     metarepo. BMad agents load this before every workflow, alongside the active
     project's project-context.md. Project context overrides this on conflict. -->

## Overview

- **Organization / Team**: REPLACE_ME
- **Mission**: REPLACE_ME
- **Scope**: Conventions here apply to every project under projects/.

## Org-wide Tech Standards

<!-- Languages, runtimes, frameworks, and versions standardized across projects, e.g.:
  - Node.js 20 LTS for all services
  - TypeScript strict mode everywhere
  - Postgres as the default relational store
-->

## Cross-cutting Conventions

<!-- Naming, branching, commit format, code review, testing baseline, e.g.:
  - Conventional Commits across all repos
  - Trunk-based with short-lived story/<id> branches
  - Tests required for all business logic
-->

## Shared Constraints

<!-- Security, compliance, licensing, accessibility, and other non-negotiables, e.g.:
  - No secrets in source; use the org secret manager
  - All public APIs require authn + input validation
  - Dependencies must use OSI-approved licenses
-->

## Precedence

Project-specific guidance in <output-folder>/project-context.md overrides this
file when the two conflict. This file is the default for anything a project does
not specify.
SHAREDCTX
  ok "$KNOWLEDGE_BASE/shared-context.md"
fi

# Install BMad customization overrides that drive per-story git worktrees.
# These hook the bmad-dev-story / bmad-create-story skills via _bmad/custom/.
if [[ -d "$SKILL_SRC/templates/bmad-custom" && -d "_bmad" ]]; then
  mkdir -p _bmad/custom
  for f in bmad-dev-story.toml bmad-create-story.toml worktree-workflow.md; do
    if [[ -f "$SKILL_SRC/templates/bmad-custom/$f" && ! -f "_bmad/custom/$f" ]]; then
      cp "$SKILL_SRC/templates/bmad-custom/$f" "_bmad/custom/$f"
      ok "_bmad/custom/$f"
    fi
  done
  # The bmad-custom TOMLs inject the shared context via a persistent_facts
  # "file:" reference. The committed templates use a tool-agnostic
  # __KNOWLEDGE_DIR__ placeholder; resolve it to the configured agent tool's
  # knowledge dir so BMad loads the file from where setup actually seeded it.
  # This runs on every setup invocation and rewrites whatever the placeholder
  # currently resolves to (placeholder or a prior tool's dir), so re-running with
  # a different agent tool repoints an already-installed override — not just the
  # first install. Uses the portable `sed -i.bak` style used for config.yaml.
  for f in bmad-dev-story.toml bmad-create-story.toml; do
    if [[ -f "_bmad/custom/$f" ]] && grep -q "shared-context.md" "_bmad/custom/$f"; then
      sed -i.bak -E "s|file:\{project-root\}/[^\"]*shared-context.md|file:{project-root}/$KNOWLEDGE_BASE/shared-context.md|g" "_bmad/custom/$f" && rm -f "_bmad/custom/$f.bak"
    fi
  done
  # Same idea for router invocations: the templates reference the router via a
  # tool-agnostic __SKILLS_DIR__ placeholder; resolve it (or a prior tool's
  # path) to the installed skill location.
  for f in bmad-dev-story.toml bmad-create-story.toml worktree-workflow.md; do
    if [[ -f "_bmad/custom/$f" ]] && grep -q 'meta-router.sh' "_bmad/custom/$f"; then
      sed -i.bak -E "s|bash [^\`[:space:]]*meta-router\.sh|bash $ROUTER_CMD|g" "_bmad/custom/$f" && rm -f "_bmad/custom/$f.bak"
    fi
  done
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 7: Install GitHub Issues sync (optional)
# ─────────────────────────────────────────────────────────────────────────────

step 7 "Installing GitHub sync files"

if [[ "$ENABLE_GH_PROJECTS" == true ]]; then
  # The sync + bootstrap scripts already ship inside the skill (step 6); only
  # the metarepo-level workflow needs installing. Point it at the skill's copy
  # of bmad-issues.py. (bmad-pr-ping.yml stays in the skill's templates — it
  # gets installed into each project's SOURCE repos, not the metarepo.)
  if [[ -f "$SKILL_SRC/templates/.github/workflows/sync-issues.yml" ]]; then
    mkdir -p .github/workflows
    cp "$SKILL_SRC/templates/.github/workflows/sync-issues.yml" .github/workflows/
    sed -i.bak "s|__SKILLS_DIR__|$SKILLS_BASE|g" .github/workflows/sync-issues.yml && rm -f .github/workflows/sync-issues.yml.bak
    ok ".github/workflows/sync-issues.yml"
  fi

  # Copy sync config template into each project
  if [[ -f "$SKILL_SRC/templates/github-sync.yaml" ]]; then
    for project in "${PROJECTS[@]}"; do
      if [[ -d "projects/$project" && ! -f "projects/$project/github-sync.yaml" ]]; then
        cp "$SKILL_SRC/templates/github-sync.yaml" "projects/$project/github-sync.yaml"
        ok "projects/$project/github-sync.yaml (edit repo field)"
      fi
    done
  fi

else
  info "Skipped — run setup again or copy templates/ manually to enable later"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 8: Generate AGENTS.md and .gitignore
# ─────────────────────────────────────────────────────────────────────────────

step 8 "Generating AGENTS.md and .gitignore"

if [[ -f "AGENTS.md" ]]; then
  warn "AGENTS.md already exists — skipping"
elif [[ -f "AGENT.md" ]]; then
  warn "AGENT.md exists — rename to AGENTS.md for cross-agent compatibility"
else
  cat > AGENTS.md << AGENTMD
# AGENTS.md

This is a BMad Method multi-project metarepo. Read this file before doing anything.

## BMad Method

This repo uses the [BMad Method](https://github.com/bmad-code-org/BMad-METHOD) — an
agent-driven development workflow with specialized roles. The shared BMad core lives
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

Use BMad slash commands or skill references depending on your IDE:
- Claude Code: \`/pm\`, \`/sm\`, \`/architect\`, \`/dev\`, \`/bmad-help\`
- Other IDEs: reference the skill files in \`$SKILLS_BASE/\`

If you're unsure what to do next, ask \`bmad-help\`.

### Key BMad files

| File | Purpose |
|---|---|
| \`_bmad/bmm/config.yaml\` | Module config (output folder, project knowledge, user level) |
| \`$KNOWLEDGE_BASE/shared-context.md\` | Overall shared context — org-wide standards for ALL projects |
| \`$USER_OUTPUT_FOLDER/project-context.md\` | Project conventions, tech stack, implementation rules |
| \`$USER_OUTPUT_FOLDER/planning-artifacts/PRD.md\` | Product requirements document |
| \`$USER_OUTPUT_FOLDER/planning-artifacts/architecture.md\` | Technical architecture |
| \`$USER_OUTPUT_FOLDER/planning-artifacts/epics/\` | Epic and story files |
| \`$USER_OUTPUT_FOLDER/implementation-artifacts/sprint-status.yaml\` | Sprint planning state |

## Multi-project routing

This metarepo hosts multiple projects that share the same BMad core. Each project
has isolated artifacts, docs, and agent skills. Five symlinks at the repo root
point to the active project:

| Root symlink | Points to | Contains |
|---|---|---|
| \`$USER_OUTPUT_FOLDER/\` | \`projects/<active>/$USER_OUTPUT_FOLDER/\` | PRDs, epics, stories, sprint status |
| \`$USER_DOCS_FOLDER/\` | \`projects/<active>/$USER_DOCS_FOLDER/\` | Project knowledge (ADRs, specs) |
| \`$SKILLS_BASE/project/\` | \`projects/<active>/$SKILLS_BASE/\` | Project-specific agent skills |
| \`repos/\` | \`projects/<active>/repos/\` | Cloned source repos for the active project |
| \`implementation/\` | \`projects/<active>/implementation/\` | Per-story git worktrees |

### Before starting any work

1. Check which project is active: \`bash $ROUTER_CMD current\`
2. Switch if needed: \`bash $ROUTER_CMD switch <project-name>\`
3. Read the overall shared context (\`$KNOWLEDGE_BASE/shared-context.md\`) and the
   active project's context (\`$USER_OUTPUT_FOLDER/project-context.md\`). Project
   context overrides shared context on conflict.
4. Never write BMad output to a project that isn't active.

### Switching projects

\`\`\`bash
bash $ROUTER_CMD list              # see all projects
bash $ROUTER_CMD switch <name>     # switch context
bash $ROUTER_CMD init <name>       # create new project
bash $ROUTER_CMD validate          # health check
\`\`\`

## Agent skills

This metarepo targets the **$AGENT_TOOL** agent tool, so agent skills live in
\`$SKILLS_BASE/\`. Skills are organized by scope:

- \`$SKILLS_BASE/<name>/\` — always-available skills (each is a directory with a
  \`SKILL.md\`). Includes \`meta-router\` and any org-wide skills.
- \`$SKILLS_BASE/project/\` — symlink to the active project's skills.
  Only available when that project is switched in.
- \`$KNOWLEDGE_BASE/\` — shared documentation available to all projects.
  Org standards, coding conventions, architecture patterns. Its
  \`shared-context.md\` is the overall shared context loaded before every workflow.

When resolving a skill reference, check the always-available skills first, then
the active project's \`project/\` skills.

## Rules

- Always verify the active project before running any BMad workflow.
- If a user mentions a project that isn't active, ask before switching.
- Follow the workflow phases in order: don't skip from brief to implementation.
- Read the overall shared context (\`$KNOWLEDGE_BASE/shared-context.md\`, org-wide)
  and the active project's \`project-context.md\` before any workflow; project
  context wins on conflict.
- Source repos are declared in \`projects/<name>/repos.yaml\` (tracked). Clones live
  in \`projects/<name>/repos/\` and per-story git worktrees in
  \`projects/<name>/implementation/<story-id>/<repo>/\` — both gitignored. The
  per-story worktree workflow is wired through BMad's customization at
  \`_bmad/custom/bmad-dev-story.toml\` (see \`_bmad/custom/worktree-workflow.md\`);
  do not duplicate those steps here.
- Each project's \`$USER_DOCS_FOLDER/\` is its \`project_knowledge\` directory.
  Shared knowledge lives in \`$KNOWLEDGE_BASE/\`, with org-wide context that
  applies to every project in \`$KNOWLEDGE_BASE/shared-context.md\`.
AGENTMD
  ok "AGENTS.md"
fi

# .gitignore
if [[ -f ".gitignore" ]]; then
  if grep -q "# meta-router" .gitignore 2>/dev/null; then
    info ".gitignore already has meta-router rules"
  else
    cat >> .gitignore << GITIGNORE

# ── meta-router managed ─────────────────────────────────────────────────────
# The output + docs symlinks at the repo root are COMMITTED (not listed here):
# their target is the active project, so meta-router reads the active project
# from the output symlink instead of a separate file. Switching repoints them,
# which lands as a tracked change.
# Root repos/implementation symlinks point at gitignored content, so they're
# recreated on switch rather than committed.
/repos
/implementation
# Source repo clones + per-story worktrees (managed independently)
projects/*/repos/
projects/*/implementation/
# Project skills symlink (recreated on switch)
$SKILLS_BASE/project
# Personal BMad customization overrides
_bmad/custom/*.user.toml
GITIGNORE
    ok "Appended meta-router rules to .gitignore"
  fi
else
  cat > .gitignore << GITIGNORE
# ── BMad Metarepo ────────────────────────────────────────────────────────────

# The output + docs symlinks at the repo root are COMMITTED (not listed here):
# their target is the active project, so meta-router reads the active project
# from the output symlink instead of a separate file. Switching repoints them,
# which lands as a tracked change.

# Root repos/implementation symlinks point at gitignored content, so they're
# recreated on switch rather than committed.
/repos
/implementation

# Source repo clones + per-story worktrees (each managed independently)
projects/*/repos/
projects/*/implementation/

# Project skills symlink (recreated on switch)
$SKILLS_BASE/project

# Personal BMad customization overrides (team overrides are committed)
_bmad/custom/*.user.toml

# Node / BMad installer
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
# Step 9: Create initial projects
# ─────────────────────────────────────────────────────────────────────────────

step 9 "Creating projects"

# printf/cat (not echo -e) so the art's backslashes aren't escape-processed.
printf '%b' "$AMBER"
cat <<'ART'
+   '             +           '                               .   .      |
                            o           *       .   +       .          --o--
 ' .             .    .        '  *          |            .              |   *
          .              _|_         .   .  -+-
.       '                 |            '     |          .   * .
                       .      '   .       .        *                  o  .   .
   '         +                      * '        .     .    .       + .
 .                     '                +        '                     +
     . +     \                      +                      '      .
              \       +   .     '     ' +     .  .      .      +             +
        '      *    +   *         +                 '     '  .       '  .      .
   .      . '                           o  .
     '             o          +  .                .      .   _..             +
.          .  .                    +       +         .     '`-. `.    +
    ' '           |       '             .     .                \  \      . *
 .              - o -          ':.                  '     '    |  |
            .     |     . .      '::._   +    . '              /  /   o
  +                                '._)             * '    _.-`_.`        .
     *      *  . .     .   .                            .   '''       *     '
'         '                   .  o       ' . .    '                 +
ART
printf '%b' "$NC"

if [[ ${#PROJECTS[@]} -eq 0 ]]; then
  info "No projects to create. Run: bash $ROUTER_CMD init <name>"
else
  # Scaffold without switching (and without the router's per-file chatter);
  # switch once at the end — only the last switch matters. Router errors still
  # surface on stderr.
  for project in "${PROJECTS[@]}"; do
    info "Creating project: ${BOLD}$project${NC}"
    bash "$ROUTER_CMD" init "$project" --no-switch >/dev/null
    ok "Initialized $project"
  done
  LAST_PROJECT="${PROJECTS[$((${#PROJECTS[@]}-1))]}"
  bash "$ROUTER_CMD" switch "$LAST_PROJECT" >/dev/null
  ok "Active project: ${BOLD}$LAST_PROJECT${NC}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 10: GitHub project boards (walkthrough)
# ─────────────────────────────────────────────────────────────────────────────

step 10 "GitHub project boards"

# The bootstrap script owns the detailed instructions (view checklist, token,
# pr-ping install) — setup just points at it.
print_github_sync_next_steps() {
  echo ""
  info "To finish GitHub sync setup later:"
  echo -e "  1. Push this metarepo to GitHub — issues are created here by default"
  echo -e "     ${DIM}(or point a project at its source repo via repo: in github-sync.yaml)${NC}"
  echo -e "  2. Run: ${CYAN}bash $BOOTSTRAP_CMD --all${NC}"
  echo -e "     ${DIM}Creates the private board(s) and prints the remaining manual steps.${NC}"
}

# Printed ONCE per setup run (the bootstrap script prints the same block when
# run standalone; setup suppresses that per-project copy to avoid repetition).
print_remaining_sync_setup() {
  echo ""
  echo -e "${BOLD}Remaining setup (once per org / per source repo):${NC}"
  echo -e "  - Org secret ${CYAN}BMAD_PROJECT_TOKEN${NC}: fine-grained PAT with org Projects"
  echo -e "    read/write + Issues read/write + Pull requests read on the metarepo"
  echo -e "    and all source repos (the sync workflow refuses to run without it)"
  echo -e "  - In each source repo: install ${CYAN}$SKILL_HOME/templates/.github/workflows/bmad-pr-ping.yml${NC},"
  echo -e "    set variable ${CYAN}BMAD_METAREPO${NC} and secret ${CYAN}BMAD_METAREPO_TOKEN${NC}"
}

# Every project in the metarepo is a candidate, not just ones created this
# run — re-running setup offers board creation for existing projects too.
CANDIDATE_PROJECTS=()
for sync_cfg in projects/*/github-sync.yaml; do
  [[ -f "$sync_cfg" ]] && CANDIDATE_PROJECTS+=("$(basename "$(dirname "$sync_cfg")")")
done

if [[ "$ENABLE_GH_PROJECTS" != true ]]; then
  info "GitHub sync not enabled — skipping"
elif [[ "$NONINTERACTIVE" == 1 ]]; then
  info "Non-interactive mode — boards are not created automatically"
  print_github_sync_next_steps
elif [[ ${#CANDIDATE_PROJECTS[@]} -eq 0 ]]; then
  info "No projects yet — create one with meta-router init, then bootstrap its board"
  print_github_sync_next_steps
elif ! command -v gh &>/dev/null || ! gh auth status &>/dev/null; then
  warn "gh CLI missing or not authenticated — boards can't be created from here"
  print_github_sync_next_steps
elif [[ -z "$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" ]]; then
  # Fresh metarepos have no GitHub remote yet, so boards (whose issues live
  # here) can't be created during setup — but the org project template doesn't
  # need the push. Offer it now: the views are built once and every future
  # board copies them.
  info "No GitHub remote yet — boards are created after you push this metarepo"
  echo ""
  echo -e "  The ${BOLD}org project template${NC} can be set up now though: build the board"
  echo -e "  views once and every future board copies them automatically."
  read -rp "  Set up the org project template now? [Y/n]: " SETUP_TEMPLATE
  case "$(printf '%s' "$SETUP_TEMPLATE" | tr '[:upper:]' '[:lower:]')" in
    n|no)
      info "Skipped — run later: bash $BOOTSTRAP_CMD --template"
      ;;
    *)
      if ! bash "$BOOTSTRAP_CMD" --template; then
        warn "Template setup didn't finish — re-run: bash $BOOTSTRAP_CMD --template"
      fi
      ;;
  esac
  print_github_sync_next_steps
else
  # Issues live in this metarepo unless a project's github-sync.yaml sets
  # repo: to its own source repo.
  METAREPO_SLUG="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"

  echo -e "  Each project gets a ${BOLD}private${NC} GitHub Project board, tracking issues that"
  echo -e "  mirror the project's BMad epics and stories. Issues are created in this"
  echo -e "  metarepo. ${DIM}(Override per project via repo: in projects/<name>/github-sync.yaml)${NC}"
  echo ""

  # Collect the projects that still need a board, then ask ONCE for the batch.
  PENDING_PROJECTS=()
  for project in "${CANDIDATE_PROJECTS[@]}"; do
    SYNC_CFG="projects/$project/github-sync.yaml"

    if grep -qE '^project:[[:space:]]*[0-9]+' "$SYNC_CFG"; then
      ok "$project: board already configured — skipping"
      continue
    fi

    PROJECT_REPO="$(sed -n 's/^repo:[[:space:]]*//p' "$SYNC_CFG" | head -n1 | tr -d '"' | tr -d "'")"
    if [[ -z "$PROJECT_REPO" || "$PROJECT_REPO" == OWNER/* ]]; then
      PROJECT_REPO="$METAREPO_SLUG"
    fi
    if [[ -z "$PROJECT_REPO" ]]; then
      info "Skipped $project — push this metarepo to GitHub first (issues live there), then run: bash $BOOTSTRAP_CMD $project"
      continue
    fi

    echo -e "    - ${BOLD}$project${NC} ${DIM}(issues → $PROJECT_REPO)${NC}"
    PENDING_PROJECTS+=("$project")
  done

  if [[ ${#PENDING_PROJECTS[@]} -eq 0 ]]; then
    info "No boards left to create"
  else
    echo ""
    read -rp "  Create private board(s) for ${#PENDING_PROJECTS[@]} project(s) now? [Y/n]: " CREATE_BOARDS
    CREATE_BOARDS_LC="$(printf '%s' "$CREATE_BOARDS" | tr '[:upper:]' '[:lower:]')"
    if [[ "$CREATE_BOARDS_LC" == "n" || "$CREATE_BOARDS_LC" == "no" ]]; then
      info "Skipped — run: bash $BOOTSTRAP_CMD --all"
      print_github_sync_next_steps
    else
      BOOTSTRAPPED_ANY=false
      for project in "${PENDING_PROJECTS[@]}"; do
        # Suppress the bootstrap's per-run "Remaining setup" block; it is
        # printed once for the whole batch below.
        if BMAD_BOOTSTRAP_SKIP_NEXT_STEPS=1 bash "$BOOTSTRAP_CMD" "$project"; then
          BOOTSTRAPPED_ANY=true
        else
          warn "Bootstrap failed for $project — fix the issue and re-run: bash $BOOTSTRAP_CMD $project"
        fi
      done
      if [[ "$BOOTSTRAPPED_ANY" == true ]]; then
        print_remaining_sync_setup
      else
        print_github_sync_next_steps
      fi
    fi
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────────────────────────

echo ""
# printf/cat (not echo -e) so the art's backslashes aren't escape-processed.
printf '%b' "$SPRING_GREEN"
cat <<'ART'
 /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\
( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )
 > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <
 /\_/\                                                                                             /\_/\
( o.o )        $$$$$$\             $$\                                                            ( o.o )
 > ^ <        $$  __$$\            $$ |                                                            > ^ <
 /\_/\        $$ /  \__| $$$$$$\ $$$$$$\   $$\   $$\  $$$$$$\                                      /\_/\
( o.o )       \$$$$$$\  $$  __$$\\_$$  _|  $$ |  $$ |$$  __$$\                                    ( o.o )
 > ^ <         \____$$\ $$$$$$$$ | $$ |    $$ |  $$ |$$ /  $$ |                                    > ^ <
 /\_/\        $$\   $$ |$$   ____| $$ |$$\ $$ |  $$ |$$ |  $$ |                                    /\_/\
( o.o )       \$$$$$$  |\$$$$$$$\  \$$$$  |\$$$$$$  |$$$$$$$  |                                   ( o.o )
 > ^ <         \______/  \_______|  \____/  \______/ $$  ____/                                     > ^ <
 /\_/\                                               $$ |                                          /\_/\
( o.o )                                              $$ |                                         ( o.o )
 > ^ <                                               \__|                                          > ^ <
 /\_/\         $$$$$$\                                    $$\            $$\                       /\_/\
( o.o )       $$  __$$\                                   $$ |           $$ |                     ( o.o )
 > ^ <        $$ /  \__| $$$$$$\  $$$$$$\$$$$\   $$$$$$\  $$ | $$$$$$\ $$$$$$\    $$$$$$\          > ^ <
 /\_/\        $$ |      $$  __$$\ $$  _$$  _$$\ $$  __$$\ $$ |$$  __$$\\_$$  _|  $$  __$$\         /\_/\
( o.o )       $$ |      $$ /  $$ |$$ / $$ / $$ |$$ /  $$ |$$ |$$$$$$$$ | $$ |    $$$$$$$$ |       ( o.o )
 > ^ <        $$ |  $$\ $$ |  $$ |$$ | $$ | $$ |$$ |  $$ |$$ |$$   ____| $$ |$$\ $$   ____|        > ^ <
 /\_/\        \$$$$$$  |\$$$$$$  |$$ | $$ | $$ |$$$$$$$  |$$ |\$$$$$$$\  \$$$$  |\$$$$$$$\         /\_/\
( o.o )        \______/  \______/ \__| \__| \__|$$  ____/ \__| \_______|  \____/  \_______|       ( o.o )
 > ^ <                                          $$ |                                               > ^ <
 /\_/\                                          $$ |                                               /\_/\
( o.o )                                         \__|                                              ( o.o )
 > ^ <                                                                                             > ^ <
 /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\  /\_/\
( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )( o.o )
 > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <  > ^ <
ART
printf '%b' "$NC"
echo ""
echo -e "  ${DIM}Output folder: $USER_OUTPUT_FOLDER${NC}"
echo -e "  ${DIM}Docs folder:   $USER_DOCS_FOLDER${NC}"
echo -e "  ${DIM}Skill level:   $USER_SKILL_LEVEL${NC}"
echo -e "  ${DIM}Agent tool:    $AGENT_TOOL (skills: $SKILLS_BASE/)${NC}"
if [[ ${#PROJECTS[@]} -gt 0 ]]; then
  echo -e "  ${DIM}Projects:      ${PROJECTS[*]}${NC}"
fi
echo ""
echo -e "  ${BOLD}Quick start:${NC}"
echo -e "    ${CYAN}bash $ROUTER_CMD list${NC}"
echo -e "    ${CYAN}bash $ROUTER_CMD switch <project>${NC}"
echo ""
