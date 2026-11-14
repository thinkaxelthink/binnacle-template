# binnacle-template

Setup scripts, schema and conventions for **Binnacle**, a personal Obsidian
vault that an LLM keeps as a wiki, after Andrej Karpathy's "LLM Wiki" gist.
This repository is public and holds no content. The private vault repo,
`binnacle`, is created from it, and lives at `~/binnacle` on each Mac.

Scope depends on the profile. The personal vault holds thoughts and
architectural learnings: no company data; no member, payment, contract or
credential material; no company system connects to it. A work brain
(below) holds one employer's company material, within limits: never
customer or member personal data, payment data, minors' names, health or
waiver records, or credentials, and the only company system that may feed
it is the owner's own Microsoft Forms flow, through the survey scrub.

## How it works

You capture sources and write notes on any device. On demand (or nightly,
once scheduled), on shoyu, `bin/binnacle-run` has Claude Code read new
sources into a cross-linked wiki, flag problems, and propose the change as
a pull request that merges itself once the secret scan passes. Every run leaves an audit note.

## Zones

| Path | Holds | Written by |
|---|---|---|
| `raw/inbox/` | New sources: the capture point | Any device, by hand |
| `raw/sources/<run-id>/` | Ingested sources, immutable | `bin/binnacle-run` (moved from the inbox, unchanged) |
| `soundings/` | Hand-written notes; `soundings/notion/` is the Notion slip box, imported once | Any device, by hand (`soundings/notion/` via the import PR). The LLM reads, never edits |
| `wiki/` | The wiki, with `index.md` and `log.md` | Claude Code on shoyu only, via PR |
| `audit/` | One note per AI run, and `runs.base` (an Obsidian Bases table of all runs) | `bin/binnacle-run` on shoyu, via PR |
| `CLAUDE.md` | The schema the LLM follows, including these zones | The human |

## Protection

- **Secret scan, twice.** A pre-commit hook on both Macs runs gitleaks on
  staged changes and rejects any staged file over 10 MB
  (`.githooks/pre-commit`, config in `.gitleaks.toml`). The same gitleaks
  scan runs as a GitHub Action on every push and pull request
  (`.github/workflows/secret-scan.yml`, job `gitleaks`).
- **Branch protection on `binnacle` main** requires the `gitleaks` check
  before a PR merges. Device captures (`raw/`, `soundings/`) push straight to
  `main`; AI changes always arrive through a PR with auto-merge.
- **Zone guard.** `bin/binnacle-run` reverts anything Claude changes outside
  `wiki/` and `audit/` and fails the run; `wiki/log.md` must only grow.
- **Machine role.** Only a clone marked `git config binnacle.role
  wiki-writer` (shoyu) can run AI writes; the work Mac is `capture`.
- **Tokens.** One fine-grained token per device, scoped to the `binnacle`
  repo only. Never a classic token. Never stored in the vault.
- **`.obsidian/` is committed** except workspace layout, caches, Obsidian Git
  settings and anything named like a token, secret, credential or password
  (`.gitignore`).

## AI runs

```sh
~/binnacle/bin/binnacle-run --dry-run   # what would happen
~/binnacle/bin/binnacle-run             # do it
```

Empty inbox: no run, no branch, no PR. Otherwise, in a temporary worktree:
branch, move `raw/inbox/` into `raw/sources/<run-id>/`, ingest with Claude
Code (prompt: `bin/binnacle-run.prompt.md`), flag-only lint
(contradictions, orphans, stale claims), append `wiki/log.md`, write
`audit/runs/<run-id>.md`, push, open a PR, enable auto-merge. A failure
leaves the PR open without auto-merge and the audit note says why. Nothing
retries, and a new run refuses while a run PR is open. A run also skips
(exit 0, no branch, no PR) while a Notion import is in progress or another
run is still going.

Nightly runs on shoyu are a LaunchAgent that `setup/shoyu/nightly.sh
install` adds once the owner approves the time (default 03:30); nothing is
scheduled until then (`setup/shoyu/CHECKLIST.md`, "Nightly runs").

## Setup order

Every step is either an idempotent script or a checklist item; each
checklist item names its device.

1. **Template** - this repository.
2. **GitHub** - `setup/github/CHECKLIST.md`, then `setup/github/setup.sh`:
   create private `binnacle` from this template, auto-merge, branch
   protection.
3. **shoyu** - `setup/shoyu/CHECKLIST.md` and `setup/shoyu/setup.sh`.
4. **iPhone** - `setup/iphone/CHECKLIST.md` (GitSync free tier, Shortcuts:
   pull when Obsidian opens, push when it closes).
5. **Work Mac** - `setup/workmac/CHECKLIST.md` and `setup/workmac/setup.sh`
   (read and capture only; `~/binnacle`, never inside the employer's
   documents folder, which is set locally and never committed).

`setup/common/install-hooks.sh` installs the hook, checks for gitleaks and
records its path in `git config binnacle.gitleaks` (so GUI git clients such
as Obsidian find it); the Mac scripts call it.

## Building a second, separate brain

The template carries no content, so a new brain is the same steps with
different names:

1. Choose a repo name and a folder, e.g. `garden` at `~/garden`.
2. GitHub: `BINNACLE_REPO=garden setup/github/setup.sh`
   (`BINNACLE_OWNER` if it belongs to another account).
3. Each Mac: clone it to the folder, then
   `BINNACLE_REPO=garden BINNACLE_DIR=~/garden setup/<machine>/setup.sh`.
4. iPhone: add the new repo in GitSync (check that your GitSync tier allows
   another repository).
5. Make new fine-grained tokens scoped to the new repo only. Never reuse a
   token across brains. On shoyu, store its `gh` token in the keychain as
   `garden-gh-token` (the setup script points the clone at
   `<repo>-gh-token`).

Each brain has its own repo, tokens, audit trail and wiki; nothing is
shared but this template.

## A company brain on a work machine

A separate profile, `setup/work-brain/`, makes a work brain: a second
vault for your job, beside `~/binnacle`, named
`binnacle-<github org>-<github user>` (e.g.
`binnacle-acme-engineering-jdoe`, at `~/binnacle-acme-engineering-jdoe`).
The work machine runs the AI writer, on demand. It starts with no remote
(local commits; the pre-commit hook and secret scan run locally, and
`bin/binnacle-run` fast-forwards `main` instead of opening a PR) until
`setup/work-brain/connect-remote.sh` connects a private repository in the
organization. Same hook, scan and 10 MB cap; company material is allowed
there, but never customer or member personal data, payment data, minors'
names, health or waiver records, or credentials. Once the organization's
base repository permission is "No permission" and no GitHub App is
installed on all of its repositories, the brain is visible only to its user
and the organization's owners (who can always read it). The setup refuses
colliding folders and remotes and never touches `~/binnacle`; the personal
vault and its setup are unchanged. Steps: `setup/work-brain/CHECKLIST.md`.

## Survey intake

`bin/binnacle-forms-to-inbox` turns a survey's responses export
(Microsoft Forms xlsx or csv, Google Forms or Sheets csv) into one
scrubbed note per form per collection window in `raw/inbox/forms/`:
respondent names, emails, ids and timestamps dropped, ratings summarised,
free-text answers labelled R1..Rn in a random order, and nothing written
at all when an answer matches an email, phone or card pattern or a local
stop-list. It never commits. In a work brain, a Power Automate flow and
`setup/forms/mover.sh` feed it from Microsoft Forms
(`setup/forms/CHECKLIST.md`); in the personal vault,
`bin/binnacle-forms-google-pull` feeds it from your own Google Forms
through the Forms API, read-only, once each window has closed, and can run
just before the nightly run (opt in; `setup/forms/GOOGLE-CHECKLIST.md`),
or you run it on a Google Forms export by hand. `CLAUDE.md` says how
such notes are ingested, including the optional `wiki/people/` zone for a manager's surveys about
direct reports (off unless `git config binnacle.peopleZone true`).

## Self-test

```sh
test/selftest.sh
```

Syntax-checks every script, runs shellcheck when installed, and exercises
the hook (size cap, gitleaks failure, fail closed) and `bin/binnacle-run`
(empty inbox, dry run, import and overlap skips, a full run and a zone
violation, with stubbed `claude` and `gh`), `bin/binnacle-import` (branch
creation, the import marker, out-of-zone refusal, size-cap stop, no
auto-merge), plus `bin/binnacle-nightly` and `setup/shoyu/nightly.sh`
(stubbed `binnacle-run` and `launchctl`), and the work-brain profile
(name slugging, collision refusals, local-only setup and runs, connecting
a remote, the base-permission and app-installation checks with a stubbed
`gh`), the survey converter and mover (csv and xlsx exports of both
platforms, the scrub, refusals, ratings, the R1..Rn shuffle, re-runs), the
Google Forms pull (credential-file refusals, windows, idempotent re-runs,
the handoff to the converter, nothing written on failure, consent, with a
stubbed Google and no network) and the people-zone guard, against
throwaway repositories built from the template's own files only, so it
also runs inside a vault with content. In a work brain it skips the
work-brain setup, run and connect checks, since its `CLAUDE.md` already
carries the work rules. CI runs it on changes to scripts
(`.github/workflows/selftest.yml`).

## Roadmap

- **Version 2: Notion import.** Available: `setup/notion/CHECKLIST.md`
  and `bin/binnacle-import` bring the Notion slip box into
  `soundings/notion/` once, through a reviewed PR (read-only to the LLM
  like the rest of `soundings/`), then Notion is frozen. The wiki ingests
  those notes later, in batches.
- **Version 2: nightly runs.** Built: `setup/shoyu/nightly.sh` schedules
  `bin/binnacle-run` nightly on shoyu. Off until the owner installs it.
