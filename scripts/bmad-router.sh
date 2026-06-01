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

# Parse repos.yaml into tab-separated "name<TAB>url<TAB>branch" lines (one per repo).
# Skips comments, tolerates quotes, defaults branch to "main", and drops any entry
# still holding a REPLACE_ME placeholder. No yq dependency.
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
repos_symlink()   { echo "$REPO_ROOT/repos"; }
impl_symlink()    { echo "$REPO_ROOT/implementation"; }
project_output()     { echo "$PROJECTS_DIR/$1/$OUTPUT_FOLDER_NAME"; }
project_docs()       { echo "$PROJECTS_DIR/$1/$DOCS_FOLDER_NAME"; }
project_skills()     { echo "$PROJECTS_DIR/$1/.agents/skills"; }
project_repos_yaml() { echo "$PROJECTS_DIR/$1/repos.yaml"; }
project_repos_dir()  { echo "$PROJECTS_DIR/$1/repos"; }
project_impl_dir()   { echo "$PROJECTS_DIR/$1/implementation"; }

get_active_project() {
  if [[ -f "$ACTIVE_FILE" ]]; then
    cat "$ACTIVE_FILE" | tr -d '[:space:]'
  else
    echo ""
  fi
}

require_active_project() {
  local active
  active="$(get_active_project)"
  [[ -n "$active" ]] || die "No active project. Run: ${BOLD}bmad-router switch <project>${NC}"
  [[ -d "$PROJECTS_DIR/$active" ]] || die "Active project '$active' not found under projects/"
  echo "$active"
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
  local repos_dir
  repos_dir="$(project_repos_dir "$project_name")"
  local impl_dir
  impl_dir="$(project_impl_dir "$project_name")"

  # Output folder
  mkdir -p "$output_dir/planning-artifacts/epics"
  mkdir -p "$output_dir/implementation-artifacts"

  # Docs folder
  mkdir -p "$docs_dir"

  # Skills folder
  mkdir -p "$skills_dir"

  # Source repos (clones) + per-story worktrees — both gitignored
  mkdir -p "$repos_dir"
  mkdir -p "$impl_dir"

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

  # Seed repos.yaml — the tracked manifest of this project's source repos
  if [[ ! -f "$(project_repos_yaml "$project_name")" ]]; then
    cat > "$(project_repos_yaml "$project_name")" << 'TMPL'
# repos.yaml — source repositories for this project.
#
# bmad-router clones these into projects/<name>/repos/ (gitignored) and creates
# per-story git worktrees under projects/<name>/implementation/<story-id>/<repo>/.
#
# A story may touch several repos (e.g. a full-stack story spanning a web app,
# a GraphQL aggregator, and a backend service). List every repo the project owns;
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

  # Seed repos/ README
  if [[ -z "$(ls -A "$repos_dir" 2>/dev/null)" ]]; then
    cat > "$repos_dir/README.md" << 'TMPL'
# repos/

Git clones of this project's source repositories live here, one directory per
entry in `../repos.yaml`. This folder is gitignored — clones are managed
independently of the metarepo.

Populate it with:

    bash scripts/bmad-router.sh clone

Per-story worktrees are created from these clones under `../implementation/`.
TMPL
  fi

  # Seed implementation/ README
  if [[ -z "$(ls -A "$impl_dir" 2>/dev/null)" ]]; then
    cat > "$impl_dir/README.md" << 'TMPL'
# implementation/

Per-story git worktrees live here, laid out as `<story-id>/<repo>/`. Each is an
isolated working tree checked out on branch `story/<story-id>` from the matching
clone in `../repos/`. This folder is gitignored.

Create worktrees for a story (one per affected repo) with:

    bash scripts/bmad-router.sh worktree <story-id> [repo...]

and tear them down with:

    bash scripts/bmad-router.sh worktree-rm <story-id>
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

  # Source repos + per-story worktrees — routed at the root so the active
  # project's clones/worktrees are reachable without a projects/<active>/ path.
  swap_symlink "$(repos_symlink)" "projects/$project_name/repos" "repos"
  swap_symlink "$(impl_symlink)" "projects/$project_name/implementation" "implementation"

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

  local rs
  rs="$(repos_symlink)"
  [[ -L "$rs" ]] && echo -e "  ${DIM}repos:  repos -> $(readlink "$rs")${NC}"

  local is
  is="$(impl_symlink)"
  [[ -L "$is" ]] && echo -e "  ${DIM}impl:   implementation -> $(readlink "$is")${NC}"

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
  mkdir -p "$project_dir"
  scaffold_output "$project_name"

  ok "Scaffolded $project_dir/"

  cmd_switch "$project_name"
}

# ─────────────────────────────────────────────────────────────────────────────
# Source repos + per-story worktrees
# ─────────────────────────────────────────────────────────────────────────────

cmd_repos() {
  local active
  active="$(require_active_project)"
  local yaml
  yaml="$(project_repos_yaml "$active")"
  [[ -f "$yaml" ]] || die "No repos.yaml for '$active'. Run: ${BOLD}bmad-router init $active${NC}"

  echo -e "${BOLD}Repos for $active:${NC}"
  local found=0
  while IFS=$'\t' read -r name url branch; do
    [[ -n "$name" ]] || continue
    found=1
    local clonedir="$(project_repos_dir "$active")/$name"
    if [[ -d "$clonedir/.git" ]]; then
      ok "$name ${DIM}($url @ $branch) [cloned]${NC}"
    else
      echo -e "  ${DIM}○ $name ($url @ $branch) [not cloned]${NC}"
    fi
  done < <(parse_repos_yaml "$yaml")

  (( found )) || warn "No repos configured (edit projects/$active/repos.yaml)"
}

cmd_clone() {
  local active
  active="$(require_active_project)"
  local want="${1:-}"
  local yaml
  yaml="$(project_repos_yaml "$active")"
  [[ -f "$yaml" ]] || die "No repos.yaml for '$active'"
  command -v git &>/dev/null || die "git not found"

  local any=0
  while IFS=$'\t' read -r name url branch; do
    [[ -n "$name" && -n "$url" ]] || continue
    [[ -n "$want" && "$want" != "$name" ]] && continue
    any=1
    local dest="$(project_repos_dir "$active")/$name"
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
  (( any )) || die "No repos configured to clone (edit projects/$active/repos.yaml)"
}

# Add a single worktree for one repo of a story.
add_worktree() {
  local active="$1" repo="$2" story="$3"
  local clonedir="$(project_repos_dir "$active")/$repo"
  [[ -d "$clonedir/.git" ]] || die "Repo '$repo' not cloned. Run: ${BOLD}bmad-router clone $repo${NC}"

  local wt="$(project_impl_dir "$active")/$story/$repo"
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
  # `worktree list` shows active worktrees instead of creating one.
  if [[ "${1:-}" == "list" ]]; then
    shift
    cmd_worktree_list "$@"
    return
  fi

  local active
  active="$(require_active_project)"

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

  [[ -n "$story" ]] || die "Usage: bmad-router worktree <story-id> [repo...] [--all]"
  [[ "$story" =~ ^[a-zA-Z0-9_.-]+$ ]] || die "Invalid story id: '$story'"
  command -v git &>/dev/null || die "git not found"

  local yaml
  yaml="$(project_repos_yaml "$active")"
  local names=()
  while IFS=$'\t' read -r n u b; do [[ -n "$n" ]] && names+=("$n"); done < <(parse_repos_yaml "$yaml")
  (( ${#names[@]} > 0 )) || die "No repos configured for '$active' (edit projects/$active/repos.yaml)"

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

  # Validate every requested repo is actually configured.
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
  active="$(require_active_project)"
  local story="${1:-}"
  [[ -n "$story" ]] || die "Usage: bmad-router worktree-rm <story-id>"
  command -v git &>/dev/null || die "git not found"

  local story_dir="$(project_impl_dir "$active")/$story"
  [[ -d "$story_dir" ]] || die "No worktrees for story '$story' (implementation/$story not found)"

  local removed=0
  for repo_path in "$story_dir"/*/; do
    [[ -d "$repo_path" ]] || continue
    local repo
    repo="$(basename "$repo_path")"
    local clonedir="$(project_repos_dir "$active")/$repo"
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
  active="$(require_active_project)"
  local impl="$(project_impl_dir "$active")"

  local printed=0
  if [[ -d "$impl" ]]; then
    for story_dir in "$impl"/*/; do
      [[ -d "$story_dir" ]] || continue
      local story
      story="$(basename "$story_dir")"
      local repos=""
      for repo_path in "$story_dir"/*/; do
        [[ -d "$repo_path" ]] || continue
        repos+=" $(basename "$repo_path")"
      done
      [[ -n "$repos" ]] || continue
      if (( ! printed )); then echo -e "${BOLD}Worktrees for $active:${NC}"; printed=1; fi
      echo -e "  ${GREEN}●${NC} $story ${DIM}(branch story/$story):${repos}${NC}"
    done
  fi

  (( printed )) || info "No active worktrees for '$active'"
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

  local active
  active="$(get_active_project)"
  echo -e "  active project:      ${DIM}${active:-none}${NC}"

  if [[ -n "$active" ]]; then
    local repos_yaml
    repos_yaml="$(project_repos_yaml "$active")"
    if [[ -f "$repos_yaml" ]]; then
      local cfg_count clone_count=0 rname
      cfg_count="$(parse_repos_yaml "$repos_yaml" | grep -c . || true)"
      while IFS=$'\t' read -r rname _ _; do
        [[ -n "$rname" && -d "$(project_repos_dir "$active")/$rname/.git" ]] && clone_count=$((clone_count + 1))
      done < <(parse_repos_yaml "$repos_yaml")
      echo -e "  configured repos:    ${DIM}${cfg_count:-0} (cloned: $clone_count)${NC}"
    fi
  fi
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

    # Source repos + worktrees (clones/worktrees are gitignored — absence is not an error)
    local repos_yaml repos_dir impl_dir
    repos_yaml="$(project_repos_yaml "$active")"
    repos_dir="$(project_repos_dir "$active")"
    impl_dir="$(project_impl_dir "$active")"
    [[ -f "$repos_yaml" ]] && ok "repos.yaml" || info "repos.yaml not found (optional)"
    [[ -d "$repos_dir" ]] && ok "repos/ (gitignored)" || info "repos/ not found (optional)"
    [[ -d "$impl_dir" ]] && ok "implementation/ (gitignored)" || info "implementation/ not found (optional)"
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

  bmad-router — Multi-project context switcher for BMAD metarepos

  USAGE
    bmad-router <command> [args]

  COMMANDS
    switch <project>            Switch active project (output + docs + skills)
    list                        List all projects (with skill counts)
    current                     Show currently active project
    init <project>              Scaffold and switch to a new project
    config                      Show resolved configuration
    validate                    Check metarepo health
    repos                       List the active project's source repos
    clone [repo]                Clone repos.yaml entries into repos/
    worktree <story> [repo...]  Create per-story worktree(s) (one per repo)
    worktree --all <story>      Create a worktree for every configured repo
    worktree list               List active per-story worktrees
    worktree-rm <story>         Remove all worktrees for a story

  SYMLINKS MANAGED
    <output-folder>            → projects/<active>/<output-folder>
    <docs-folder>              → projects/<active>/<docs-folder>
    repos                      → projects/<active>/repos
    implementation             → projects/<active>/implementation
    .agents/skills/project     → projects/<active>/.agents/skills

  SOURCE REPOS + WORKTREES
    repos.yaml                 Tracked manifest of the project's source repos
    repos/<name>/              Git clone of each repo (gitignored)
    implementation/<story>/<repo>/   Per-story worktree on branch story/<story> (gitignored)

  CONFIG RESOLUTION (first match wins for each)
    Output folder:  BMAD_OUTPUT_FOLDER env → config.yaml output_folder → "features"
    Docs folder:    BMAD_DOCS_FOLDER env → config.yaml project_knowledge → "docs"

  EXAMPLES
    bmad-router init food-inventory
    bmad-router switch film-camera-app
    bmad-router clone
    bmad-router worktree STORY-001 web api      # full-stack story across two repos
    bmad-router worktree-rm STORY-001
    BMAD_OUTPUT_FOLDER=specs bmad-router init my-project

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
    *) die "Unknown command: $cmd (run 'bmad-router help' for usage)" ;;
  esac
}

main "$@"
