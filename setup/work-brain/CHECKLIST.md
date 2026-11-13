# Work brain setup checklist

A work brain is a second, separate Binnacle vault for your job: a company
brain on your work machine, where Claude Code writes the wiki from the
sources you capture. It sits beside the personal `~/binnacle` and shares
nothing with it but this template. Nothing here changes the personal vault,
its setup scripts, or the `binnacle.workDocs` guard on the work Mac.

The examples use the organization `acme-engineering` and the user `jdoe`;
use your own.

## Name and place

- **Name:** `binnacle-<github org>-<github user>`, lowercased; every run of
  characters other than letters, digits and `-` becomes one `-`. For
  `acme-engineering` and `jdoe`: `binnacle-acme-engineering-jdoe`. The
  same name is used for the folder, the GitHub repository and the keychain
  item for its token (`binnacle-acme-engineering-jdoe-gh-token`).
- **Folder:** `~/binnacle-acme-engineering-jdoe` by default, beside
  `~/binnacle`; `--dir` picks another.
- **Collisions:** the script refuses a folder that already exists and is
  not this brain's vault, a vault whose `origin` points elsewhere, and
  `~/binnacle` or anything inside it or resolving to it through a symlink.
  It never touches `~/binnacle`.

## What may go in

The same rules as the personal vault: the gitleaks + 10 MB pre-commit hook
on every commit, the gitleaks scan on GitHub once a remote is connected,
and no file over 10 MB. Company material may go in, within these limits,
which the script also writes into the vault's `CLAUDE.md` and run prompt
so Claude Code skips such sources:

- no customer or member personal data;
- no payment data;
- no minors' names;
- no health or waiver records;
- no credentials (passwords, API keys, tokens, private keys, connection
  strings).

Survey responses may cover HR topics when you are the manager running the
survey. No company system connects to the vault, with one exception: your
own Microsoft Forms flow may feed `raw/inbox/forms/`, and only through the
scrub in `bin/binnacle-forms-to-inbox`, which runs before anything is
committed (`setup/forms/CHECKLIST.md`). Follow your employer's own
policies on what may be stored where; they win over this list.

## Who can see it

Until you connect a remote, the brain exists only on this machine. Once
connected, it is a **private** repository in the organization. The
organization's owners can always read it: no setting removes their access
to any repository in the organization. Beyond you and the owners, it is
visible only **provided the organization's base repository permission is
"No permission" and no GitHub App is installed on all of its
repositories**. With any other base permission (Read, Write, Admin),
every member of the organization can read it. A GitHub App installed with
access to all repositories can read every new private repository, the
brain included, whatever the base permission. Anyone you later add to the
repository yourself, as a collaborator or through a team, can read it too;
keep that list empty. `connect-remote.sh` (and `setup.sh`, when `gh` is
logged in) reads the base permission and the app installations and warns,
with the fix, when the base permission is not "No permission" or an app is
installed on all repositories.

## Before the script

- [ ] **[work machine, human]** Install Homebrew, then
      `brew install git gitleaks gh`. If Homebrew on this machine belongs
      to another user, install gitleaks per-user instead: download the macOS
      archive and the checksums file for the latest release from
      github.com/gitleaks/gitleaks/releases, verify it with
      `shasum -a 256 -c --ignore-missing gitleaks_<version>_checksums.txt`,
      and put the `gitleaks` binary in `~/.local/bin`. `gh` is needed only
      to connect a remote later.
- [ ] **[work machine, human]** Install Claude Code and log in with the
      account your employer approves for this work (`claude`, then follow
      the login prompt).
- [ ] **[work machine, human]** Install Obsidian.
- [ ] **[work machine, human]** Clone this template somewhere outside
      `~/binnacle` (it is public and holds no content):

      ```sh
      git clone https://github.com/thinkaxelthink/binnacle-template.git ~/src/binnacle-template
      ```

## The script

```sh
~/src/binnacle-template/setup/work-brain/setup.sh \
  --org acme-engineering --user jdoe --git-email jdoe@acme.example
# safe to re-run; later runs can use the copy inside the vault:
~/binnacle-acme-engineering-jdoe/setup/work-brain/setup.sh --org acme-engineering --user jdoe
```

Without `--org` or `--user` it asks for them. `--dir` sets another folder.
It:

- refuses a colliding folder (see "Name and place") before changing
  anything, and refuses to copy from a checkout that holds vault content;
- creates the vault locally from the template, with **no remote**:
  `git init`, the template's files, the company content limits above
  written into `CLAUDE.md` and `bin/binnacle-run.prompt.md`;
- marks it `binnacle.role=wiki-writer` (this machine runs the AI writer),
  `binnacle.localOnly=true`, `binnacle.profile=work-brain`;
- sets the commit identity in this vault only, never `--global`:
  `user.name` from `--git-name`, else the existing vault-local name, else
  your GitHub user; `user.email` from `--git-email` (your work address),
  else the existing vault-local email, else
  `<user>@users.noreply.github.com`;
- installs the gitleaks + 10 MB pre-commit hook and records the gitleaks
  path, then makes the first commit through it;
- checks `git`, `claude`, `gh` and Obsidian (warnings only).

## In Obsidian

- [ ] **[work machine, human]** Open folder as vault:
      `~/binnacle-acme-engineering-jdoe`.
- [ ] **[work machine, human]** Community plugins on; install and enable
      **Obsidian Git**. Until a remote is connected, use only its commit
      (auto commit on a timer is fine); turn auto pull and push off.
- [ ] **[work machine, human]** Write only in `raw/inbox/` (captures) and
      `soundings/` (your own notes). Claude Code writes `wiki/` and
      `audit/`.

## On-demand runs

Runs happen when you start them; nothing is scheduled.

- [ ] **[work machine, human]** Put a test note in `raw/inbox/` and commit
      it (Obsidian Git, or `git add` and `git commit`); the run reads the
      inbox from the committed `main`. Then:

      ```sh
      ~/binnacle-acme-engineering-jdoe/bin/binnacle-run --dry-run
      ~/binnacle-acme-engineering-jdoe/bin/binnacle-run
      ```

      Local only, the run works in a temporary worktree on a
      `binnacle-run/<run-id>` branch (ingest, flag-only lint,
      `wiki/log.md`, audit note), commits through the pre-commit scan, then
      fast-forwards `main` to it. If the run fails, or `main` moved
      meanwhile, the branch is kept and the next run refuses until you
      merge it (`git merge binnacle-run/<run-id>`) or delete it
      (`git branch -D binnacle-run/<run-id>`).

## Connect a remote (later, when you decide)

The organization must allow branch protection and auto-merge on private
repositories (GitHub Team or Enterprise).

- [ ] **[browser, org owner]** Organization > Settings > Member privileges
      > Base permissions: **No permission**. If you are not an owner, ask
      one, and confirm it before connecting. Otherwise every member can read
      the brain.
- [ ] **[browser, org owner]** Organization > Settings > GitHub Apps: for
      each installed app, Configure > Repository access. Uninstall apps
      that are unused; set the rest to **Only select repositories**. An app
      with access to all repositories can read the brain, whatever the base
      permission. Reading the installations needs an owner (with `gh`, a
      login with the `admin:org` scope); if you are not one, ask one.
- [ ] **[browser, human]** Create an **empty private** repository
      `acme-engineering/binnacle-acme-engineering-jdoe`: no README,
      license or `.gitignore`. Add no collaborators or teams.
- [ ] **[browser, human]** Create a fine-grained token: resource owner
      `acme-engineering`, only this repository, Contents and Pull requests
      read and write, with an expiry (the organization may need to approve
      it). Never a classic token. Store it for `gh`, which
      `bin/binnacle-run` uses:
      `security add-generic-password -U -s binnacle-acme-engineering-jdoe-gh-token -a "$USER" -w`.
      Git asks for it on the first push (username: your GitHub login;
      password: the token) and keeps it in the keychain.
- [ ] **[work machine, human]** Connect:

      ```sh
      ~/binnacle-acme-engineering-jdoe/setup/work-brain/connect-remote.sh
      ```

      It re-runs the collision checks (any `origin` must be this
      repository, the repository must hold nothing but this brain's
      history, its name must be the brain's name, and it must be private
      when `gh` can see it), adds `origin`, pushes `main`, unsets
      `binnacle.localOnly`, then checks the base permission and the app
      installations. `--url` picks
      another address for the same repository name.
- [ ] **[browser, human]** In the repository: Actions shows the
      `secret-scan` workflow ran with a job named `gitleaks`. Settings >
      General: allow auto-merge, allow squash merging, automatically delete
      head branches. Settings > Branches: protect `main`, require the
      `gitleaks` status check, block force pushes and deletion.
- [ ] **[work machine, human]** Obsidian Git: turn on auto pull on startup,
      pull before push, **Sync method: Rebase**, and commit-and-sync.
- [ ] **[work machine, human]** One more on-demand run: it now pushes a
      `binnacle-run/<run-id>` branch, opens a PR and enables auto-merge,
      exactly like the personal vault on shoyu. Confirm the PR waits for
      `gitleaks`, then merges by itself.
