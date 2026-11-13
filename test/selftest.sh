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

scripts=(.githooks/pre-commit bin/binnacle-run bin/binnacle-import setup/common/lib.sh setup/common/install-hooks.sh
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
[ -z "${STUB_TOKEN_LOG:-}" ] || echo "token=${GH_TOKEN:-}" >>"$STUB_TOKEN_LOG"
case "$1 $2" in
  "pr list") [ -n "${STUB_GH_OPEN:-}" ] && echo "https://github.com/example/binnacle/pull/9"; exit 0 ;;
  "pr create")
    prev=
    for a in "$@"; do [ "$prev" = --body-file ] && cp "$a" "$STUB_BODY"; prev=$a; done
    echo "https://github.com/example/binnacle/pull/1"; exit 0 ;;
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
