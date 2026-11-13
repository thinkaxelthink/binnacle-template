#!/usr/bin/env bash
# Schedule, pause or inspect the nightly AI run on shoyu. Idempotent.
#
# Usage: setup/shoyu/nightly.sh install|uninstall|status
#
#   install    render setup/shoyu/launchd/com.binnacle.nightly.plist for
#              this vault into ~/Library/LaunchAgents and load it in your
#              GUI launchd domain (launchctl bootstrap gui/<uid>; no sudo).
#              It runs bin/binnacle-nightly daily at the chosen local time.
#              Re-run it to change the time.
#   uninstall  unload the LaunchAgent and delete its plist (pauses nightly
#              runs; install again to resume).
#   status     whether it is installed and loaded, its time, the last exit
#              code launchd saw, and the last run in the nightly log.
#
# Env:   BINNACLE_DIR (~/binnacle), BINNACLE_NIGHTLY_HOUR (3),
#        BINNACLE_NIGHTLY_MINUTE (30): local time, 24-hour clock.
#
# setup/shoyu/setup.sh never runs this: scheduling is a separate, explicit
# step once the owner approves the time (CHECKLIST.md, "Nightly runs").
set -eu

here=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=../common/lib.sh
. "$here/../common/lib.sh"

label=com.binnacle.nightly
template=$here/launchd/$label.plist
agents=$HOME/Library/LaunchAgents
dest=$agents/$label.plist
log_dir=$HOME/Library/Logs/binnacle
domain=gui/$(id -u)
service=$domain/$label

usage() { sed -n '2,/^set -eu/p' "$0" | sed '$d; s/^# \{0,1\}//'; }

loaded() { launchctl print "$service" >/dev/null 2>&1; }

unload() {
  local i
  loaded || return 0
  launchctl bootout "$service" || bn_die "launchctl bootout $service failed"
  # bootout returns before the job is gone; bootstrap fails until it is.
  for i in 1 2 3 4 5 6 7 8 9 10; do
    loaded || return 0
    sleep 1
  done
  bn_die "$service is still loaded after bootout"
}

# Two-digit hour and minute from the installed plist, e.g. 03:30.
installed_time() {
  awk '/<key>(Hour|Minute)<\/key>/ { getline; gsub(/[^0-9]/, ""); printf "%s%02d", sep, $0; sep = ":" }' "$dest"
}

xml_escape() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

number_in() { # value, min, max, name -> prints the value without leading zeros
  case $1 in '' | *[!0-9]*) bn_die "$4 must be a number from $2 to $3, not '$1'" ;; esac
  if [ "$((10#$1))" -lt "$2" ] || [ "$((10#$1))" -gt "$3" ]; then
    bn_die "$4 must be a number from $2 to $3, not '$1'"
  fi
  printf '%s' "$((10#$1))"
}

cmd_install() {
  local hour minute role wrapper wrapper_xml tmp
  command -v launchctl >/dev/null 2>&1 || bn_die "launchctl not found: the nightly LaunchAgent is for macOS (shoyu)"
  hour=$(number_in "${BINNACLE_NIGHTLY_HOUR:-3}" 0 23 BINNACLE_NIGHTLY_HOUR)
  minute=$(number_in "${BINNACLE_NIGHTLY_MINUTE:-30}" 0 59 BINNACLE_NIGHTLY_MINUTE)
  role=$(git -C "$BINNACLE_DIR" config --get binnacle.role 2>/dev/null || true)
  [ "$role" = wiki-writer ] \
    || bn_die "$BINNACLE_DIR has binnacle.role '${role:-unset}', not wiki-writer: nightly runs belong on shoyu (run setup/shoyu/setup.sh first)"
  wrapper=$(bn_physical_path "$BINNACLE_DIR/bin/binnacle-nightly")
  if [ ! -f "$wrapper" ] || [ ! -x "$wrapper" ]; then bn_die "$wrapper is missing or not executable"; fi
  [ -f "$template" ] || bn_die "missing template $template"
  wrapper_xml=$(xml_escape "$wrapper")

  if [ -f "$dest" ] && ! grep -qF "<string>$wrapper_xml</string>" "$dest"; then
    bn_die "$dest already schedules another vault; run uninstall (with that vault's BINNACLE_DIR) first"
  fi

  bn_log "render $label ($(printf '%02d:%02d' "$hour" "$minute") local)"
  mkdir -p "$agents" "$log_dir"
  tmp=$(mktemp "$agents/.$label.XXXXXX")
  BN_NIGHTLY=$wrapper_xml BN_HOUR=$hour BN_MINUTE=$minute BN_LOG_DIR=$(xml_escape "$log_dir") awk '
    function rep(s, k, v,   i, out) {
      out = ""
      while ((i = index(s, k)) > 0) { out = out substr(s, 1, i - 1) v; s = substr(s, i + length(k)) }
      return out s
    }
    {
      line = rep($0, "{{NIGHTLY}}", ENVIRON["BN_NIGHTLY"])
      line = rep(line, "{{HOUR}}", ENVIRON["BN_HOUR"])
      line = rep(line, "{{MINUTE}}", ENVIRON["BN_MINUTE"])
      line = rep(line, "{{LOG_DIR}}", ENVIRON["BN_LOG_DIR"])
      print line
    }' "$template" >"$tmp"
  if command -v plutil >/dev/null 2>&1; then
    plutil -lint -s "$tmp" || { rm -f "$tmp"; bn_die "rendered plist does not lint"; }
  fi
  chmod 644 "$tmp"

  unload
  mv -f "$tmp" "$dest"
  bn_ok "$dest"
  launchctl enable "$service" || bn_die "launchctl enable $service failed"
  launchctl bootstrap "$domain" "$dest" || bn_die "launchctl bootstrap $domain $dest failed"
  bn_ok "loaded in $domain: $wrapper runs daily at $(installed_time) local"
  bn_log "log: $log_dir/nightly.log; pause with: $0 uninstall"
}

cmd_uninstall() {
  command -v launchctl >/dev/null 2>&1 || bn_die "launchctl not found: the nightly LaunchAgent is for macOS (shoyu)"
  unload
  rm -f "$dest"
  bn_ok "$label unloaded and removed: no nightly runs until install"
}

cmd_status() {
  bn_log "$label"
  if [ -f "$dest" ]; then
    bn_ok "installed: $dest (daily at $(installed_time) local)"
  else
    bn_ok "not installed (no $dest)"
  fi
  if command -v launchctl >/dev/null 2>&1 && loaded; then
    bn_ok "loaded in $domain"
    launchctl print "$service" | grep -E '^[[:space:]]*(runs|last exit code) = ' | sed 's/^[[:space:]]*/  ok   /' || true
  else
    bn_ok "not loaded"
  fi
  if [ -f "$log_dir/nightly.log" ]; then
    bn_log "last run ($log_dir/nightly.log)"
    grep '^=== ' "$log_dir/nightly.log" | tail -n 2
  else
    bn_ok "no nightly log yet ($log_dir/nightly.log)"
  fi
}

case "${1:-}" in
  install) cmd_install ;;
  uninstall) cmd_uninstall ;;
  status) cmd_status ;;
  -h | --help) usage ;;
  *) usage >&2; exit 2 ;;
esac
