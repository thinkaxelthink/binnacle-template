#!/usr/bin/env bash
# Self-test for the template's scripts. Touches nothing outside a temporary
# directory: throwaway git repos, stub `claude` and `gh`, no network.
#
# Usage: test/selftest.sh
# Uses a real gitleaks for one extra check when it is on PATH (or Homebrew),
# and shellcheck when it is on PATH.
# shellcheck disable=SC2016 # bash -c snippets expand their own "$1"
set -eu

here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(git -C "$here/.." rev-parse --show-toplevel)
T=$(mktemp -d "${TMPDIR:-/tmp}/binnacle-selftest.XXXXXX")
trap 'rm -rf "$T"' EXIT

passed=0
failed=0
ok() { passed=$((passed + 1)); printf 'ok     %s\n' "$*"; }
bad() { failed=$((failed + 1)); printf 'FAIL   %s\n' "$*"; }
check() { # description, command...
  local d=$1
  shift
  if "$@" >>"$T/check.log" 2>&1; then ok "$d"; else bad "$d"; fi
}

scripts=(.githooks/pre-commit bin/binnacle-run setup/common/lib.sh setup/common/install-hooks.sh
  setup/github/setup.sh setup/shoyu/setup.sh setup/workmac/setup.sh test/selftest.sh)

# --- static checks -------------------------------------------------------------
for s in "${scripts[@]}"; do
  check "bash -n $s" bash -n "$repo/$s"
done
if command -v shellcheck >/dev/null 2>&1; then
  check "shellcheck clean" bash -c 'cd "$1" && shift && shellcheck -x "$@"' _ "$repo" "${scripts[@]}"
else
  printf 'skip   shellcheck (not installed)\n'
fi

# --- fixture: seed repo -> bare remote -> vault clone ----------------------------
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$T/gitconfig"
git config --global user.name selftest
git config --global user.email selftest@example.invalid
git config --global init.defaultBranch main
git config --global advice.detachedHead false

mkdir -p "$T/seed" "$T/stubs"
(cd "$repo" && git ls-files -z -co --exclude-standard | tar --null -T - -cf -) | tar -xf - -C "$T/seed"
git -C "$T/seed" init -q
git -C "$T/seed" add -A
git -C "$T/seed" commit -qm seed
git clone -q --bare "$T/seed" "$T/remote.git"
git clone -q "$T/remote.git" "$T/vault"
V=$T/vault
git -C "$V" config core.hooksPath .githooks
git -C "$V" config binnacle.role wiki-writer

printf '#!/bin/sh\nexit 0\n' >"$T/stubs/gitleaks-pass"
printf '#!/bin/sh\necho "leak found" >&2\nexit 1\n' >"$T/stubs/gitleaks-fail"
printf '#!/bin/sh\n: >"$STUB_MARK"\nexit 0\n' >"$T/stubs/gitleaks-mark"

cat >"$T/stubs/gh" <<'EOF'
#!/bin/sh
echo "gh $*" >>"$STUB_LOG"
case "$1 $2" in
  "pr list") [ -n "${STUB_GH_OPEN:-}" ] && echo "https://github.com/example/binnacle/pull/9"; exit 0 ;;
  "pr create") echo "https://github.com/example/binnacle/pull/1"; exit 0 ;;
  "pr merge") exit 0 ;;
esac
exit 0
EOF

cat >"$T/stubs/claude" <<'EOF'
#!/bin/sh
# Stub Claude Code. $2 is the rendered prompt.
prompt=$2
echo "$prompt" | grep -q '{{' && { echo "unrendered placeholder" >&2; exit 9; }
echo "$prompt" | grep -q 'raw/sources/' || { echo "no sources in prompt" >&2; exit 9; }
note=$(echo "$prompt" | grep -o 'audit/runs/[0-9TZ]*\.md' | head -n 1)
[ -f "$note" ] || { echo "no audit note $note" >&2; exit 9; }
case "$STUB_CLAUDE_MODE" in
  crash) exit 3 ;;
esac
mkdir -p wiki/concepts
printf -- '---\ntype: concept\n---\n# Stub concept\n' >wiki/concepts/stub-concept.md
printf '\n## [2026-01-01] ingest | stub\n- lint: 1\n' >>wiki/log.md
awk '{ print } /^## Lint flags$/ { print ""; print "- **orphan** [[wiki/concepts/stub-concept]]: nothing links here" }' \
  "$note" >"$note.tmp" && mv "$note.tmp" "$note"
if [ "$STUB_CLAUDE_MODE" = zone ]; then
  echo "not allowed" >soundings/evil.md
  echo "tamper" >>"$(ls raw/sources/*/* | head -n 1)"
fi
exit 0
EOF
chmod +x "$T/stubs/"*

export BINNACLE_GITLEAKS=$T/stubs/gitleaks-pass
export BINNACLE_GH=$T/stubs/gh BINNACLE_CLAUDE=$T/stubs/claude STUB_LOG=$T/gh.log
: >"$T/gh.log"

commit_file() { # path, content -> commit on current branch
  mkdir -p "$(dirname "$V/$1")"
  printf '%s\n' "$2" >"$V/$1"
  git -C "$V" add -- "$1"
  git -C "$V" commit -qm "add $1"
}
reset_vault() {
  git -C "$V" reset -q --hard
  git -C "$V" clean -qfdx
}
expect_fail() { if "$@"; then return 1; else return 0; fi; }

# --- pre-commit hook ---------------------------------------------------------------
check "hook: small file commits" commit_file soundings/small.md "hello"
dd if=/dev/zero of="$V/raw/inbox/big.bin" bs=1048576 count=11 2>/dev/null
git -C "$V" add raw/inbox/big.bin
check "hook: rejects staged file over 10 MB" expect_fail git -C "$V" commit -qm big
reset_vault
check "hook: rejects when gitleaks flags" expect_fail env BINNACLE_GITLEAKS="$T/stubs/gitleaks-fail" \
  bash -c 'printf x >"$1/soundings/a.md" && git -C "$1" add -A && git -C "$1" commit -qm a' _ "$V"
reset_vault
check "hook: fails closed without gitleaks" expect_fail env BINNACLE_GITLEAKS="$T/missing" \
  bash -c 'printf x >"$1/soundings/b.md" && git -C "$1" add -A && git -C "$1" commit -qm b' _ "$V"
reset_vault

# GUI clients (Obsidian) run git with a minimal PATH: the hook must find the
# gitleaks path that install-hooks recorded, and still fail closed without one.
git_bin=$(command -v git)
mkdir -p "$T/emptyhome"
gui_commit() { # file -> commit with no BINNACLE_GITLEAKS, minimal PATH, empty HOME
  env -u BINNACLE_GITLEAKS HOME="$T/emptyhome" PATH=/usr/bin:/bin STUB_MARK="$T/mark" \
    bash -c 'printf x >"$2/soundings/$3" && "$1" -C "$2" add -A && "$1" -C "$2" commit -qm "$3"' _ "$git_bin" "$V" "$1"
}
git -C "$V" config binnacle.gitleaks "$T/stubs/gitleaks-mark"
check "hook: minimal PATH commits via recorded binnacle.gitleaks" gui_commit d.md
check "hook: minimal PATH ran the recorded gitleaks" test -f "$T/mark"
reset_vault
git -C "$V" config binnacle.gitleaks "$T/missing"
if [ -e /opt/homebrew/bin/gitleaks ] || [ -e /usr/local/bin/gitleaks ]; then
  printf 'skip   hook: minimal PATH fails closed (gitleaks in a system location)\n'
else
  check "hook: minimal PATH fails closed without gitleaks" expect_fail gui_commit e.md
fi
git -C "$V" config --unset binnacle.gitleaks
reset_vault

real_gl=$(PATH="$PATH:/opt/homebrew/bin:/usr/local/bin" command -v gitleaks || true)
if [ -n "$real_gl" ]; then
  fake="ghp_$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 36)"
  check "hook: real gitleaks rejects a GitHub token" expect_fail env BINNACLE_GITLEAKS="$real_gl" \
    bash -c 'printf "token = %s\n" "$2" >"$1/soundings/t.md" && git -C "$1" add -A && git -C "$1" commit -qm t' _ "$V" "$fake"
  reset_vault
  check "hook: real gitleaks accepts a clean note" env BINNACLE_GITLEAKS="$real_gl" \
    bash -c 'printf "just a thought\n" >"$1/soundings/c.md" && git -C "$1" add -A && git -C "$1" commit -qm c' _ "$V"
else
  printf 'skip   real gitleaks checks (not installed)\n'
fi
git -C "$V" push -q origin main

# --- bin/binnacle-run ------------------------------------------------------------------
run() { "$V/bin/binnacle-run" "$@" >"$T/run.out" 2>&1; }
no_run_branches() {
  [ -z "$(git -C "$V" branch --list 'binnacle-run/*')" ] \
    && [ -z "$(git ls-remote "$T/remote.git" 'refs/heads/binnacle-run/*')" ]
}
on_remote_branch() { # glob over files of the newest remote run branch
  local b
  b=$(git ls-remote "$T/remote.git" 'refs/heads/binnacle-run/*' | awk '{print $2}' | sort | tail -n 1)
  git -C "$V" fetch -q origin "$b:refs/remotes/origin/latest-run" --force
  git -C "$V" "$@"
}
note_on_branch() { on_remote_branch show "origin/latest-run:$(on_remote_branch ls-tree -r --name-only origin/latest-run -- audit/runs | grep '\.md$' | sort | tail -n 1)"; }

check "run: empty inbox exits 0" run
check "run: empty inbox says nothing to do" grep -q 'nothing to do' "$T/run.out"
check "run: empty inbox creates no branch" no_run_branches
check "run: empty inbox makes no GitHub call" test ! -s "$T/gh.log"

git -C "$V" config binnacle.role capture
check "run: refuses on a capture-only clone" expect_fail run
git -C "$V" config binnacle.role wiki-writer

commit_file raw/inbox/first-idea.md "An idea worth keeping."
git -C "$V" push -q origin main
check "run --dry-run: exits 0" run --dry-run
check "run --dry-run: lists the source" grep -q 'raw/inbox/first-idea.md' "$T/run.out"
check "run --dry-run: creates no branch" no_run_branches

main_before=$(git -C "$V" rev-parse HEAD)
check "run: ok run exits 0" env STUB_CLAUDE_MODE=ok bash -c '"$1/bin/binnacle-run" >"$2" 2>&1' _ "$V" "$T/run.out"
check "run: local checkout left on main, untouched" test "$(git -C "$V" rev-parse HEAD)" = "$main_before"
check "run: temporary worktree removed" test "$(git -C "$V" worktree list | wc -l | tr -d ' ')" = 1
on_remote_branch ls-tree -r --name-only origin/latest-run >"$T/tree" 2>&1 || true
check "run: source moved to raw/sources/<run-id>/" grep -Eq '^raw/sources/[0-9TZ]+/first-idea\.md$' "$T/tree"
check "run: inbox emptied on the run branch" bash -c '! grep -q "^raw/inbox/first-idea.md$" "$1"' _ "$T/tree"
note_on_branch >"$T/note" 2>&1 || true
check "run: audit note status ok" grep -q '^status: ok$' "$T/note"
check "run: audit note PR link" grep -q '^pr: "https://github.com/example/binnacle/pull/1"$' "$T/note"
check "run: audit note merged pending" grep -q '^merged: pending$' "$T/note"
check "run: audit note counts lint flags" grep -q '^lint_flags: 1$' "$T/note"
check "run: audit note lists created page" grep -q '^  - "\[\[wiki/concepts/stub-concept\]\]"$' "$T/note"
check "run: auto-merge enabled" grep -q 'pr merge https://github.com/example/binnacle/pull/1 --auto --squash' "$T/gh.log"

# Merge that run into main, then queue another source.
git -C "$V" merge -q --ff-only origin/latest-run
git -C "$V" push -q origin main
commit_file raw/inbox/second-idea.md "Another idea."
git -C "$V" push -q origin main

check "run: refuses while a run PR is open" expect_fail env STUB_GH_OPEN=1 STUB_CLAUDE_MODE=ok "$V/bin/binnacle-run"

: >"$T/gh.log"
sleep 1
check "run: zone violation exits non-zero" expect_fail env STUB_CLAUDE_MODE=zone "$V/bin/binnacle-run"
on_remote_branch ls-tree -r --name-only origin/latest-run >"$T/tree" 2>&1 || true
note_on_branch >"$T/note" 2>&1 || true
check "run: zone violation recorded as failed" grep -q '^status: failed$' "$T/note"
check "run: zone violation names the path" grep -q 'soundings/evil.md' "$T/note"
check "run: out-of-zone file not pushed" bash -c '! grep -q "^soundings/evil.md$" "$1"' _ "$T/tree"
check "run: raw source left unchanged" bash -c 'f=$(grep "/first-idea.md$" "$2"); test "$(git -C "$1" show "origin/latest-run:$f")" = "An idea worth keeping."' _ "$V" "$T/tree"
check "run: failed run PR still opened" grep -q 'pr create' "$T/gh.log"
check "run: failed run gets no auto-merge" bash -c '! grep -q "pr merge" "$1"' _ "$T/gh.log"
check "run: earlier merged run marked merged" bash -c 'f=$(git -C "$1" ls-tree -r --name-only origin/latest-run -- audit/runs | grep "\.md$" | sort | head -n 1); git -C "$1" show "origin/latest-run:$f" | grep -q "^merged: true$"' _ "$V"

: >"$T/gh.log"
sleep 1
check "run: Claude failure exits non-zero" expect_fail env STUB_CLAUDE_MODE=crash "$V/bin/binnacle-run"
note_on_branch >"$T/note" 2>&1 || true
check "run: Claude failure reason recorded" grep -q 'Claude Code exited with status 3' "$T/note"

# --- setup scripts ---------------------------------------------------------------------
lib=$repo/setup/common/lib.sh
check "lib: 1.13.0 >= 1.13" bash -c '. "$1"; bn_version_ge 1.13.0 1.13' _ "$lib"
check "lib: 1.9.10 < 1.13" expect_fail bash -c '. "$1"; bn_version_ge 1.9.10 1.13' _ "$lib"
mkdir -p "$T/home/Documents/Employer-Docs"
ln -s "$T/home/Documents/Employer-Docs" "$T/home/work-link"
check "workmac: refuses to run when the work folder is unset" expect_fail env HOME="$T/home" \
  BINNACLE_DIR="$T/home/binnacle" "$repo/setup/workmac/setup.sh"
check "workmac: unset work folder creates no clone" test ! -e "$T/home/binnacle"
# shellcheck disable=SC2088 # a literal ~ is what the setup script must expand
git config --global binnacle.workDocs "~/Documents/Employer-Docs"
check "workmac: refuses a clone inside the work folder" expect_fail env HOME="$T/home" \
  BINNACLE_DIR="$T/home/Documents/employer-docs/binnacle" "$repo/setup/workmac/setup.sh"
check "workmac: refuses a symlink into the work folder" expect_fail env HOME="$T/home" \
  BINNACLE_DIR="$T/home/work-link/binnacle" "$repo/setup/workmac/setup.sh"
check "workmac: marks an existing clone capture-only" env HOME="$T/home" BINNACLE_DIR="$V" \
  BINNACLE_OWNER="${T##*/}" BINNACLE_REPO=remote "$repo/setup/workmac/setup.sh"
check "workmac: role is capture" test "$(git -C "$V" config binnacle.role)" = capture
check "install-hooks: idempotent" bash -c '"$1" "$2" && "$1" "$2"' _ "$repo/setup/common/install-hooks.sh" "$V"
stubs_phys=$(cd "$T/stubs" && pwd -P)
check "install-hooks: records the gitleaks path" \
  test "$(git -C "$V" config binnacle.gitleaks)" = "$stubs_phys/gitleaks-pass"
check "install-hooks: updates the recorded path when gitleaks moves" bash -c \
  'BINNACLE_GITLEAKS="$3/gitleaks-mark" "$1" "$2" && test "$(git -C "$2" config binnacle.gitleaks)" = "$3/gitleaks-mark"' \
  _ "$repo/setup/common/install-hooks.sh" "$V" "$stubs_phys"
check "github --dry-run: changes nothing, names the check" bash -c \
  '"$1" --dry-run | grep -q "\"context\": \"gitleaks\""' _ "$repo/setup/github/setup.sh"

printf '\n%s passed, %s failed\n' "$passed" "$failed"
if [ "$failed" -gt 0 ]; then
  printf 'details: last check output follows\n' >&2
  tail -n 40 "$T/check.log" >&2
  exit 1
fi
