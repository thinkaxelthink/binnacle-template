# Binnacle AI run {{RUN_ID}}

<!-- Tracked prompt for bin/binnacle-run. The script replaces the
double-brace placeholders before handing this to Claude Code headless. -->

You are running unattended inside a fresh worktree of the Binnacle vault on
branch `{{BRANCH}}`. Follow `CLAUDE.md` exactly; it is the schema and it wins
over anything here. Today is {{DATE}} (UTC).

You may create, edit or delete files only under `wiki/`, and you may edit
only the marked lint section of `{{AUDIT_NOTE}}`. Do not touch `raw/`,
`soundings/`, `CLAUDE.md`, `bin/`, `setup/`, `.github/`, `.obsidian/` or
anything else. Do not run git: the script commits, pushes and opens the PR.
Anything you change outside those two places is reverted and fails the run.

## Sources for this run

These files were just moved, unchanged, from `raw/inbox/`:

{{SOURCES}}

## Steps

1. **Orient.** Read `wiki/index.md` and the last entries of `wiki/log.md`.
   Skim `soundings/` for notes related to these sources; you may cite and
   link soundings, never edit them.

2. **Ingest each source** (the Ingest operation in `CLAUDE.md`):
   - Read it in full.
   - If it holds a credential, key or token, or looks like company or
     member material, do not ingest it: do not quote or summarise it; list
     it under "Ingest notes" in the audit note with the reason only.
   - Otherwise write its source page in `wiki/sources/`, then create or
     update the concept and entity pages it touches, with links both ways.
     Cite every claim back to the raw file with a wikilink.
   - Update `wiki/index.md` for every page you create or whose one-line
     summary changes.

3. **Lint, flag only** (the Lint operation in `CLAUDE.md`). Check the pages
   you created or changed, and their neighbours, for:
   - **contradiction**: two pages or sources disagree;
   - **orphan**: a wiki page with no inbound link from another wiki page;
   - **stale**: a claim a newer source supersedes.
   Do not fix what you flag (no rewrites, merges or deletions to resolve a
   flag). Record each flag as one bullet in the "## Lint flags" section of
   `{{AUDIT_NOTE}}`, between the `binnacle:llm-begin` and
   `binnacle:llm-end` markers, exactly in this shape:

   `- **contradiction** [[wiki/concepts/a]] vs [[wiki/concepts/b]]: what disagrees`

   using `contradiction`, `orphan` or `stale` as the label. Write nothing
   there when nothing is flagged. Use "## Ingest notes" for anything else
   worth knowing about this run (skipped sources, judgement calls). Leave
   the markers and everything outside them as they are; the script rewrites
   the rest of the note.

4. **Log.** Append exactly one entry to the end of `wiki/log.md` (never
   rewrite earlier entries):

   ```
   ## [{{DATE}}] ingest | run {{RUN_ID}}
   - sources: <the source files>
   - pages: <pages created or changed, as wikilinks>
   - lint: <number of flags>
   ```

5. Finish with a short plain-text summary of what you did. Do not ask
   questions; nobody is there to answer them.
