#!/usr/bin/env bash
# Move survey responses from the synced Forms folder into raw/inbox/forms/,
# through bin/binnacle-forms-to-inbox. On demand only; it never commits.
#
# Usage: setup/forms/mover.sh [--vault DIR] [--sync-dir DIR] [FORM...]
#        setup/forms/mover.sh [--vault DIR] [--sync-dir DIR] --purge FORM...
#   --vault     the vault (default: the vault this script belongs to)
#   --sync-dir  the synced folder the Power Automate flow writes to
#               (default: git config binnacle.formsSyncDir in the vault)
#   --purge     delete the FORMs' processed exports; refused while the
#               last window's note is still in raw/inbox/forms/
#   FORM        subfolders to process (default: every subfolder but processed)
#
# The synced folder holds one subfolder per form, where the flow writes one
# .csv file per response (setup/forms/CHECKLIST.md). Each form's settings
# live in the vault, in the gitignored <vault>/.binnacle/forms/<FORM>.conf,
# as key=value lines: form_title, form_id, audience, consent_notice_version,
# from and to (the window, YYYY-MM-DD) (required), subject, identity,
# invited, platform (default msforms), date_order (dmy or mdy). For each
# form with new .csv files the converter rebuilds the window's one note
# from those and the window's earlier exports, kept in
# <sync dir>/processed/<FORM>/<from>-to-<to>/, then the new files move
# there too. While the last window's note is still in raw/inbox/forms/,
# from/to may change only to a window that contains it: the note is then
# rebuilt under the wider window from all its exports, which move to the
# new window's folder, and the old-named note is removed. The form is
# refused, nothing changed, when its settings lack from or to, when a
# response is dated outside the window, when from/to change to a window
# that does not contain the waiting note's, or when the window overlaps
# one whose note has already left the inbox (every window written is
# listed in processed/<FORM>/.windows). Exports are never deleted but by
# --purge. A refusal or error keeps the files
# where they are and moves on to the next form; the exit status is then 1.
# The synced folder must be outside the vault.
set -eu

here=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=../common/lib.sh
. "$here/../common/lib.sh"

usage() { sed -n '5,12p' "$0" | sed 's/^# \{0,1\}//'; }

# last_written FORM: set last_window and last_note from the form's record
# of the note it last wrote.
last_written() {
  last_window="" last_note=""
  if [ -f "$sync_dir/processed/$1/.note" ]; then
    read -r last_window last_note <"$sync_dir/processed/$1/.note" || true
  fi
}

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
  failed=0
  for form in "${forms[@]}"; do
    case $form in "" | . | .. | */* | processed) bn_warn "skipping '$form': not a form folder name"; failed=1; continue ;; esac
    last_written "$form"
    if [ -n "$last_note" ] && [ -f "$inbox/$last_note" ]; then
      bn_warn "not purging $form: its note raw/inbox/forms/$last_note is not ingested yet"
      failed=1
      continue
    fi
    [ ! -d "$sync_dir/processed/$form" ] \
      || find "$sync_dir/processed/$form" -mindepth 1 -maxdepth 1 -type d -exec rm -rf -- {} +
    bn_ok "processed exports of $form deleted"
  done
  exit "$failed"
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
  ymd='[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
  # shellcheck disable=SC2254 # $ymd is a pattern
  case $conf_from:$conf_to in
    $ymd:$ymd) ;;
    *)
      bn_warn "$conf needs the window as from=YYYY-MM-DD and to=YYYY-MM-DD; files kept"
      failed=1
      continue ;;
  esac
  window=$conf_from-to-$conf_to
  form_dir=$sync_dir/processed/$form
  done_dir=$form_dir/$window
  last_written "$form"
  widen=""
  if [ -n "$last_note" ] && [ -f "$inbox/$last_note" ]; then
    if [ "$last_window" != "$window" ]; then
      if [[ $conf_from > ${last_window%%-to-*} || $conf_to < ${last_window##*-to-} ]]; then
        bn_warn "the note for window $last_window, raw/inbox/forms/$last_note, is not ingested yet; until it is, from/to may only widen to contain it, not change to $window; files kept"
        failed=1
        continue
      fi
      widen=$last_window
    fi
    skip=$last_window
  else
    skip=""
  fi
  overlap=""
  if [ -f "$form_dir/.windows" ]; then
    while IFS= read -r w || [ -n "$w" ]; do
      [ -n "$w" ] && [ "$w" != "$skip" ] || continue
      [[ $conf_from > ${w##*-to-} || $conf_to < ${w%%-to-*} ]] || overlap=$w
    done <"$form_dir/.windows"
  fi
  if [ -n "$overlap" ]; then
    bn_warn "window $window overlaps window $overlap, whose note has already left raw/inbox/forms/; set from= and to= for a later window, or remove the late file(s) from $dir; files kept"
    failed=1
    continue
  fi
  earlier_dir=$form_dir/${widen:-$window}
  earlier=()
  if [ -d "$earlier_dir" ]; then
    while IFS= read -r -d '' f; do earlier+=("$f"); done \
      < <(find "$earlier_dir" -mindepth 1 -maxdepth 1 -type f -name '*.csv' -print0 | LC_ALL=C sort -z)
  fi
  clash=""
  for f in "${files[@]}"; do [ ! -e "$earlier_dir/${f##*/}" ] || clash=${f##*/}; done
  if [ -n "$clash" ]; then
    bn_warn "$clash is already in $earlier_dir; rename or remove the new copy; files kept"
    failed=1
    continue
  fi
  args=(--vault "$vault" --platform "$conf_platform" --form-title "$conf_form_title"
    --form-id "$conf_form_id" --audience "$conf_audience"
    --consent-notice-version "$conf_consent_notice_version"
    --from "$conf_from" --to "$conf_to" --within-window)
  [ -z "$conf_subject" ] || args+=(--subject "$conf_subject")
  [ -z "$conf_identity" ] || args+=(--identity "$conf_identity")
  [ -z "$conf_invited" ] || args+=(--invited "$conf_invited")
  [ -z "$conf_date_order" ] || args+=(--date-order "$conf_date_order")
  if out=$("$converter" "${args[@]}" "${earlier[@]+"${earlier[@]}"}" "${files[@]}"); then
    printf '%s\n' "$out"
    note=$(printf '%s\n' "$out" | sed -n 's|^binnacle-forms-to-inbox: wrote raw/inbox/forms/\([^ /]*\.md\) .*|\1|p')
    [ -n "$note" ] || bn_die "cannot tell which note the converter wrote for $form"
    mkdir -p "$done_dir"
    if [ -n "$widen" ]; then
      [ "${#earlier[@]}" -eq 0 ] || mv -- "${earlier[@]}" "$done_dir/"
      rmdir -- "$earlier_dir" 2>/dev/null || true
      grep -vxF -- "$widen" "$form_dir/.windows" >"$form_dir/.windows.tmp" || true
      mv -- "$form_dir/.windows.tmp" "$form_dir/.windows"
    fi
    printf '%s %s\n' "$window" "$note" >"$form_dir/.note"
    grep -qxF -- "$window" "$form_dir/.windows" 2>/dev/null || printf '%s\n' "$window" >>"$form_dir/.windows"
    if [ -n "$widen" ] && [ "$last_note" != "$note" ]; then
      rm -f -- "${inbox:?}/$last_note"
      bn_ok "replaced raw/inbox/forms/$last_note with $note"
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
