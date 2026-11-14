#!/usr/bin/env bash
# Bring a work brain's template files up to date with this template checkout.
#
# Usage: setup/work-brain/update.sh VAULT
#   VAULT   the work brain's folder, e.g. ~/binnacle-acme-engineering-jdoe
#
# Run it from a clean, up-to-date binnacle-template checkout, never from the
# vault. It:
#   1. finds the template commit the vault was built from: git config
#      binnacle.templateBase (setup.sh and this script record it), else the
#      revision named in the vault's first commit message;
#   2. rebuilds that commit as setup.sh did (the template's files plus that
#      commit's own wb_apply_rules) and compares it with the vault's
#      template-owned files: any file edited, removed or added over a
#      template file in the vault stops the update, naming it;
#   3. copies what changed upstream between that commit and this checkout's
#      HEAD (additions, edits, deletions, renames), with HEAD's
#      wb_apply_rules re-run on it, onto a new binnacle-update/<id> branch
#      in a temporary worktree. wiki/, raw/, soundings/ and audit/ are never
#      touched; upstream changes there are listed, not applied;
#   4. commits it (the pre-commit secret scan runs), then
#      - local only (binnacle.localOnly true): fast-forwards main and
#        records the new base;
#      - connected: pushes the branch and opens a PR, never auto-merged. The
#        new base is recorded as pending and becomes the base when the next
#        run of this script finds the PR merged.
# It refuses ~/binnacle (or anything resolving into it), a folder that is
# not a work-brain vault, a vault with uncommitted changes or off main, a
# connected vault whose main differs from origin's, a waiting
# binnacle-run/* or binnacle-update/* branch or PR, and a base this
# checkout does not have.
# Env: BINNACLE_GH (gh).
set -eu

here=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=../common/lib.sh
. "$here/../common/lib.sh"
# shellcheck source=lib.sh
. "$here/lib.sh"

GH=${BINNACLE_GH:-gh}
BASE=main
usage() { sed -n '4,5p' "$0" | sed 's/^# \{0,1\}//'; }

vault=""
while [ "$#" -gt 0 ]; do
  case $1 in
    -h | --help) usage; exit 0 ;;
    -*) usage >&2; exit 2 ;;
    *) [ -z "$vault" ] || { usage >&2; exit 2; }; vault=$1; shift ;;
  esac
done
[ -n "$vault" ] || { usage >&2; exit 2; }

# --- which vault, which template -----------------------------------------------
wb_refuse_personal "$vault"
[ -d "$vault" ] || bn_die "$vault is not a folder"
vault=$(cd "$vault" && pwd -P)
name=$(wb_vault_name "$vault")
[ -n "$name" ] || bn_die "refusing: $vault is not a work-brain vault (binnacle.profile is not $WB_PROFILE at its top); nothing was changed"
wb_check_origin "$vault"
src=$(git -C "$here/../.." rev-parse --show-toplevel)
[ "$(bn_physical_path "$src")" != "$vault" ] \
  || bn_die "refusing: run this script from a binnacle-template checkout, not from the vault's own copy"
wb_template_is_clean "$src"
head=$(git -C "$src" rev-parse HEAD)

bn_log "work brain $name at $vault, template $src ($(git -C "$src" rev-parse --short HEAD))"

local_only=0
[ "$(git -C "$vault" config --get binnacle.localOnly || true)" != true ] || local_only=1

# --- vault state -----------------------------------------------------------------
[ "$(git -C "$vault" symbolic-ref --quiet --short HEAD || true)" = "$BASE" ] \
  || bn_die "refusing: $vault is not on $BASE; switch back to $BASE first"
[ -z "$(git -C "$vault" status --porcelain)" ] \
  || bn_die "refusing: $vault has uncommitted changes; commit or discard them first (git -C $vault status)"
waiting=$(git -C "$vault" for-each-ref --format='%(refname:short)' 'refs/heads/binnacle-run/*' 'refs/heads/binnacle-update/*' | tr '\n' ' ')
[ -z "$waiting" ] \
  || bn_die "refusing: a branch is still waiting: $waiting- merge it into $BASE or delete it first"

if [ "$local_only" -eq 0 ]; then
  git -C "$vault" remote get-url origin >/dev/null 2>&1 \
    || bn_die "$vault is not local only (binnacle.localOnly) but has no origin; connect it first (setup/work-brain/connect-remote.sh)"
  gh_path=$(command -v "$GH" 2>/dev/null || true)
  case $gh_path in
    /*) ;;
    *) bn_die "gh not found ('$GH'); a connected vault needs it to open the update PR" ;;
  esac
  sync_ref=refs/binnacle-update/base
  git -C "$vault" fetch --quiet --no-write-fetch-head --refmap= origin "+refs/heads/$BASE:$sync_ref" \
    || bn_die "could not fetch $BASE from origin"
  remote_main=$(git -C "$vault" rev-parse "$sync_ref")
  git -C "$vault" update-ref -d "$sync_ref"
  [ "$remote_main" = "$(git -C "$vault" rev-parse "$BASE")" ] \
    || bn_die "refusing: local $BASE differs from origin's; pull (and push) first so they match"
  # gh finds the repository from the working directory.
  ghv() { (cd "$vault" && "$gh_path" "$@"); }

  pending=$(git -C "$vault" config --get binnacle.templateBasePending || true)
  pending_branch=$(git -C "$vault" config --get binnacle.templateUpdateBranch || true)
  if [ -n "$pending" ]; then
    state=$(ghv pr view "$pending_branch" --json state --jq .state) \
      || bn_die "could not read the state of the earlier update PR ($pending_branch) with gh"
    case $state in
      OPEN) bn_die "refusing: the earlier update PR ($pending_branch) is still open; merge or close it first" ;;
      MERGED)
        git -C "$vault" config binnacle.templateBase "$pending"
        bn_ok "the earlier update PR ($pending_branch) was merged: base is now $(git -C "$src" rev-parse --short "$pending" 2>/dev/null || echo "$pending")" ;;
      *) bn_warn "the earlier update PR ($pending_branch) was closed without merging; the base stays as it was" ;;
    esac
    git -C "$vault" config --unset binnacle.templateBasePending || true
    git -C "$vault" config --unset binnacle.templateUpdateBranch || true
  fi
  open_prs=$(ghv pr list --state open --base "$BASE" --json headRefName,url \
    --jq '.[] | select((.headRefName | startswith("binnacle-run/")) or (.headRefName | startswith("binnacle-update/"))) | .url') \
    || bn_die "could not list open PRs with gh"
  [ -z "$open_prs" ] || bn_die "refusing: a run or update PR is still open: $open_prs - merge or close it first"
fi

# --- base --------------------------------------------------------------------------
recorded=$(git -C "$vault" config --get binnacle.templateBase || true)
if [ -n "$recorded" ]; then
  base_rev=$recorded
  base_from="binnacle.templateBase"
else
  root=$(git -C "$vault" rev-list --max-parents=0 "$BASE" | tail -n 1)
  subject=$(git -C "$vault" log -1 --format=%s "$root")
  base_rev=""
  case $subject in *", from binnacle-template "*) base_rev=${subject##*, from binnacle-template } ;; esac
  case $base_rev in "" | *[!0-9a-f]*) bn_die "refusing: unknown base: binnacle.templateBase is unset and the first commit ('$subject') names no template revision. Set it by hand once you know it: git -C $vault config binnacle.templateBase <commit>" ;; esac
  base_from="the first commit message"
fi
base=$(git -C "$src" rev-parse --verify -q "$base_rev^{commit}") \
  || bn_die "refusing: unknown base: this checkout does not have template commit $base_rev (from $base_from). Pull (or git fetch --unshallow) the template and re-run."
git -C "$src" merge-base --is-ancestor "$base" "$head" \
  || bn_die "refusing: this checkout's HEAD does not contain the vault's base $base_rev; check out main and pull the template"
bn_ok "base $(git -C "$src" rev-parse --short "$base") (from $base_from)"

if [ "$base" = "$head" ]; then
  git -C "$vault" config binnacle.templateBase "$head"
  bn_ok "already up to date; binnacle.templateBase = $head"
  exit 0
fi

# --- rebuild base and new template -------------------------------------------------
work=$(mktemp -d "${TMPDIR:-/tmp}/binnacle-update.XXXXXX")
wt=""
branch=""
finished=0
# shellcheck disable=SC2317,SC2329 # called by the EXIT trap
on_exit() {
  if [ "$finished" -eq 0 ]; then
    [ -z "$wt" ] || git -C "$vault" worktree remove --force "$wt" >/dev/null 2>&1 || true
    [ -z "$branch" ] || git -C "$vault" branch -q -D "$branch" >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
}
trap on_exit EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

gitdir=$(git -C "$vault" rev-parse --absolute-git-dir)
# The content zones: never compared, copied or changed.
zones=(':(exclude)wiki' ':(exclude)raw' ':(exclude)soundings' ':(exclude)audit')

# build REV DIR: write template commit REV to DIR with that commit's own
# wb_apply_rules, as setup.sh did, and print its tree in the vault's store.
build() {
  local rev=$1 dir=$2
  mkdir -p "$dir"
  git -C "$src" archive --format=tar "$rev" | tar -xf - -C "$dir"
  [ -f "$dir/setup/work-brain/lib.sh" ] \
    || bn_die "template commit $rev has no setup/work-brain/lib.sh; it cannot be a work brain's base"
  # shellcheck source=/dev/null # the commit's own helpers
  (. "$dir/setup/common/lib.sh" && . "$dir/setup/work-brain/lib.sh" && wb_apply_rules "$dir") >&2 \
    || bn_die "the company scope rules do not apply to template commit $rev"
  rm -f "$work/index"
  GIT_INDEX_FILE=$work/index git -C "$dir" --git-dir="$gitdir" --work-tree="$dir" add -A --force
  GIT_INDEX_FILE=$work/index git -C "$dir" --git-dir="$gitdir" write-tree
}
base_tree=$(build "$base" "$work/base")
new_tree=$(build "$head" "$work/new")

# --- local edits -------------------------------------------------------------------
edited=()
while IFS= read -r -d '' st && IFS= read -r -d '' p; do
  case $st in
    D) edited+=("$p (removed in the vault)") ;;
    *) edited+=("$p") ;;
  esac
done < <(git -C "$vault" diff-tree -r -z --no-renames --name-status --diff-filter=MDT "$base_tree" "$BASE" -- "${zones[@]}")

# --- upstream changes ----------------------------------------------------------------
copy=()
remove=()
summary=()
while IFS= read -r -d '' st && IFS= read -r -d '' p; do
  case $st in
    D) remove+=("$p"); summary+=("deleted  $p") ;;
    A)
      # A file the vault already has at that path is the vault's own unless
      # it is exactly the new template file.
      have=$(git -C "$vault" ls-tree "$BASE" -- "$p")
      want=$(git -C "$vault" ls-tree "$new_tree" -- "$p")
      [ -z "$have" ] || [ "$have" = "$want" ] || edited+=("$p (exists in the vault, not in the base)")
      copy+=("$p"); summary+=("added    $p") ;;
    *) copy+=("$p"); summary+=("changed  $p") ;;
  esac
done < <(git -C "$vault" diff-tree -r -z --no-renames --name-status "$base_tree" "$new_tree" -- "${zones[@]}")

skipped=()
while IFS= read -r -d '' p; do skipped+=("$p"); done \
  < <(git -C "$vault" diff-tree -r -z --no-renames --name-only "$base_tree" "$new_tree" -- wiki raw soundings audit)

if [ "${#edited[@]}" -gt 0 ]; then
  printf 'error: refusing: these template files were edited in the vault since base %s:\n' \
    "$(git -C "$src" rev-parse --short "$base")" >&2
  printf '  %s\n' "${edited[@]}" >&2
  bn_die "nothing was changed. Undo those edits (or move them out of template files), commit, and re-run."
fi
bn_ok "no template file edited in the vault"

for p in ${skipped[@]+"${skipped[@]}"}; do
  bn_warn "not applied (content zone, never touched): $p changed upstream; copy it by hand if you want it"
done

if [ "${#summary[@]}" -eq 0 ]; then
  git -C "$vault" config binnacle.templateBase "$head"
  bn_ok "no template file changed upstream outside the content zones; binnacle.templateBase = $head"
  finished=1
  exit 0
fi

# --- branch, copy, commit ------------------------------------------------------------
run_id=$(date -u +%Y%m%dT%H%M%SZ)
short_base=$(git -C "$src" rev-parse --short "$base")
short_head=$(git -C "$src" rev-parse --short "$head")
title="update from binnacle-template $short_base..$short_head"
wt=$work/vault
git -C "$vault" worktree add --quiet -b "binnacle-update/$run_id" "$wt" "$BASE"
branch=binnacle-update/$run_id
for p in ${remove[@]+"${remove[@]}"}; do
  git -C "$wt" --literal-pathspecs rm -q -- "$p"
done
for p in ${copy[@]+"${copy[@]}"}; do
  git -C "$wt" --literal-pathspecs checkout "$new_tree" -- "$p"
done
# Every template-owned file on the branch is now the new template's.
[ -z "$(git -C "$wt" diff --cached --no-renames --name-only --diff-filter=MDT "$new_tree" -- "${zones[@]}")" ] \
  || bn_die "the branch does not match the new template; nothing was changed"
git -C "$wt" commit -q -m "$title" \
  || bn_die "the commit was refused (pre-commit secret scan or 10 MB cap); nothing was changed"
bn_ok "branch $branch: ${#summary[@]} file(s)"
printf '    %s\n' "${summary[@]}"

if [ "$local_only" -eq 1 ]; then
  git -C "$vault" merge --quiet --ff-only "$branch" >/dev/null 2>&1 \
    || bn_die "$BASE moved while updating; nothing was changed, re-run"
  git -C "$vault" worktree remove --force "$wt"
  git -C "$vault" branch -q -D "$branch"
  git -C "$vault" config binnacle.templateBase "$head"
  finished=1
  bn_ok "$BASE fast-forwarded (local only, no remote); binnacle.templateBase = $head"
  exit 0
fi

git -C "$wt" push -q origin "$branch" || bn_die "git push failed; nothing was changed"
body=$work/pr-body.md
# shellcheck disable=SC2016 # literal backticks: Markdown code spans
{
  printf 'Template update for this work brain, created by `setup/work-brain/update.sh`.\n\n'
  printf -- '- template: `%s` to `%s`\n' "$base" "$head"
  printf -- '- company scope rules re-applied to `CLAUDE.md` and the run prompt\n'
  printf -- '- `wiki/`, `raw/`, `soundings/` and `audit/` not touched\n\n'
  printf 'Files:\n\n'
  printf -- '- `%s`\n' "${summary[@]}"
  if [ "${#skipped[@]}" -gt 0 ]; then
    printf '\nChanged upstream in a content zone, not applied:\n\n'
    printf -- '- `%s`\n' "${skipped[@]}"
  fi
  printf '\nNot auto-merged: review and merge it yourself. The next run of\n'
  printf '`update.sh` records `%s` as the base once this PR is merged.\n' "$short_head"
} >"$body"
pr=$(ghv pr create --base "$BASE" --head "$branch" --title "$title" --body-file "$body") \
  || bn_die "branch $branch is pushed but opening the PR failed; open it by hand, and once it is merged run: git -C $vault config binnacle.templateBase $head"
pr=$(printf '%s\n' "$pr" | tail -n 1)
git -C "$vault" config binnacle.templateBasePending "$head"
git -C "$vault" config binnacle.templateUpdateBranch "$branch"
git -C "$vault" worktree remove --force "$wt"
git -C "$vault" branch -q -D "$branch"
finished=1
bn_ok "PR: $pr (not auto-merged; merge it yourself)"
bn_log "after merging, pull $BASE; the next update.sh run records $short_head as the base"
