#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(pwd)"
SKILL_DIR_REL="${SKILL_DIR#"$REPO_ROOT"/}"
ROUTER_SELF="$SKILL_DIR_REL/scripts/meta-router.sh"
BOOTSTRAP_SELF="$SKILL_DIR_REL/scripts/bmad-github-bootstrap.sh"

BMAD_CORE="$REPO_ROOT/_bmad"
WORKSPACES_DIR="$REPO_ROOT/workspaces"
LEGACY_ACTIVE_FILE="$REPO_ROOT/active-project.txt"

TOOL_DIR=""
SKILLS_BASE=""
KNOWLEDGE_BASE=""
SKILLS_DIR=""
SKILLS_WORKSPACE_LINK=""

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

parse_repos_yaml() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  awk '
    function clean(s) { sub(/^[^:]*:[[:space:]]*/, "", s); gsub(/["\x27]/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*-[[:space:]]*name[[:space:]]*:/ {
      if (have) print name "\t" url "\t" branch
      have = 1; name = clean($0); url = ""; branch = "main"; next
    }
    /^[[:space:]]*url[[:space:]]*:/    { url = clean($0); next }
    /^[[:space:]]*branch[[:space:]]*:/ { branch = clean($0); next }
    END { if (have) print name "\t" url "\t" branch }
  ' "$file" | awk -F'\t' '$1 != "REPLACE_ME" && $2 != "REPLACE_ME"'
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

  local env_val="${!env_var:-}"
  if [[ -n "$env_val" ]]; then
    echo "$env_val"
    return
  fi

  local raw
  raw="$(read_yaml_key "$BMAD_CORE/bmm/config.yaml" "$yaml_key")"
  if [[ -n "$raw" ]]; then
    strip_project_root "$raw"
    return
  fi

  raw="$(read_toml_key "$BMAD_CORE/config.toml" "$yaml_key")"
  if [[ -n "$raw" ]]; then
    strip_project_root "$raw"
    return
  fi

  echo "$default"
}

tool_dir_for_tool() {
  case "$1" in
    claude-code)    echo ".claude" ;;
    github-copilot) echo ".github" ;;
    codex)          echo ".codex" ;;
    *)              echo ".agents" ;;
  esac
}

OUTPUT_FOLDER_NAME=""
DOCS_FOLDER_NAME=""
AGENT_TOOL=""

check_metarepo() {
  [[ -d "$BMAD_CORE" ]] || die "Not in a BMad metarepo — _bmad/ directory not found at $REPO_ROOT"
  [[ -d "$WORKSPACES_DIR" ]] || die "No workspaces/ directory found at $REPO_ROOT"
  OUTPUT_FOLDER_NAME="$(resolve_config_value BMAD_OUTPUT_FOLDER output_folder features)"
  DOCS_FOLDER_NAME="$(resolve_config_value BMAD_DOCS_FOLDER project_knowledge docs)"
  AGENT_TOOL="$(resolve_config_value BMAD_AGENT_TOOL agent_tool claude-code)"
  TOOL_DIR="$(tool_dir_for_tool "$AGENT_TOOL")"
  SKILLS_BASE="$TOOL_DIR/skills"
  KNOWLEDGE_BASE="$TOOL_DIR/knowledge"
  SKILLS_DIR="$REPO_ROOT/$SKILLS_BASE"
  SKILLS_WORKSPACE_LINK="$SKILLS_DIR/workspace"
}

symlink_path()    { echo "$REPO_ROOT/$OUTPUT_FOLDER_NAME"; }
docs_symlink()    { echo "$REPO_ROOT/$DOCS_FOLDER_NAME"; }
repos_symlink()   { echo "$REPO_ROOT/repos"; }
impl_symlink()    { echo "$REPO_ROOT/implementation"; }
workspace_output()     { echo "$WORKSPACES_DIR/$1/$OUTPUT_FOLDER_NAME"; }
workspace_docs()       { echo "$WORKSPACES_DIR/$1/$DOCS_FOLDER_NAME"; }
workspace_skills()     { echo "$WORKSPACES_DIR/$1/$SKILLS_BASE"; }
workspace_repos_yaml() { echo "$WORKSPACES_DIR/$1/repos.yaml"; }
workspace_repos_dir()  { echo "$WORKSPACES_DIR/$1/repos"; }
workspace_impl_dir()   { echo "$WORKSPACES_DIR/$1/implementation"; }

get_active_workspace() {
  get_symlink_target
}

require_active_workspace() {
  local active
  active="$(get_active_workspace)"
  [[ -n "$active" ]] || die "No active workspace. Run: ${BOLD}meta-router switch <workspace>${NC}"
  [[ -d "$WORKSPACES_DIR/$active" ]] || die "Active workspace '$active' not found under workspaces/"
  echo "$active"
}

get_symlink_target() {
  local sp
  sp="$(symlink_path)"
  if [[ -L "$sp" ]]; then
    local escaped_folder="${OUTPUT_FOLDER_NAME//./\\.}"
    readlink "$sp" | sed "s|^workspaces/||" | sed "s|/${escaped_folder}$||"
  else
    echo ""
  fi
}

list_workspaces() {
  local active
  active="$(get_active_workspace)"

  if [[ ! -d "$WORKSPACES_DIR" ]] || [[ -z "$(ls -A "$WORKSPACES_DIR" 2>/dev/null)" ]]; then
    warn "No workspaces found. Run: ${BOLD}meta-router init <name>${NC}"
    return
  fi

  echo -e "${BOLD}Workspaces:${NC}  ${DIM}(output: ${OUTPUT_FOLDER_NAME}, docs: ${DOCS_FOLDER_NAME})${NC}"
  for dir in "$WORKSPACES_DIR"/*/; do
    [[ -d "$dir" ]] || continue
    local name
    name="$(basename "$dir")"
    local markers=""
    local pskills
    pskills="$(workspace_skills "$name")"
    if [[ -d "$pskills" ]]; then
      local skill_count
      skill_count=$(find "$pskills" -name 'SKILL.md' 2>/dev/null | wc -l | tr -d '[:space:]')
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

scaffold_output() {
  local workspace_name="$1"
  local output_dir
  output_dir="$(workspace_output "$workspace_name")"
  local docs_dir
  docs_dir="$(workspace_docs "$workspace_name")"
  local skills_dir
  skills_dir="$(workspace_skills "$workspace_name")"
  local repos_dir
  repos_dir="$(workspace_repos_dir "$workspace_name")"
  local impl_dir
  impl_dir="$(workspace_impl_dir "$workspace_name")"

  mkdir -p "$output_dir/planning-artifacts/epics"
  mkdir -p "$output_dir/implementation-artifacts"

  mkdir -p "$docs_dir"

  mkdir -p "$skills_dir"

  mkdir -p "$repos_dir"
  mkdir -p "$impl_dir"

  if [[ ! -f "$output_dir/workspace-context.md" ]]; then
    cat > "$output_dir/workspace-context.md" << 'TMPL'
# Workspace Context

<!-- Generated by meta-router. Edit this file to capture your workspace's
     conventions, tech stack decisions, and implementation rules. BMad agents
     read this before every workflow. -->

## Workspace Overview

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
    info "Seeded workspace-context.md template"
  fi

  if [[ ! -f "$output_dir/implementation-artifacts/sprint-status.yaml" ]]; then
    cat > "$output_dir/implementation-artifacts/sprint-status.yaml" << 'TMPL'
# Sprint Status — generated by the BMad sprint-planning workflow
development_status: {}
TMPL
  fi

  if [[ -z "$(ls -A "$docs_dir" 2>/dev/null)" ]]; then
    cat > "$docs_dir/README.md" << TMPL
# ${workspace_name} — Project Knowledge

Place workspace documentation here: ADRs, API specs, domain glossary,
onboarding guides, etc. BMad agents read this directory as project_knowledge.

Shared knowledge that applies to all workspaces lives at \`${KNOWLEDGE_BASE}/\`.
TMPL
  fi

  if [[ -z "$(ls -A "$skills_dir" 2>/dev/null)" ]]; then
    cat > "$skills_dir/README.md" << TMPL
# Workspace Skills

Place agent skill folders here. Each skill should be a directory with a
SKILL.md file. These skills are only active when this workspace is the
active meta-router context.

Example:
  workspaces/${workspace_name}/${SKILLS_BASE}/
    my-api-skill/
      SKILL.md
TMPL
  fi

  if [[ ! -f "$(workspace_repos_yaml "$workspace_name")" ]]; then
    cat > "$(workspace_repos_yaml "$workspace_name")" << 'TMPL'
# repos.yaml — source repositories for this workspace.
#
# meta-router clones these into workspaces/<name>/repos/ (gitignored) and creates
# per-story git worktrees under workspaces/<name>/implementation/<story-id>/<repo>/.
#
# A story may touch several repos (e.g. a full-stack story spanning a web app,
# a GraphQL aggregator, and a backend service). List every repo the workspace owns;
# each story declares which subset it touches via its "## Affected Repos" section.
#
# Each entry needs: name (local clone dir), url (git remote), branch (default branch).
repos:
  # - name: web
  #   url: git@github.com:you/web.git
  #   branch: main
  # - name: api
  #   url: git@github.com:you/api.git
  #   branch: main
TMPL
    info "Seeded repos.yaml template"
  fi

  if [[ ! -f "$WORKSPACES_DIR/$workspace_name/github-sync.yaml" ]]; then
    cat > "$WORKSPACES_DIR/$workspace_name/github-sync.yaml" << 'TMPL'
# GitHub sync configuration for this workspace.
# Used by the meta-router skill's bmad-issues.py and the sync-issues GitHub Action.

# Optional: the GitHub repo where delivery issues (epics + stories) are
# created. Defaults to the metarepo — set this only if you want a workspace's
# issues to live next to its code instead. The planning checklist issue is
# always created in the metarepo.
# repo: owner/repo

# GitHub Project (v2) board for this workspace. Filled in by the skill's
# bmad-github-bootstrap.sh — leave null to sync issues without a board.
# project_owner defaults to the owner of the issues repo.
project: null
project_owner: null

# Labels applied to delivery issues by type (created automatically if
# missing). The sync also applies bmad-delivery / bmad-planning labels, which
# the board views filter on.
labels:
  epic: epic
  story: story

# Set false to skip the "Planning: <workspace>" checklist issue in the metarepo.
planning: true
TMPL
    info "Seeded github-sync.yaml (create the board with bash $BOOTSTRAP_SELF $workspace_name)"
  fi

  if [[ -z "$(ls -A "$repos_dir" 2>/dev/null)" ]]; then
    cat > "$repos_dir/README.md" << 'TMPL'
# repos/

Git clones of this workspace's source repositories live here, one directory per
entry in `../repos.yaml`. This folder is gitignored — clones are managed
independently of the metarepo.

Populate it with:

    bash __ROUTER__ clone

Per-story worktrees are created from these clones under `../implementation/`.
TMPL
    sed -i.bak "s|__ROUTER__|$ROUTER_SELF|g" "$repos_dir/README.md" && rm -f "$repos_dir/README.md.bak"
  fi

  if [[ -z "$(ls -A "$impl_dir" 2>/dev/null)" ]]; then
    cat > "$impl_dir/README.md" << 'TMPL'
# implementation/

Per-story git worktrees live here, laid out as `<story-id>/<repo>/`. Each is an
isolated working tree checked out on branch `story/<story-id>` from the matching
clone in `../repos/`. This folder is gitignored.

Create worktrees for a story (one per affected repo) with:

    bash __ROUTER__ worktree <story-id> [repo...]

and tear them down with:

    bash __ROUTER__ worktree-rm <story-id>
TMPL
    sed -i.bak "s|__ROUTER__|$ROUTER_SELF|g" "$impl_dir/README.md" && rm -f "$impl_dir/README.md.bak"
  fi

  for d in "$output_dir/planning-artifacts/epics" "$output_dir/implementation-artifacts"; do
    if [[ -z "$(ls -A "$d" 2>/dev/null)" ]]; then
      touch "$d/.gitkeep"
    fi
  done
}

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
  local workspace_name="$1"

  mkdir -p \
    "$(workspace_output "$workspace_name")" \
    "$(workspace_docs "$workspace_name")" \
    "$(workspace_repos_dir "$workspace_name")" \
    "$(workspace_impl_dir "$workspace_name")"

  swap_symlink "$(symlink_path)" "workspaces/$workspace_name/$OUTPUT_FOLDER_NAME" "$OUTPUT_FOLDER_NAME"

  swap_symlink "$(docs_symlink)" "workspaces/$workspace_name/$DOCS_FOLDER_NAME" "$DOCS_FOLDER_NAME"

  swap_symlink "$(repos_symlink)" "workspaces/$workspace_name/repos" "repos"
  swap_symlink "$(impl_symlink)" "workspaces/$workspace_name/implementation" "implementation"

  mkdir -p "$SKILLS_DIR"
  if [[ -L "$SKILLS_WORKSPACE_LINK" ]]; then
    rm "$SKILLS_WORKSPACE_LINK"
  elif [[ -e "$SKILLS_WORKSPACE_LINK" ]]; then
    warn "$SKILLS_BASE/workspace is not a symlink — skipping skills switch"
    return
  fi
  if [[ -d "$(workspace_skills "$workspace_name")" ]]; then
    ln -s "../../workspaces/$workspace_name/$SKILLS_BASE" "$SKILLS_WORKSPACE_LINK"
  fi
}

cmd_switch() {
  local workspace_name="${1:-}"
  [[ -n "$workspace_name" ]] || die "Usage: meta-router switch <workspace-name>"

  local target_dir
  target_dir="$(workspace_output "$workspace_name")"

  if [[ ! -d "$WORKSPACES_DIR/$workspace_name" ]]; then
    warn "Workspace '$workspace_name' not found."
    echo ""
    list_workspaces
    echo ""
    echo -e "To create it: ${BOLD}meta-router init $workspace_name${NC}"
    exit 1
  fi

  if [[ ! -d "$target_dir" ]]; then
    info "Scaffolding for '$workspace_name'..."
    scaffold_output "$workspace_name"
  fi

  switch_all_symlinks "$workspace_name"
  rm -f "$LEGACY_ACTIVE_FILE"

  ok "Switched to ${BOLD}$workspace_name${NC}"

  local skill_count
  skill_count=$(find "$(workspace_skills "$workspace_name")" -name 'SKILL.md' 2>/dev/null | wc -l | tr -d '[:space:]')
  if (( skill_count > 0 )); then
    ok "$skill_count workspace skill(s) activated"
  fi

  local ctx="$target_dir/workspace-context.md"
  if [[ -f "$ctx" ]] && grep -q "REPLACE_ME" "$ctx"; then
    info "workspace-context.md not filled in yet — edit it so agents know this workspace's conventions"
  elif [[ -f "$ctx" ]]; then
    local lines
    lines=$(wc -l < "$ctx")
    if (( lines > 5 )); then
      echo ""
      echo -e "${DIM}── workspace-context.md ──${NC}"
      head -20 "$ctx" | sed 's/^/  /'
      if (( lines > 20 )); then echo -e "  ${DIM}... ($(( lines - 20 )) more lines)${NC}"; fi
    fi
  fi

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

  local docs_dir
  docs_dir="$(workspace_docs "$workspace_name")"
  local doc_count
  doc_count=$(find "$docs_dir" -name '*.md' -not -name 'README.md' 2>/dev/null | wc -l | tr -d '[:space:]')
  if (( doc_count > 0 )); then
    echo ""
    echo -e "${DIM}── docs ──${NC}"
    ok "$doc_count doc file(s) in $DOCS_FOLDER_NAME/"
  fi
}

cmd_list() {
  list_workspaces
}

cmd_current() {
  local active
  active="$(get_active_workspace)"

  if [[ -z "$active" ]]; then
    warn "No active workspace. Run: ${BOLD}meta-router switch <workspace>${NC}"
    echo ""
    list_workspaces
    return
  fi

  echo -e "${GREEN}●${NC} Active workspace: ${BOLD}$active${NC}"

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

  local rs
  rs="$(repos_symlink)"
  [[ -L "$rs" ]] && echo -e "  ${DIM}repos:  repos -> $(readlink "$rs")${NC}"

  local is
  is="$(impl_symlink)"
  [[ -L "$is" ]] && echo -e "  ${DIM}impl:   implementation -> $(readlink "$is")${NC}"

  if [[ -L "$SKILLS_WORKSPACE_LINK" ]]; then
    local skill_count
    skill_count=$(find -L "$SKILLS_WORKSPACE_LINK" -name 'SKILL.md' 2>/dev/null | wc -l | tr -d '[:space:]')
    echo -e "  ${DIM}skills: $SKILLS_BASE/workspace ($skill_count skill(s))${NC}"
  else
    echo -e "  ${DIM}skills: no workspace-specific skills${NC}"
  fi
}

cmd_init() {
  local workspace_name="${1:-}"
  [[ -n "$workspace_name" ]] || die "Usage: meta-router init <workspace-name> [--no-switch]"

  local do_switch=true
  if [[ "${2:-}" == "--no-switch" ]]; then
    do_switch=false
  fi

  if [[ ! "$workspace_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    die "Workspace name must contain only letters, numbers, hyphens, and underscores."
  fi

  local workspace_dir="$WORKSPACES_DIR/$workspace_name"
  local output_dir
  output_dir="$(workspace_output "$workspace_name")"

  if [[ -d "$output_dir" ]]; then
    warn "Workspace '$workspace_name' already exists."
    if [[ "$do_switch" == true ]]; then
      info "Switching to it instead."
      cmd_switch "$workspace_name"
    fi
    return
  fi

  info "Creating workspace: $workspace_name"
  mkdir -p "$workspace_dir"
  scaffold_output "$workspace_name"

  ok "Scaffolded $workspace_dir/"

  if [[ "$do_switch" == true ]]; then
    cmd_switch "$workspace_name"
  fi
}

cmd_repos() {
  local active
  active="$(require_active_workspace)"
  local yaml
  yaml="$(workspace_repos_yaml "$active")"
  [[ -f "$yaml" ]] || die "No repos.yaml for '$active'. Run: ${BOLD}meta-router init $active${NC}"

  echo -e "${BOLD}Repos for $active:${NC}"
  local found=0
  while IFS=$'\t' read -r name url branch; do
    [[ -n "$name" ]] || continue
    found=1
    local clonedir; clonedir="$(workspace_repos_dir "$active")/$name"
    if [[ -d "$clonedir/.git" ]]; then
      ok "$name ${DIM}($url @ $branch) [cloned]${NC}"
    else
      echo -e "  ${DIM}○ $name ($url @ $branch) [not cloned]${NC}"
    fi
  done < <(parse_repos_yaml "$yaml")

  (( found )) || warn "No repos configured (edit workspaces/$active/repos.yaml)"
}

cmd_clone() {
  local active
  active="$(require_active_workspace)"
  local want="${1:-}"
  local yaml
  yaml="$(workspace_repos_yaml "$active")"
  [[ -f "$yaml" ]] || die "No repos.yaml for '$active'"
  command -v git &>/dev/null || die "git not found"

  local any=0
  while IFS=$'\t' read -r name url branch; do
    [[ -n "$name" && -n "$url" ]] || continue
    [[ -n "$want" && "$want" != "$name" ]] && continue
    any=1
    local dest; dest="$(workspace_repos_dir "$active")/$name"
    if [[ -d "$dest/.git" ]]; then
      info "$name already cloned"
      continue
    fi
    info "Cloning $name from $url ($branch)"
    git clone --branch "$branch" "$url" "$dest" || die "clone failed for $name"
    ok "Cloned $name -> repos/$name"
  done < <(parse_repos_yaml "$yaml")

  if [[ -n "$want" ]] && (( ! any )); then
    die "Repo '$want' not found in repos.yaml"
  fi
  (( any )) || die "No repos configured to clone (edit workspaces/$active/repos.yaml)"
}

add_worktree() {
  local active="$1" repo="$2" story="$3"
  local clonedir; clonedir="$(workspace_repos_dir "$active")/$repo"
  [[ -d "$clonedir/.git" ]] || die "Repo '$repo' not cloned. Run: ${BOLD}meta-router clone $repo${NC}"

  local wt; wt="$(workspace_impl_dir "$active")/$story/$repo"
  if [[ -e "$wt" ]]; then
    warn "worktree already exists: implementation/$story/$repo (skipping)"
    return 0
  fi
  mkdir -p "$(dirname "$wt")"

  local branch="story/$story"
  if git -C "$clonedir" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$clonedir" worktree add "$wt" "$branch" || die "git worktree add failed for $repo"
  else
    git -C "$clonedir" worktree add -b "$branch" "$wt" || die "git worktree add failed for $repo"
  fi
  ok "worktree: implementation/$story/$repo ${DIM}(branch $branch)${NC}"
}

cmd_worktree() {
  if [[ "${1:-}" == "list" ]]; then
    shift
    cmd_worktree_list "$@"
    return
  fi

  local active
  active="$(require_active_workspace)"

  local story="" all=0
  local repos=()
  for arg in "$@"; do
    case "$arg" in
      --all) all=1 ;;
      *)
        if [[ -z "$story" ]]; then story="$arg"; else repos+=("$arg"); fi
        ;;
    esac
  done

  [[ -n "$story" ]] || die "Usage: meta-router worktree <story-id> [repo...] [--all]"
  [[ "$story" =~ ^[a-zA-Z0-9_.-]+$ ]] || die "Invalid story id: '$story'"
  command -v git &>/dev/null || die "git not found"

  local yaml
  yaml="$(workspace_repos_yaml "$active")"
  local names=()
  while IFS=$'\t' read -r n _u _b; do [[ -n "$n" ]] && names+=("$n"); done < <(parse_repos_yaml "$yaml")
  (( ${#names[@]} > 0 )) || die "No repos configured for '$active' (edit workspaces/$active/repos.yaml)"

  local targets=()
  if (( all )); then
    targets=("${names[@]}")
  elif (( ${#repos[@]} > 0 )); then
    targets=("${repos[@]}")
  elif (( ${#names[@]} == 1 )); then
    targets=("${names[0]}")
  else
    die "Multiple repos configured — specify which to use (or --all): ${names[*]}"
  fi

  local repo
  for repo in "${targets[@]}"; do
    printf '%s\n' "${names[@]}" | grep -qx "$repo" || die "Repo '$repo' not in repos.yaml (configured: ${names[*]})"
  done

  info "Creating worktree(s) for story '$story' on branch story/$story"
  for repo in "${targets[@]}"; do
    add_worktree "$active" "$repo" "$story"
  done
}

cmd_worktree_rm() {
  local active
  active="$(require_active_workspace)"
  local story="${1:-}"
  [[ -n "$story" ]] || die "Usage: meta-router worktree-rm <story-id>"
  [[ "$story" =~ ^[a-zA-Z0-9_.-]+$ ]] || die "Invalid story id: '$story'"
  command -v git &>/dev/null || die "git not found"

  local story_dir; story_dir="$(workspace_impl_dir "$active")/$story"
  [[ -d "$story_dir" ]] || die "No worktrees for story '$story' (implementation/$story not found)"

  local removed=0
  for repo_path in "$story_dir"/*/; do
    [[ -d "$repo_path" ]] || continue
    local repo
    repo="$(basename "$repo_path")"
    local clonedir; clonedir="$(workspace_repos_dir "$active")/$repo"
    if [[ -d "$clonedir/.git" ]]; then
      git -C "$clonedir" worktree remove --force "$repo_path" 2>/dev/null || rm -rf "$repo_path"
      git -C "$clonedir" worktree prune 2>/dev/null || true
    else
      rm -rf "$repo_path"
    fi
    ok "removed worktree: implementation/$story/$repo"
    removed=1
  done

  rmdir "$story_dir" 2>/dev/null || rm -rf "$story_dir"
  (( removed )) || warn "No repo worktrees found under implementation/$story"
}

cmd_worktree_list() {
  local active
  active="$(require_active_workspace)"
  local impl; impl="$(workspace_impl_dir "$active")"

  local printed=0
  if [[ -d "$impl" ]]; then
    for story_dir in "$impl"/*/; do
      [[ -d "$story_dir" ]] || continue
      local story
      story="$(basename "$story_dir")"
      local repo_list=""
      for repo_path in "$story_dir"/*/; do
        [[ -d "$repo_path" ]] || continue
        repo_list+=" $(basename "$repo_path")"
      done
      [[ -n "$repo_list" ]] || continue
      if (( ! printed )); then echo -e "${BOLD}Worktrees for $active:${NC}"; printed=1; fi
      echo -e "  ${GREEN}●${NC} $story ${DIM}(branch story/$story):${repo_list}${NC}"
    done
  fi

  (( printed )) || info "No active worktrees for '$active'"
}

cmd_config() {
  echo -e "${BOLD}Meta Router Configuration${NC}"
  echo ""
  echo -e "  output folder:       ${GREEN}$OUTPUT_FOLDER_NAME${NC}"
  echo -e "  docs folder:         ${GREEN}$DOCS_FOLDER_NAME${NC}"
  echo -e "  agent tool:          ${GREEN}$AGENT_TOOL${NC} ${DIM}(skills: $SKILLS_BASE/)${NC}"

  if [[ -f "$REPO_ROOT/$KNOWLEDGE_BASE/shared-context.md" ]]; then
    echo -e "  shared context:      ${GREEN}$KNOWLEDGE_BASE/shared-context.md${NC} ${DIM}(present)${NC}"
  else
    echo -e "  shared context:      ${DIM}$KNOWLEDGE_BASE/shared-context.md (not seeded)${NC}"
  fi

  if [[ -n "${BMAD_AGENT_TOOL:-}" ]]; then
    echo -e "  tool source:         ${DIM}BMAD_AGENT_TOOL env var${NC}"
  elif [[ -f "$BMAD_CORE/bmm/config.yaml" ]] && grep -qE '^\s*agent_tool\s*:' "$BMAD_CORE/bmm/config.yaml" 2>/dev/null; then
    echo -e "  tool source:         ${DIM}_bmad/bmm/config.yaml${NC}"
  else
    echo -e "  tool source:         ${DIM}default${NC}"
  fi

  if [[ -n "${BMAD_OUTPUT_FOLDER:-}" ]]; then
    echo -e "  output source:       ${DIM}BMAD_OUTPUT_FOLDER env var${NC}"
  elif [[ -f "$BMAD_CORE/bmm/config.yaml" ]] && grep -qE '^\s*output_folder\s*:' "$BMAD_CORE/bmm/config.yaml" 2>/dev/null; then
    echo -e "  output source:       ${DIM}_bmad/bmm/config.yaml${NC}"
  else
    echo -e "  output source:       ${DIM}default${NC}"
  fi

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

  if [[ -L "$SKILLS_WORKSPACE_LINK" ]]; then
    echo -e "  workspace skills:      ${DIM}$(readlink "$SKILLS_WORKSPACE_LINK")${NC}"
  else
    echo -e "  workspace skills:      ${DIM}not linked${NC}"
  fi

  local active
  active="$(get_active_workspace)"
  echo -e "  active workspace:      ${DIM}${active:-none}${NC}"

  if [[ -n "$active" ]]; then
    local repos_yaml
    repos_yaml="$(workspace_repos_yaml "$active")"
    if [[ -f "$repos_yaml" ]]; then
      local cfg_count clone_count=0 rname
      cfg_count="$(parse_repos_yaml "$repos_yaml" | grep -c . || true)"
      while IFS=$'\t' read -r rname _ _; do
        [[ -n "$rname" && -d "$(workspace_repos_dir "$active")/$rname/.git" ]] && clone_count=$((clone_count + 1))
      done < <(parse_repos_yaml "$repos_yaml")
      echo -e "  configured repos:    ${DIM}${cfg_count:-0} (cloned: $clone_count)${NC}"
    fi
  fi
}

cmd_validate() {
  local errors=0

  echo -e "${BOLD}Validating BMad metarepo...${NC}"
  echo -e "${DIM}  output: $OUTPUT_FOLDER_NAME | docs: $DOCS_FOLDER_NAME | tool: $AGENT_TOOL (skills: $SKILLS_BASE/)${NC}"
  echo ""

  if [[ -d "$BMAD_CORE" ]]; then
    ok "_bmad/"
  else
    warn "_bmad/ missing"; errors=$((errors + 1))
  fi

  if [[ -d "$WORKSPACES_DIR" ]]; then
    ok "workspaces/"
  else
    warn "workspaces/ missing"; errors=$((errors + 1))
  fi

  if [[ -d "$REPO_ROOT/$TOOL_DIR" ]]; then
    ok "$TOOL_DIR/ (agent tool home)"
  else
    warn "$TOOL_DIR/ missing"; errors=$((errors + 1))
  fi

  if [[ -f "$REPO_ROOT/AGENTS.md" ]]; then
    ok "AGENTS.md"
  else
    warn "AGENTS.md missing"; errors=$((errors + 1))
  fi

  if [[ -d "$REPO_ROOT/$KNOWLEDGE_BASE" ]]; then
    ok "$KNOWLEDGE_BASE/ (shared)"
  else
    info "$KNOWLEDGE_BASE/ not found (optional)"
  fi

  if [[ -f "$REPO_ROOT/$KNOWLEDGE_BASE/shared-context.md" ]]; then
    ok "$KNOWLEDGE_BASE/shared-context.md (shared context)"
  else
    info "$KNOWLEDGE_BASE/shared-context.md not found (run setup.sh to seed)"
  fi

  local sp
  sp="$(symlink_path)"
  if [[ -L "$sp" ]]; then
    if [[ -d "$sp" ]]; then
      ok "$OUTPUT_FOLDER_NAME symlink → $(readlink "$sp") (valid)"
    else
      warn "$OUTPUT_FOLDER_NAME symlink → $(readlink "$sp") (BROKEN)"; errors=$((errors + 1))
    fi
  elif [[ -e "$sp" ]]; then
    warn "$OUTPUT_FOLDER_NAME is a real directory, not a symlink"; errors=$((errors + 1))
  else
    warn "$OUTPUT_FOLDER_NAME symlink missing"; errors=$((errors + 1))
  fi

  local ds
  ds="$(docs_symlink)"
  if [[ -L "$ds" ]]; then
    if [[ -d "$ds" ]]; then
      ok "$DOCS_FOLDER_NAME symlink → $(readlink "$ds") (valid)"
    else
      warn "$DOCS_FOLDER_NAME symlink → $(readlink "$ds") (BROKEN)"; errors=$((errors + 1))
    fi
  elif [[ -e "$ds" ]]; then
    warn "$DOCS_FOLDER_NAME is a real directory, not a symlink"; errors=$((errors + 1))
  else
    warn "$DOCS_FOLDER_NAME symlink missing"; errors=$((errors + 1))
  fi

  local root_link
  for root_link in "$(repos_symlink)" "$(impl_symlink)"; do
    local link_name
    link_name="$(basename "$root_link")"
    if [[ -L "$root_link" ]]; then
      if [[ -d "$root_link" ]]; then
        ok "$link_name symlink → $(readlink "$root_link") (valid)"
      else
        warn "$link_name symlink → $(readlink "$root_link") (BROKEN)"; errors=$((errors + 1))
      fi
    elif [[ -e "$root_link" ]]; then
      warn "$link_name is a real directory, not a symlink"; errors=$((errors + 1))
    else
      warn "$link_name symlink missing"; errors=$((errors + 1))
    fi
  done

  if [[ -L "$SKILLS_WORKSPACE_LINK" ]]; then
    if [[ -d "$SKILLS_WORKSPACE_LINK" ]]; then
      ok "$SKILLS_BASE/workspace symlink (valid)"
    else
      warn "$SKILLS_BASE/workspace symlink (BROKEN)"; errors=$((errors + 1))
    fi
  elif [[ -e "$SKILLS_WORKSPACE_LINK" ]]; then
    warn "$SKILLS_BASE/workspace is not a symlink"; errors=$((errors + 1))
  else
    info "$SKILLS_BASE/workspace not set (no workspace skills)"
  fi

  local active
  active="$(get_active_workspace)"

  local out
  out="$(workspace_output "$active")"
  if [[ -n "$active" && -d "$out" ]]; then
    echo ""
    echo -e "${BOLD}Active workspace artifacts ($active):${NC}"

    if [[ -d "$out/planning-artifacts" ]]; then
      ok "planning-artifacts/"
    else
      warn "planning-artifacts/ missing"
    fi

    if [[ -d "$out/planning-artifacts/epics" ]]; then
      ok "planning-artifacts/epics/"
    else
      warn "planning-artifacts/epics/ missing"
    fi

    if [[ -d "$out/implementation-artifacts" ]]; then
      ok "implementation-artifacts/"
    else
      warn "implementation-artifacts/ missing"
    fi

    if [[ -f "$out/workspace-context.md" ]]; then
      ok "workspace-context.md"
    else
      warn "workspace-context.md missing"
    fi

    local sync_yaml="$WORKSPACES_DIR/$active/github-sync.yaml"
    if [[ ! -f "$sync_yaml" ]]; then
      info "github-sync.yaml not found (GitHub sync disabled for this workspace)"
    elif grep -qE '^project:[[:space:]]*[0-9]+' "$sync_yaml"; then
      ok "github-sync.yaml (project board configured)"
    else
      info "github-sync.yaml present, board not created — run bash $BOOTSTRAP_SELF $active"
    fi

    local repos_yaml repos_dir impl_dir
    repos_yaml="$(workspace_repos_yaml "$active")"
    repos_dir="$(workspace_repos_dir "$active")"
    impl_dir="$(workspace_impl_dir "$active")"
    if [[ -f "$repos_yaml" ]]; then ok "repos.yaml"; else info "repos.yaml not found (optional)"; fi
    if [[ -d "$repos_dir" ]]; then ok "repos/ (gitignored)"; else info "repos/ not found (optional)"; fi
    if [[ -d "$impl_dir" ]]; then ok "implementation/ (gitignored)"; else info "implementation/ not found (optional)"; fi
    if [[ -f "$repos_yaml" ]]; then
      local cfg_count clone_count=0 rname
      cfg_count="$(parse_repos_yaml "$repos_yaml" | grep -c . || true)"
      while IFS=$'\t' read -r rname _ _; do
        [[ -n "$rname" && -d "$repos_dir/$rname/.git" ]] && clone_count=$((clone_count + 1))
      done < <(parse_repos_yaml "$repos_yaml")
      info "repos configured: ${cfg_count:-0} (cloned: $clone_count)"
    fi
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

  meta-router — Multi-workspace context switcher for BMad metarepos

  USAGE
    meta-router <command> [args]

  COMMANDS
    switch <workspace>            Switch active workspace (output + docs + repos + implementation + skills)
    list                        List all workspaces (with skill counts)
    current                     Show currently active workspace
    init <workspace> [--no-switch]  Scaffold a new workspace (and switch to it unless --no-switch)
    config                      Show resolved configuration
    validate                    Check metarepo health
    repos                       List the active workspace's source repos
    clone [repo]                Clone repos.yaml entries into repos/
    worktree <story> [repo...]  Create per-story worktree(s) (one per repo)
    worktree <story> --all      Create a worktree for every configured repo
    worktree list               List active per-story worktrees
    worktree-rm <story>         Remove all worktrees for a story

  SYMLINKS MANAGED
    <output-folder>            → workspaces/<active>/<output-folder>
    <docs-folder>              → workspaces/<active>/<docs-folder>
    repos                      → workspaces/<active>/repos
    implementation             → workspaces/<active>/implementation
    $SKILLS_BASE/workspace   → workspaces/<active>/$SKILLS_BASE

  SOURCE REPOS + WORKTREES
    repos.yaml                 Tracked manifest of the workspace's source repos
    repos/<name>/              Git clone of each repo (gitignored)
    implementation/<story>/<repo>/   Per-story worktree on branch story/<story> (gitignored)

  CONFIG RESOLUTION (first match wins for each)
    Output folder:  BMAD_OUTPUT_FOLDER env → config.yaml output_folder → "features"
    Docs folder:    BMAD_DOCS_FOLDER env → config.yaml project_knowledge → "docs"
    Agent tool:     BMAD_AGENT_TOOL env → config.yaml agent_tool → "claude-code"
                    (claude-code→.claude/skills, github-copilot→.github/skills,
                     codex→.codex/skills)

  EXAMPLES
    meta-router init food-inventory
    meta-router switch film-camera-app
    meta-router clone
    meta-router worktree STORY-001 web api      # full-stack story across two repos
    meta-router worktree-rm STORY-001
    BMAD_OUTPUT_FOLDER=specs meta-router init my-workspace

EOF
}

main() {
  check_metarepo

  local cmd="${1:-help}"
  shift || true

  case "$cmd" in
    switch)      cmd_switch "$@" ;;
    list)        cmd_list "$@" ;;
    current)     cmd_current "$@" ;;
    init)        cmd_init "$@" ;;
    config)      cmd_config "$@" ;;
    validate)    cmd_validate "$@" ;;
    repos)       cmd_repos "$@" ;;
    clone)       cmd_clone "$@" ;;
    worktree)    cmd_worktree "$@" ;;
    worktree-rm) cmd_worktree_rm "$@" ;;
    help|-h|--help) cmd_help ;;
    *) die "Unknown command: $cmd (run 'meta-router help' for usage)" ;;
  esac
}

main "$@"
