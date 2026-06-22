#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
REPO_ROOT="$(pwd)"
WORKSPACES_DIR="$REPO_ROOT/workspaces"
SKILL_DIR_REL="${SKILL_DIR#"$REPO_ROOT"/}"

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

command -v gh >/dev/null || die "gh CLI not found — install from https://cli.github.com"
gh auth status >/dev/null 2>&1 || die "gh CLI not authenticated. Run: gh auth login"

TOKEN_SCOPES="$(gh auth status 2>&1 | sed -n 's/.*Token scopes: //p' | head -n1)"
if [[ -n "$TOKEN_SCOPES" && "$TOKEN_SCOPES" != *"'project'"* ]]; then
  warn "Your gh token lacks the 'project' scope (have: $TOKEN_SCOPES)."
  if [[ -t 0 ]]; then
    echo -e "  ${DIM}'project' is required to create boards; admin:org only to create org issue types.${NC}"
    read -rp "  Refresh the token now? (runs: gh auth refresh -s project,admin:org) [Y/n]: " REFRESH_TOKEN
    case "$(printf '%s' "$REFRESH_TOKEN" | tr '[:upper:]' '[:lower:]')" in
      n|no) die "cannot create boards without the 'project' scope. Run: gh auth refresh -s project,admin:org" ;;
    esac
    gh auth refresh -s project,admin:org || die "token refresh failed — run it manually: gh auth refresh -s project,admin:org"
    ok "Token refreshed"
  else
    die "Run: gh auth refresh -s project,admin:org   then re-run this script"
  fi
fi

read_sync_value() {
  sed -n "s/^$2:[[:space:]]*//p" "$1" | head -n1 | tr -d '"' | tr -d "'"
}

OWNER_ID=""
OWNER_IS_ORG=false

resolve_owner() {
  OWNER_ID="$(gh api graphql -f query='query($login: String!) { organization(login: $login) { id } }' \
    -f login="$1" --jq '.data.organization.id' 2>/dev/null || true)"
  if [[ -n "$OWNER_ID" ]]; then
    OWNER_IS_ORG=true
    return 0
  fi
  OWNER_IS_ORG=false
  OWNER_ID="$(gh api graphql -f query='query($login: String!) { user(login: $login) { id } }' \
    -f login="$1" --jq '.data.user.id' 2>/dev/null || true)"
  [[ -n "$OWNER_ID" ]]
}

TEMPLATE_TITLE_DEFAULT="BMad Project Template"
ROOT_SYNC_CFG="$REPO_ROOT/github-sync.yaml"
TEMPLATE_TITLE="${BMAD_TEMPLATE_NAME:-}"
if [[ -z "$TEMPLATE_TITLE" && -f "$ROOT_SYNC_CFG" ]]; then
  TEMPLATE_TITLE="$(read_sync_value "$ROOT_SYNC_CFG" template)"
fi
TEMPLATE_TITLE="${TEMPLATE_TITLE:-$TEMPLATE_TITLE_DEFAULT}"

TEMPLATE_PROJECT_ID=""
TEMPLATE_CHECKED_OWNER=""

save_root_sync_value() {
  local key="$1" value="$2" quiet="${3:-}"
  if [[ -f "$ROOT_SYNC_CFG" && "$(read_sync_value "$ROOT_SYNC_CFG" "$key")" == "$value" ]]; then
    return 0
  fi
  if [[ -f "$ROOT_SYNC_CFG" ]] && grep -qE "^$key:" "$ROOT_SYNC_CFG"; then
    sed -i.bak "s|^$key:.*|$key: $value|" "$ROOT_SYNC_CFG" && rm -f "$ROOT_SYNC_CFG.bak"
  else
    if [[ ! -f "$ROOT_SYNC_CFG" ]]; then
      printf '# Metarepo-wide GitHub sync settings.\n# Per-workspace settings live in workspaces/<name>/github-sync.yaml.\n\n' > "$ROOT_SYNC_CFG"
    fi
    echo "$key: $value" >> "$ROOT_SYNC_CFG"
  fi
  [[ "$quiet" == "quiet" ]] || ok "Saved to github-sync.yaml ($key: $value)"
}

save_template_name() {
  save_root_sync_value template "$TEMPLATE_TITLE"
}

BOARD_OWNER=""
BOARD_OWNER_RUN_CHOICE=""

pick_board_owner() {
  local workspace_cfg="$1" fallback="$2"
  local configured
  configured="$(read_sync_value "$workspace_cfg" project_owner)"
  if [[ -n "$configured" && "$configured" != "null" ]]; then
    BOARD_OWNER="$configured"
    return
  fi
  if [[ -f "$ROOT_SYNC_CFG" ]]; then
    configured="$(read_sync_value "$ROOT_SYNC_CFG" project_owner)"
    if [[ -n "$configured" && "$configured" != "null" ]]; then
      BOARD_OWNER="$configured"
      return
    fi
  fi
  if [[ -n "$BOARD_OWNER_RUN_CHOICE" ]]; then
    BOARD_OWNER="$BOARD_OWNER_RUN_CHOICE"
    return
  fi
  if [[ ! -t 0 ]]; then
    BOARD_OWNER="$fallback"
    return
  fi

  local user_login owners=() owner_login idx choice
  user_login="$(gh api user --jq .login 2>/dev/null || true)"
  [[ -n "$user_login" ]] && owners+=("$user_login")
  while IFS= read -r owner_login; do
    [[ -n "$owner_login" ]] && owners+=("$owner_login")
  done < <(gh api user/orgs --jq '.[].login' 2>/dev/null || true)

  echo ""
  echo -e "  Where should the project boards live?"
  echo -e "  ${DIM}(Templates need an org — personal boards get a per-board view checklist.)${NC}"
  if [[ ${#owners[@]} -gt 0 ]]; then
    idx=1
    for owner_login in "${owners[@]}"; do
      if [[ "$owner_login" == "$user_login" ]]; then
        echo -e "    $idx) $owner_login ${DIM}(personal)${NC}"
      else
        echo -e "    $idx) $owner_login"
      fi
      idx=$((idx + 1))
    done
    read -rp "  Board owner (number or name) [$fallback]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#owners[@]} )); then
      BOARD_OWNER="${owners[$((choice - 1))]}"
    else
      BOARD_OWNER="${choice:-$fallback}"
    fi
  else
    read -rp "  Board owner (org or username) [$fallback]: " BOARD_OWNER
    BOARD_OWNER="${BOARD_OWNER:-$fallback}"
  fi
  BOARD_OWNER_RUN_CHOICE="$BOARD_OWNER"

  read -rp "  Save '$BOARD_OWNER' as the default board owner for this metarepo? [Y/n]: " SAVE_OWNER
  case "$(printf '%s' "$SAVE_OWNER" | tr '[:upper:]' '[:lower:]')" in
    n|no) ;;
    *) save_root_sync_value project_owner "$BOARD_OWNER" ;;
  esac
}

find_template_id() {
  local owner="$1" stored_id
  if [[ -f "$ROOT_SYNC_CFG" ]]; then
    stored_id="$(read_sync_value "$ROOT_SYNC_CFG" template_id)"
    if [[ -n "$stored_id" && "$stored_id" != "null" ]]; then
      local verified
      verified="$(gh api graphql -f query='query($id: ID!) {
          node(id: $id) { ... on ProjectV2 {
            id template
            owner { ... on Organization { login } ... on User { login } }
          } }
        }' -f id="$stored_id" \
        --jq ".data.node | select(.template == true) | select(.owner.login == \"$owner\") | .id" 2>/dev/null || true)"
      if [[ -n "$verified" ]]; then
        echo "$verified"
        return
      fi
      warn "Stored template_id no longer resolves to a template owned by '$owner' — falling back to a name search" >&2
    fi
  fi
  gh api graphql -f query='query($login: String!, $q: String!) {
      organization(login: $login) {
        projectsV2(first: 20, query: $q) { nodes { id title template } }
      }
    }' -f login="$owner" -f q="$TEMPLATE_TITLE" \
    --jq ".data.organization.projectsV2.nodes[] | select(.title == \"$TEMPLATE_TITLE\" and .template == true) | .id" 2>/dev/null | head -n1
}

warn_if_backlog_view_missing() {
  local project_id="$1" url="$2"
  local view_names
  view_names="$(gh api graphql -f query='query($id: ID!) {
      node(id: $id) { ... on ProjectV2 { views(first: 20) { nodes { name } } } }
    }' -f id="$project_id" --jq '[.data.node.views.nodes[].name] | join("|")' 2>/dev/null || true)"
  if [[ "$view_names" == *"Backlog"* ]]; then
    ok "View 'Backlog' found"
  else
    warn "View 'Backlog' not found — the sync works fine without views; add them anytime: $url"
  fi
}

ensure_template() {
  local owner="$1"
  [[ "$owner" == "$TEMPLATE_CHECKED_OWNER" ]] && return 0
  TEMPLATE_CHECKED_OWNER="$owner"
  TEMPLATE_PROJECT_ID=""

  if [[ "$OWNER_IS_ORG" != true ]]; then
    info "'$owner' is a user account — project templates need an org; creating boards directly"
    return 0
  fi

  TEMPLATE_PROJECT_ID="$(find_template_id "$owner")"
  if [[ -n "$TEMPLATE_PROJECT_ID" ]]; then
    ok "Using org template '$TEMPLATE_TITLE' (views copy automatically)"
    set_status_options "$TEMPLATE_PROJECT_ID" || true
    save_root_sync_value template_id "$TEMPLATE_PROJECT_ID" quiet
    return 0
  fi

  local unmarked unmarked_id unmarked_url
  unmarked="$(gh api graphql -f query='query($login: String!, $q: String!) {
      organization(login: $login) {
        projectsV2(first: 20, query: $q) { nodes { id title template url } }
      }
    }' -f login="$owner" -f q="$TEMPLATE_TITLE" \
    --jq ".data.organization.projectsV2.nodes[] | select(.title == \"$TEMPLATE_TITLE\" and .template == false) | [.id, .url] | @tsv" 2>/dev/null | head -n1)"
  if [[ -n "$unmarked" ]]; then
    unmarked_id="${unmarked%%$'\t'*}"
    unmarked_url="${unmarked##*$'\t'}"
    warn "Project '$TEMPLATE_TITLE' exists but isn't marked as a template ($unmarked_url)"
    if [[ ! -t 0 ]]; then
      info "Mark it in ⚙ Settings → Templates (or run this script interactively), then re-run"
      return 0
    fi
    read -rp "  Mark it as the org template now? [Y/n]: " MARK_EXISTING
    case "$(printf '%s' "$MARK_EXISTING" | tr '[:upper:]' '[:lower:]')" in
      n|no)
        info "Leaving it unmarked — boards get per-board view checklists"
        return 0
        ;;
    esac
    if gh api graphql -f query='mutation($id: ID!) {
         markProjectV2AsTemplate(input: {projectId: $id}) { projectV2 { id } }
       }' -f id="$unmarked_id" >/dev/null 2>&1; then
      ok "Marked '$TEMPLATE_TITLE' as the org template"
      TEMPLATE_PROJECT_ID="$unmarked_id"
      set_status_options "$TEMPLATE_PROJECT_ID" || true
      save_template_name
      save_root_sync_value template_id "$unmarked_id" quiet
    else
      warn "Marking failed — open $unmarked_url → ⚙ Settings → Templates → 'Make template', then re-run"
    fi
    return 0
  fi

  if [[ ! -t 0 ]]; then
    warn "No '$TEMPLATE_TITLE' in org '$owner' — creating boards directly. Run interactively to set up the template once."
    return 0
  fi

  local existing_templates=() template_entry template_id_field idx
  while IFS= read -r template_entry; do
    [[ -n "$template_entry" ]] && existing_templates+=("$template_entry")
  done < <(gh api graphql -f query='query($login: String!) {
      organization(login: $login) {
        projectsV2(first: 50) { nodes { id title template } }
      }
    }' -f login="$owner" \
    --jq '.data.organization.projectsV2.nodes[] | select(.template == true) | [.id, .title] | @tsv' 2>/dev/null || true)

  if [[ ${#existing_templates[@]} -gt 0 ]]; then
    echo ""
    echo -e "  Org '$owner' already has project template(s):"
    idx=1
    for template_entry in "${existing_templates[@]}"; do
      echo -e "    $idx) ${template_entry#*$'\t'}"
      idx=$((idx + 1))
    done
    read -rp "  Use one of these? (number, or Enter to create a new template): " TEMPLATE_CHOICE
    if [[ "$TEMPLATE_CHOICE" =~ ^[0-9]+$ ]] && (( TEMPLATE_CHOICE >= 1 && TEMPLATE_CHOICE <= ${#existing_templates[@]} )); then
      template_entry="${existing_templates[$((TEMPLATE_CHOICE - 1))]}"
      template_id_field="${template_entry%%$'\t'*}"
      TEMPLATE_TITLE="${template_entry#*$'\t'}"
      TEMPLATE_PROJECT_ID="$template_id_field"
      ok "Using template '$TEMPLATE_TITLE'"
      set_status_options "$TEMPLATE_PROJECT_ID" || true
      save_template_name
      save_root_sync_value template_id "$TEMPLATE_PROJECT_ID" quiet
      return 0
    fi
  fi

  echo ""
  echo -e "  No ${BOLD}$TEMPLATE_TITLE${NC} found in org '$owner'. Creating one means you build"
  echo -e "  the views ${BOLD}once${NC} and every future board copies them automatically."
  read -rp "  Create the template now? (~5 min, one time ever) [Y/n]: " CREATE_TEMPLATE
  case "$(printf '%s' "$CREATE_TEMPLATE" | tr '[:upper:]' '[:lower:]')" in
    n|no)
      info "Skipped — boards get a per-board view checklist instead"
      return 0
      ;;
  esac

  read -rp "  Template name [$TEMPLATE_TITLE]: " CUSTOM_TEMPLATE_NAME
  if [[ -n "$CUSTOM_TEMPLATE_NAME" ]]; then
    if [[ ! "$CUSTOM_TEMPLATE_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9\ ._-]*$ ]]; then
      warn "Template names are limited to letters, numbers, spaces, dots, hyphens, underscores — using '$TEMPLATE_TITLE'"
    else
      TEMPLATE_TITLE="$CUSTOM_TEMPLATE_NAME"
    fi
  fi

  info "Creating template project '$TEMPLATE_TITLE'..."
  local created template_id template_url
  created="$(gh api graphql -f query='mutation($ownerId: ID!, $title: String!) {
      createProjectV2(input: {ownerId: $ownerId, title: $title}) {
        projectV2 { id number url }
      }
    }' -f ownerId="$OWNER_ID" -f title="$TEMPLATE_TITLE" \
    --jq '.data.createProjectV2.projectV2' 2>/dev/null)" || die "template project creation failed"
  template_id="$(jq -r .id <<< "$created")"
  template_url="$(jq -r .url <<< "$created")"
  gh api graphql -f query='mutation($id: ID!) {
      updateProjectV2(input: {projectId: $id, public: false}) { projectV2 { id } }
    }' -f id="$template_id" >/dev/null 2>&1 || true
  set_status_options "$template_id" || true
  print_view_checklist "$template_url"
  echo -e "  ${DIM}Tip: delete the default 'View 1' so copies start clean.${NC}"

  echo ""
  read -rp "  Press Enter when you've added the views (they're optional — add or change them anytime): " REPLY
  warn_if_backlog_view_missing "$template_id" "$template_url"

  if gh api graphql -f query='mutation($id: ID!) {
       markProjectV2AsTemplate(input: {projectId: $id}) { projectV2 { id } }
     }' -f id="$template_id" >/dev/null 2>&1; then
    ok "Template ready — every future board copies its views automatically"
    TEMPLATE_PROJECT_ID="$template_id"
    save_template_name
    save_root_sync_value template_id "$template_id" quiet
  else
    warn "Could not mark the project as a template via the API — boards will be created directly this run."
    echo -e "    ${DIM}Manual fallback: open $template_url → ⚙ Settings → Templates → 'Make template',"
    echo -e "    then re-run — the template is found automatically once marked.${NC}"
    TEMPLATE_PROJECT_ID=""
  fi
}

project_exists() {
  gh api graphql -f query='query($login: String!, $number: Int!) {
      organization(login: $login) { projectV2(number: $number) { id } }
    }' -f login="$1" -F number="$2" --jq '.data.organization.projectV2.id' 2>/dev/null ||
  gh api graphql -f query='query($login: String!, $number: Int!) {
      user(login: $login) { projectV2(number: $number) { id } }
    }' -f login="$1" -F number="$2" --jq '.data.user.projectV2.id' 2>/dev/null ||
  true
}

ensure_issue_types() {
  local org="$1"
  local existing
  existing="$(gh api "orgs/$org/issue-types" --jq '.[].name' 2>/dev/null || true)"
  if [[ -z "$existing" ]]; then
    warn "Cannot read org issue types for '$org' (personal account, or missing permission) — sync falls back to labels"
    return
  fi
  local type_name create_output
  for type_name in Feature Epic Story; do
    if grep -qx "$type_name" <<< "$existing"; then
      ok "Issue type '$type_name' exists"
      continue
    fi
    if create_output="$(gh api "orgs/$org/issue-types" -X POST \
         -f name="$type_name" -f description="BMad $type_name" -F is_enabled=true 2>&1)"; then
      ok "Created org issue type '$type_name'"
    else
      warn "Could not create issue type '$type_name' — sync falls back to labels"
      echo -e "    ${DIM}$(head -n1 <<< "$create_output") — needs org admin + a token with admin:org (gh auth refresh -s project,admin:org)${NC}"
    fi
  done
}

ensure_labels() {
  local repo="$1"; shift
  local spec name color
  for spec in "$@"; do
    name="${spec%%=*}"
    color="${spec##*=}"
    if gh api "repos/$repo/labels/$name" >/dev/null 2>&1; then
      continue
    fi
    if gh api "repos/$repo/labels" -X POST -f name="$name" -f color="$color" >/dev/null 2>&1; then
      ok "Created label '$name' in $repo"
    else
      warn "Could not create label '$name' in $repo"
    fi
  done
}

set_status_options() {
  local project_id="$1"
  local field_id current_json current_names
  field_id="$(gh api graphql -f query='query($id: ID!) {
      node(id: $id) { ... on ProjectV2 {
        fields(first: 30) { nodes { ... on ProjectV2SingleSelectField { id name } } }
      } }
    }' -f id="$project_id" \
    --jq '.data.node.fields.nodes[] | select(.name == "Status") | .id' 2>/dev/null || true)"

  if [[ -z "$field_id" ]]; then
    warn "Could not find the Status field"
    return 1
  fi

  current_json="$(gh api graphql -f query='query($id: ID!) {
      node(id: $id) { ... on ProjectV2SingleSelectField { options { id name } } }
    }' -f id="$field_id" --jq '.data.node.options' 2>/dev/null || echo '[]')"
  current_names="$(jq -r 'map(.name) | join(",")' <<< "$current_json" 2>/dev/null || echo "")"
  if [[ "$current_names" == "Backlog,Ready,In Progress,In Review,Done" ]]; then
    ok "Status options already configured"
    return 0
  fi

  local options_literal="" entry option_name color description
  while IFS='|' read -r option_name color description; do
    entry="{name: \"$option_name\", color: $color, description: \"$description\"}"
    options_literal+="${options_literal:+, }$entry"
  done <<'OPTS'
Backlog|GRAY|Defined, not started
Ready|BLUE|Story file created, ready for dev
In Progress|YELLOW|Being implemented
In Review|ORANGE|PR open / code review
Done|GREEN|Complete
OPTS

  if gh api graphql -f query="mutation(\$fieldId: ID!) {
      updateProjectV2Field(input: {fieldId: \$fieldId, singleSelectOptions: [$options_literal]}) {
        projectV2Field { ... on ProjectV2SingleSelectField { id } }
      }
    }" -f fieldId="$field_id" >/dev/null 2>&1; then
    ok "Status options: Backlog / Ready / In Progress / In Review / Done"
  else
    warn "Could not set Status options via API — add them manually (see checklist)"
    return 1
  fi
}

write_sync_config() {
  local config="$1" number="$2" owner="$3"
  for pair in "project=$number" "project_owner=$owner"; do
    local key="${pair%%=*}" value="${pair##*=}"
    if grep -qE "^$key:" "$config"; then
      sed -i.bak "s|^$key:.*|$key: $value|" "$config" && rm -f "$config.bak"
    else
      echo "$key: $value" >> "$config"
    fi
  done
}

print_view_checklist() {
  local url="$1"
  echo ""
  echo -e "${BOLD}Manual board setup (no API exists for these) — $url${NC}"
  echo ""
  echo -e "  Create these views, in this order:"
  echo -e "  ${BOLD}1. Backlog${NC}        Board · group by Status · hide the Done column"
  echo -e "     filter:  ${CYAN}label:bmad-delivery is:open -label:epic -label:feature${NC}"
  echo -e "  ${BOLD}2. Epic Progress${NC}  Table · show the Sub-issue progress field"
  echo -e "     filter:  ${CYAN}label:bmad-delivery label:epic${NC}"
  echo -e "  ${BOLD}3. Features${NC}       Table · show the Sub-issue progress field"
  echo -e "     filter:  ${CYAN}label:bmad-delivery label:feature${NC}"
  echo -e "  ${BOLD}4. Planning${NC}       Table · show the Sub-issue progress field"
  echo -e "     filter:  ${CYAN}label:bmad-planning${NC}"
  echo ""
  echo -e "  In the project's ⚙ settings:"
  echo -e "  - Enable the ${BOLD}Sub-issue progress${NC} and ${BOLD}Parent issue${NC} fields"
  echo -e "  - Status field settings: set ${BOLD}Backlog${NC} as the default value (GitHub has no"
  echo -e "    API for field defaults). ${DIM}Only affects manually-added cards — the sync"
  echo -e "    sets Status on everything it creates.${NC}"
  echo -e "  - Workflows — ${BOLD}none are required${NC}; the sync adds items and writes Status itself:"
  echo ""
  echo -e "    ┌──────────────────────┬────────────────────────────────────────────────────┐"
  echo -e "    │ Auto-add sub-issues  │ Keep on (enabled by default)                       │"
  echo -e "    │ Item closed → Done   │ Worth repairing — instant update on manual closes  │"
  echo -e "    │ Auto-close issue     │ Leave off — fights the sync (reopen ping-pong)     │"
  echo -e "    │ Everything else      │ Leave off — the sync covers it                     │"
  echo -e "    └──────────────────────┴────────────────────────────────────────────────────┘"
  echo ""
  echo -e "    ${DIM}Red icons mean a workflow points at a removed Status option (options whose"
  echo -e "    names survive the update usually keep working). To repair one: click"
  echo -e "    it → Edit → reselect the Status value → Save and turn on.${NC}"
  echo -e "  ${DIM}(Label filters work for issues in any org or personal account —"
  echo -e "  org-only issue types stay as extra metadata where available.)${NC}"
}

PROJECT_FIELD_NAME="Project"

list_project_names() {
  local config
  for config in "$WORKSPACES_DIR"/*/github-sync.yaml; do
    [[ -f "$config" ]] || continue
    basename "$(dirname "$config")"
  done
}

ensure_project_field() {
  local project_id="$1"
  local field_id
  field_id="$(gh api graphql -f query='query($id: ID!) {
      node(id: $id) { ... on ProjectV2 {
        fields(first: 50) { nodes { ... on ProjectV2SingleSelectField { id name } } }
      } }
    }' -f id="$project_id" \
    --jq ".data.node.fields.nodes[] | select(.name == \"$PROJECT_FIELD_NAME\") | .id" 2>/dev/null || true)"
  if [[ -n "$field_id" ]]; then
    ok "Field '$PROJECT_FIELD_NAME' exists (the sync keeps its options current)"
    return 0
  fi

  local options_literal="" name
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    name="${name//\\/\\\\}"
    name="${name//\"/\\\"}"
    options_literal+="${options_literal:+, }{name: \"$name\", color: GRAY, description: \"\"}"
  done < <(list_project_names)
  [[ -n "$options_literal" ]] || options_literal='{name: "unassigned", color: GRAY, description: ""}'

  if gh api graphql -f query="mutation(\$projectId: ID!) {
      createProjectV2Field(input: {projectId: \$projectId, dataType: SINGLE_SELECT, name: \"$PROJECT_FIELD_NAME\", singleSelectOptions: [$options_literal]}) {
        projectV2Field { ... on ProjectV2SingleSelectField { id } }
      }
    }" -f projectId="$project_id" >/dev/null 2>&1; then
    ok "Created field '$PROJECT_FIELD_NAME' (one option per workspace)"
  else
    warn "Could not create the '$PROJECT_FIELD_NAME' field — add a single-select field named '$PROJECT_FIELD_NAME' to the board manually"
    return 1
  fi
}

print_portfolio_view_checklist() {
  local url="$1"
  echo ""
  echo -e "${BOLD}Suggested portfolio views (no API exists for these) — $url${NC}"
  echo ""
  echo -e "  ${BOLD}1. By Project${NC}   Board · group by ${CYAN}$PROJECT_FIELD_NAME${NC} · hide the Done column"
  echo -e "     filter:  ${CYAN}label:bmad-delivery is:open -label:epic -label:feature${NC}"
  echo -e "  ${BOLD}2. Features${NC}     Table · group by ${CYAN}$PROJECT_FIELD_NAME${NC} · show the Sub-issue progress field"
  echo -e "     filter:  ${CYAN}label:bmad-delivery label:feature${NC}"
  echo -e "  ${BOLD}3. Planning${NC}     Table · group by ${CYAN}$PROJECT_FIELD_NAME${NC}"
  echo -e "     filter:  ${CYAN}label:bmad-planning${NC}"
  echo ""
}

bootstrap_portfolio() {
  echo ""
  echo -e "${BOLD}── portfolio board ──${NC}"

  local metarepo fallback_owner
  metarepo="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
  fallback_owner="${metarepo%%/*}"
  [[ -n "$fallback_owner" ]] || fallback_owner="$(gh api user --jq .login 2>/dev/null || true)"

  local configured_owner=""
  [[ -f "$ROOT_SYNC_CFG" ]] && configured_owner="$(read_sync_value "$ROOT_SYNC_CFG" portfolio_owner)"
  if [[ -n "$configured_owner" && "$configured_owner" != "null" ]]; then
    BOARD_OWNER="$configured_owner"
  else
    pick_board_owner "/dev/null" "$fallback_owner"
  fi
  resolve_owner "$BOARD_OWNER" || die "cannot resolve owner '$BOARD_OWNER' — check the name and token"

  local existing_number=""
  [[ -f "$ROOT_SYNC_CFG" ]] && existing_number="$(read_sync_value "$ROOT_SYNC_CFG" portfolio)"
  if [[ -n "$existing_number" && "$existing_number" != "null" ]]; then
    local existing_id
    existing_id="$(project_exists "$BOARD_OWNER" "$existing_number")"
    if [[ -n "$existing_id" ]]; then
      ok "Portfolio board #$existing_number already exists for '$BOARD_OWNER' — verifying fields"
      set_status_options "$existing_id" || true
      ensure_project_field "$existing_id" || true
      save_root_sync_value portfolio_owner "$BOARD_OWNER"
      return 0
    fi
    warn "github-sync.yaml points at portfolio #$existing_number but it doesn't exist — creating a new one"
  fi

  ensure_template "$BOARD_OWNER"

  local title="${BMAD_PORTFOLIO_TITLE:-BMad Portfolio}"
  local created="" project_id project_number project_url
  if [[ -n "$TEMPLATE_PROJECT_ID" ]]; then
    info "Creating private portfolio board '$title' from the template..."
    created="$(gh api graphql -f query='mutation($projectId: ID!, $ownerId: ID!, $title: String!) {
        copyProjectV2(input: {projectId: $projectId, ownerId: $ownerId, title: $title, includeDraftIssues: false}) {
          projectV2 { id number url }
        }
      }' -f projectId="$TEMPLATE_PROJECT_ID" -f ownerId="$OWNER_ID" -f title="$title" \
      --jq '.data.copyProjectV2.projectV2' 2>/dev/null)" || created=""
    [[ -n "$created" ]] || warn "Template copy failed — falling back to direct creation"
  fi
  if [[ -z "$created" ]]; then
    info "Creating private portfolio board '$title'..."
    created="$(gh api graphql -f query='mutation($ownerId: ID!, $title: String!) {
        createProjectV2(input: {ownerId: $ownerId, title: $title}) {
          projectV2 { id number url }
        }
      }' -f ownerId="$OWNER_ID" -f title="$title" \
      --jq '.data.createProjectV2.projectV2' 2>/dev/null)" ||
      die "Portfolio creation failed — your token likely lacks the project scope. Run: gh auth refresh -s project"
    [[ -n "$created" ]] || die "Portfolio creation returned nothing — run: gh auth refresh -s project"
  fi

  project_id="$(jq -r .id <<< "$created")"
  project_number="$(jq -r .number <<< "$created")"
  project_url="$(jq -r .url <<< "$created")"

  gh api graphql -f query='mutation($id: ID!) {
      updateProjectV2(input: {projectId: $id, public: false}) { projectV2 { id } }
    }' -f id="$project_id" >/dev/null 2>&1 || warn "Could not pin visibility — verify it is Private in settings"

  ok "Portfolio board #$project_number (private): $project_url"
  set_status_options "$project_id" || true
  ensure_project_field "$project_id" || true
  save_root_sync_value portfolio "$project_number"
  save_root_sync_value portfolio_owner "$BOARD_OWNER"
  print_portfolio_view_checklist "$project_url"
}

bootstrap_workspace() {
  local workspace_name="$1"
  local config="$WORKSPACES_DIR/$workspace_name/github-sync.yaml"

  echo ""
  echo -e "${BOLD}── $workspace_name ──${NC}"

  [[ -f "$config" ]] || { warn "No github-sync.yaml — run: bash $SKILL_DIR_REL/scripts/meta-router.sh init $workspace_name (or copy $SKILL_DIR_REL/templates/github-sync.yaml), then re-run"; return 1; }

  local repo
  repo="$(read_sync_value "$config" repo)"
  if [[ -z "$repo" || "$repo" == OWNER/* ]]; then
    repo="$(cd "$REPO_ROOT" && gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
    if [[ -z "$repo" ]]; then
      warn "No repo: in $config and this metarepo has no GitHub remote — push the metarepo to GitHub (or set repo: explicitly), then re-run"
      return 1
    fi
    info "Issues repo: $repo (metarepo default)"
  fi

  local owner="${repo%%/*}"
  local existing_number existing_owner
  existing_number="$(read_sync_value "$config" project)"
  if [[ -n "$existing_number" && "$existing_number" != "null" ]]; then
    existing_owner="$(read_sync_value "$config" project_owner)"
    [[ -z "$existing_owner" || "$existing_owner" == "null" ]] && existing_owner="$owner"
    if [[ -n "$(project_exists "$existing_owner" "$existing_number")" ]]; then
      ok "Project #$existing_number already exists for '$existing_owner' — nothing to do"
      return 0
    fi
    warn "github-sync.yaml points at project #$existing_number but it doesn't exist — creating a new one"
  fi

  pick_board_owner "$config" "$owner"
  resolve_owner "$BOARD_OWNER" || { warn "Cannot resolve board owner '$BOARD_OWNER' — check the name and token"; return 1; }

  ensure_issue_types "$owner"
  ensure_labels "$repo" \
    "bmad-delivery=1D76DB" "bmad-orphaned=D93F0B" "feature=8250DF" "epic=3E4B9E" "story=0E8A16"

  local metarepo
  metarepo="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
  if [[ -n "$metarepo" ]]; then
    ensure_labels "$metarepo" "bmad-planning=BFD4F2" "bmad-orphaned=D93F0B"
  fi

  ensure_template "$BOARD_OWNER"

  local created project_id project_number project_url
  if [[ -n "$TEMPLATE_PROJECT_ID" ]]; then
    info "Creating private GitHub Project '$workspace_name' from the template..."
    created="$(gh api graphql -f query='mutation($projectId: ID!, $ownerId: ID!, $title: String!) {
        copyProjectV2(input: {projectId: $projectId, ownerId: $ownerId, title: $title, includeDraftIssues: false}) {
          projectV2 { id number url }
        }
      }' -f projectId="$TEMPLATE_PROJECT_ID" -f ownerId="$OWNER_ID" -f title="$workspace_name" \
      --jq '.data.copyProjectV2.projectV2' 2>/dev/null)" || created=""
    if [[ -z "$created" ]]; then
      warn "Template copy failed — falling back to direct creation"
    fi
  fi
  if [[ -z "${created:-}" ]]; then
    info "Creating private GitHub Project '$workspace_name'..."
    created="$(gh api graphql -f query='mutation($ownerId: ID!, $title: String!) {
        createProjectV2(input: {ownerId: $ownerId, title: $title}) {
          projectV2 { id number url }
        }
      }' -f ownerId="$OWNER_ID" -f title="$workspace_name" \
      --jq '.data.createProjectV2.projectV2' 2>/dev/null)" ||
      die "Project creation failed — your token likely lacks the project scope. Run: gh auth refresh -s project"
    [[ -n "$created" ]] || die "Project creation returned nothing — run: gh auth refresh -s project"
  fi

  project_id="$(jq -r .id <<< "$created")"
  project_number="$(jq -r .number <<< "$created")"
  project_url="$(jq -r .url <<< "$created")"

  gh api graphql -f query='mutation($id: ID!) {
      updateProjectV2(input: {projectId: $id, public: false}) { projectV2 { id } }
    }' -f id="$project_id" >/dev/null 2>&1 || warn "Could not pin visibility — verify it is Private in settings"

  ok "Project #$project_number (private): $project_url"
  set_status_options "$project_id" || true
  write_sync_config "$config" "$project_number" "$BOARD_OWNER"
  ok "Wrote project number to ${config#"$REPO_ROOT/"}"
  if [[ -n "$TEMPLATE_PROJECT_ID" ]]; then
    ok "Views inherited from the template — no manual board setup needed"
  else
    print_view_checklist "$project_url"
  fi
}

main() {
  local target="${1:-}"
  [[ -n "$target" ]] || die "Usage: bmad-github-bootstrap.sh <workspace-name> | --all | --template | --portfolio"

  if [[ "$target" == "--portfolio" ]]; then
    bootstrap_portfolio
    return 0
  fi

  if [[ "$target" == "--template" ]]; then
    local metarepo fallback_owner
    metarepo="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
    fallback_owner="${metarepo%%/*}"
    [[ -n "$fallback_owner" ]] || fallback_owner="$(gh api user --jq .login 2>/dev/null || true)"
    pick_board_owner "/dev/null" "$fallback_owner"
    resolve_owner "$BOARD_OWNER" || die "cannot resolve owner '$BOARD_OWNER'"
    [[ "$OWNER_IS_ORG" == true ]] || die "'$BOARD_OWNER' is a user account — project templates require an org"
    ensure_template "$BOARD_OWNER"
    [[ -n "$TEMPLATE_PROJECT_ID" ]] || die "template not set up — re-run when ready"
    return 0
  fi

  local failures=0
  if [[ "$target" == "--all" ]]; then
    local found=0
    for config in "$WORKSPACES_DIR"/*/github-sync.yaml; do
      [[ -f "$config" ]] || continue
      found=1
      bootstrap_workspace "$(basename "$(dirname "$config")")" || failures=$((failures + 1))
    done
    [[ "$found" == 1 ]] || die "No workspaces with github-sync.yaml under workspaces/"
  else
    bootstrap_workspace "$target" || failures=1
  fi

  if [[ "${BMAD_BOOTSTRAP_SKIP_NEXT_STEPS:-0}" != 1 ]]; then
    echo ""
    echo -e "${BOLD}Remaining setup (once per org / per source repo):${NC}"
    echo -e "  - Org secret ${CYAN}BMAD_PROJECT_TOKEN${NC}: fine-grained PAT with org Projects"
    echo -e "    read/write + Issues read/write + Pull requests read on the metarepo"
    echo -e "    and all source repos (the sync workflow refuses to run without it)"
    echo -e "  - In each source repo: install ${CYAN}$SKILL_DIR_REL/templates/.github/workflows/bmad-pr-ping.yml${NC},"
    echo -e "    set variable ${CYAN}BMAD_METAREPO${NC} and secret ${CYAN}BMAD_METAREPO_TOKEN${NC}"
    echo -e "  - Optional: ${CYAN}bash $SKILL_DIR_REL/scripts/bmad-github-bootstrap.sh --portfolio${NC} creates one"
    echo -e "    org-wide board aggregating every workspace, sliced by a Project field"
    echo ""
  fi
  return "$failures"
}

main "$@"
