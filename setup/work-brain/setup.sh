#!/usr/bin/env bash
# Set up a company brain on a work machine: a separate vault, beside the
# personal ~/binnacle, where Claude Code writes the wiki. Idempotent.
#
# Usage: setup/work-brain/setup.sh --org ORG --user USER [--dir DIR]
#                                  [--git-name NAME] [--git-email EMAIL]
#   --org        the employer's GitHub organization login (e.g. acme-engineering)
#   --user       your GitHub user login (e.g. jdoe)
#   --dir        where the vault lives (default ~/binnacle-<org>-<user>)
#   --git-name   commit name in this vault only (default: the existing
#                vault-local name, else USER)
#   --git-email  commit email in this vault only, e.g. your work address
#                (default: the existing vault-local email, else
#                USER@users.noreply.github.com)
#   Missing --org or --user are asked for when run from a terminal.
#
# Run it from a clean binnacle-template checkout the first time; later runs
# can use the copy inside the vault. It starts with no remote: the vault is
# created locally from the template (git init, local commits, the gitleaks +
# 10 MB pre-commit hook), marked binnacle.role=wiki-writer and
# binnacle.localOnly=true. setup/work-brain/connect-remote.sh adds the
# remote later. It refuses any folder that is not new or this brain's own
# vault, a vault whose origin points elsewhere, and ~/binnacle (or anything
# that resolves into it), which it never touches.
# Env: BINNACLE_GH (gh), BINNACLE_GITLEAKS, BINNACLE_GIT_NAME and
#      BINNACLE_GIT_EMAIL (same as the flags; the flags win).
# Human-only steps are in setup/work-brain/CHECKLIST.md.
set -eu

here=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=../common/lib.sh
. "$here/../common/lib.sh"
# shellcheck source=lib.sh
. "$here/lib.sh"

usage() { sed -n '5,15p' "$0" | sed 's/^# \{0,1\}//'; }

org="" user="" dir=""
while [ "$#" -gt 0 ]; do
  case $1 in
    --org | --user | --dir | --git-name | --git-email)
      [ "$#" -ge 2 ] || bn_die "$1 needs a value"
      case $1 in
        --org) org=$2 ;;
        --user) user=$2 ;;
        --dir) dir=$2 ;;
        --git-name) BINNACLE_GIT_NAME=$2 ;;
        --git-email) BINNACLE_GIT_EMAIL=$2 ;;
      esac
      shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

ask() { # variable, prompt
  local v
  [ -t 0 ] || bn_die "$2 is required (--${1}); see --help"
  printf '%s: ' "$2" >&2
  IFS= read -r v || true
  printf -v "$1" '%s' "$v"
}
[ -n "$org" ] || ask org "GitHub organization login"
[ -n "$user" ] || ask user "your GitHub user login"

name=$(wb_name "$org" "$user")
org_slug=$(wb_slug "$org")
# A literal leading ~ means $HOME.
# shellcheck disable=SC2088
case $dir in
  "") dir=$HOME/$name ;;
  "~") dir=$HOME ;;
  "~/"*) dir=$HOME/${dir#"~/"} ;;
esac
case $dir in /*) ;; *) dir=$PWD/$dir ;; esac
dir=${dir%/}

bn_log "work brain $name at $dir"
state=$(wb_check_target "$dir" "$name")
if [ "$state" = new ]; then bn_ok "$dir is new"; else bn_ok "$dir is this brain's vault"; fi

gl=$(bn_find_gitleaks)
[ -n "$gl" ] || bn_die "gitleaks not found - install it first (CHECKLIST.md, 'Before the script'); nothing was changed"

bn_log "vault"
if [ "$state" = new ]; then
  src=$(git -C "$here/../.." rev-parse --show-toplevel)
  wb_template_is_clean "$src"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" symbolic-ref HEAD refs/heads/main
  git -C "$dir" config binnacle.profile "$WB_PROFILE"
  git -C "$dir" config binnacle.brainName "$name"
  git -C "$dir" config binnacle.org "$org_slug"
  git -C "$dir" config binnacle.localOnly true
  bn_ok "new local repository (no remote; binnacle.localOnly = true)"
fi
if ! git -C "$dir" rev-parse --verify -q 'HEAD^{commit}' >/dev/null; then
  # New, or a first run that stopped before its first commit.
  src=$(git -C "$here/../.." rev-parse --show-toplevel)
  [ "$(bn_physical_path "$src")" != "$(bn_physical_path "$dir")" ] \
    || bn_die "$dir has no commit yet; run this script from the binnacle-template checkout"
  wb_template_is_clean "$src"
  git -C "$src" archive --format=tar HEAD | tar -xf - -C "$dir"
  wb_apply_rules "$dir"
  template_rev=$(git -C "$src" rev-parse --short HEAD)
  bn_ok "template files copied ($template_rev), company content limits written to CLAUDE.md"
else
  bn_ok "existing vault"
fi

bn_log "machine role"
git -C "$dir" config binnacle.role wiki-writer
bn_ok "binnacle.role = wiki-writer (bin/binnacle-run runs here)"
git -C "$dir" config binnacle.ghTokenItem "$name-gh-token"
bn_ok "binnacle.ghTokenItem = $name-gh-token (used once a remote is connected)"

bn_log "git identity (vault only)"
BINNACLE_DIR=$dir
BINNACLE_OWNER=$(wb_slug "$user")
bn_set_git_identity

bn_log "hooks"
"$dir/setup/common/install-hooks.sh" "$dir"

if ! git -C "$dir" rev-parse --verify -q 'HEAD^{commit}' >/dev/null; then
  bn_log "first commit (the pre-commit hook scans it)"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m "work brain $name, from binnacle-template ${template_rev:-}"
  bn_ok "committed on main"
fi

bn_log "tools"
for tool in git claude gh; do
  if command -v "$tool" >/dev/null 2>&1; then
    bn_ok "$tool: $(command -v "$tool")"
  elif [ "$tool" = gh ]; then
    bn_warn "gh not found: not needed until you connect a remote (CHECKLIST.md)"
  else
    bn_warn "$tool not found on PATH (CHECKLIST.md, 'Before the script')"
  fi
done

ver=$(bn_obsidian_version)
if [ -n "$ver" ]; then
  bn_ok "Obsidian $ver"
else
  bn_warn "Obsidian not found in /Applications (CHECKLIST.md)"
fi

if command -v "${BINNACLE_GH:-gh}" >/dev/null 2>&1 && "${BINNACLE_GH:-gh}" auth status >/dev/null 2>&1; then
  wb_base_permission "$org_slug"
else
  bn_log "org base repository permission: checked when you connect the remote (gh is not logged in here)"
fi

if [ "$(git -C "$dir" config --get binnacle.localOnly || true)" = true ]; then
  bn_log "ready, local only. Connect a remote later: $dir/setup/work-brain/connect-remote.sh"
else
  bn_log "ready, connected to $(git -C "$dir" remote get-url origin)"
fi
bn_log "remaining human steps: $dir/setup/work-brain/CHECKLIST.md"
