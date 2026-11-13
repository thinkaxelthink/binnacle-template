# iPhone setup checklist

Read and capture only. All steps are human steps on the iPhone; there is no
script. Do `setup/github/CHECKLIST.md` and shoyu first.

The iPhone cannot run the pre-commit hook, so the gitleaks Action on every
push is the only secret check for its commits. Never paste a password, key
or token into a note, and keep attachments under 10 MB.

## Install

- [ ] **[iPhone, human]** App Store: install **Obsidian**.
- [ ] **[iPhone, human]** App Store: install **GitSync** (free tier).
- [ ] **[iPhone, human]** Create the iPhone fine-grained token (binnacle
      only; Contents read/write; see the GitHub checklist).

## Clone

- [ ] **[iPhone, human]** In Obsidian, create an empty vault named
      `binnacle` stored on the iPhone (not iCloud), then close Obsidian.
- [ ] **[iPhone, human]** In GitSync, add the repository
      `https://github.com/thinkaxelthink/binnacle.git` with HTTPS and the
      token, and point it at Obsidian's `binnacle` vault folder. Let it
      clone.
- [ ] **[iPhone, human]** Open Obsidian; the vault shows `raw/`,
      `soundings/`, `wiki/`, `audit/`.

## Sync automation (Shortcuts)

- [ ] **[iPhone, human]** Shortcuts > Automation > New > App > Obsidian >
      **Is Opened** > Run Immediately. Action: GitSync's sync (pull)
      action for the `binnacle` repository.
- [ ] **[iPhone, human]** Shortcuts > Automation > New > App > Obsidian >
      **Is Closed** > Run Immediately. Action: GitSync's sync (commit and
      push) action for the `binnacle` repository.
- [ ] **[iPhone, human]** Test: add a note in `raw/inbox/`, close Obsidian,
      check the commit on GitHub and that the `gitleaks` check passed.

## Writing

- [ ] **[iPhone, human]** Write only in `raw/inbox/` (captures) and
      `soundings/` (hand-written notes). Read everything else.
