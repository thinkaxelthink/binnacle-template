#!/usr/bin/env bash
# Connect a work brain to its GitHub repository: add origin, push main, and
# leave local-only mode. Run it only when you decide to; it is never part of
# setup.sh. Safe to re-run.
#
# Usage: setup/work-brain/connect-remote.sh [--url URL]
#   --url      the repository (default https://github.com/<org>/<brain name>.git);
#              its name must be the brain's name
#
# Before pushing it re-runs the collision checks: the vault must be a work
# brain (never ~/binnacle), any existing origin must be this URL, the
# repository must be reachable and hold nothing but this brain's own
# history, and when gh can see it, it must be private. Afterwards it checks
# the org's base repository permission and warns, with the fix, when org
# members could read the repository. Create the empty private repository
# first (setup/work-brain/CHECKLIST.md, "Connect a remote").
# Env: BINNACLE_GH (gh).
set -eu

here=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=../common/lib.sh
. "$here/../common/lib.sh"
# shellcheck source=lib.sh
. "$here/lib.sh"

GH=${BINNACLE_GH:-gh}
usage() { sed -n '6,8p' "$0" | sed 's/^# \{0,1\}//'; }

url=""
while [ "$#" -gt 0 ]; do
  case $1 in
    --url) [ "$#" -ge 2 ] || bn_die "--url needs a value"; url=$2; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done

vault=$(git -C "$here/../.." rev-parse --show-toplevel)
wb_refuse_personal "$vault"
name=$(wb_vault_name "$vault")
[ -n "$name" ] || bn_die "$vault is not a work-brain vault (run setup/work-brain/setup.sh first)"
org=$(git -C "$vault" config --local --get binnacle.org || true)
[ -n "$org" ] || bn_die "$vault has no binnacle.org; re-run setup/work-brain/setup.sh"
url=${url:-https://github.com/$org/$name.git}

bn_log "work brain $name at $vault -> $url"

# The repository's name must be the brain's name.
repo_name=${url%/}
repo_name=${repo_name%.git}
repo_name=${repo_name##*/}
repo_name=${repo_name##*:}
if [ "$(printf '%s' "$repo_name" | tr '[:upper:]' '[:lower:]')" != "$name" ]; then
  bn_die "refusing: $url is the repository '$repo_name', not '$name'"
fi

origin=$(git -C "$vault" remote get-url origin 2>/dev/null || true)
if [ -n "$origin" ] && [ "$origin" != "$url" ]; then
  bn_die "refusing: origin already points elsewhere ($origin); nothing was changed"
fi
git -C "$vault" rev-parse --verify -q 'refs/heads/main^{commit}' >/dev/null \
  || bn_die "$vault has no main branch with a commit"

# GitHub visibility, when gh can see the repository.
owner_repo=""
case $url in
  https://github.com/*) owner_repo=${url#https://github.com/} ;;
  git@github.com:*) owner_repo=${url#git@github.com:} ;;
esac
owner_repo=${owner_repo%/}
owner_repo=${owner_repo%.git}
if [ -n "$owner_repo" ] && command -v "$GH" >/dev/null 2>&1 \
  && private=$("$GH" api "repos/$owner_repo" --jq .private 2>/dev/null); then
  [ "$private" = true ] \
    || bn_die "refusing: $owner_repo is not private. Make it private (Settings > General > Danger Zone) before connecting."
  bn_ok "$owner_repo is private"
else
  bn_warn "could not confirm with gh that the repository is private; check it in the browser before you write anything into the brain"
fi

# What the remote already holds must be this brain's own history.
heads=$(git -C "$vault" ls-remote --heads "$url" 2>&1) \
  || bn_die "cannot read $url. Create the empty private repository first and make sure your credentials can reach it (CHECKLIST.md).
$heads"
foreign=""
while read -r sha ref; do
  [ -n "$sha" ] || continue
  if ! git -C "$vault" cat-file -e "$sha^{commit}" 2>/dev/null \
    || ! git -C "$vault" merge-base --is-ancestor "$sha" refs/heads/main; then
    foreign="$foreign ${ref#refs/heads/}"
  fi
done <<EOF
$heads
EOF
[ -z "$foreign" ] \
  || bn_die "refusing: $url already holds history that is not this brain's (branch(es):$foreign). It points elsewhere; nothing was changed."
if [ -z "$heads" ]; then bn_ok "repository is empty"; else bn_ok "repository holds only this brain's history"; fi

bn_log "connect"
if [ -z "$origin" ]; then
  git -C "$vault" remote add origin "$url"
  bn_ok "origin = $url"
else
  bn_ok "origin already $url"
fi
git -C "$vault" config binnacle.remoteUrl "$url"
git -C "$vault" push -q -u origin main || bn_die "git push failed; fix access and re-run (nothing else changed)"
bn_ok "main pushed"
git -C "$vault" config --unset binnacle.localOnly || true
bn_ok "binnacle.localOnly unset: bin/binnacle-run now pushes run branches and opens PRs"

wb_base_permission "$org"

bn_log "connected. Finish the repository settings and token: $vault/setup/work-brain/CHECKLIST.md, 'Connect a remote'"
