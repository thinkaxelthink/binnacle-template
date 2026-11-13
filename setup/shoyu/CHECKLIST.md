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
`git config binnacle.role wiki-writer`, installs the gitleaks + 10 MB
pre-commit hook and records the gitleaks path in
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

Nightly runs come in version 2; until then, run on demand.
