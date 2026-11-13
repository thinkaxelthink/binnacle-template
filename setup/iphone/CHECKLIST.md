# iPhone setup checklist

Read and capture only. All steps are human steps on the iPhone; there is no
script. Do `setup/github/CHECKLIST.md` and shoyu first.

The iPhone cannot run the pre-commit hook, so the gitleaks Action on every
push is the only secret check for its commits. Never paste a password, key
or token into a note, and keep attachments under 10 MB.

## Install

- [ ] **[iPhone, human]** App Store: install **Obsidian**.
- [ ] **[iPhone, human]** App Store: install **GitSync** by ViscousPotential
      Ltd (free tier): <https://apps.apple.com/app/id6744980427>. It is a
      standalone iOS app, not an Obsidian community plugin. Obsidian's
      plugin list has look-alikes, "GitSync Portal" (Kai Liu) and
      "GitSync.md Connect" (codybontecou); do not install them.
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

These automations are made in Apple's **Shortcuts** app (the iOS app,
Automation tab), not in Obsidian's settings or GitSync's settings.

GitSync offers a single Shortcuts action, **Sync Now** ("Synchronize the
currently selected repository"); there is no separate pull action or
commit-and-push action. One sync fetches, pulls, stages, commits and pushes,
so both automations use **Sync Now**: on open it brings down remote changes,
on close it commits and pushes the new notes. Source:
<https://github.com/ViscousPot/GitSync/blob/main/ios/Runner/SyncNowIntent.swift>
(the action's definition) and
<https://github.com/ViscousPot/GitSync> (README feature list: what a sync does).

- [ ] **[iPhone, human]** In GitSync, open the `binnacle` repository's
      **Quick Sync Settings** and turn on **Use for Sync Shortcut**, so
      **Sync Now** acts on `binnacle`.
- [ ] **[iPhone, human]** Shortcuts > Automation > New > App > Obsidian >
      **Is Opened** > Run Immediately. Action: GitSync's **Sync Now**
      (pulls the `binnacle` repository).
- [ ] **[iPhone, human]** Shortcuts > Automation > New > App > Obsidian >
      **Is Closed** > Run Immediately. Action: GitSync's **Sync Now**
      (commits and pushes the `binnacle` repository).
- [ ] **[iPhone, human]** Test: add a note in `raw/inbox/`, close Obsidian,
      check the commit on GitHub and that the `gitleaks` check passed.

## Writing

- [ ] **[iPhone, human]** Write only in `raw/inbox/` (captures) and
      `soundings/` (hand-written notes). Read everything else.
