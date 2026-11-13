#!/usr/bin/env bash
# Create the private vault repo from this template and protect it. Idempotent.
# Run once, from any Mac, with the owner's interactive `gh auth login`
# session (not a device token). See setup/github/CHECKLIST.md first.
#
# Usage: setup/github/setup.sh [--dry-run]
# Env:   BINNACLE_OWNER (thinkaxelthink), BINNACLE_REPO (binnacle),
#        BINNACLE_TEMPLATE_REPO (binnacle-template),
#        BINNACLE_SCAN_CHECK (gitleaks) - the required status check, i.e. the
#        job name in .github/workflows/secret-scan.yml.
#
# What it does:
#   1. marks OWNER/binnacle-template as a template repository
#   2. creates OWNER/binnacle from it as a PRIVATE repo (skipped if it exists)
#   3. enables auto-merge (squash) and branch deletion on merge
#   4. protects main: the scan check must pass before a PR merges; no
#      reviews required; force pushes and deletion blocked. Admins are not
#      enforced, so the owner's device captures can still push to main.
set -eu

here=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=../common/lib.sh
. "$here/../common/lib.sh"

TEMPLATE=${BINNACLE_TEMPLATE_REPO:-binnacle-template}
CHECK=${BINNACLE_SCAN_CHECK:-gitleaks}
GH=${BINNACLE_GH:-gh}
repo="$BINNACLE_OWNER/$BINNACLE_REPO"
template="$BINNACLE_OWNER/$TEMPLATE"

dry=0
case "${1:-}" in
  --dry-run) dry=1 ;;
  "") ;;
  *) bn_die "usage: $0 [--dry-run]" ;;
esac

run() {
  if [ "$dry" -eq 1 ]; then
    printf '  dry-run: %s\n' "$*"
  else
    "$@"
  fi
}

protection_json() {
  cat <<EOF
{
  "required_status_checks": { "strict": false, "checks": [ { "context": "$CHECK" } ] },
  "enforce_admins": false,
  "required_pull_request_reviews": null,
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
EOF
}

if [ "$dry" -eq 0 ]; then
  "$GH" auth status >/dev/null 2>&1 || bn_die "gh is not logged in; run: gh auth login"
fi

bn_log "template: $template"
run "$GH" api -X PATCH "repos/$template" -F is_template=true --silent
bn_ok "is_template = true"

bn_log "vault repo: $repo"
if [ "$dry" -eq 0 ] && "$GH" repo view "$repo" >/dev/null 2>&1; then
  bn_ok "$repo already exists"
else
  run "$GH" repo create "$repo" --private --template "$template"
fi

if [ "$dry" -eq 0 ]; then
  private=$("$GH" api "repos/$repo" --jq .private)
  [ "$private" = "true" ] || bn_die "$repo is not private. Make it private in Settings before continuing."
  bn_ok "$repo is private"

  # Template copies finish asynchronously; wait for main to appear.
  i=0
  until "$GH" api "repos/$repo/branches/main" --silent >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -le 30 ] || bn_die "main branch did not appear in $repo after 60s"
    sleep 2
  done
fi

bn_log "repository settings"
run "$GH" api -X PATCH "repos/$repo" --silent \
  -F allow_auto_merge=true -F allow_squash_merge=true -F delete_branch_on_merge=true
bn_ok "auto-merge on, squash merge on, delete branch on merge"

bn_log "branch protection on main (required check: $CHECK)"
if [ "$dry" -eq 1 ]; then
  printf '  dry-run: %s api -X PUT repos/%s/branches/main/protection --input -\n' "$GH" "$repo"
  protection_json | sed 's/^/    /'
else
  if ! out=$(protection_json | "$GH" api -X PUT "repos/$repo/branches/main/protection" --input - 2>&1); then
    case $out in
      *"Upgrade to GitHub Pro"*|*"upgrade"*)
        bn_die "GitHub refused branch protection on a private repo for this plan: $out
Private-repo branch protection and auto-merge need GitHub Pro (or Team). See CHECKLIST.md." ;;
      *) bn_die "setting branch protection failed: $out" ;;
    esac
  fi
  bn_ok "main protected"
fi

bn_log "done. Verify the items under 'After the script' in $here/CHECKLIST.md"
