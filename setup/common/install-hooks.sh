#!/usr/bin/env bash
# Install the Binnacle pre-commit hook into a vault clone. Idempotent.
#
# Usage: setup/common/install-hooks.sh [vault-dir]
#   vault-dir defaults to the repository this script lives in.
#
# Points core.hooksPath at the tracked .githooks/ directory, so hook updates
# arrive with git pull, checks that gitleaks is installed (the hook refuses
# every commit without it), and records its absolute path in
# `git config binnacle.gitleaks`, so the hook finds it even when a GUI app
# such as Obsidian runs git with a PATH that lacks the install directory.
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
  bn_die "gitleaks not found - install it (gitleaks step in setup/<device>/CHECKLIST.md: Homebrew, or the official release binary in ~/.local/bin), then re-run this script; the hook blocks every commit until then"
fi
bn_ok "gitleaks found: $gl ($("$gl" version 2>/dev/null || echo unknown version))"

if [ "$(git -C "$vault" config --get binnacle.gitleaks || true)" = "$gl" ]; then
  bn_ok "binnacle.gitleaks already $gl"
else
  git -C "$vault" config binnacle.gitleaks "$gl"
  bn_ok "binnacle.gitleaks set to $gl"
fi
