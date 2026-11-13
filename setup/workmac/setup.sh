#!/usr/bin/env bash
# Set up the work Mac: a read-and-capture-only clone of the vault. Idempotent.
#
# Usage: setup/workmac/setup.sh
# Env:   BINNACLE_OWNER (thinkaxelthink), BINNACLE_REPO (binnacle),
#        BINNACLE_DIR (~/binnacle),
#        BINNACLE_WORK_DOCS - your employer's documents folder; the clone may
#        never live inside it. Required: taken from this variable, else from
#        `git config --global binnacle.workDocs` (set by a CHECKLIST.md step).
#        It is local to the Mac and never committed; with neither set the
#        script refuses to run.
#        BINNACLE_GIT_NAME (existing vault-local user.name, else BINNACLE_OWNER),
#        BINNACLE_GIT_EMAIL (existing vault-local user.email, else
#        BINNACLE_OWNER@users.noreply.github.com)
#
# No AI writes happen here: the clone is marked binnacle.role=capture, and
# bin/binnacle-run refuses to run unless the role is wiki-writer.
# Human-only steps are in setup/workmac/CHECKLIST.md.
set -eu

here=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=../common/lib.sh
. "$here/../common/lib.sh"

bn_log "location guard"
BINNACLE_WORK_DOCS=${BINNACLE_WORK_DOCS:-$(git config --global --get binnacle.workDocs || true)}
# A literal leading ~ (as git config stores it) means $HOME.
# shellcheck disable=SC2088
case $BINNACLE_WORK_DOCS in
  "~") BINNACLE_WORK_DOCS=$HOME ;;
  "~/"*) BINNACLE_WORK_DOCS=$HOME/${BINNACLE_WORK_DOCS#"~/"} ;;
esac
case $BINNACLE_WORK_DOCS in
  "") bn_die "the work documents folder is not set. Set it first (CHECKLIST.md):
  git config --global binnacle.workDocs \"\$HOME/Documents/<employer folder>\"" ;;
  /*) ;;
  *) bn_die "binnacle.workDocs must be an absolute path, got '$BINNACLE_WORK_DOCS'" ;;
esac
if bn_path_is_under "$BINNACLE_DIR" "$BINNACLE_WORK_DOCS"; then
  bn_die "refusing: $BINNACLE_DIR is inside $BINNACLE_WORK_DOCS. Keep the vault outside work folders (default ~/binnacle)."
fi
bn_ok "$BINNACLE_DIR is outside $BINNACLE_WORK_DOCS"

bn_log "vault clone"
bn_clone_vault

bn_log "machine role"
git -C "$BINNACLE_DIR" config binnacle.role capture
bn_ok "binnacle.role = capture (bin/binnacle-run refuses here)"

bn_log "git identity (vault clone only)"
bn_set_git_identity

bn_log "hooks"
"$BINNACLE_DIR/setup/common/install-hooks.sh" "$BINNACLE_DIR"

bn_log "Obsidian"
ver=$(bn_obsidian_version)
if [ -n "$ver" ]; then
  bn_ok "Obsidian $ver"
else
  bn_warn "Obsidian not found in /Applications (see CHECKLIST.md)"
fi
if [ -d "$BINNACLE_DIR/.obsidian/plugins/obsidian-git" ]; then
  bn_ok "obsidian-git present in the vault"
else
  bn_warn "obsidian-git not installed yet - CHECKLIST.md, 'In Obsidian'"
fi

bn_log "work Mac ready (read and capture only). Remaining human steps: $here/CHECKLIST.md"
