# shellcheck shell=bash
# Shared helpers for the Binnacle setup scripts. Source it; do not run it.

BINNACLE_OWNER=${BINNACLE_OWNER:-thinkaxelthink}
BINNACLE_REPO=${BINNACLE_REPO:-binnacle}
BINNACLE_DIR=${BINNACLE_DIR:-$HOME/binnacle}
BINNACLE_MIN_OBSIDIAN=${BINNACLE_MIN_OBSIDIAN:-1.13}

bn_log() { printf '==> %s\n' "$*"; }
bn_ok() { printf '  ok   %s\n' "$*"; }
bn_warn() { printf '  WARN %s\n' "$*" >&2; }
bn_die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

# Print the absolute path of a usable gitleaks binary, or nothing.
# Looks at BINNACLE_GITLEAKS (when set, the only candidate), PATH, then the
# per-user (~/.local/bin) and Homebrew install locations, the same places
# .githooks/pre-commit searches.
bn_find_gitleaks() {
  local c
  if [ -n "${BINNACLE_GITLEAKS:-}" ]; then
    if [ -f "$BINNACLE_GITLEAKS" ] && [ -x "$BINNACLE_GITLEAKS" ]; then
      bn_physical_path "$BINNACLE_GITLEAKS"
    fi
    return 0
  fi
  for c in "$(command -v gitleaks || true)" "$HOME/.local/bin/gitleaks" \
    /opt/homebrew/bin/gitleaks /usr/local/bin/gitleaks; do
    if [ -n "$c" ] && [ -f "$c" ] && [ -x "$c" ]; then
      bn_physical_path "$c"
      return 0
    fi
  done
  return 0
}

# bn_version_ge A B: succeed when dotted version A >= B.
bn_version_ge() {
  local IFS=.
  # shellcheck disable=SC2206 # splitting on dots is the point
  local a=($1) b=($2) i x y
  for i in 0 1 2 3; do
    x=${a[i]:-0}
    y=${b[i]:-0}
    x=${x%%[!0-9]*}
    y=${y%%[!0-9]*}
    x=${x:-0}
    y=${y:-0}
    if [ "$x" -gt "$y" ]; then return 0; fi
    if [ "$x" -lt "$y" ]; then return 1; fi
  done
  return 0
}

# Print the installed Obsidian app version (macOS), or nothing.
# Obsidian updates itself through obsidian-<version>.asar files, so the
# newest of those wins over the installer version in Info.plist.
bn_obsidian_version() {
  local best="" v f plist=/Applications/Obsidian.app/Contents/Info.plist
  if [ -f "$plist" ]; then
    best=$(defaults read "${plist%.plist}" CFBundleShortVersionString 2>/dev/null || true)
  fi
  for f in "$HOME/Library/Application Support/obsidian"/obsidian-*.asar; do
    [ -e "$f" ] || continue
    v=${f##*/obsidian-}
    v=${v%.asar}
    if [ -z "$best" ] || bn_version_ge "$v" "$best"; then best=$v; fi
  done
  [ -n "$best" ] && printf '%s\n' "$best"
  return 0
}

# Print the physical (symlink-free) form of a path that may not exist yet.
bn_physical_path() {
  local p=$1 rest=""
  case $p in /*) ;; *) p="$PWD/$p" ;; esac
  while [ ! -d "$p" ]; do
    rest="/${p##*/}$rest"
    p=${p%/*}
    [ -n "$p" ] || p=/
  done
  printf '%s%s\n' "$(cd -P "$p" && pwd -P)" "$rest" | sed 's#//*#/#g'
}

# bn_path_is_under PATH DIR: succeed when PATH is DIR or inside it,
# compared case-insensitively (APFS default) after resolving symlinks.
bn_path_is_under() {
  local p d
  p=$(bn_physical_path "$1" | tr '[:upper:]' '[:lower:]')
  d=$(bn_physical_path "$2" | tr '[:upper:]' '[:lower:]')
  d=${d%/}
  case "$p/" in "$d"/*) return 0 ;; esac
  return 1
}

# Clone the vault to BINNACLE_DIR, or verify an existing clone.
bn_clone_vault() {
  local url="https://github.com/$BINNACLE_OWNER/$BINNACLE_REPO.git" origin
  if [ -d "$BINNACLE_DIR/.git" ]; then
    origin=$(git -C "$BINNACLE_DIR" remote get-url origin 2>/dev/null || true)
    case $origin in
      *"$BINNACLE_OWNER/$BINNACLE_REPO"|*"$BINNACLE_OWNER/$BINNACLE_REPO.git")
        bn_ok "vault clone present at $BINNACLE_DIR" ;;
      *) bn_die "$BINNACLE_DIR is a git repo whose origin is '$origin', not $BINNACLE_OWNER/$BINNACLE_REPO" ;;
    esac
  elif [ -e "$BINNACLE_DIR" ]; then
    bn_die "$BINNACLE_DIR exists but is not a git clone; move it aside first"
  else
    bn_log "cloning $url to $BINNACLE_DIR"
    git clone "$url" "$BINNACLE_DIR"
  fi
}

# Set the commit identity in the vault clone only, never --global. Without
# one, git falls back to user@<hostname> and leaks the machine's network
# name into every vault commit. user.name: BINNACLE_GIT_NAME, else the
# existing vault-local name, else BINNACLE_OWNER. user.email:
# BINNACLE_GIT_EMAIL, else the existing vault-local email, else
# BINNACLE_OWNER@users.noreply.github.com.
bn_set_git_identity() {
  local git_name git_email
  git_name=${BINNACLE_GIT_NAME:-$(git -C "$BINNACLE_DIR" config --local user.name 2>/dev/null || true)}
  git_name=${git_name:-$BINNACLE_OWNER}
  git_email=${BINNACLE_GIT_EMAIL:-$(git -C "$BINNACLE_DIR" config --local user.email 2>/dev/null || true)}
  git_email=${git_email:-$BINNACLE_OWNER@users.noreply.github.com}
  git -C "$BINNACLE_DIR" config --local user.name "$git_name"
  git -C "$BINNACLE_DIR" config --local user.email "$git_email"
  bn_ok "commits in $BINNACLE_DIR authored as $git_name <$git_email>"
}
