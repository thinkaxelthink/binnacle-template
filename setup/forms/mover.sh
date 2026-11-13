#!/usr/bin/env bash
# Move survey responses from the synced Forms folder into raw/inbox/forms/,
# through bin/binnacle-forms-to-inbox. On demand only; it never commits.
#
# Usage: setup/forms/mover.sh [--vault DIR] [--sync-dir DIR] [FORM...]
#   --vault     the vault (default: the vault this script belongs to)
#   --sync-dir  the synced folder the Power Automate flow writes to
#               (default: git config binnacle.formsSyncDir in the vault)
#   FORM        subfolders to process (default: every subfolder)
#
# The synced folder holds one subfolder per form, where the flow writes one
# .csv file per response (setup/forms/CHECKLIST.md). Each form's settings
# live in the vault, in the gitignored <vault>/.binnacle/forms/<FORM>.conf,
# as key=value lines: form_title, form_id, audience,
# consent_notice_version (required), subject, identity, invited, platform
# (default msforms). For each form the converter makes one note from all
# its .csv files; once the note is written, exactly those files are
# deleted. A refusal or error keeps them and moves on to the next form; the
# exit status is then 1. The synced folder must be outside the vault.
set -eu

here=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=../common/lib.sh
. "$here/../common/lib.sh"

usage() { sed -n '5,9p' "$0" | sed 's/^# \{0,1\}//'; }

vault="" sync_dir=""
forms=()
while [ "$#" -gt 0 ]; do
  case $1 in
    --vault | --sync-dir)
      [ "$#" -ge 2 ] || bn_die "$1 needs a value"
      if [ "$1" = --vault ]; then vault=$2; else sync_dir=$2; fi
      shift 2 ;;
    -h | --help) usage; exit 0 ;;
    -*) usage >&2; exit 2 ;;
    *) forms+=("$1"); shift ;;
  esac
done

[ -n "$vault" ] || vault=$(git -C "$here/../.." rev-parse --show-toplevel)
[ -d "$vault/raw/inbox" ] || bn_die "$vault is not a Binnacle vault (no raw/inbox/)"
[ -n "$sync_dir" ] || sync_dir=$(git -C "$vault" config --get binnacle.formsSyncDir || true)
[ -n "$sync_dir" ] \
  || bn_die "no synced folder: set it once with git -C $vault config binnacle.formsSyncDir <folder> (setup/forms/CHECKLIST.md)"
[ -d "$sync_dir" ] || bn_die "synced folder $sync_dir not found"
if bn_path_is_under "$sync_dir" "$vault" || bn_path_is_under "$vault" "$sync_dir"; then
  bn_die "refusing: the synced folder $sync_dir and the vault $vault overlap; raw exports must stay outside the vault"
fi
converter=$vault/bin/binnacle-forms-to-inbox
[ -x "$converter" ] || bn_die "$converter not found"

if [ "${#forms[@]}" -eq 0 ]; then
  while IFS= read -r -d '' d; do forms+=("${d##*/}"); done \
    < <(find "$sync_dir" -mindepth 1 -maxdepth 1 -type d ! -name '.*' -print0 | LC_ALL=C sort -z)
fi
[ "${#forms[@]}" -gt 0 ] || { bn_log "no form folders in $sync_dir: nothing to do"; exit 0; }

# read_conf FILE: set the conf_* variables from key=value lines. The file
# is parsed, never sourced.
read_conf() {
  local line key
  conf_form_title="" conf_form_id="" conf_audience="" conf_consent_notice_version=""
  conf_subject="" conf_identity="" conf_invited="" conf_platform=msforms
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case $line in "" | "#"*) continue ;; *=*) ;; *) bn_warn "$1: ignoring a line without '='"; continue ;; esac
    key=${line%%=*}
    case $key in
      form_title | form_id | audience | consent_notice_version | subject | identity | invited | platform)
        printf -v "conf_$key" '%s' "${line#*=}" ;;
      *) bn_warn "$1: ignoring unknown key '$key'" ;;
    esac
  done <"$1"
}

failed=0
for form in "${forms[@]}"; do
  case $form in "" | . | .. | */*) bn_warn "skipping '$form': not a folder name"; failed=1; continue ;; esac
  dir=$sync_dir/$form
  conf=$vault/.binnacle/forms/$form.conf
  bn_log "form $form"
  if [ ! -d "$dir" ]; then
    bn_warn "no folder $dir"
    failed=1
    continue
  fi
  files=()
  while IFS= read -r -d '' f; do files+=("$f"); done \
    < <(find "$dir" -mindepth 1 -maxdepth 1 -type f -name '*.csv' -print0 | LC_ALL=C sort -z)
  if [ "${#files[@]}" -eq 0 ]; then
    bn_ok "no new responses"
    continue
  fi
  if [ ! -f "$conf" ]; then
    bn_warn "${#files[@]} response file(s) waiting, but no settings file $conf (setup/forms/CHECKLIST.md); files kept"
    failed=1
    continue
  fi
  read_conf "$conf"
  args=(--vault "$vault" --platform "$conf_platform" --form-title "$conf_form_title"
    --form-id "$conf_form_id" --audience "$conf_audience"
    --consent-notice-version "$conf_consent_notice_version")
  [ -z "$conf_subject" ] || args+=(--subject "$conf_subject")
  [ -z "$conf_identity" ] || args+=(--identity "$conf_identity")
  [ -z "$conf_invited" ] || args+=(--invited "$conf_invited")
  if "$converter" "${args[@]}" "${files[@]}"; then
    rm -f -- "${files[@]}"
    bn_ok "${#files[@]} response file(s) converted and deleted from $dir"
  else
    bn_warn "not converted; the ${#files[@]} response file(s) stay in $dir"
    failed=1
  fi
done

if [ "$failed" -ne 0 ]; then
  bn_warn "some forms were not moved (see above)"
  exit 1
fi
bn_log "done. Review raw/inbox/forms/, then commit; nothing was committed"
