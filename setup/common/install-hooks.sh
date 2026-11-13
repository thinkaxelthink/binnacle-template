#!/usr/bin/env bash
# Install the Binnacle pre-commit hook into a vault clone. Idempotent.
#
# Usage: setup/common/install-hooks.sh [vault-dir]
#   vault-dir defaults to the repository this script lives in.
#
# Points core.hooksPath at the tracked .githooks/ directory, so hook updates
# arrive with git pull, and checks that gitleaks is installed (the hook
# refuses every commit without it).
set -eu

here=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=lib.sh
. "$here/lib.sh"

vault=${1:-$here/../..}
vault=$(git -C "$vault" rev-parse --show-toplevel 2>/dev/null) \
  || bn_die "not a git repository: ${1:-$here/../..}"

bn_log "installing hooks in $vault"
[ -f "$vault/.githooks/pre-commit" ] || bn_die "$vault/.githooks/pre-commit is missing"
chmod +x "$vault/.githooks/pre-commit"

if [ "$(git -C "$vault" config --get core.hooksPath || true)" = ".githooks" ]; then
  bn_ok "core.hooksPath already .githooks"
else
  git -C "$vault" config core.hooksPath .githooks
  bn_ok "core.hooksPath set to .githooks"
fi

gl=$(bn_find_gitleaks)
if [ -z "$gl" ]; then
  bn_die "gitleaks not found - install it (brew install gitleaks); the hook blocks every commit until then"
fi
bn_ok "gitleaks found: $gl ($("$gl" version 2>/dev/null || echo unknown version))"
