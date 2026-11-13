#!/usr/bin/env bash
# Move survey responses from the synced Forms folder into raw/inbox/forms/,
# through bin/binnacle-forms-to-inbox. On demand only; it never commits.
#
# Usage: setup/forms/mover.sh [--vault DIR] [--sync-dir DIR] [FORM...]
#        setup/forms/mover.sh [--vault DIR] [--sync-dir DIR] --purge FORM...
#   --vault     the vault (default: the vault this script belongs to)
#   --sync-dir  the synced folder the Power Automate flow writes to
#               (default: git config binnacle.formsSyncDir in the vault)
#   --purge     delete the FORMs' processed exports (once the window's note
#               is ingested); converts nothing
#   FORM        subfolders to process (default: every subfolder but processed)
#
# The synced folder holds one subfolder per form, where the flow writes one
# .csv file per response (setup/forms/CHECKLIST.md). Each form's settings
# live in the vault, in the gitignored <vault>/.binnacle/forms/<FORM>.conf,
# as key=value lines: form_title, form_id, audience,
# consent_notice_version (required), subject, identity, invited, platform
# (default msforms), from and to (the window, YYYY-MM-DD), date_order (dmy
# or mdy). For each form with new .csv files the converter rebuilds the
# window's one note from those and every earlier export of the window,
# kept in <sync dir>/processed/<FORM>/; once the note is written, the new
# files move there too, and the note this run replaces, if its window
# differed, is removed from raw/inbox/forms/. Exports are never deleted
# but by --purge. A refusal or error keeps the files where they are and
# moves on to the next form; the exit status is then 1. The synced folder
# must be outside the vault.
set -eu

here=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=../common/lib.sh
. "$here/../common/lib.sh"

usage() { sed -n '5,12p' "$0" | sed 's/^# \{0,1\}//'; }

vault="" sync_dir="" purge=0
forms=()
while [ "$#" -gt 0 ]; do
  case $1 in
    --vault | --sync-dir)
      [ "$#" -ge 2 ] || bn_die "$1 needs a value"
      if [ "$1" = --vault ]; then vault=$2; else sync_dir=$2; fi
      shift 2 ;;
    --purge) purge=1; shift ;;
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
inbox=$vault/raw/inbox/forms

if [ "$purge" -eq 1 ]; then
  [ "${#forms[@]}" -gt 0 ] || bn_die "--purge needs the FORM folders to purge"
  for form in "${forms[@]}"; do
    case $form in "" | . | .. | */*) bn_die "'$form' is not a folder name" ;; esac
    rm -rf -- "${sync_dir:?}/processed/$form"
    bn_ok "processed exports of $form deleted"
  done
  exit 0
fi

if [ "${#forms[@]}" -eq 0 ]; then
  while IFS= read -r -d '' d; do forms+=("${d##*/}"); done \
    < <(find "$sync_dir" -mindepth 1 -maxdepth 1 -type d ! -name '.*' ! -name processed -print0 | LC_ALL=C sort -z)
fi
[ "${#forms[@]}" -gt 0 ] || { bn_log "no form folders in $sync_dir: nothing to do"; exit 0; }

# read_conf FILE: set the conf_* variables from key=value lines. The file
# is parsed, never sourced.
read_conf() {
  local line key
  conf_form_title="" conf_form_id="" conf_audience="" conf_consent_notice_version=""
  conf_subject="" conf_identity="" conf_invited="" conf_platform=msforms
  conf_from="" conf_to="" conf_date_order=""
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    case $line in "" | "#"*) continue ;; *=*) ;; *) bn_warn "$1: ignoring a line without '='"; continue ;; esac
    key=${line%%=*}
    case $key in
      form_title | form_id | audience | consent_notice_version | subject | identity | invited | platform \
        | from | to | date_order)
        printf -v "conf_$key" '%s' "${line#*=}" ;;
      *) bn_warn "$1: ignoring unknown key '$key'" ;;
    esac
  done <"$1"
}

failed=0
for form in "${forms[@]}"; do
  case $form in "" | . | .. | */* | processed) bn_warn "skipping '$form': not a form folder name"; failed=1; continue ;; esac
  dir=$sync_dir/$form
  done_dir=$sync_dir/processed/$form
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
  earlier=()
  if [ -d "$done_dir" ]; then
    while IFS= read -r -d '' f; do earlier+=("$f"); done \
      < <(find "$done_dir" -mindepth 1 -maxdepth 1 -type f -name '*.csv' -print0 | LC_ALL=C sort -z)
  fi
  last_note=""
  [ ! -f "$done_dir/.note" ] || last_note=$(cat "$done_dir/.note")
  if [ "${#earlier[@]}" -gt 0 ] && { [ -z "$last_note" ] || [ ! -f "$inbox/$last_note" ]; }; then
    bn_warn "the ${#earlier[@]} processed export(s) in $done_dir belong to a note no longer in raw/inbox/forms/ (already ingested?); if that window is done, run setup/forms/mover.sh --purge $form, then the mover again; files kept"
    failed=1
    continue
  fi
  clash=""
  for f in "${files[@]}"; do [ ! -e "$done_dir/${f##*/}" ] || clash=${f##*/}; done
  if [ -n "$clash" ]; then
    bn_warn "$clash is already in $done_dir; rename or remove the new copy; files kept"
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
  [ -z "$conf_from" ] || args+=(--from "$conf_from")
  [ -z "$conf_to" ] || args+=(--to "$conf_to")
  [ -z "$conf_date_order" ] || args+=(--date-order "$conf_date_order")
  if out=$("$converter" "${args[@]}" "${earlier[@]+"${earlier[@]}"}" "${files[@]}"); then
    printf '%s\n' "$out"
    note=$(printf '%s\n' "$out" | sed -n 's|^binnacle-forms-to-inbox: wrote raw/inbox/forms/\([^ /]*\.md\) .*|\1|p')
    [ -n "$note" ] || bn_die "cannot tell which note the converter wrote for $form"
    mkdir -p "$done_dir"
    printf '%s\n' "$note" >"$done_dir/.note"
    if [ -n "$last_note" ] && [ "$last_note" != "$note" ]; then
      rm -f -- "${inbox:?}/$last_note"
      bn_ok "replaced raw/inbox/forms/$last_note"
    fi
    mv -- "${files[@]}" "$done_dir/"
    bn_ok "${#files[@]} new response file(s) converted with ${#earlier[@]} earlier one(s); all kept in $done_dir"
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
