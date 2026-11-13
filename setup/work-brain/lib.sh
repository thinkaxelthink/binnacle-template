# shellcheck shell=bash
# Helpers for the work-brain profile (a company brain on a work machine).
# Source it after setup/common/lib.sh; do not run it.

# The personal vault. The work-brain scripts never create, change or
# connect anything at or inside it.
WB_PERSONAL_DIR=$HOME/binnacle
WB_PROFILE=work-brain

# wb_slug TEXT: lowercase; every run of characters outside [a-z0-9-]
# becomes one '-'; repeated dashes collapse; leading and trailing dashes go.
wb_slug() {
  printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]' \
    | LC_ALL=C sed -e 's/[^a-z0-9-][^a-z0-9-]*/-/g' -e 's/--*/-/g' -e 's/^-//' -e 's/-$//'
}

# wb_name ORG USER: print binnacle-<org>-<user>, both slugged.
wb_name() {
  local org user
  org=$(wb_slug "$1")
  user=$(wb_slug "$2")
  [ -n "$org" ] || bn_die "the GitHub org '$1' has no letters or digits to name the brain after"
  [ -n "$user" ] || bn_die "the GitHub user '$2' has no letters or digits to name the brain after"
  printf 'binnacle-%s-%s\n' "$org" "$user"
}

# wb_refuse_personal DIR: die when DIR is the personal vault or inside it,
# after resolving symlinks.
wb_refuse_personal() {
  if bn_path_is_under "$1" "$WB_PERSONAL_DIR"; then
    bn_die "refusing: $1 is (or resolves to) the personal vault $WB_PERSONAL_DIR or a folder inside it. The work brain lives beside it, e.g. ~/binnacle-<org>-<user>."
  fi
}

# wb_vault_name DIR: print the brain name DIR is marked with, or nothing
# when DIR is not the top of a work-brain vault.
wb_vault_name() {
  local top
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 0
  [ "$(bn_physical_path "$top")" = "$(bn_physical_path "$1")" ] || return 0
  [ "$(git -C "$1" config --local --get binnacle.profile || true)" = "$WB_PROFILE" ] || return 0
  git -C "$1" config --local --get binnacle.brainName || true
}

# wb_check_origin DIR: die when DIR has an origin remote that is not the one
# connect-remote.sh recorded (binnacle.remoteUrl).
wb_check_origin() {
  local origin recorded
  origin=$(git -C "$1" remote get-url origin 2>/dev/null || true)
  [ -n "$origin" ] || return 0
  recorded=$(git -C "$1" config --local --get binnacle.remoteUrl || true)
  [ "$origin" = "$recorded" ] \
    || bn_die "refusing: $1 has origin '$origin', which is not the remote this brain was connected to (${recorded:-none}). It points elsewhere; fix or remove that remote by hand first."
}

# wb_check_target DIR NAME: refuse every target except a new folder or this
# brain's own vault. Prints "new" or "existing".
wb_check_target() {
  local dir=$1 name=$2 found
  wb_refuse_personal "$dir"
  if [ -L "$dir" ] && [ ! -e "$dir" ]; then
    bn_die "refusing: $dir is a symlink to nothing; remove it or pick another --dir"
  fi
  if [ ! -e "$dir" ]; then
    echo new
    return 0
  fi
  [ -d "$dir" ] || bn_die "refusing: $dir exists and is not a folder; pick another --dir"
  found=$(wb_vault_name "$dir")
  if [ -z "$found" ]; then
    bn_die "refusing: $dir exists and is not a work-brain vault. Move it aside or pick another --dir; nothing was changed."
  fi
  [ "$found" = "$name" ] \
    || bn_die "refusing: $dir is the work brain '$found', not '$name'. Pick another --dir; nothing was changed."
  wb_check_origin "$dir"
  echo existing
}

# wb_template_is_clean SRC: die unless SRC's committed tree holds no vault
# content (only the template's empty seeds), so a vault with notes can never
# be copied into a new brain.
wb_template_is_clean() {
  local src=$1 p extra="" first
  git -C "$src" rev-parse --verify -q 'HEAD^{commit}' >/dev/null \
    || bn_die "$src has no commits; run this script from a binnacle-template checkout"
  while IFS= read -r p; do
    case $p in
      raw/inbox/.gitkeep | soundings/.gitkeep | audit/runs/.gitkeep | wiki/index.md | wiki/log.md) ;;
      *) extra="$extra $p" ;;
    esac
  done < <(git -C "$src" ls-tree -r --name-only HEAD -- raw soundings wiki audit/runs)
  first=${extra# }
  first=${first%% *}
  if [ -n "$extra" ] || git -C "$src" show HEAD:wiki/log.md 2>/dev/null | grep -q '^## \[' \
    || git -C "$src" show HEAD:wiki/index.md 2>/dev/null | grep -q '\[\['; then
    bn_die "refusing: $src holds vault content${first:+ (e.g. $first)}; run this script from a clean binnacle-template checkout, never from a vault"
  fi
}

# wb_replace FILE OLD NEW [all]: replace the exact text OLD with NEW, once
# (OLD must occur exactly once) or, with "all", everywhere (at least once).
wb_replace() {
  local f=$1 old=$2 new=$3 mode=${4:-once} body out=""
  body=$(cat "$f" && printf x) || bn_die "cannot read $f"
  body=${body%x}
  case $body in *"$old"*) ;; *) bn_die "$f: text to replace not found: ${old%%$'\n'*}" ;; esac
  if [ "$mode" = once ]; then
    case ${body#*"$old"} in *"$old"*) bn_die "$f: text to replace occurs more than once: ${old%%$'\n'*}" ;; esac
  fi
  while :; do
    case $body in *"$old"*) ;; *) break ;; esac
    out=$out${body%%"$old"*}$new
    body=${body#*"$old"}
    [ "$mode" = all ] || break
  done
  printf '%s%s' "$out" "$body" >"$f"
}

# wb_apply_rules VAULT: rewrite the personal scope rules in the new vault's
# CLAUDE.md and run prompt for a company brain. Fails if any expected text
# is missing, so a template change cannot silently skip a rule.
wb_apply_rules() {
  local c=$1/CLAUDE.md p=$1/bin/binnacle-run.prompt.md
  wb_replace "$c" "This vault is a personal LLM-maintained wiki," \
    "This vault is a work LLM-maintained wiki (a company brain),"
  wb_replace "$c" "Scope is personal: the owner's own thinking and architectural learnings.
The vault never holds company data, member or customer data, payment or
contract material, or credentials, and no company system connects to it." \
    "Scope is work: a company brain, the owner's working knowledge for one
employer, kept in a private repository in that employer's GitHub
organization. Company material may go in, within these limits: never
customer or member personal data, payment data, minors' names, health or
waiver records, or credentials. No company system connects to the vault.

Until a remote is connected (\`git config binnacle.localOnly true\`),
everything stays on this machine: where this file says a PR is opened and
auto-merged, the branch is fast-forwarded into \`main\` instead, after the
pre-commit secret scan has passed on its commits."
  wb_replace "$c" "- Never write company or member material into the vault. If a source looks
  like it, skip it the same way." \
    "- Never write customer or member personal data, payment data, minors'
  names, or health or waiver records into the vault. If a source holds any,
  skip it the same way."
  wb_replace "$c" "holds secrets or company material." \
    "holds secrets or anything the scope above rules out."
  wb_replace "$c" "Only shoyu (the clone" "Only the work machine (the clone"
  wb_replace "$c" "on shoyu" "on the work machine" all
  wb_replace "$p" "   - If it holds a credential, key or token, or looks like company or
     member material, do not ingest it:" \
    "   - If it holds a credential, key or token, or customer or member personal
     data, payment data, minors' names, or health or waiver records, do not
     ingest it:"
}

# wb_base_permission ORG: warn, with the fix, when the org's base repository
# permission lets members read private repos. Never fails: it only warns.
wb_base_permission() {
  local org=$1 gh=${BINNACLE_GH:-gh} perm
  local fix="GitHub > $org > Settings > Member privileges > Base permissions: No permission (https://github.com/organizations/$org/settings/member_privileges)"
  bn_log "org base repository permission ($org)"
  if ! command -v "$gh" >/dev/null 2>&1; then
    bn_warn "gh not found, so the base permission cannot be read. Check it by hand: $fix"
    return 0
  fi
  if ! perm=$("$gh" api "orgs/$org" --jq '.default_repository_permission // ""' 2>/dev/null); then
    bn_warn "could not read org '$org' with gh (not logged in, not an organization, or no access). Check it by hand: $fix"
    return 0
  fi
  case $perm in
    none)
      bn_ok "base permission is none: the brain repo is visible only to you and the $org owners (and anyone you add to it yourself)" ;;
    "")
      bn_warn "cannot read the base permission: GitHub shows it only to org owners (an owner's gh login). Ask an owner, or check by hand: $fix" ;;
    *)
      bn_warn "base repository permission is '$perm': every member of $org can read the private brain repo (org owners always can). Fix: $fix" ;;
  esac
  return 0
}
