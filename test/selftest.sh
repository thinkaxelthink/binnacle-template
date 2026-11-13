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

scripts=(.githooks/pre-commit bin/binnacle-run bin/binnacle-import bin/binnacle-nightly setup/common/lib.sh
  setup/common/install-hooks.sh setup/github/setup.sh setup/shoyu/setup.sh setup/shoyu/nightly.sh
  setup/workmac/setup.sh setup/work-brain/lib.sh setup/work-brain/setup.sh setup/work-brain/connect-remote.sh
  test/selftest.sh)

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
[ -z "${STUB_TOKEN_LOG:-}" ] || echo "token=${GH_TOKEN:-}" >>"$STUB_TOKEN_LOG"
case "$1 $2" in
  "pr list") [ -n "${STUB_GH_OPEN:-}" ] && echo "https://github.com/example/binnacle/pull/9"; exit 0 ;;
  "pr create")
    prev=
    for a in "$@"; do [ "$prev" = --body-file ] && cp "$a" "$STUB_BODY"; prev=$a; done
    echo "https://github.com/example/binnacle/pull/1"; exit 0 ;;
  "pr merge") exit 0 ;;
  "api --paginate")
    [ "${STUB_ORG_APPS:-}" = FAIL ] && exit 1
    [ -n "${STUB_ORG_APPS:-}" ] || exit 0
    prev=
    for a in "$@"; do [ "$prev" = --jq ] && q=$a; prev=$a; done
    jq -r "$q" "$STUB_ORG_APPS"; exit ;;
  "api orgs/"*) [ "${STUB_ORG_PERM:-}" = FAIL ] && exit 1; echo "${STUB_ORG_PERM:-}"; exit 0 ;;
  "api repos/"*) [ -n "${STUB_REPO_PRIVATE:-}" ] || exit 1; echo "$STUB_REPO_PRIVATE"; exit 0 ;;
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
export STUB_BODY=$T/pr-body.md
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

# A Notion import in progress (binnacle.importBranch) makes the run skip,
# even with sources waiting. A local import/* branch left after an import
# does not.
git -C "$V" config binnacle.importBranch import/notion-20261113
check "import: binnacle.importBranch set -> run exits 0" run
check "import: says skipped: import in progress" grep -q 'skipped: import in progress' "$T/run.out"
check "import: --dry-run skips too" bash -c '"$1/bin/binnacle-run" --dry-run >"$2" 2>&1 && grep -q "skipped: import in progress" "$2"' _ "$V" "$T/run.out"
git -C "$V" config --unset binnacle.importBranch
git -C "$V" branch import/notion/20261113
check "import: leftover import/* branch -> --dry-run exits 0" run --dry-run
check "import: leftover import/* branch does not skip" bash -c '! grep -q "skipped" "$1"' _ "$T/run.out"
check "import: leftover import/* branch still lists the source" grep -q 'raw/inbox/first-idea.md' "$T/run.out"
git -C "$V" branch -q -D import/notion/20261113
check "import: skips create no run branch" no_run_branches
check "import: skips make no GitHub call" test ! -s "$T/gh.log"

# One run at a time: a lock directory under .git holding the owner's PID.
lock=$V/.git/binnacle-run.lock
mkdir -p "$T/holder"
printf '#!/bin/sh\nsleep 60\nexit 0\n' >"$T/holder/binnacle-run"
chmod +x "$T/holder/binnacle-run"
"$T/holder/binnacle-run" &
holder=$!
mkdir "$lock"
echo "$holder" >"$lock/pid"
check "lock: a live run makes a second run skip (exit 0)" run
check "lock: says skipped: another binnacle-run, with its pid" \
  grep -q "skipped: another binnacle-run is in progress (pid $holder;" "$T/run.out"
check "lock: overlap creates no run branch" no_run_branches
check "lock: overlap makes no GitHub call" test ! -s "$T/gh.log"
check "lock: the live run's lock is left alone" test "$(cat "$lock/pid")" = "$holder"
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
# A live PID that is not a binnacle-run (PID reuse) counts as stale.
echo "$$" >"$lock/pid"

main_before=$(git -C "$V" rev-parse HEAD)
# Obsidian Git's refs: the run must read origin's main without updating them.
# A stale origin/main (inbox still empty there) proves the run used its own ref.
git -C "$V" update-ref refs/remotes/origin/main "$main_before~1"
rm -f "$V/.git/FETCH_HEAD"
check "run: ok run exits 0" env STUB_CLAUDE_MODE=ok bash -c '"$1/bin/binnacle-run" >"$2" 2>&1' _ "$V" "$T/run.out"
check "lock: stale lock (PID not a binnacle-run) broken" grep -q "removed a stale lock (pid $$)" "$T/run.out"
check "lock: released after a run" test ! -e "$lock"
check "lock: nothing left beside it" bash -c '! ls "$1/.git" | grep -q binnacle-run.lock' _ "$V"
check "run: local checkout left on main, untouched" test "$(git -C "$V" rev-parse HEAD)" = "$main_before"
check "run: refs/remotes/origin/main not updated" test "$(git -C "$V" rev-parse refs/remotes/origin/main)" = "$(git -C "$V" rev-parse "$main_before~1")"
check "run: FETCH_HEAD not written" test ! -e "$V/.git/FETCH_HEAD"
git -C "$V" update-ref refs/remotes/origin/main "$main_before"
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

# GitHub token: keychain first, then binnacle.ghTokenFile; GH_TOKEN in the
# environment wins over both. An open run PR stops each run right after the
# lookup, so the stub gh records which token it got and nothing else happens.
mkdir -p "$T/nokeychain"
printf '#!/bin/sh\necho "User interaction is not allowed." >&2\nexit 36\n' >"$T/nokeychain/security"
chmod +x "$T/nokeychain/security"
tokfile=$T/gh-token
printf 'file-token-123\n' >"$tokfile"
chmod 600 "$tokfile"
git -C "$V" config binnacle.ghTokenFile "$tokfile"
token_run() { # extra env... -> run output in $T/run.out, token gh saw in $T/token.log
  : >"$T/token.log"
  env -u GH_TOKEN PATH="$T/nokeychain:$PATH" STUB_GH_OPEN=1 STUB_TOKEN_LOG="$T/token.log" "$@" \
    bash -x "$V/bin/binnacle-run" >"$T/run.out" 2>&1 || true
}
token_run
check "token: file used when the keychain is unreachable" grep -qx 'token=file-token-123' "$T/token.log"
check "token: newline stripped, value never printed (even under bash -x)" \
  bash -c '! grep -q file-token-123 "$1"' _ "$T/run.out"
chmod 640 "$tokfile"
token_run
check "token: file with group/other access refused" grep -q 'refusing binnacle.ghTokenFile' "$T/run.out"
check "token: refused file never reaches gh" test ! -s "$T/token.log"
chmod 600 "$tokfile"
token_run GH_TOKEN=env-token-456
check "token: GH_TOKEN from the environment wins" grep -qx 'token=env-token-456' "$T/token.log"
git -C "$V" config --unset binnacle.ghTokenFile

: >"$T/gh.log"
sleep 1
sh -c 'exit 0' &
dead=$!
wait "$dead" || true
mkdir "$lock"
echo "$dead" >"$lock/pid"
check "run: zone violation exits non-zero" expect_fail env STUB_CLAUDE_MODE=zone "$V/bin/binnacle-run"
check "lock: stale lock (dead PID) broken, released after a failed run" test ! -e "$lock"
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

# --- bin/binnacle-import ------------------------------------------------------------
reset_vault
git -C "$V" switch -q main
git -C "$V" pull -q --ff-only origin main
imp() { BINNACLE_DIR=$V "$repo/bin/binnacle-import" "$@" >"$T/imp.out" 2>&1; }
imp_branch() { git -C "$V" symbolic-ref --short HEAD; }
marker() { git -C "$V" config --get binnacle.importBranch; }
no_marker() { expect_fail marker; }
: >"$T/gh.log"

git -C "$V" config binnacle.role capture
check "import: refuses on a capture-only clone" expect_fail imp start
git -C "$V" config binnacle.role wiki-writer
printf 'x\n' >"$V/soundings/dirty.md"
check "import start: refuses a dirty tree" expect_fail imp start
check "import start: dirty tree creates no branch" test "$(imp_branch)" = main
rm -f "$V/soundings/dirty.md"
git -C "$V" commit -q --allow-empty -m "local only"
check "import start: refuses when main is ahead of origin" expect_fail imp start
git -C "$V" reset -q --hard origin/main

check "import start: exits 0" imp start
check "import start: creates import/notion-<timestamp>" bash -c '[[ $(git -C "$1" symbolic-ref --short HEAD) =~ ^import/notion-[0-9]{8}T[0-9]{6}Z$ ]]' _ "$V"
import_branch=$(imp_branch)
check "import start: sets binnacle.importBranch" test "$(marker)" = "$import_branch"
check "import start: re-run is a no-op" imp start
check "import start: re-run keeps the branch" test "$(imp_branch)" = "$import_branch"
check "import status: shows the import branch" bash -c 'BINNACLE_DIR=$1 "$2" status | grep -q "import branch: *$3"' _ "$V" "$repo/bin/binnacle-import" "$import_branch"

mkdir -p "$V/soundings/notion/Slip box/attachments"
printf -- '---\nnotion-id: abc\n---\n# Idea\nSee [[Other]].\n' >"$V/soundings/notion/Slip box/Idea.md"
printf '# Other\n' >"$V/soundings/notion/Slip box/Other.md"
printf 'PNGDATA' >"$V/soundings/notion/Slip box/attachments/pic.png"
printf 'stray\n' >"$V/wiki/stray.md"
check "import finish: refuses a change outside soundings/notion/" expect_fail imp finish
check "import finish: names the out-of-zone path" grep -q 'wiki/stray.md' "$T/imp.out"
check "import finish: out-of-zone refusal commits nothing" test "$(git -C "$V" rev-list --count origin/main..HEAD)" = 0
check "import finish: refusal keeps the branch and marker" test "$(marker)" = "$import_branch"
rm -f "$V/wiki/stray.md"

mkdir -p "$V/.obsidian"
printf '{"types":{"notion-id":"text"}}\n' >"$V/.obsidian/types.json"
printf '{}\n' >"$V/.obsidian/app.json"
check "import finish: refuses a neighbour of .obsidian/types.json" expect_fail imp finish
check "import finish: names .obsidian/app.json" grep -q '^  .obsidian/app.json$' "$T/imp.out"
check "import finish: does not name .obsidian/types.json as refused" bash -c '! grep -q "^  .obsidian/types.json$" "$1"' _ "$T/imp.out"
check "import finish: neighbour refusal commits nothing" test "$(git -C "$V" rev-list --count origin/main..HEAD)" = 0
rm -f "$V/.obsidian/app.json"

head -c 2048 /dev/zero >"$V/soundings/notion/Slip box/attachments/huge.bin"
check "import finish: stops on a file over the cap" expect_fail env BINNACLE_MAX_FILE_BYTES=1024 \
  BINNACLE_DIR="$V" "$repo/bin/binnacle-import" finish
BINNACLE_MAX_FILE_BYTES=1024 BINNACLE_DIR="$V" "$repo/bin/binnacle-import" finish >"$T/imp.out" 2>&1 || true
check "import finish: lists the oversized file" grep -q 'attachments/huge.bin (2048 bytes)' "$T/imp.out"
check "import finish: size stop commits nothing" test "$(git -C "$V" rev-list --count origin/main..HEAD)" = 0
rm -f "$V/soundings/notion/Slip box/attachments/huge.bin"

check "import finish: hook failure stops" expect_fail env BINNACLE_GITLEAKS="$T/stubs/gitleaks-fail" \
  BINNACLE_DIR="$V" "$repo/bin/binnacle-import" finish
check "import finish: hook failure commits and pushes nothing" bash -c \
  'test "$(git -C "$1" rev-list --count origin/main..HEAD)" = 0 && test -z "$(git ls-remote "$2" "refs/heads/$3")"' \
  _ "$V" "$T/remote.git" "$import_branch"
check "import finish: still on the branch after a stop" test "$(marker)" = "$import_branch"

: >"$T/gh.log"
rm -f "$T/pr-body.md"
check "import finish: exits 0" imp finish
check "import finish: branch pushed" test -n "$(git ls-remote "$T/remote.git" "refs/heads/$import_branch")"
check "import finish: commit holds only soundings/notion/ and .obsidian/types.json" bash -c \
  'test -z "$(git -C "$1" diff --name-only "origin/main...$2" | grep -v -e "^soundings/notion/" -e "^\.obsidian/types\.json$")"' _ "$V" "$import_branch"
check "import finish: .obsidian/types.json committed" bash -c \
  'test "$(git -C "$1" show "$2:.obsidian/types.json")" = "{\"types\":{\"notion-id\":\"text\"}}"' _ "$V" "$import_branch"
check "import finish: PR body names .obsidian/types.json" grep -q '^- also changes `.obsidian/types.json`' "$T/pr-body.md"
check "import finish: PR opened against main" grep -q "pr create --base main --head $import_branch" "$T/gh.log"
check "import finish: PR URL printed" grep -q 'PR: https://github.com/example/binnacle/pull/1' "$T/imp.out"
check "import finish: counts reported" grep -q 'imported: 3 files (2 notes, 1 attachments, 0 bases)' "$T/imp.out"
check "import finish: no auto-merge" bash -c '! grep -q "pr merge" "$1"' _ "$T/gh.log"
check "import finish: back on main" test "$(imp_branch)" = main
check "import finish: binnacle.importBranch unset" no_marker
check "import finish: re-run is a no-op" imp finish
check "import finish: re-run says nothing to finish" grep -q 'nothing to finish' "$T/imp.out"

# Re-run of an interrupted finish (PR already open) whose switch back to
# main fails (index locked): the marker stays set, and the token from the
# file reaches gh without ever being printed.
git -C "$V" switch -q "$import_branch"
git -C "$V" config binnacle.importBranch "$import_branch"
git -C "$V" config binnacle.ghTokenFile "$tokfile"
: >"$T/token.log"
: >"$T/gh.log"
: >"$V/.git/index.lock"
env -u GH_TOKEN PATH="$T/nokeychain:$PATH" STUB_GH_OPEN=1 STUB_TOKEN_LOG="$T/token.log" BINNACLE_DIR="$V" \
  bash -x "$repo/bin/binnacle-import" finish >"$T/imp.out" 2>&1 || true
rm -f "$V/.git/index.lock"
check "import finish: re-run finds the open PR instead of opening another" bash -c '! grep -q "pr create" "$1"' _ "$T/gh.log"
check "import finish: re-run never enables auto-merge" bash -c '! grep -q "pr merge" "$1"' _ "$T/gh.log"
check "import finish: token reaches gh" grep -qx 'token=file-token-123' "$T/token.log"
check "import finish: token never printed (even under bash -x)" bash -c '! grep -q file-token-123 "$1"' _ "$T/imp.out"
git -C "$V" config --unset binnacle.ghTokenFile
check "import finish: stops at the switch back to main" grep -q "could not switch" "$T/imp.out"
check "import finish: failed switch keeps binnacle.importBranch" test "$(marker)" = "$import_branch"
git -C "$V" config --unset binnacle.importBranch
git -C "$V" switch -q main

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
shoyu_setup() { # extra env... -> runs setup/shoyu against the fixture vault
  env HOME="$T/home" BINNACLE_DIR="$V" BINNACLE_OWNER="${T##*/}" BINNACLE_REPO=remote "$@" \
    "$repo/setup/shoyu/setup.sh" >"$T/shoyu.out" 2>&1 || true
}
global_before=$(cat "$T/gitconfig")
shoyu_setup
check "shoyu: user.name defaults to the owner" test "$(git -C "$V" config --local user.name)" = "${T##*/}"
check "shoyu: user.email defaults to the noreply address" \
  test "$(git -C "$V" config --local user.email)" = "${T##*/}@users.noreply.github.com"
git -C "$V" config --local user.name "Vault Person"
git -C "$V" config --local user.email 12345+vault@users.noreply.github.com
shoyu_setup
check "shoyu: existing vault-local user.name kept" test "$(git -C "$V" config --local user.name)" = "Vault Person"
check "shoyu: existing vault-local user.email kept" \
  test "$(git -C "$V" config --local user.email)" = 12345+vault@users.noreply.github.com
shoyu_setup BINNACLE_GIT_NAME="Env Name" BINNACLE_GIT_EMAIL=env@example.invalid
check "shoyu: BINNACLE_GIT_NAME overrides" test "$(git -C "$V" config --local user.name)" = "Env Name"
check "shoyu: BINNACLE_GIT_EMAIL overrides" test "$(git -C "$V" config --local user.email)" = env@example.invalid
check "shoyu: global git config untouched" test "$(cat "$T/gitconfig")" = "$global_before"
check "shoyu: setup.sh does not schedule nightly runs" test ! -e "$T/home/Library/LaunchAgents"
git -C "$V" config --local --unset user.name
git -C "$V" config --local --unset user.email
workmac_setup() { # extra env... -> runs setup/workmac against the fixture vault
  env HOME="$T/home" BINNACLE_DIR="$V" BINNACLE_OWNER="${T##*/}" BINNACLE_REPO=remote "$@" \
    "$repo/setup/workmac/setup.sh" >"$T/workmac.out" 2>&1 || true
}
workmac_setup
check "workmac: user.name defaults to the owner" test "$(git -C "$V" config --local user.name)" = "${T##*/}"
check "workmac: user.email defaults to the noreply address" \
  test "$(git -C "$V" config --local user.email)" = "${T##*/}@users.noreply.github.com"
git -C "$V" config --local user.name "Vault Person"
git -C "$V" config --local user.email 12345+vault@users.noreply.github.com
workmac_setup
check "workmac: existing vault-local user.name kept" test "$(git -C "$V" config --local user.name)" = "Vault Person"
check "workmac: existing vault-local user.email kept" \
  test "$(git -C "$V" config --local user.email)" = 12345+vault@users.noreply.github.com
workmac_setup BINNACLE_GIT_NAME="Env Name" BINNACLE_GIT_EMAIL=env@example.invalid
check "workmac: BINNACLE_GIT_NAME overrides" test "$(git -C "$V" config --local user.name)" = "Env Name"
check "workmac: BINNACLE_GIT_EMAIL overrides" test "$(git -C "$V" config --local user.email)" = env@example.invalid
check "workmac: global git config untouched" test "$(cat "$T/gitconfig")" = "$global_before"
git -C "$V" config binnacle.role wiki-writer # back to shoyu's role for the nightly.sh checks below
check "install-hooks: idempotent" bash -c '"$1" "$2" && "$1" "$2"' _ "$repo/setup/common/install-hooks.sh" "$V"
stubs_phys=$(cd "$T/stubs" && pwd -P)
check "install-hooks: records the gitleaks path" \
  test "$(git -C "$V" config binnacle.gitleaks)" = "$stubs_phys/gitleaks-pass"
check "install-hooks: updates the recorded path when gitleaks moves" bash -c \
  'BINNACLE_GITLEAKS="$3/gitleaks-mark" "$1" "$2" && test "$(git -C "$2" config binnacle.gitleaks)" = "$3/gitleaks-mark"' \
  _ "$repo/setup/common/install-hooks.sh" "$V" "$stubs_phys"
check "github --dry-run: changes nothing, names the check" bash -c \
  '"$1" --dry-run | grep -q "\"context\": \"gitleaks\""' _ "$repo/setup/github/setup.sh"

# --- bin/binnacle-nightly -----------------------------------------------------------------
# The wrapper beside a stub binnacle-run, started the way launchd starts it:
# empty environment but HOME, bare PATH.
NW=$T/nightly-vault
mkdir -p "$NW/bin" "$T/nhome"
cp "$repo/bin/binnacle-nightly" "$NW/bin/"
cat >"$NW/bin/binnacle-run" <<'EOF'
#!/bin/sh
echo "stub-run PATH=$PATH"
echo "stub-run cwd=$(pwd -P)"
echo "stub-run token ghp_abcdefghijklmnopqrstuvwxyz0123456789 key sk-ant-api03-SECRETSECRET"
echo x >>"$NIGHTLY_CALLS"
exit "${STUB_RUN_STATUS:-0}"
EOF
chmod +x "$NW/bin/binnacle-run"
nlog=$T/nhome/Library/Logs/binnacle/nightly.log
nightly() { # extra env... -> exit status of the wrapper in $T/nightly.status
  local st=0
  : >"$T/nightly.calls"
  env -i HOME="$T/nhome" PATH=/usr/bin:/bin NIGHTLY_CALLS="$T/nightly.calls" "$@" \
    "$NW/bin/binnacle-nightly" >"$T/nightly.out" 2>&1 || st=$?
  echo "$st" >"$T/nightly.status"
}
nightly STUB_RUN_STATUS=7
check "nightly: exits with binnacle-run's status" test "$(cat "$T/nightly.status")" = 7
check "nightly: runs binnacle-run once (no retry)" test "$(wc -l <"$T/nightly.calls" | tr -d ' ')" = 1
check "nightly: log written to ~/Library/Logs/binnacle/nightly.log" test -s "$nlog"
check "nightly: log readable by its owner only" test -n "$(find "$nlog" -perm 600)"
check "nightly: explicit PATH (~/.local/bin, Homebrew, system)" grep -qxF \
  "stub-run PATH=$T/nhome/.local/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin" "$nlog"
check "nightly: runs from the vault clone it lives in" grep -qxF "stub-run cwd=$(cd "$NW" && pwd -P)" "$nlog"
check "nightly: dated start line" grep -Eq '^=== [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:]{8} .* binnacle-nightly start' "$nlog"
check "nightly: records the exit status" grep -q 'binnacle-nightly end: exit 7 (' "$nlog"
check "nightly: token-shaped strings masked" bash -c \
  '! grep -Eq "ghp_abcdef|SECRETSECRET" "$1" && grep -q "ghp_\[redacted\]" "$1"' _ "$nlog"
nightly
check "nightly: second run appends" test "$(grep -c 'binnacle-nightly start' "$nlog")" = 2
check "nightly: ok run records exit 0" bash -c 'tail -n 1 "$1" | grep -q "end: exit 0 ("' _ "$nlog"
dd if=/dev/zero bs=1024 count=1100 2>/dev/null | tr '\0' 'x' >>"$nlog"
nightly
check "nightly: log over 1 MB moved to nightly.log.1" test "$(wc -c <"$nlog.1" | tr -d ' ')" -gt 1048576
check "nightly: fresh log after rotation" test "$(grep -c 'binnacle-nightly start' "$nlog")" = 1

# --- setup/shoyu/nightly.sh (stub launchctl) ----------------------------------------------
mkdir -p "$T/lstub" "$T/lhome"
cat >"$T/lstub/launchctl" <<'EOF'
#!/bin/sh
echo "launchctl $*" >>"$STUB_LAUNCHCTL_LOG"
case "$1" in
  print) [ -e "$STUB_LAUNCHCTL_LOADED" ] || exit 113; printf '\truns = 1\n\tlast exit code = 0\n' ;;
  bootstrap) : >"$STUB_LAUNCHCTL_LOADED" ;;
  bootout) rm -f "$STUB_LAUNCHCTL_LOADED" ;;
esac
exit 0
EOF
chmod +x "$T/lstub/launchctl"
NS=$repo/setup/shoyu/nightly.sh
plist=$T/lhome/Library/LaunchAgents/com.binnacle.nightly.plist
nightly_sh() { # extra env... subcommand
  env HOME="$T/lhome" BINNACLE_DIR="$V" PATH="$T/lstub:$PATH" STUB_LAUNCHCTL_LOG="$T/launchctl.log" \
    STUB_LAUNCHCTL_LOADED="$T/launchctl.loaded" "$@" >"$T/nightly-sh.out" 2>&1
}
plist_time() { awk '/<key>(Hour|Minute)<\/key>/ { getline; gsub(/[^0-9]/, ""); printf "%s%s", sep, $0; sep = ":" }' "$plist"; }
: >"$T/launchctl.log"
check "nightly.sh install: default time" nightly_sh "$NS" install
check "nightly.sh install: plist renders 03:30" test "$(plist_time)" = 3:30
check "nightly.sh install: plist runs the vault's wrapper" \
  grep -qF "<string>$(cd "$V" && pwd -P)/bin/binnacle-nightly</string>" "$plist"
check "nightly.sh install: no placeholder left" bash -c '! grep -q "{{" "$1"' _ "$plist"
if command -v plutil >/dev/null 2>&1; then
  check "nightly.sh install: plist lints" plutil -lint -s "$plist"
fi
check "nightly.sh install: bootstrap in the GUI domain" \
  grep -qxF "launchctl bootstrap gui/$(id -u) $plist" "$T/launchctl.log"
check "nightly.sh install: chosen time" nightly_sh BINNACLE_NIGHTLY_HOUR=4 BINNACLE_NIGHTLY_MINUTE=05 "$NS" install
check "nightly.sh install: plist renders 04:05" test "$(plist_time)" = 4:5
check "nightly.sh install: re-install boots out the old job first" \
  grep -qxF "launchctl bootout gui/$(id -u)/com.binnacle.nightly" "$T/launchctl.log"
check "nightly.sh install: refuses hour 24" expect_fail nightly_sh BINNACLE_NIGHTLY_HOUR=24 "$NS" install
check "nightly.sh install: refuses a non-number minute" expect_fail nightly_sh BINNACLE_NIGHTLY_MINUTE=x "$NS" install
check "nightly.sh install: refused time leaves the plist alone" test "$(plist_time)" = 4:5
nightly_sh "$NS" status || true
check "nightly.sh status: shows the time" grep -q "installed: .* (daily at 04:05 local)" "$T/nightly-sh.out"
check "nightly.sh status: shows launchd's last exit code" grep -q "last exit code = 0" "$T/nightly-sh.out"
git clone -q "$T/remote.git" "$T/vault2"
git -C "$T/vault2" config binnacle.role wiki-writer
check "nightly.sh install: refuses to replace another vault's schedule" \
  expect_fail nightly_sh BINNACLE_DIR="$T/vault2" "$NS" install
git -C "$V" config binnacle.role capture
check "nightly.sh install: refuses a capture-only clone" expect_fail nightly_sh "$NS" install
git -C "$V" config binnacle.role wiki-writer
check "nightly.sh uninstall: exits 0" nightly_sh "$NS" uninstall
check "nightly.sh uninstall: plist removed and job unloaded" \
  bash -c 'test ! -e "$1" && test ! -e "$2"' _ "$plist" "$T/launchctl.loaded"
check "nightly.sh uninstall: idempotent" nightly_sh "$NS" uninstall
check "nightly.sh status: exits 0 when not installed" nightly_sh "$NS" status

# --- setup/work-brain (company brain on a work machine) -------------------------------------
# A throwaway HOME with a personal ~/binnacle that must never change. The
# profile runs from the seed checkout (the template as committed).
WH=$T/wbhome
mkdir -p "$WH"
git clone -q "$T/remote.git" "$WH/binnacle"
printf 'personal note\n' >"$WH/binnacle/soundings/mine.md"
personal_sum() { (cd "$WH/binnacle" && find . -path ./.git/index -prune -o -type f -print | LC_ALL=C sort | xargs cksum); }
personal_before=$(personal_sum)
wblib() { bash -c '. "$1/setup/common/lib.sh"; . "$1/setup/work-brain/lib.sh"; shift; "$@"' _ "$repo" "$@"; }
check "work-brain: slug lowercases and joins words" test "$(wblib wb_slug 'Acme Engineering')" = acme-engineering
check "work-brain: slug squeezes runs and trims dashes" test "$(wblib wb_slug '--ACME__Eng!!--')" = acme-eng
check "work-brain: name binnacle-<org>-<user>" \
  test "$(wblib wb_name Acme-Engineering JDoe)" = binnacle-acme-engineering-jdoe
check "work-brain: name refuses an org with nothing left after slugging" expect_fail wblib wb_name '!!!' jdoe

B=$WH/binnacle-acme-engineering-jdoe
wb_setup() { # args... -> setup from the seed checkout, output in $T/wb.out
  env HOME="$WH" "$T/seed/setup/work-brain/setup.sh" "$@" >"$T/wb.out" 2>&1
}
global_before=$(cat "$T/gitconfig")
check "work-brain setup: refuses without --org when not on a terminal" expect_fail wb_setup --user jdoe </dev/null
check "work-brain setup: creates the brain, no remote" wb_setup --org Acme-Engineering --user JDoe --git-email jdoe@acme.example
check "work-brain setup: default folder ~/binnacle-<org>-<user>" test -d "$B/.git"
check "work-brain setup: one commit on main" test "$(git -C "$B" rev-list --count main 2>/dev/null)" = 1
check "work-brain setup: clean tree after the first commit" test -z "$(git -C "$B" status --porcelain)"
check "work-brain setup: no remote" test -z "$(git -C "$B" remote)"
check "work-brain setup: local only" test "$(git -C "$B" config binnacle.localOnly)" = true
check "work-brain setup: runs the AI writer (wiki-writer)" test "$(git -C "$B" config binnacle.role)" = wiki-writer
check "work-brain setup: token item named after the brain" \
  test "$(git -C "$B" config binnacle.ghTokenItem)" = binnacle-acme-engineering-jdoe-gh-token
check "work-brain setup: hook installed" test "$(git -C "$B" config --local core.hooksPath)" = .githooks
check "work-brain setup: vault-only work email" test "$(git -C "$B" config --local user.email)" = jdoe@acme.example
check "work-brain setup: user.name defaults to the GitHub user" test "$(git -C "$B" config --local user.name)" = jdoe
check "work-brain setup: global git config untouched" test "$(cat "$T/gitconfig")" = "$global_before"
check "work-brain setup: CLAUDE.md states the company content limits" grep -q "payment data, minors' names, health or" "$B/CLAUDE.md"
check "work-brain setup: CLAUDE.md names no personal machine" bash -c '! grep -q shoyu "$1"' _ "$B/CLAUDE.md"
check "work-brain setup: CLAUDE.md drops the personal scope" bash -c '! grep -q "Scope is personal" "$1"' _ "$B/CLAUDE.md"
check "work-brain setup: run prompt skips the limited material" grep -q 'health or waiver records' "$B/bin/binnacle-run.prompt.md"
check "work-brain setup: template CLAUDE.md unchanged" bash -c 'grep -q "Scope is personal" "$1"' _ "$repo/CLAUDE.md"
check "work-brain hook: rejects a file over the cap" expect_fail env BINNACLE_MAX_FILE_BYTES=4 \
  bash -c 'printf 12345 >"$1/raw/inbox/big.md" && git -C "$1" add -A && git -C "$1" commit -qm big' _ "$B"
git -C "$B" reset -q --hard
git -C "$B" clean -qfdx
check "work-brain hook: rejects when gitleaks flags" expect_fail env BINNACLE_GITLEAKS="$T/stubs/gitleaks-fail" \
  bash -c 'printf x >"$1/soundings/a.md" && git -C "$1" add -A && git -C "$1" commit -qm a' _ "$B"
git -C "$B" reset -q --hard
git -C "$B" clean -qfdx
check "work-brain setup: re-run is safe" wb_setup --org acme-engineering --user jdoe
check "work-brain setup: re-run adds no commit" test "$(git -C "$B" rev-list --count main)" = 1
check "work-brain setup: re-run from the vault's own copy" env HOME="$WH" "$B/setup/work-brain/setup.sh" --org acme-engineering --user jdoe

# Collisions: nothing but a new folder or this brain's own vault.
mkdir -p "$WH/foreign"
check "work-brain collision: refuses an existing foreign folder" expect_fail wb_setup --org acme --user jdoe --dir "$WH/foreign"
check "work-brain collision: foreign folder left empty" test -z "$(ls -A "$WH/foreign")"
git init -q "$WH/other-repo"
check "work-brain collision: refuses an unrelated git repo" expect_fail wb_setup --org acme --user jdoe --dir "$WH/other-repo"
check "work-brain collision: refuses another brain's vault" expect_fail wb_setup --org acme-engineering --user someone --dir "$B"
check "work-brain collision: refuses ~/binnacle" expect_fail wb_setup --org acme --user jdoe --dir "$WH/binnacle"
check "work-brain collision: refuses a folder inside ~/binnacle" expect_fail wb_setup --org acme --user jdoe --dir "$WH/binnacle/brain"
ln -s "$WH/binnacle" "$WH/binnacle-acme-jdoe"
check "work-brain collision: refuses a symlink to ~/binnacle" expect_fail wb_setup --org acme --user jdoe
rm "$WH/binnacle-acme-jdoe"
git -C "$B" remote add origin "$T/elsewhere.git"
check "work-brain collision: refuses a vault whose origin points elsewhere" expect_fail wb_setup --org acme-engineering --user jdoe
check "work-brain collision: says origin points elsewhere" grep -q 'points elsewhere' "$T/wb.out"
git -C "$B" remote remove origin
check "work-brain collision: refuses to copy from a vault with content" expect_fail \
  env HOME="$WH" "$V/setup/work-brain/setup.sh" --org acme --user jdoe2
check "work-brain collision: content refusal creates nothing" test ! -e "$WH/binnacle-acme-jdoe2"

# Local-only runs: no remote, no gh; main is fast-forwarded to the run.
: >"$T/gh.log"
printf 'A work idea.\n' >"$B/raw/inbox/work-idea.md"
git -C "$B" add -A
git -C "$B" commit -qm capture
brun() { "$B/bin/binnacle-run" "$@" >"$T/brun.out" 2>&1; }
check "work-brain run --dry-run: exits 0" brun --dry-run
check "work-brain run --dry-run: says local only" grep -q 'local only: no push, no PR' "$T/brun.out"
check "work-brain run --dry-run: lists the source" grep -q 'raw/inbox/work-idea.md' "$T/brun.out"
main_before=$(git -C "$B" rev-parse main)
check "work-brain run: ok run exits 0" env STUB_CLAUDE_MODE=ok "$B/bin/binnacle-run" >"$T/brun.out" 2>&1
check "work-brain run: main fast-forwarded" git -C "$B" merge-base --is-ancestor "$main_before" main
check "work-brain run: main moved" test "$(git -C "$B" rev-parse main)" != "$main_before"
check "work-brain run: source moved on main" bash -c 'ls "$1"/raw/sources/*/work-idea.md' _ "$B"
check "work-brain run: wiki page on main" test -f "$B/wiki/concepts/stub-concept.md"
check "work-brain run: no run branch left" test -z "$(git -C "$B" branch --list 'binnacle-run/*')"
check "work-brain run: no GitHub call" test ! -s "$T/gh.log"
check "work-brain run: still no remote" test -z "$(git -C "$B" remote)"
check "work-brain run: audit note says local only" bash -c 'grep -q "^- PR: none (local only" "$1"/audit/runs/*.md' _ "$B"
check "work-brain run: audit note merged true" bash -c 'grep -q "^merged: true$" "$1"/audit/runs/*.md' _ "$B"
printf 'Another work idea.\n' >"$B/raw/inbox/second.md"
git -C "$B" add -A
git -C "$B" commit -qm capture2
main_before=$(git -C "$B" rev-parse main)
sleep 1
check "work-brain run: Claude failure exits non-zero" expect_fail env STUB_CLAUDE_MODE=crash "$B/bin/binnacle-run"
check "work-brain run: failed run leaves main alone" test "$(git -C "$B" rev-parse main)" = "$main_before"
check "work-brain run: failed run keeps its branch" test -n "$(git -C "$B" branch --list 'binnacle-run/*')"
check "work-brain run: refuses while a run branch waits" expect_fail env STUB_CLAUDE_MODE=ok "$B/bin/binnacle-run"
git -C "$B" for-each-ref --format='%(refname:short)' 'refs/heads/binnacle-run/*' | xargs git -C "$B" branch -q -D
check "work-brain run: no GitHub call on failure either" test ! -s "$T/gh.log"

# Org base permission: warns with the fix, never blocks.
bp() { env STUB_ORG_PERM="$1" bash -c '. "$2/setup/common/lib.sh"; . "$2/setup/work-brain/lib.sh"; wb_base_permission acme' _ "$1" "$repo" >"$T/bp.out" 2>&1; }
check "base permission: none is ok" bp none
check "base permission: none says visible only to you and the owners" grep -q 'visible only to you and the acme owners' "$T/bp.out"
check "base permission: read warns but does not fail" bp read
check "base permission: read names the fix" grep -q "base repository permission is 'read'.*Base permissions: No permission" "$T/bp.out"
check "base permission: unreadable value says so, gives the manual check" bp ""
check "base permission: unreadable mentions owners and the manual check" grep -q 'only to org owners.*check by hand' "$T/bp.out"
check "base permission: API failure warns, does not fail" bp FAIL
check "base permission: API failure gives the manual check" grep -q 'could not read org .acme.*Check it by hand' "$T/bp.out"
check "base permission: asked the org endpoint" grep -q 'gh api orgs/acme --jq' "$T/gh.log"

# GitHub Apps installed on all repositories: warns with the fix, never blocks.
# The stub runs the real --jq filter over fixtures shaped like GitHub's
# documented GET /orgs/{org}/installations response.
cat >"$T/installations-mixed.json" <<'EOF'
{"total_count": 2, "installations": [
  {"id": 1, "app_id": 11, "app_slug": "ci-bot", "target_type": "Organization", "repository_selection": "all",
   "account": {"login": "acme"}},
  {"id": 2, "app_id": 22, "app_slug": "docs-sync", "target_type": "Organization", "repository_selection": "selected",
   "account": {"login": "acme"}}
]}
EOF
cat >"$T/installations-selected.json" <<'EOF'
{"total_count": 1, "installations": [
  {"id": 2, "app_id": 22, "app_slug": "docs-sync", "target_type": "Organization", "repository_selection": "selected",
   "account": {"login": "acme"}}
]}
EOF
apps() { env STUB_ORG_APPS="$1" bash -c '. "$2/setup/common/lib.sh"; . "$2/setup/work-brain/lib.sh"; wb_app_installations acme' _ "$1" "$repo" >"$T/apps.out" 2>&1; }
if command -v jq >/dev/null 2>&1; then
  check "app installations: only selected-repos apps is ok" apps "$T/installations-selected.json"
  check "app installations: none says so" grep -q 'no GitHub App is installed on all repositories of acme' "$T/apps.out"
  check "app installations: none gives no warning" bash -c '! grep -qi warn "$1"' _ "$T/apps.out"
  check "app installations: an all-repos app warns but does not fail" apps "$T/installations-mixed.json"
  check "app installations: names the all-repos app" grep -q "GitHub App 'ci-bot' is installed on all repositories of acme" "$T/apps.out"
  check "app installations: does not name the selected-repos app" bash -c '! grep -q docs-sync "$1"' _ "$T/apps.out"
  check "app installations: gives the fix" grep -q 'Repository access: Only select repositories, or uninstall' "$T/apps.out"
else
  printf 'skip   app installations jq filter checks (jq not installed)\n'
fi
check "app installations: unreadable warns, does not fail" apps FAIL
check "app installations: unreadable says so and gives the manual check" \
  grep -q 'could not read the app installations of .acme.*check by hand' "$T/apps.out"

# Connecting a remote: explicit, re-checks collisions, then warns on base permission.
mkdir -p "$T/gh-acme"
BR=$T/gh-acme/binnacle-acme-engineering-jdoe.git
git init -q --bare "$BR"
connect() { env STUB_ORG_PERM=read STUB_ORG_APPS="$T/installations-mixed.json" "$B/setup/work-brain/connect-remote.sh" "$@" >"$T/connect.out" 2>&1; }
git init -q --bare "$T/gh-acme/wrong-name.git"
check "connect: refuses a repository with another name" expect_fail connect --url "$T/gh-acme/wrong-name.git"
check "connect: refuses a public GitHub repository" expect_fail env STUB_REPO_PRIVATE=false \
  "$B/setup/work-brain/connect-remote.sh" --url https://github.com/acme-engineering/binnacle-acme-engineering-jdoe.git
FR=$T/gh-foreign/binnacle-acme-engineering-jdoe.git
git clone -q --bare "$T/remote.git" "$FR"
check "connect: refuses a repository holding other history" expect_fail connect --url "$FR"
check "connect: foreign history adds no origin" test -z "$(git -C "$B" remote)"
check "connect: exits 0" connect --url "$BR"
check "connect: origin set" test "$(git -C "$B" remote get-url origin)" = "$BR"
check "connect: main pushed" test "$(git -C "$BR" rev-parse main)" = "$(git -C "$B" rev-parse main)"
check "connect: leaves local-only mode" expect_fail git -C "$B" config --get binnacle.localOnly
check "connect: warns on a readable base permission" grep -q "base repository permission is 'read'" "$T/connect.out"
if command -v jq >/dev/null 2>&1; then
  check "connect: warns on an app installed on all repositories" grep -q "GitHub App 'ci-bot' is installed on all repositories" "$T/connect.out"
else
  printf 'skip   connect: app installation warning (jq not installed)\n'
fi
check "connect: re-run is safe" connect --url "$BR"
check "connect: setup re-run accepts the connected origin" wb_setup --org acme-engineering --user jdoe
check "connect: refuses a different repository once connected" expect_fail connect --url "$T/gh-acme2/binnacle-acme-engineering-jdoe.git"
git -C "$B" remote set-url origin "$T/elsewhere/binnacle-acme-engineering-jdoe.git"
check "connect: setup refuses an origin changed by hand" expect_fail wb_setup --org acme-engineering --user jdoe
git -C "$B" remote set-url origin "$BR"
check "connect: refuses to run in ~/binnacle" expect_fail \
  env HOME="$WH" "$WH/binnacle/setup/work-brain/connect-remote.sh" --url "$BR"
check "work-brain: personal ~/binnacle untouched" test "$(personal_sum)" = "$personal_before"

printf '\n%s passed, %s failed\n' "$passed" "$failed"
if [ "$failed" -gt 0 ]; then
  printf 'details: last check output follows\n' >&2
  tail -n 40 "$T/check.log" >&2
  exit 1
fi
