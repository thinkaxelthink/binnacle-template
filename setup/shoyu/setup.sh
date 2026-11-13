#!/usr/bin/env bash
# Set up shoyu, the only machine where Claude Code writes the wiki. Idempotent.
#
# Usage: setup/shoyu/setup.sh
# Env:   BINNACLE_OWNER (thinkaxelthink), BINNACLE_REPO (binnacle),
#        BINNACLE_DIR (~/binnacle), BINNACLE_MIN_OBSIDIAN (1.13),
#        BINNACLE_GH_TOKEN_FILE (unset; a mode-600 token file for when the
#        keychain is unreachable, recorded as binnacle.ghTokenFile),
#        BINNACLE_GIT_NAME (existing vault-local user.name, else BINNACLE_OWNER),
#        BINNACLE_GIT_EMAIL (BINNACLE_OWNER@users.noreply.github.com)
#
# Human-only steps (token, App Store, logins, plugin install) are in
# setup/shoyu/CHECKLIST.md. Run this after its "Before the script" items.
set -eu

here=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=../common/lib.sh
. "$here/../common/lib.sh"

problems=0
problem() {
  bn_warn "$*"
  problems=$((problems + 1))
}

bn_log "vault clone"
bn_clone_vault

bn_log "machine role"
git -C "$BINNACLE_DIR" config binnacle.role wiki-writer
bn_ok "binnacle.role = wiki-writer (bin/binnacle-run only runs where this is set)"
git -C "$BINNACLE_DIR" config binnacle.ghTokenItem "$BINNACLE_REPO-gh-token"
bn_ok "binnacle.ghTokenItem = $BINNACLE_REPO-gh-token (keychain item bin/binnacle-run reads for gh)"
if [ -n "${BINNACLE_GH_TOKEN_FILE:-}" ]; then
  if [ -f "$BINNACLE_GH_TOKEN_FILE" ] && [ ! -L "$BINNACLE_GH_TOKEN_FILE" ]; then
    token_file=$(bn_physical_path "$BINNACLE_GH_TOKEN_FILE")
    git -C "$BINNACLE_DIR" config binnacle.ghTokenFile "$token_file"
    bn_ok "binnacle.ghTokenFile = $token_file (used when the keychain item is unreachable)"
  else
    problem "BINNACLE_GH_TOKEN_FILE '$BINNACLE_GH_TOKEN_FILE' is not a regular file; binnacle.ghTokenFile not set"
  fi
fi

bn_log "git identity (vault clone only)"
# Without one, git falls back to user@<hostname> and leaks the machine's
# network name into every vault commit. Set locally, never --global.
git_name=${BINNACLE_GIT_NAME:-$(git -C "$BINNACLE_DIR" config --local user.name 2>/dev/null || true)}
git_name=${git_name:-$BINNACLE_OWNER}
git_email=${BINNACLE_GIT_EMAIL:-$BINNACLE_OWNER@users.noreply.github.com}
git -C "$BINNACLE_DIR" config --local user.name "$git_name"
git -C "$BINNACLE_DIR" config --local user.email "$git_email"
bn_ok "commits in $BINNACLE_DIR authored as $git_name <$git_email>"

bn_log "hooks"
"$BINNACLE_DIR/setup/common/install-hooks.sh" "$BINNACLE_DIR"

bn_log "tools"
for tool in git gh claude; do
  if command -v "$tool" >/dev/null 2>&1; then
    bn_ok "$tool: $(command -v "$tool")"
  else
    problem "$tool not found on PATH (see CHECKLIST.md)"
  fi
done

bn_log "Obsidian >= $BINNACLE_MIN_OBSIDIAN"
ver=$(bn_obsidian_version)
if [ -z "$ver" ]; then
  problem "Obsidian not found in /Applications (see CHECKLIST.md)"
elif bn_version_ge "$ver" "$BINNACLE_MIN_OBSIDIAN"; then
  bn_ok "Obsidian $ver"
else
  problem "Obsidian $ver is older than $BINNACLE_MIN_OBSIDIAN - update it (Settings > General > Check for updates)"
fi

bn_log "Obsidian Git plugin"
if [ -d "$BINNACLE_DIR/.obsidian/plugins/obsidian-git" ]; then
  bn_ok "obsidian-git present in the vault"
else
  bn_warn "obsidian-git not installed yet - CHECKLIST.md, 'In Obsidian'"
fi

if [ "$problems" -gt 0 ]; then
  bn_die "$problems check(s) failed; fix them and re-run (safe to repeat)"
fi
bn_log "shoyu ready. Remaining human steps: $here/CHECKLIST.md"
