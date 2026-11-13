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
  bin/binnacle-forms-to-inbox setup/forms/mover.sh test/selftest.sh)

# --- static checks -------------------------------------------------------------
for s in "${scripts[@]}"; do
  check "bash -n $s" bash -n "$repo/$s"
done
if command -v shellcheck >/dev/null 2>&1; then
  check "shellcheck clean" bash -c 'cd "$1" && shift && shellcheck -x "$@"' _ "$repo" "${scripts[@]}"
else
  printf 'skip   shellcheck (not installed)\n'
fi
check "python parses bin/binnacle-forms-to-inbox.py" \
  python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' "$repo/bin/binnacle-forms-to-inbox.py"

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
[ -z "${STUB_PROMPT:-}" ] || printf '%s\n' "$prompt" >"$STUB_PROMPT"
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
if [ "$STUB_CLAUDE_MODE" = people ]; then
  mkdir -p wiki/people
  printf -- '---\ntype: person\n---\n# Sample subject\n' >wiki/people/sample-subject.md
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

# --- survey intake: bin/binnacle-forms-to-inbox and setup/forms/mover.sh -------------------
# Synthetic exports only: placeholder people (jdoe, asmith, bkim), example.com
# addresses. FV is a fresh vault clone; nothing here is committed.
FV=$T/forms-vault
git clone -q "$T/remote.git" "$FV"
fv_head=$(git -C "$FV" rev-parse HEAD)
F=$T/forms
mkdir -p "$F"
cat >"$F/mkxlsx.py" <<'EOF'
# mkxlsx.py CSV XLSX DATE_COLUMN DATE_FORMAT: a minimal xlsx (shared strings,
# an inline-string header row, numbers, date serials) from a csv fixture.
import csv, datetime, sys, zipfile
from xml.sax.saxutils import escape
src, dst, dcol, dfmt = sys.argv[1:5]
rows = list(csv.reader(open(src, newline="", encoding="utf-8")))
shared, index, out = [], {}, []
def ref(c, r):
    n, c = "", c + 1
    while c:
        c, x = divmod(c - 1, 26)
        n = chr(65 + x) + n
    return "%s%d" % (n, r)
for r, row in enumerate(rows, start=1):
    cells = []
    for c, v in enumerate(row):
        if not v:
            continue
        if r == 1:
            cells.append('<c r="%s" t="inlineStr"><is><t>%s</t></is></c>' % (ref(c, r), escape(v)))
        elif rows[0][c] == dcol:
            d = datetime.datetime.strptime(v, dfmt) - datetime.datetime(1899, 12, 30)
            cells.append('<c r="%s" s="1"><v>%r</v></c>' % (ref(c, r), d.total_seconds() / 86400))
        elif v.isdigit():
            cells.append('<c r="%s"><v>%s</v></c>' % (ref(c, r), v))
        else:
            index.setdefault(v, len(shared))
            if index[v] == len(shared):
                shared.append(v)
            cells.append('<c r="%s" t="s"><v>%d</v></c>' % (ref(c, r), index[v]))
    out.append('<row r="%d">%s</row>' % (r, "".join(cells)))
M = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
P = "http://schemas.openxmlformats.org/package/2006/relationships"
with zipfile.ZipFile(dst, "w") as z:
    z.writestr("[Content_Types].xml", '<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>')
    z.writestr("xl/workbook.xml", '<workbook xmlns="%s" xmlns:r="%s"><sheets><sheet name="Form1" sheetId="1" r:id="rId7"/></sheets></workbook>' % (M, R))
    z.writestr("xl/_rels/workbook.xml.rels", '<Relationships xmlns="%s"><Relationship Id="rId7" Type="%s/worksheet" Target="worksheets/responses.xml"/></Relationships>' % (P, R))
    z.writestr("xl/sharedStrings.xml", '<sst xmlns="%s">%s</sst>' % (M, "".join('<si><t xml:space="preserve">%s</t></si>' % escape(s) for s in shared)))
    z.writestr("xl/worksheets/responses.xml", '<worksheet xmlns="%s"><sheetData>%s</sheetData></worksheet>' % (M, "".join(out)))
EOF
cat >"$F/google.csv" <<'EOF'
Timestamp,Email Address,How satisfied are you? (1-5),What should we change?,The team communicates well
11/2/2026 9:15:00,jdoe@example.com,4,"More focus time, fewer meetings",Agree
11/5/2026 14:00:00,asmith@example.com,5,,Strongly agree
11/9/2026 17:30:00,bkim@example.com,2,"Pat Lee could share
plans earlier",Disagree
EOF
cat >"$F/msforms.csv" <<'EOF'
ID,Start time,Completion time,Email,Name,Last modified time,Rate the onboarding (0-10),What helped most?
101,2026-11-03 09:58:00,2026-11-03 10:00:00,jdoe@example.com,jdoe,,8,The buddy system
102,2026-11-04 11:10:00,2026-11-04 11:12:00,asmith@example.com,asmith,,6,Written runbooks
103,2026-11-10 16:01:00,2026-11-10 16:05:00,bkim@example.com,bkim,,9,
EOF
python3 -I "$F/mkxlsx.py" "$F/msforms.csv" "$F/msforms.xlsx" "Completion time" "%Y-%m-%d %H:%M:%S"
python3 -I "$F/mkxlsx.py" "$F/google.csv" "$F/google.xlsx" "Timestamp" "%m/%d/%Y %H:%M:%S"

F2I=$repo/bin/binnacle-forms-to-inbox
FO=$FV/raw/inbox/forms
conv() { # args... -> converter into $FV, output in $T/conv.out
  "$F2I" --vault "$FV" --form-title "Team pulse" --audience "platform team" \
    --consent-notice-version v1 "$@" >"$T/conv.out" 2>&1
}
only_note() { # -> path of the one note in raw/inbox/forms/
  local n
  n=$(find "$FO" -name '*.md' 2>/dev/null)
  [ "$(printf '%s\n' "$n" | grep -c .)" = 1 ] && printf '%s\n' "$n"
}
sha() { python3 -I -c 'import hashlib, sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest())' "$1"; }
body_lacks() { # pattern, note -> the pattern is nowhere but exported_at
  ! grep -v '^exported_at:' "$2" | grep -q "$1"
}
gl_hash=$(sha ABC123)
ms_hash=$(sha ms-form-1)

check "forms dates: day and month undecidable is refused" expect_fail conv --form-id ABC123 "$F/google.csv"
check "forms dates: the refusal asks for --date-order, writes nothing" bash -c 'grep -q -- "--date-order" "$1" && test ! -e "$2"' _ "$T/conv.out" "$FO"
check "forms dates: --date-order dmy reads day first" conv --form-id ABC123 --date-order dmy "$F/google.csv"
check "forms dates: dmy window" test -f "$FO/form-${gl_hash:0:12}-2026-02-11-to-2026-09-11.md"
rm -rf "$FO"
check "forms dates: --from and --to need no date order" conv --form-id ABC123 --from 2026-11-01 --to 2026-11-30 "$F/google.csv"
check "forms dates: declared window" test -f "$FO/form-${gl_hash:0:12}-2026-11-01-to-2026-11-30.md"
rm -rf "$FO"
check "forms google csv: exits 0" conv --form-id "https://docs.google.com/forms/d/e/ABC123/viewform" --invited 5 --date-order mdy "$F/google.csv"
N=$(only_note || true)
check "forms google csv: one note per form and window" test "$N" = "$FO/form-${gl_hash:0:12}-2026-11-02-to-2026-11-09.md"
check "forms: front-matter type form-responses" grep -qx 'type: form-responses' "$N"
check "forms: platform told from the headers" grep -qx 'platform: google' "$N"
check "forms: form_id_hash is the sha256 of the id in the link" grep -qx "form_id_hash: $gl_hash" "$N"
check "forms: raw form id and link never written" bash -c '! grep -q "ABC123\|docs.google" "$1"' _ "$N"
check "forms: window from the response dates" bash -c 'grep -qx "collected_from: 2026-11-02" "$1" && grep -qx "collected_to: 2026-11-09" "$1"' _ "$N"
check "forms: retention review 12 months after the window" grep -qx 'retention_review: 2027-11-09' "$N"
check "forms: respondents, invited, identity, notice, audience" bash -c 'grep -qx "respondents: 3" "$1" && grep -qx "invited: 5" "$1" && grep -qx "identity: anonymous" "$1" && grep -qx "consent_notice_version: \"v1\"" "$1" && grep -qx "audience: \"platform team\"" "$1"' _ "$N"
check "forms: emails and names dropped" body_lacks 'example.com\|jdoe\|asmith\|bkim\|Email Address' "$N"
check "forms: per-response timestamps dropped" body_lacks '9:15\|14:00\|17:30\|Timestamp' "$N"
check "forms: numeric rating as distribution and median" bash -c 'grep -qx "Rating: 3 answers, median 4." "$1" && grep -qx "| 3 | 0 |" "$1" && grep -qx "| 5 | 1 |" "$1"' _ "$N"
check "forms: Likert rating with the full scale and median" bash -c 'grep -qx "Rating: 3 answers, median Agree." "$1" && grep -qx "| Strongly disagree | 0 |" "$1"' _ "$N"
check "forms: free text as R1..Rn, multi-line kept" bash -c 'grep -Eqx "\- \*\*R[1-3]:\*\* More focus time, fewer meetings" "$1" && grep -qx "  plans earlier" "$1"' _ "$N"
check "forms: no stop-list is a note, not an error" grep -q 'no stop-list at' "$T/conv.out"

rm -rf "$FO"
check "forms google xlsx: exits 0" conv --form-id ABC123 "$F/google.xlsx"
N=$(only_note || true)
check "forms google xlsx: same window and platform" bash -c 'grep -qx "platform: google" "$1" && grep -qx "collected_to: 2026-11-09" "$1" && grep -qx "respondents: 3" "$1"' _ "$N"
check "forms google xlsx: same rating summary" grep -qx 'Rating: 3 answers, median Agree.' "$N"
check "forms google xlsx: emails dropped" body_lacks 'example.com' "$N"

rm -rf "$FO"
check "forms msforms csv: exits 0" conv --form-id ms-form-1 "$F/msforms.csv"
N=$(only_note || true)
check "forms msforms csv: platform msforms" grep -qx 'platform: msforms' "$N"
check "forms msforms csv: window from completion times" bash -c 'grep -qx "collected_from: 2026-11-03" "$1" && grep -qx "collected_to: 2026-11-10" "$1"' _ "$N"
check "forms msforms csv: names, emails, times dropped" \
  body_lacks 'jdoe\|example.com\|Start time\|Completion time\|Last modified\|10:00\|^## .*Name' "$N"
check "forms msforms csv: response ids dropped" bash -c '! grep -qw "10[123]" "$1"' _ "$N"
check "forms msforms csv: 0-10 rating median" grep -qx 'Rating: 3 answers, median 8.' "$N"
check "forms msforms csv: invited left empty when not given" grep -qx 'invited: ' "$N"

rm -rf "$FO"
check "forms msforms xlsx: exits 0" conv --form-id ms-form-1 "$F/msforms.xlsx"
N=$(only_note || true)
check "forms msforms xlsx: same note name as the csv" test "${N##*/}" = "form-${ms_hash:0:12}-2026-11-03-to-2026-11-10.md"
check "forms msforms xlsx: same window, rating and answers as the csv" bash -c 'grep -qx "collected_from: 2026-11-03" "$1" && grep -qx "Rating: 3 answers, median 8." "$1" && grep -Eq "R[1-3]:\*\* Written runbooks" "$1"' _ "$N"
check "forms msforms xlsx: identity columns dropped" body_lacks 'jdoe\|example.com\|Completion time' "$N"

# Shuffle: R labels follow a fresh random order every run, not the rows.
printf 'Timestamp,Thoughts\n' >"$F/six.csv"
for w in alpha bravo charlie delta echo foxtrot; do printf '11/13/2026 9:00:00,%s\n' "$w" >>"$F/six.csv"; done
labels=""
for _ in 1 2 3 4 5 6 7 8; do
  rm -rf "$FO"
  conv --form-id six "$F/six.csv" || true
  labels="$labels $(grep -o 'R[0-9]:\*\* alpha' "$FO"/*.md | cut -d: -f1)"
done
check "forms: R1..R6 each used once" bash -c 'for i in 1 2 3 4 5 6; do test "$(grep -c "^- \*\*R$i:\*\*" "$1")" = 1 || exit 1; done' _ "$(only_note)"
check "forms: answer order shuffled per run" test "$(printf '%s' "$labels" | tr ' ' '\n' | sed '/^$/d' | sort -u | wc -l | tr -d ' ')" -gt 1

# Refusals: non-zero, nothing written, class and place but never the value.
rm -rf "$FO"
refuse() { # name, text, converter args... -> csv with TEXT as one answer, converted
  local name=$1 text=$2
  shift 2
  printf 'Timestamp,What should we change?\n11/13/2026 9:00:00,fine\n11/14/2026 9:00:00,"%s"\n' "$text" >"$F/$name.csv"
  conv --form-id refuse "$@" "$F/$name.csv"
}
refused() { # class, secret -> exit 3, no note, class and place named, value not printed
  local cls=$1 secret=$2
  test "$(cat "$T/rc")" = 3 && test ! -e "$FO" && grep -q "$cls pattern: .*column 2 \"What should we change?\", row 3" "$T/conv.out" \
    && ! grep -qF "$secret" "$T/conv.out"
}
for case_ in "email|someone@example.org|write to someone@example.org please" \
  "phone|555-123-4567|call me on 555-123-4567" "phone|7946 0958|or +44 20 7946 0958" \
  "card|1111 1111|card 4111 1111 1111 1111 ok"; do
  cls=${case_%%|*}
  secret=${case_#*|}
  secret=${secret%%|*}
  set +e; refuse r "${case_##*|}"; echo $? >"$T/rc"; set -e
  check "forms refusal: $cls pattern ($secret)" refused "$cls" "$secret"
done
mkdir -p "$FV/.binnacle"
printf '# names to refuse\nRobin Quill\nPat Lee\nPat\n' >"$FV/.binnacle/forms-stoplist"
set +e; refuse r "ask Robin Quill"; echo $? >"$T/rc"; set -e
check "forms refusal: default stop-list term" refused stop-list "Robin"
set +e; refuse r "Pat could plan earlier"; echo $? >"$T/rc"; set -e
check "forms refusal: a name on the stop-list without --subject" refused stop-list "Pat could"
check "forms subject: the declared subject's name passes the stop-list" refuse r "Pat Lee could plan earlier; Pat is great" --subject "Pat Lee"
check "forms subject: named in front-matter and answers" bash -c 'grep -qx "subject: \"Pat Lee\"" "$1" && grep -q "Pat is great" "$1"' _ "$(only_note)"
set +e; refuse r "Pat and Robin Quill" --subject "Pat Lee"; echo $? >"$T/rc"; set -e
check "forms subject: other stop-list names still refused" bash -c 'test "$(cat "$1")" = 3' _ "$T/rc"
rm -rf "$FO"
printf 'Sam Lee\n' >"$T/colleague-stoplist"
set +e; refuse r "Sam Lee was rude" --subject "Pat Lee" --stop-list "$T/colleague-stoplist"; echo $? >"$T/rc"; set -e
check "forms subject: a colleague sharing the subject's surname is refused" refused stop-list "Sam"
printf 'Pat Lee\nLee Quill\n' >"$T/colleague-stoplist"
set +e; refuse r "Pat Lee Quill helped" --subject "Pat Lee" --stop-list "$T/colleague-stoplist"; echo $? >"$T/rc"; set -e
check "forms subject: a stop-list name overlapping the subject's is refused" refused stop-list "Quill"
printf 'Lee Quill\n' >"$T/other-stoplist"
set +e; refuse r "Lee Quill helped" --stop-list "$T/other-stoplist"; echo $? >"$T/rc"; set -e
check "forms refusal: --stop-list file" bash -c 'test "$(cat "$1")" = 3' _ "$T/rc"
check "forms: a missing --stop-list file is an error" expect_fail conv --form-id x --stop-list "$T/missing" "$F/six.csv"
rm -f "$FV/.binnacle/forms-stoplist"

# Re-runs: the same form and window replaces its note only.
rm -rf "$FO"
check "forms re-run: first window" conv --form-id ms-form-1 "$F/msforms.csv"
check "forms re-run: a declared window" conv --form-id ms-form-1 --from 2026-10-01 --to 2026-10-31 "$F/msforms.csv"
check "forms re-run: another window is another note" test "$(find "$FO" -name '*.md' | wc -l | tr -d ' ')" = 2
head -n 3 "$F/msforms.csv" >"$F/msforms-two.csv"
check "forms re-run: same window exits 0" conv --form-id ms-form-1 --to 2026-11-10 "$F/msforms-two.csv"
check "forms re-run: still two notes" test "$(find "$FO" -name '*.md' | wc -l | tr -d ' ')" = 2
check "forms re-run: that window's note replaced" grep -qx 'respondents: 2' "$FO/form-${ms_hash:0:12}-2026-11-03-to-2026-11-10.md"
check "forms re-run: the other window's note kept" grep -qx 'respondents: 3' "$FO/form-${ms_hash:0:12}-2026-10-01-to-2026-10-31.md"
before=$(cd "$FO" && cksum ./*.md)
printf 'Completion time,What should we change?\n2026-11-03 10:00:00,mail jdoe@example.com\n' >"$F/leak.csv"
check "forms re-run: a refused re-run exits non-zero" expect_fail conv --form-id ms-form-1 --to 2026-11-10 "$F/leak.csv"
check "forms re-run: a refused re-run leaves the notes alone" test "$(cd "$FO" && cksum ./*.md)" = "$before"
check "forms: headers that differ between files are refused" expect_fail conv --form-id x "$F/msforms.csv" "$F/google.csv"
printf 'What should we change?\nnothing\n' >"$F/notime.csv"
printf '"Completion time";"Rate it, from 0 to 10, please";"What, if anything, should change?"\n2026-11-03 10:00:00;7;"less churn, more focus"\n' >"$F/semicolon.csv"
rm -rf "$FO"
check "forms csv: semicolon export with commas in quoted titles" conv --form-id semi --platform msforms "$F/semicolon.csv"
check "forms csv: semicolon columns kept apart" bash -c 'grep -qx "## 1. Rate it, from 0 to 10, please" "$1" && grep -qx "Rating: 1 answer, median 7." "$1" && grep -qx "## 2. What, if anything, should change?" "$1" && grep -Eqx "\- \*\*R1:\*\* less churn, more focus" "$1"' _ "$(only_note)"
check "forms: no timestamps needs --from and --to" expect_fail conv --form-id x --platform google "$F/notime.csv"
check "forms: no timestamps with --from and --to" conv --form-id notime --platform google --from 2026-11-01 --to 2026-11-02 "$F/notime.csv"
check "forms: no temporary files left" test -z "$(find "$FO" -name '.tmp-*')"
check "forms: nothing committed" test "$(git -C "$FV" rev-parse HEAD)" = "$fv_head"

# Mover: synced folder -> converter -> exports kept in processed/<form>/<window>/.
rm -rf "$FO"
SY=$T/onedrive/Binnacle\ forms
mkdir -p "$SY/team-pulse" "$SY/leaky" "$SY/unset" "$SY/nowin" "$FV/.binnacle/forms"
for i in 1 2 3; do
  printf 'Completion time,Rate the week (1-5),What went well?\n"11/1%s/2026 9:0%s:00",%s,"answer %s, with a comma"\n' "$i" "$i" "$((i + 2))" "$i" >"$SY/team-pulse/r$i.csv"
done
printf 'not a response\n' >"$SY/team-pulse/desktop.ini"
printf 'Completion time,What went well?\n11/12/2026 9:00:00,ask jdoe@example.com\n' >"$SY/leaky/r1.csv"
printf 'Completion time,What went well?\n11/12/2026 9:00:00,fine\n' >"$SY/unset/r1.csv"
printf 'Completion time,What went well?\n2026-11-12 9:00:00,fine\n' >"$SY/nowin/r1.csv"
printf '# team pulse\nform_title=Team pulse\nform_id=pulse-1\naudience=Platform team\nconsent_notice_version=v2\ninvited=9\ndate_order=mdy\nfrom=2026-11-11\nto=2026-11-14\n' \
  >"$FV/.binnacle/forms/team-pulse.conf"
sed 's/pulse-1/leaky-1/' "$FV/.binnacle/forms/team-pulse.conf" >"$FV/.binnacle/forms/leaky.conf"
sed 's/pulse-1/nowin-1/; /^to=/d' "$FV/.binnacle/forms/team-pulse.conf" >"$FV/.binnacle/forms/nowin.conf"
git -C "$FV" config binnacle.formsSyncDir "$SY"
mover() { "$repo/setup/forms/mover.sh" --vault "$FV" "$@" >"$T/mover.out" 2>&1; }
pulse=form-$(sha pulse-1 | cut -c1-12)
w1=2026-11-11-to-2026-11-14
w2=2026-12-01-to-2026-12-31
state() { # -> checksums of the inbox notes and every synced file, to show nothing changed
  (cd "$FO" && find . -type f -exec cksum {} + | sort)
  (cd "$SY" && find . -type f -exec cksum {} + | sort)
}
check "mover: one form exits 0" mover team-pulse
N=$(only_note || true)
check "mover: one note named for the declared window" test "${N##*/}" = "$pulse-$w1.md"
check "mover: settings reach the note" bash -c 'grep -qx "respondents: 3" "$1" && grep -qx "invited: 9" "$1" && grep -qx "consent_notice_version: \"v2\"" "$1" && grep -qx "platform: msforms" "$1" && grep -qx "collected_from: 2026-11-11" "$1" && grep -qx "collected_to: 2026-11-14" "$1"' _ "$N"
check "mover: rating and free text" bash -c 'grep -qx "Rating: 3 answers, median 4." "$1" && grep -Eq "R[1-3]:\*\* answer 2, with a comma" "$1"' _ "$N"
check "mover: converted exports moved out of the form folder" test -z "$(find "$SY/team-pulse" -name '*.csv')"
check "mover: converted exports kept in processed/<form>/<window>/" bash -c 'for i in 1 2 3; do test -f "$1/processed/team-pulse/$2/r$i.csv" || exit 1; done' _ "$SY" "$w1"
check "mover: other files left alone" test -f "$SY/team-pulse/desktop.ini"
check "mover: never commits" bash -c 'test "$(git -C "$1" rev-parse HEAD)" = "$2" && test -z "$(git -C "$1" diff --cached --name-only)"' _ "$FV" "$fv_head"
check "mover: no new responses is fine" mover team-pulse
check "mover: every folder, with refusals and a missing settings file, exits non-zero" expect_fail mover
check "mover: processed/ is not taken for a form" bash -c '! grep -q "form processed" "$1"' _ "$T/mover.out"
check "mover: refused form keeps its export" test -f "$SY/leaky/r1.csv"
check "mover: refusal names the class, not the value" bash -c 'grep -q "email pattern" "$1" && ! grep -q "jdoe@" "$1"' _ "$T/mover.out"
check "mover: missing settings keeps the export and says so" bash -c 'test -f "$1/unset/r1.csv" && grep -q "no settings file" "$2"' _ "$SY" "$T/mover.out"
check "mover: settings without from/to keep the export and say so" bash -c 'test -f "$1/nowin/r1.csv" && grep -q "nowin.conf needs the window as from=YYYY-MM-DD and to=YYYY-MM-DD" "$2"' _ "$SY" "$T/mover.out"
check "mover: only the converted note in the inbox" test "$(find "$FO" -name '*.md' | wc -l | tr -d ' ')" = 1
rm -rf "$SY/leaky" "$SY/unset" "$SY/nowin"
printf 'Completion time,Rate the week (1-5),What went well?\n11/20/2026 8:00:00,1,too late\n' >"$SY/team-pulse/out.csv"
before=$(state)
check "mover: a response outside the window is refused" expect_fail mover team-pulse
check "mover: the refusal names the file, not the value" bash -c 'grep -q "out.csv, row 2" "$1" && ! grep -q "too late\|11/20" "$1"' _ "$T/mover.out"
check "mover: nothing changed by an out-of-window refusal" test "$(state)" = "$before"
rm -f "$SY/team-pulse/out.csv"
printf 'Completion time,Rate the week (1-5),What went well?\n11/12/2026 18:00:00,5,late same day\n' >"$SY/team-pulse/r4.csv"
check "mover: a late file in the same window exits 0" mover team-pulse
check "mover: same window, one complete note" bash -c 'test "$(find "$1" -name "*.md" | wc -l | tr -d " ")" = 1 && n=$1/$2.md && grep -qx "respondents: 4" "$n" && grep -q "answer 1, with a comma" "$n" && grep -q "answer 3, with a comma" "$n" && grep -q "late same day" "$n"' _ "$FO" "$pulse-$w1"
check "mover: every export of the window kept" test "$(find "$SY/processed/team-pulse/$w1" -name '*.csv' | wc -l | tr -d ' ')" = 4
printf 'Completion time,Rate the week (1-5),What went well?\n12/14/2026 8:00:00,4,next window\n' >"$SY/team-pulse/r5.csv"
before=$(state)
check "mover: a next-window file while the note waits is refused" expect_fail mover team-pulse
check "mover: nothing changed by that refusal" test "$(state)" = "$before"
sed -i.bak "s/^from=.*/from=2026-12-01/; s/^to=.*/to=2026-12-31/" "$FV/.binnacle/forms/team-pulse.conf"
check "mover: a new window while the last note waits is refused" expect_fail mover team-pulse
check "mover: that refusal names the waiting note" grep -q "$pulse-$w1.md, is not ingested yet" "$T/mover.out"
check "mover: nothing changed by the new-window refusal" test "$(state)" = "$before"
check "mover: --purge while the note waits is refused" expect_fail mover --purge team-pulse
check "mover: nothing purged" test "$(state)" = "$before"
mv "$FO/$pulse-$w1.md" "$T/ingested.md"
check "mover: after ingest the new window converts" mover team-pulse
check "mover: the new window's note holds only its responses" bash -c 'test "$(find "$1" -name "*.md" | wc -l | tr -d " ")" = 1 && grep -qx "respondents: 1" "$1/$2.md"' _ "$FO" "$pulse-$w2"
check "mover: old exports stay under their window" bash -c 'test "$(find "$1/$2" -name "*.csv" | wc -l | tr -d " ")" = 4 && test -f "$1/$3/r5.csv"' _ "$SY/processed/team-pulse" "$w1" "$w2"
mv "$FO/$pulse-$w2.md" "$T/ingested2.md"
check "mover: --purge once ingested exits 0" mover --purge team-pulse
check "mover: --purge deletes every processed export" test -z "$(find "$SY/processed/team-pulse" -name '*.csv')"
printf 'Completion time,Rate the week (1-5),What went well?\n12/15/2026 8:00:00,2,after ingest\n' >"$SY/team-pulse/r6.csv"
check "mover: a late file for an ingested window is refused" expect_fail mover team-pulse
check "mover: that refusal keeps the file" bash -c 'test -f "$1/team-pulse/r6.csv" && test -z "$(find "$2" -name "*.md")"' _ "$SY" "$FO"
check "mover: refuses a synced folder inside the vault" expect_fail mover --sync-dir "$FV/raw"
git -C "$FV" config --unset binnacle.formsSyncDir
check "mover: refuses without a synced folder" expect_fail mover
check "mover: says how to set it" grep -q 'binnacle.formsSyncDir' "$T/mover.out"
check "mover: .binnacle/ is gitignored" bash -c 'git -C "$1" check-ignore -q .binnacle/forms-stoplist && test -z "$(git -C "$1" status --porcelain -- .binnacle)"' _ "$FV"

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
check "work-brain setup: CLAUDE.md allows only the owner's Forms flow" grep -q "own Microsoft Forms flow may" "$B/CLAUDE.md"
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

# People zone: wiki/people/ is written only with binnacle.peopleZone true.
printf 'A survey note.\n' >"$B/raw/inbox/survey.md"
git -C "$B" add -A
git -C "$B" commit -qm capture3
main_before=$(git -C "$B" rev-parse main)
sleep 1
check "people zone off: a run writing wiki/people/ fails" \
  expect_fail env STUB_CLAUDE_MODE=people STUB_PROMPT="$T/prompt.txt" "$B/bin/binnacle-run"
check "people zone off: the prompt says off" grep -q 'is \*\*off\*\* in this vault' "$T/prompt.txt"
check "people zone off: main unchanged" test "$(git -C "$B" rev-parse main)" = "$main_before"
people_branch() { git -C "$B" for-each-ref --format='%(refname:short)' 'refs/heads/binnacle-run/*'; }
check "people zone off: the page reverted on the run branch" \
  expect_fail git -C "$B" cat-file -e "$(people_branch):wiki/people/sample-subject.md"
check "people zone off: the audit note names the page" bash -c 'b=$2; git -C "$1" show "$b:$(git -C "$1" ls-tree -r --name-only "$b" -- audit/runs | sort | tail -n 1)" | grep -q "wiki/people/sample-subject.md"' _ "$B" "$(people_branch)"
people_branch | xargs git -C "$B" branch -q -D
git -C "$B" config binnacle.peopleZone true
sleep 1
check "people zone on: the run exits 0" env STUB_CLAUDE_MODE=people STUB_PROMPT="$T/prompt.txt" "$B/bin/binnacle-run"
check "people zone on: the prompt says on" grep -q 'is \*\*on\*\* in this vault' "$T/prompt.txt"
check "people zone on: the page reaches main" test -f "$B/wiki/people/sample-subject.md"
git -C "$B" config --unset binnacle.peopleZone

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
