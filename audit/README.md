# Audit

One note per AI run in `audit/runs/<run-id>.md`, written by
`bin/binnacle-run` on shoyu. Open `runs.base` in Obsidian (1.9 or later,
Bases core plugin enabled) for a table of every run.

Each note's frontmatter records: `date`, `status` (`ok` / `failed`),
`sources` (raw files processed, as links), `pages` (wiki pages created or
changed, as links), `lint_flags` (count), `pr` (pull request URL),
`merged`, and `reason` (why a run failed). The body repeats this and holds
the run's lint flags and ingest notes.

`merged` values:

- `pending`: the run succeeded and auto-merge is on; GitHub merges the PR
  once the gitleaks check passes.
- `false`: the run failed; the PR was left open without auto-merge and
  `reason` says why. Nothing retries; fix and merge the PR by hand, or close
  it, before the next run (a run refuses to start while a run PR is open).
- `true`: the note is on `main`. A note can only reach `main` by its PR
  being merged, so the next run flips any earlier `pending` or `false` it
  finds on `main` to `true`.

A failed run's note lives on its PR branch until that PR is merged, so the
table on `main` shows it only after merging. Open run PRs are the list of
failed runs still waiting for you.

Only `bin/binnacle-run` and Claude Code on shoyu write here, and only on a
run branch. See CLAUDE.md, "Audit notes".
