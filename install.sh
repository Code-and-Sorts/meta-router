#!/usr/bin/env bash
set -euo pipefail

REPO="${META_ROUTER_REPO:-Code-and-Sorts/meta-router}"
REF="${META_ROUTER_REF:-}"

err() { echo "error: $*" >&2; exit 1; }
info() { echo "→ $*" >&2; }

command -v curl >/dev/null 2>&1 || err "curl is required"
command -v tar  >/dev/null 2>&1 || err "tar is required"

if [[ -z "$REF" ]]; then
  info "Resolving latest release of $REPO..."
  REF="$(curl -fsSL --retry 3 "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
        | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)" || true
  [[ -n "$REF" ]] || err "could not resolve the latest release of $REPO. Publish a release, or pin a ref: META_ROUTER_REF=<tag>"
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

info "Downloading meta-router $REF..."
curl -fsSL --retry 3 "https://github.com/$REPO/archive/$REF.tar.gz" \
  | tar -xz -C "$TMP" --strip-components=1 \
  || err "failed to download $REPO@$REF (does the ref exist?)"

SETUP="$TMP/skills/meta-router/scripts/setup.sh"
[[ -f "$SETUP" ]] || err "setup.sh not found in $REPO@$REF (expected skills/meta-router/scripts/setup.sh)"

info "Running setup ($REF)..."
if { : </dev/tty; } 2>/dev/null; then
  bash "$SETUP" "$@" </dev/tty
else
  bash "$SETUP" "$@"
fi
