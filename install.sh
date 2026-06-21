#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# install.sh — Bootstrap a meta-router metarepo from a tagged release.
# ─────────────────────────────────────────────────────────────────────────────
# setup.sh copies its whole skill tree (SKILL.md + scripts/ + templates/) into
# the new metarepo, so it can't be piped straight from curl — it needs those
# sibling files on disk. This installer fetches a pinned tarball, unpacks it,
# and runs setup.sh from it.
#
# Usage (run remotely, pinned to a tag):
#   curl -fsSL https://raw.githubusercontent.com/Code-and-Sorts/meta-router/v0.1.0/install.sh \
#     | META_ROUTER_REF=v0.1.0 bash -s -- my-metarepo
#
# Or track the latest release (default when META_ROUTER_REF is unset):
#   curl -fsSL https://raw.githubusercontent.com/Code-and-Sorts/meta-router/main/install.sh \
#     | bash -s -- my-metarepo
#
# Everything after `--` is forwarded to setup.sh (positional target dir, etc.),
# and setup.sh's BMAD_SETUP_* environment variables are honored as usual.
# ─────────────────────────────────────────────────────────────────────────────

REPO="${META_ROUTER_REPO:-Code-and-Sorts/meta-router}"
# A git ref to install: a tag (v1.2.3), branch, or commit SHA. When unset, the
# newest published GitHub Release is used.
REF="${META_ROUTER_REF:-}"

err() { echo "error: $*" >&2; exit 1; }
info() { echo "→ $*" >&2; }

command -v curl >/dev/null 2>&1 || err "curl is required"
command -v tar  >/dev/null 2>&1 || err "tar is required"

if [[ -z "$REF" ]]; then
  info "Resolving latest release of $REPO..."
  REF="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)" || true
  [[ -n "$REF" ]] || err "could not resolve the latest release of $REPO. Publish a release, or pin a ref: META_ROUTER_REF=<tag>"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# GitHub serves any ref (tag, branch, or SHA) as a tarball wrapped in a single
# <repo>-<ref>/ directory; --strip-components=1 unwraps it.
info "Downloading meta-router $REF..."
curl -fsSL "https://github.com/$REPO/archive/$REF.tar.gz" \
  | tar -xz -C "$TMP" --strip-components=1 \
  || err "failed to download $REPO@$REF (does the ref exist?)"

SETUP="$TMP/skills/meta-router/scripts/setup.sh"
[[ -f "$SETUP" ]] || err "setup.sh not found in $REPO@$REF (expected skills/meta-router/scripts/setup.sh)"

info "Running setup ($REF)..."
# Run setup as a child (not exec) so the cleanup trap still fires. When this
# installer is itself piped (curl | bash), setup.sh's stdin would point at the
# consumed pipe and its prompts would read EOF — reattach the controlling
# terminal when there is one so prompts work; otherwise inherit stdin (CI,
# where BMAD_SETUP_NONINTERACTIVE=1 is used).
if { : </dev/tty; } 2>/dev/null; then
  bash "$SETUP" "$@" </dev/tty
else
  bash "$SETUP" "$@"
fi
