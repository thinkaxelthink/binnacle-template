# shoyu setup checklist

shoyu is the only machine where Claude Code writes the wiki. Do
`setup/github/CHECKLIST.md` first.

## Before the script

- [ ] **[shoyu, human]** Install Homebrew, then `brew install git gh gitleaks`.
      If Homebrew on this Mac belongs to another macOS user, install
      gitleaks per-user instead: download the macOS archive and the
      checksums file for the latest release from
      github.com/gitleaks/gitleaks/releases, verify it with
      `shasum -a 256 -c --ignore-missing gitleaks_<version>_checksums.txt`,
      and put the `gitleaks` binary in `~/.local/bin`. The script below
      records where gitleaks is, so the hook finds it even when Obsidian
      runs git without `~/.local/bin` on its PATH.
- [ ] **[shoyu, human]** Install Claude Code and log in (`claude`, then
      follow the login prompt).
- [ ] **[shoyu, human]** Install or update Obsidian to 1.13 or later
      (obsidian.md, or Settings > General > Check for updates).
- [ ] **[shoyu, human]** Create the shoyu fine-grained token (binnacle only;
      Contents and Pull requests read/write; see the GitHub checklist).
- [ ] **[shoyu, human]** Store it for `gh`, which `bin/binnacle-run` uses to
      open PRs and enable auto-merge:
      `security add-generic-password -U -s binnacle-gh-token -a "$USER" -w`
      (prompts for the token; nothing lands in shell history).

      If the keychain is unreachable from the session that runs
      `bin/binnacle-run` (e.g. over SSH, where `security` fails with "User
      interaction is not allowed"), keep the token in a file instead: one
      line, owned by you, mode 600 (`chmod 600`), outside the vault, e.g.
      `~/.config/binnacle/gh-token`. Pass it to the script below as
      `BINNACLE_GH_TOKEN_FILE=~/.config/binnacle/gh-token`, which records it
      as `git config binnacle.ghTokenFile`. The keychain item still wins when
      it is readable; `bin/binnacle-run` refuses a file other users can read.
- [ ] **[shoyu, human]** Clone the vault; when git asks, the username is
      your GitHub login and the password is the token. The macOS keychain
      keeps it for later pushes.

      ```sh
      git clone https://github.com/thinkaxelthink/binnacle.git ~/binnacle
      ```

## The script

```sh
~/binnacle/setup/shoyu/setup.sh   # safe to re-run
```

It verifies the clone at `~/binnacle`, marks it
`git config binnacle.role wiki-writer`, sets the commit identity in the
vault clone only (`user.name` from `BINNACLE_GIT_NAME`, else the existing
local name, else `BINNACLE_OWNER`; `user.email` from `BINNACLE_GIT_EMAIL`,
else the existing local email, else `<BINNACLE_OWNER>@users.noreply.github.com`)
so Obsidian Git's commits never carry the machine's hostname, installs the
gitleaks + 10 MB pre-commit hook and records the gitleaks path in
`git config binnacle.gitleaks`, and checks `git`, `gh`, `claude`, and
Obsidian >= 1.13.

## In Obsidian

- [ ] **[shoyu, human]** Open folder as vault: `~/binnacle`. Signing in to
      an Obsidian account is optional; git is the sync, not Obsidian Sync.
- [ ] **[shoyu, human]** Settings > Community plugins: turn them on, install
      and enable **Obsidian Git**.
- [ ] **[shoyu, human]** Obsidian Git settings: auto pull on startup on;
      auto commit-and-sync every 10 minutes (or your preference); pull
      before push on; **Sync method: Rebase** (not Merge). These settings
      stay on this Mac (`data.json` is not committed).
- [ ] **[shoyu, human]** Settings > Core plugins: **Bases** on. Open
      `audit/runs.base`.
- [ ] **[shoyu, human]** Commit and push `.obsidian/` once (Obsidian Git:
      "Commit-and-sync"), so other devices get the plugin list.

## First run

- [ ] **[shoyu, human]** Drop a test note into `raw/inbox/`, let Obsidian
      Git push it, then:

      ```sh
      ~/binnacle/bin/binnacle-run --dry-run
      ~/binnacle/bin/binnacle-run
      ```

      The run happens in a temporary worktree; `~/binnacle` stays on `main`.
      Expect a PR URL, auto-merge on, and a new note in `audit/runs/` after
      the merge.

## Nightly runs

Proposed: a LaunchAgent for your shoyu user runs `bin/binnacle-nightly`
every day at **03:30 local time**. The wrapper runs the same
`bin/binnacle-run` as above (branch, ingest, flag-only lint, `wiki/log.md`,
audit note, PR, auto-merge once the gitleaks check passes), with a fixed
PATH, and logs to `~/Library/Logs/binnacle/nightly.log`. A failed run
leaves its PR open with the reason in the audit note and is never retried;
later runs refuse until you merge or close that PR. An empty inbox means no
run and no PR. 03:30 is after late-evening captures have synced and
outside the 02:00-03:00 hour that daylight-saving changes skip or repeat.

Nothing is scheduled until you install it; `setup.sh` never does.

- [ ] **[shoyu, human]** Approve the time (03:30, or pick another below).
- [ ] **[shoyu, human]** Do "First run" above by hand first, so you know the
      token and Claude Code login work. The nightly run happens in your
      logged-in session, so the keychain item is used when it is readable,
      else `binnacle.ghTokenFile`. If your login keychain locks itself (on
      sleep or after a timeout), a 03:30 run may wait on an unlock prompt:
      in that case keep the token only in the file and delete the keychain
      item (`security delete-generic-password -s binnacle-gh-token`).
- [ ] **[shoyu, human]** Install, on shoyu while logged in to its desktop:

      ```sh
      ~/binnacle/setup/shoyu/nightly.sh install
      # or another time (24-hour, local), e.g. 02:15:
      BINNACLE_NIGHTLY_HOUR=2 BINNACLE_NIGHTLY_MINUTE=15 ~/binnacle/setup/shoyu/nightly.sh install
      ```

      It writes `~/Library/LaunchAgents/com.binnacle.nightly.plist` and
      loads it with `launchctl bootstrap gui/<uid>` (no sudo). Re-run it to
      change the time.
- [ ] **[shoyu, human]** Check it: `~/binnacle/setup/shoyu/nightly.sh status`
      shows whether it is installed and loaded, its time, the last exit
      code launchd saw, and the start and end lines of the last run.

**Reading the log.** `tail -n 40 ~/Library/Logs/binnacle/nightly.log`.
Each run sits between `=== <date> binnacle-nightly start` and
`=== <date> binnacle-nightly end: exit <status>`. Exit 0 is a finished run
(a PR link), an empty inbox ("nothing to do") or a skip ("skipped: ...");
anything else is a failure, with the reason on the lines above and in the
run's audit note. Past 1 MB the log moves to `nightly.log.1`. Claude
Code's own output for a run stays in the temporary folder the log names.
If launchd cannot start the wrapper at all, its error is in
`~/Library/Logs/binnacle/launchd.log`.

**Pausing.** `~/binnacle/setup/shoyu/nightly.sh uninstall` unloads the job
and deletes the plist; `install` again resumes it.

How it behaves:

- **Sleep.** If shoyu is asleep at 03:30, launchd runs the job when it
  wakes (once, however many nights were missed). If shoyu is shut down,
  that night is skipped.
- **Logged in.** A LaunchAgent only runs while the shoyu user is logged in
  (a locked screen is fine). After a restart nothing runs until you log in
  again. If shoyu cannot stay logged in, the alternative is a cron entry
  for the shoyu user (`crontab -e`, e.g.
  `30 3 * * * $HOME/binnacle/bin/binnacle-nightly`): it runs without a
  login, but skips nights shoyu was asleep and needs
  `binnacle.ghTokenFile`, because the keychain is out of reach. The
  template does not set cron up.
- **Notion import.** While an import is in progress (`git config
  binnacle.importBranch` is set in `~/binnacle`), runs log "skipped: import
  in progress" and do nothing; the first run after the import finishes
  picks up the inbox. A local `import/*` branch left behind after the
  import does not stop runs.
- **One run at a time.** A run holds `~/binnacle/.git/binnacle-run.lock`;
  a run started meanwhile (by hand or by the schedule) logs "skipped:
  another binnacle-run is in progress". A lock left by a crashed run is
  cleared automatically.
- **Obsidian Git.** The run works in a temporary worktree from
  `origin/main` and never checks out, commits or pushes in `~/binnacle`,
  so Obsidian Git's pull and commit-and-sync carry on as usual. The run's
  `git fetch` writes only its own ref `refs/binnacle-run/base`; it never
  touches `refs/remotes/origin/main` or `FETCH_HEAD`, which Obsidian Git's
  pull uses. Captures Obsidian Git has not pushed by
  03:30 wait for the next night.
