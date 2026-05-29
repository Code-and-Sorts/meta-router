#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# bmad-router.sh — Multi-project context switcher for BMAD metarepos
# ─────────────────────────────────────────────────────────────────────────────
# Manages three symlinks per project switch:
#   1. Output folder (features, PRDs, epics, stories)
#   2. Project docs  (project_knowledge — ADRs, specs, domain docs)
#   3. Project skills (agent skills specific to one project)
#
# Shared knowledge lives at .agents/knowledge/ and is always available.
# ─────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BMAD_CORE="$REPO_ROOT/_bmad"
PROJECTS_DIR="$REPO_ROOT/projects"
ACTIVE_FILE="$REPO_ROOT/active-project.txt"
AGENTS_DIR="$REPO_ROOT/.agents"
SKILLS_DIR="$AGENTS_DIR/skills"
SKILLS_PROJECT_LINK="$SKILLS_DIR/project"

# Colors
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

# ─────────────────────────────────────────────────────────────────────────────
# Config resolution
# ─────────────────────────────────────────────────────────────────────────────

read_yaml_key() {
  local file="$1" key="$2"
  if [[ -f "$file" ]]; then
    grep -E "^\s*${key}\s*:" "$file" 2>/dev/null | head -1 | sed 's/^[^:]*:\s*//' | tr -d '"' | tr -d "'" | xargs
  fi
}

read_toml_key() {
  local file="$1" key="$2"
  if [[ -f "$file" ]]; then
    grep -E "^\s*${key}\s*=" "$file" 2>/dev/null | head -1 | sed 's/^[^=]*=\s*//' | tr -d '"' | tr -d "'" | xargs
  fi
}

strip_project_root() {
  local raw="$1"
  local name
  name=$(echo "$raw" | sed 's|{project[-_]root}/||' | sed 's|/$||')
  if [[ "$name" == *"/"* ]]; then
    name=$(basename "$name")
  fi
  echo "$name"
}

resolve_config_value() {
  local env_var="$1" yaml_key="$2" default="$3"

  # 1. Env override
  local env_val="${!env_var:-}"
  if [[ -n "$env_val" ]]; then
    echo "$env_val"
    return
  fi

  # 2. config.yaml
  local raw
  raw="$(read_yaml_key "$BMAD_CORE/bmm/config.yaml" "$yaml_key")"
  if [[ -n "$raw" ]]; then
    strip_project_root "$raw"
    return
  fi

  # 3. config.toml
  raw="$(read_toml_key "$BMAD_CORE/config.toml" "$yaml_key")"
  if [[ -n "$raw" ]]; then
    strip_project_root "$raw"
    return
  fi

  echo "$default"
}

OUTPUT_FOLDER_NAME=""
DOCS_FOLDER_NAME=""

check_metarepo() {
  [[ -d "$BMAD_CORE" ]] || die "Not in a BMAD metarepo — _bmad/ directory not found at $REPO_ROOT"
  [[ -d "$PROJECTS_DIR" ]] || die "No projects/ directory found at $REPO_ROOT"
  OUTPUT_FOLDER_NAME="$(resolve_config_value BMAD_OUTPUT_FOLDER output_folder features)"
  DOCS_FOLDER_NAME="$(resolve_config_value BMAD_DOCS_FOLDER project_knowledge docs)"
}

# Computed paths
symlink_path()    { echo "$REPO_ROOT/$OUTPUT_FOLDER_NAME"; }
docs_symlink()    { echo "$REPO_ROOT/$DOCS_FOLDER_NAME"; }
project_output()  { echo "$PROJECTS_DIR/$1/$OUTPUT_FOLDER_NAME"; }
project_docs()    { echo "$PROJECTS_DIR/$1/$DOCS_FOLDER_NAME"; }
project_skills()  { echo "$PROJECTS_DIR/$1/.agents/skills"; }

get_active_project() {
  if [[ -f "$ACTIVE_FILE" ]]; then
    cat "$ACTIVE_FILE" | tr -d '[:space:]'
  else
    echo ""
  fi
}

get_symlink_target() {
  local sp
  sp="$(symlink_path)"
  if [[ -L "$sp" ]]; then
    readlink "$sp" | sed "s|^projects/||" | sed "s|/${OUTPUT_FOLDER_NAME}$||"
  else
    echo ""
  fi
}

list_projects() {
  local active
  active="$(get_active_project)"

  if [[ ! -d "$PROJECTS_DIR" ]] || [[ -z "$(ls -A "$PROJECTS_DIR" 2>/dev/null)" ]]; then
    warn "No projects found. Run: ${BOLD}bmad-router init <name>${NC}"
    return
  fi

  echo -e "${BOLD}Projects:${NC}  ${DIM}(output: ${OUTPUT_FOLDER_NAME}, docs: ${DOCS_FOLDER_NAME})${NC}"
  for dir in "$PROJECTS_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    local name
    name="$(basename "$dir")"
    local markers=""
    # Skill count
    if [[ -d "$PROJECTS_DIR/$name/.agents/skills" ]]; then
      local skill_count
      skill_count=$(find "$PROJECTS_DIR/$name/.agents/skills" -name 'SKILL.md' 2>/dev/null | wc -l | tr -d '[:space:]')
      if (( skill_count > 0 )); then
        markers+=" ${DIM}[${skill_count} skill(s)]${NC}"
      fi
    fi
    if [[ "$name" == "$active" ]]; then
      echo -e "  ${GREEN}● $name${NC} ${DIM}(active)${NC}${markers}"
    else
      echo -e "  ${DIM}○${NC} $name${markers}"
    fi
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# Scaffold
# ─────────────────────────────────────────────────────────────────────────────

scaffold_output() {
  local project_name="$1"
  local output_dir
  output_dir="$(project_output "$project_name")"
  local docs_dir
  docs_dir="$(project_docs "$project_name")"
  local skills_dir
  skills_dir="$(project_skills "$project_name")"

  # Output folder
  mkdir -p "$output_dir/planning-artifacts/epics"
  mkdir -p "$output_dir/implementation-artifacts"

  # Docs folder
  mkdir -p "$docs_dir"

  # Skills folder
  mkdir -p "$skills_dir"

  # Seed project-context.md
  if [[ ! -f "$output_dir/project-context.md" ]]; then
    cat > "$output_dir/project-context.md" << 'TMPL'
# Project Context

<!-- Generated by bmad-router. Edit this file to capture your project's
     conventions, tech stack decisions, and implementation rules. BMAD agents
     read this before every workflow. -->

## Project Overview

- **Name**: REPLACE_ME
- **Description**: REPLACE_ME
- **Tech Stack**: REPLACE_ME

## Implementation Rules

<!-- Add rules the Dev agent must follow, e.g.:
  - Use functional components with hooks (no class components)
  - All API routes must validate input with zod
  - Tests required for all business logic
-->

## Conventions

<!-- Naming, folder structure, commit message format, etc. -->
TMPL
    info "Seeded project-context.md template"
  fi

  # Seed sprint-status.yaml
  if [[ ! -f "$output_dir/implementation-artifacts/sprint-status.yaml" ]]; then
    cat > "$output_dir/implementation-artifacts/sprint-status.yaml" << 'TMPL'
# Sprint Status — managed by BMAD sprint-planning workflow
current_sprint: null
epics: []
TMPL
  fi

  # Seed docs README
  if [[ -z "$(ls -A "$docs_dir" 2>/dev/null)" ]]; then
    cat > "$docs_dir/README.md" << TMPL
# ${project_name} — Project Knowledge

Place project documentation here: ADRs, API specs, domain glossary,
onboarding guides, etc. BMAD agents read this directory as project_knowledge.

Shared knowledge that applies to all projects lives at \`.agents/knowledge/\`.
TMPL
  fi

  # Seed skills README
  if [[ -z "$(ls -A "$skills_dir" 2>/dev/null)" ]]; then
    cat > "$skills_dir/README.md" << 'TMPL'
# Project Skills

Place agent skill folders here. Each skill should be a directory with a
SKILL.md file. These skills are only active when this project is the
active bmad-router context.

Example:
  .agents/skills/
    my-api-skill/
      SKILL.md
TMPL
  fi

  # .gitkeep for empty dirs
  for d in "$output_dir/planning-artifacts/epics" "$output_dir/implementation-artifacts"; do
    if [[ -z "$(ls -A "$d" 2>/dev/null)" ]]; then
      touch "$d/.gitkeep"
    fi
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# Symlink management
# ─────────────────────────────────────────────────────────────────────────────

swap_symlink() {
  local link_path="$1" target="$2" label="$3"

  if [[ -e "$link_path" && ! -L "$link_path" ]]; then
    die "$label exists at repo root but is NOT a symlink. Move or remove it first."
  fi
  if [[ -L "$link_path" ]]; then
    rm "$link_path"
  fi
  ln -s "$target" "$link_path"
}

switch_all_symlinks() {
  local project_name="$1"

  # Output folder
  swap_symlink "$(symlink_path)" "projects/$project_name/$OUTPUT_FOLDER_NAME" "$OUTPUT_FOLDER_NAME"

  # Docs folder
  swap_symlink "$(docs_symlink)" "projects/$project_name/$DOCS_FOLDER_NAME" "$DOCS_FOLDER_NAME"

  # Skills
  mkdir -p "$SKILLS_DIR"
  if [[ -L "$SKILLS_PROJECT_LINK" ]]; then
    rm "$SKILLS_PROJECT_LINK"
  elif [[ -e "$SKILLS_PROJECT_LINK" ]]; then
    warn ".agents/skills/project is not a symlink — skipping skills switch"
    return
  fi
  if [[ -d "$(project_skills "$project_name")" ]]; then
    ln -s "../../projects/$project_name/.agents/skills" "$SKILLS_PROJECT_LINK"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Commands
# ─────────────────────────────────────────────────────────────────────────────

cmd_switch() {
  local project_name="${1:-}"
  [[ -n "$project_name" ]] || die "Usage: bmad-router switch <project-name>"

  local target_dir
  target_dir="$(project_output "$project_name")"

  if [[ ! -d "$PROJECTS_DIR/$project_name" ]]; then
    warn "Project '$project_name' not found."
    echo ""
    list_projects
    echo ""
    echo -e "To create it: ${BOLD}bmad-router init $project_name${NC}"
    exit 1
  fi

  if [[ ! -d "$target_dir" ]]; then
    info "Scaffolding for '$project_name'..."
    scaffold_output "$project_name"
  fi

  switch_all_symlinks "$project_name"
  echo "$project_name" > "$ACTIVE_FILE"

  ok "Switched to ${BOLD}$project_name${NC}"

  # Report skills
  local skill_count
  skill_count=$(find "$(project_skills "$project_name")" -name 'SKILL.md' 2>/dev/null | wc -l | tr -d '[:space:]')
  if (( skill_count > 0 )); then
    ok "$skill_count project skill(s) activated"
  fi

  # Project context summary
  local ctx="$target_dir/project-context.md"
  if [[ -f "$ctx" ]]; then
    local lines
    lines=$(wc -l < "$ctx")
    if (( lines > 5 )); then
      echo ""
      echo -e "${DIM}── project-context.md ──${NC}"
      head -20 "$ctx" | sed 's/^/  /'
      if (( lines > 20 )); then echo -e "  ${DIM}... ($(( lines - 20 )) more lines)${NC}"; fi
    fi
  fi

  # Artifact inventory
  echo ""
  echo -e "${DIM}── artifacts ──${NC}"
  local prd="$target_dir/planning-artifacts/PRD.md"
  local arch="$target_dir/planning-artifacts/architecture.md"
  local epics_dir="$target_dir/planning-artifacts/epics"
  local sprint="$target_dir/implementation-artifacts/sprint-status.yaml"

  [[ -f "$prd" ]] && ok "PRD.md" || echo -e "  ${DIM}○ PRD.md (not yet created)${NC}"
  [[ -f "$arch" ]] && ok "architecture.md" || echo -e "  ${DIM}○ architecture.md (not yet created)${NC}"

  local epic_count
  epic_count=$(find "$epics_dir" -name '*.md' 2>/dev/null | wc -l | tr -d '[:space:]')
  if (( epic_count > 0 )); then
    ok "$epic_count epic file(s)"
  else
    echo -e "  ${DIM}○ epics/ (empty)${NC}"
  fi

  [[ -f "$sprint" ]] && ok "sprint-status.yaml" || echo -e "  ${DIM}○ sprint-status.yaml${NC}"

  # Docs summary
  local docs_dir
  docs_dir="$(project_docs "$project_name")"
  local doc_count
  doc_count=$(find "$docs_dir" -name '*.md' -not -name 'README.md' 2>/dev/null | wc -l | tr -d '[:space:]')
  if (( doc_count > 0 )); then
    echo ""
    echo -e "${DIM}── docs ──${NC}"
    ok "$doc_count doc file(s) in $DOCS_FOLDER_NAME/"
  fi
}

cmd_list() {
  list_projects
}

cmd_current() {
  local active
  active="$(get_active_project)"
  local symlink_target
  symlink_target="$(get_symlink_target)"

  if [[ -z "$active" && -z "$symlink_target" ]]; then
    warn "No active project. Run: ${BOLD}bmad-router switch <project>${NC}"
    echo ""
    list_projects
    return
  fi

  if [[ -n "$active" && -n "$symlink_target" && "$active" != "$symlink_target" ]]; then
    warn "Mismatch: active-project.txt says '${active}' but symlink points to '${symlink_target}'"
    info "Run ${BOLD}bmad-router switch $active${NC} to fix."
    return
  fi

  local name="${active:-$symlink_target}"
  echo -e "${GREEN}●${NC} Active project: ${BOLD}$name${NC}"

  local sp
  sp="$(symlink_path)"
  if [[ -L "$sp" ]]; then
    echo -e "  ${DIM}output: $OUTPUT_FOLDER_NAME -> $(readlink "$sp")${NC}"
  fi

  local ds
  ds="$(docs_symlink)"
  if [[ -L "$ds" ]]; then
    echo -e "  ${DIM}docs:   $DOCS_FOLDER_NAME -> $(readlink "$ds")${NC}"
  fi

  if [[ -L "$SKILLS_PROJECT_LINK" ]]; then
    local skill_count
    skill_count=$(find "$SKILLS_PROJECT_LINK" -name 'SKILL.md' 2>/dev/null | wc -l | tr -d '[:space:]')
    echo -e "  ${DIM}skills: .agents/skills/project ($skill_count skill(s))${NC}"
  else
    echo -e "  ${DIM}skills: no project-specific skills${NC}"
  fi
}

cmd_init() {
  local project_name="${1:-}"
  [[ -n "$project_name" ]] || die "Usage: bmad-router init <project-name>"

  if [[ ! "$project_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    die "Project name must contain only letters, numbers, hyphens, and underscores."
  fi

  local project_dir="$PROJECTS_DIR/$project_name"
  local output_dir
  output_dir="$(project_output "$project_name")"

  if [[ -d "$output_dir" ]]; then
    warn "Project '$project_name' already exists."
    info "Switching to it instead."
    cmd_switch "$project_name"
    return
  fi

  info "Creating project: $project_name"
  mkdir -p "$project_dir/src"
  scaffold_output "$project_name"

  ok "Scaffolded $project_dir/"

  cmd_switch "$project_name"
}

cmd_config() {
  echo -e "${BOLD}BMAD Router Configuration${NC}"
  echo ""
  echo -e "  output folder:       ${GREEN}$OUTPUT_FOLDER_NAME${NC}"
  echo -e "  docs folder:         ${GREEN}$DOCS_FOLDER_NAME${NC}"

  # Source for output folder
  if [[ -n "${BMAD_OUTPUT_FOLDER:-}" ]]; then
    echo -e "  output source:       ${DIM}BMAD_OUTPUT_FOLDER env var${NC}"
  elif [[ -f "$BMAD_CORE/bmm/config.yaml" ]] && grep -qE '^\s*output_folder\s*:' "$BMAD_CORE/bmm/config.yaml" 2>/dev/null; then
    echo -e "  output source:       ${DIM}_bmad/bmm/config.yaml${NC}"
  else
    echo -e "  output source:       ${DIM}default${NC}"
  fi

  # Source for docs folder
  if [[ -n "${BMAD_DOCS_FOLDER:-}" ]]; then
    echo -e "  docs source:         ${DIM}BMAD_DOCS_FOLDER env var${NC}"
  elif [[ -f "$BMAD_CORE/bmm/config.yaml" ]] && grep -qE '^\s*project_knowledge\s*:' "$BMAD_CORE/bmm/config.yaml" 2>/dev/null; then
    echo -e "  docs source:         ${DIM}_bmad/bmm/config.yaml${NC}"
  else
    echo -e "  docs source:         ${DIM}default${NC}"
  fi

  local sp
  sp="$(symlink_path)"
  if [[ -L "$sp" ]]; then
    echo -e "  output symlink:      ${DIM}$(readlink "$sp")${NC}"
  else
    echo -e "  output symlink:      ${DIM}not set${NC}"
  fi

  local ds
  ds="$(docs_symlink)"
  if [[ -L "$ds" ]]; then
    echo -e "  docs symlink:        ${DIM}$(readlink "$ds")${NC}"
  else
    echo -e "  docs symlink:        ${DIM}not set${NC}"
  fi

  if [[ -L "$SKILLS_PROJECT_LINK" ]]; then
    echo -e "  project skills:      ${DIM}$(readlink "$SKILLS_PROJECT_LINK")${NC}"
  else
    echo -e "  project skills:      ${DIM}not linked${NC}"
  fi

  echo -e "  active project:      ${DIM}$(get_active_project || echo 'none')${NC}"
}

cmd_validate() {
  local errors=0

  echo -e "${BOLD}Validating BMAD metarepo...${NC}"
  echo -e "${DIM}  output: $OUTPUT_FOLDER_NAME | docs: $DOCS_FOLDER_NAME${NC}"
  echo ""

  [[ -d "$BMAD_CORE" ]]    && ok "_bmad/" || { warn "_bmad/ missing"; ((errors++)); }
  [[ -d "$PROJECTS_DIR" ]] && ok "projects/" || { warn "projects/ missing"; ((errors++)); }
  [[ -d "$AGENTS_DIR" ]]   && ok ".agents/" || { warn ".agents/ missing"; ((errors++)); }
  [[ -f "$REPO_ROOT/AGENTS.md" ]] && ok "AGENTS.md" || { warn "AGENTS.md missing"; ((errors++)); }

  # Shared knowledge
  if [[ -d "$AGENTS_DIR/knowledge" ]]; then
    ok ".agents/knowledge/ (shared)"
  else
    info ".agents/knowledge/ not found (optional)"
  fi

  # Output symlink
  local sp
  sp="$(symlink_path)"
  if [[ -L "$sp" ]]; then
    if [[ -d "$sp" ]]; then
      ok "$OUTPUT_FOLDER_NAME symlink → $(readlink "$sp") (valid)"
    else
      warn "$OUTPUT_FOLDER_NAME symlink → $(readlink "$sp") (BROKEN)"; ((errors++))
    fi
  elif [[ -e "$sp" ]]; then
    warn "$OUTPUT_FOLDER_NAME is a real directory, not a symlink"; ((errors++))
  else
    warn "$OUTPUT_FOLDER_NAME symlink missing"; ((errors++))
  fi

  # Docs symlink
  local ds
  ds="$(docs_symlink)"
  if [[ -L "$ds" ]]; then
    if [[ -d "$ds" ]]; then
      ok "$DOCS_FOLDER_NAME symlink → $(readlink "$ds") (valid)"
    else
      warn "$DOCS_FOLDER_NAME symlink → $(readlink "$ds") (BROKEN)"; ((errors++))
    fi
  elif [[ -e "$ds" ]]; then
    warn "$DOCS_FOLDER_NAME is a real directory, not a symlink"; ((errors++))
  else
    warn "$DOCS_FOLDER_NAME symlink missing"; ((errors++))
  fi

  # Skills symlink
  if [[ -L "$SKILLS_PROJECT_LINK" ]]; then
    if [[ -d "$SKILLS_PROJECT_LINK" ]]; then
      ok ".agents/skills/project symlink (valid)"
    else
      warn ".agents/skills/project symlink (BROKEN)"; ((errors++))
    fi
  elif [[ -e "$SKILLS_PROJECT_LINK" ]]; then
    warn ".agents/skills/project is not a symlink"; ((errors++))
  else
    info ".agents/skills/project not set (no project skills)"
  fi

  # active-project.txt
  local active
  active="$(get_active_project)"
  if [[ -n "$active" ]]; then
    ok "active-project.txt → $active"
    local sym_target
    sym_target="$(get_symlink_target)"
    if [[ -n "$sym_target" && "$active" != "$sym_target" ]]; then
      warn "Mismatch: active-project.txt='$active' vs symlink='$sym_target'"; ((errors++))
    fi
  else
    warn "active-project.txt missing or empty"; ((errors++))
  fi

  # Active project artifacts
  local out
  out="$(project_output "$active")"
  if [[ -n "$active" && -d "$out" ]]; then
    echo ""
    echo -e "${BOLD}Active project artifacts ($active):${NC}"
    [[ -d "$out/planning-artifacts" ]] && ok "planning-artifacts/" || warn "planning-artifacts/ missing"
    [[ -d "$out/planning-artifacts/epics" ]] && ok "planning-artifacts/epics/" || warn "planning-artifacts/epics/ missing"
    [[ -d "$out/implementation-artifacts" ]] && ok "implementation-artifacts/" || warn "implementation-artifacts/ missing"
    [[ -f "$out/project-context.md" ]] && ok "project-context.md" || warn "project-context.md missing"
  fi

  echo ""
  if (( errors == 0 )); then
    ok "All checks passed."
  else
    warn "$errors issue(s) found."
  fi

  return $errors
}

cmd_help() {
  cat << EOF

  bmad-router — Multi-project context switcher for BMAD metarepos

  USAGE
    bmad-router <command> [args]

  COMMANDS
    switch <project>    Switch active project (output + docs + skills)
    list                List all projects (with skill counts)
    current             Show currently active project
    init <project>      Scaffold and switch to a new project
    config              Show resolved configuration
    validate            Check metarepo health

  SYMLINKS MANAGED
    <output-folder>            → projects/<active>/<output-folder>
    <docs-folder>              → projects/<active>/<docs-folder>
    .agents/skills/project     → projects/<active>/.agents/skills

  CONFIG RESOLUTION (first match wins for each)
    Output folder:  BMAD_OUTPUT_FOLDER env → config.yaml output_folder → "features"
    Docs folder:    BMAD_DOCS_FOLDER env → config.yaml project_knowledge → "docs"

  EXAMPLES
    bmad-router init food-inventory
    bmad-router switch film-camera-app
    bmad-router list
    bmad-router config
    BMAD_OUTPUT_FOLDER=specs bmad-router init my-project

EOF
}

main() {
  check_metarepo

  local cmd="${1:-help}"
  shift || true

  case "$cmd" in
    switch)   cmd_switch "$@" ;;
    list)     cmd_list "$@" ;;
    current)  cmd_current "$@" ;;
    init)     cmd_init "$@" ;;
    config)   cmd_config "$@" ;;
    validate) cmd_validate "$@" ;;
    help|-h|--help) cmd_help ;;
    *) die "Unknown command: $cmd (run 'bmad-router help' for usage)" ;;
  esac
}

main "$@"
