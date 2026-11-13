# GitHub setup checklist

Do this first, once. Device checklists come after.

## Before the script

- [ ] **[any Mac, human]** The GitHub account must allow branch protection
      and auto-merge on a *private* repository. On a personal account that
      means GitHub Pro (GitHub Free only offers them on public repos).
      `setup/github/setup.sh` stops with a clear message if the plan is
      missing.
- [ ] **[any Mac, human]** Install the GitHub CLI (`brew install gh`) and
      log in as the repo owner: `gh auth login`. This interactive login is
      used only for this one-time admin script; devices use their own
      fine-grained tokens (below).
- [ ] **[any Mac, human]** `binnacle-template` is pushed to GitHub with
      `.github/workflows/secret-scan.yml` on its default branch.

## The script

```sh
setup/github/setup.sh --dry-run   # shows every call, changes nothing
setup/github/setup.sh             # safe to re-run
```

It marks the template repo as a template, creates `binnacle` from it as a
**private** repo, turns on auto-merge (squash) and delete-branch-on-merge,
and protects `main`:

- required status check `gitleaks` (the job in `secret-scan.yml`) before
  any PR merges, so AI PRs auto-merge only on a green scan;
- no required reviews; force pushes and branch deletion blocked;
- admins not enforced, so the owner's device captures (iPhone, Macs) can
  still push straight to `main`. The scan still runs on those pushes; it
  reports, it cannot block them.

## After the script

- [ ] **[browser, human]** In `binnacle` > Actions, confirm the
      `secret-scan` workflow ran on `main` and its job is named `gitleaks`.
- [ ] **[browser, human]** Settings > Branches shows the rule on `main`
      with `gitleaks` required.
- [ ] **[shoyu, human]** After shoyu setup, run one real `bin/binnacle-run`
      and confirm the PR waits for `gitleaks`, then merges by itself.
- [ ] **[iPhone or a Mac, human]** Push one capture straight to `main` and
      confirm it is accepted.

## Device tokens (fine-grained only)

Create one token per device at GitHub > Settings > Developer settings >
Personal access tokens > **Fine-grained tokens**. Never use a classic
token: it reaches every repository you own.

| Device | Repository access | Permissions | Stored in |
|---|---|---|---|
| shoyu | Only select repositories: `binnacle` | Contents: read and write; Pull requests: read and write | macOS keychain (git credential helper, and item `binnacle-gh-token` for `gh`, or a mode-600 file when the keychain is unreachable: setup/shoyu/CHECKLIST.md) |
| work Mac | Only select repositories: `binnacle` | Contents: read and write | macOS keychain (git credential helper) |
| iPhone | Only select repositories: `binnacle` | Contents: read and write | GitSync |

Metadata: read-only is added automatically. Give each token an expiry and
a name that says which device holds it, so one device can be revoked alone.
No token ever goes into the vault, a script or `.obsidian/`.
