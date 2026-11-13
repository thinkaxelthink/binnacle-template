# Work Mac setup checklist

Read and capture only. No AI writes here: the clone is marked
`binnacle.role=capture` and `bin/binnacle-run` refuses to run. Do
`setup/github/CHECKLIST.md` and shoyu first.

The vault lives at `~/binnacle`, never inside your employer's documents
folder (the script refuses that location). Capture only personal thoughts and
architectural learnings; nothing from work systems, no member, payment or
contract material, no credentials.

## Before the script

- [ ] **[work Mac, human]** Install Homebrew, then
      `brew install git gitleaks`.
- [ ] **[work Mac, human]** Install Obsidian.
- [ ] **[work Mac, human]** Record your employer's documents folder, so the
      script can refuse to place the vault inside it. This stays in this
      Mac's `~/.gitconfig` and is never committed; the script will not run
      without it:

      ```sh
      git config --global binnacle.workDocs "$HOME/Documents/<employer folder>"
      ```
- [ ] **[work Mac, human]** Create the work Mac fine-grained token (binnacle
      only; Contents read/write; see the GitHub checklist).
- [ ] **[work Mac, human]** Clone; when git asks, the username is your
      GitHub login and the password is the token (kept in the keychain):

      ```sh
      git clone https://github.com/thinkaxelthink/binnacle.git ~/binnacle
      ```

## The script

```sh
~/binnacle/setup/workmac/setup.sh   # safe to re-run
```

It refuses to run until `binnacle.workDocs` is set, refuses any vault
location inside that folder, verifies the clone, marks it
`git config binnacle.role capture`, and installs the gitleaks + 10 MB
pre-commit hook.

## In Obsidian

- [ ] **[work Mac, human]** Open folder as vault: `~/binnacle`.
- [ ] **[work Mac, human]** Community plugins on; enable **Obsidian Git**
      (already listed in the committed `.obsidian/`).
- [ ] **[work Mac, human]** Obsidian Git settings: auto pull on startup on;
      auto commit-and-sync on a timer; pull before push on.
- [ ] **[work Mac, human]** Write only in `raw/inbox/` (captures) and
      `soundings/` (hand-written notes). Read everything else.
- [ ] **[work Mac, human]** Do not run Claude Code or any other AI tool
      against `~/binnacle`.
