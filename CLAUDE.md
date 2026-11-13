# Binnacle: vault schema

This vault is a personal LLM-maintained wiki, after Andrej Karpathy's
"LLM Wiki" pattern. Sources go in, the LLM keeps a cross-linked wiki of them
up to date, and the human reads, browses and asks questions in Obsidian.
This file is the schema: it tells the LLM how the vault is laid out and how
to maintain it. Read it before every operation and follow it exactly.

(In the `binnacle-template` repository itself there is no content: these
rules describe the vault the template produces, and changes to the template
machinery are ordinary reviewed code changes.)

Scope is personal: the owner's own thinking and architectural learnings.
The vault never holds company data, member or customer data, payment or
contract material, or credentials, and no company system connects to it.

## Zones

| Path | What it holds | Who writes it | The LLM may |
|---|---|---|---|
| `raw/inbox/` | New sources waiting for ingest. The capture point. | Any device, by hand; `raw/inbox/forms/` also by `bin/binnacle-forms-to-inbox` (scrubbed survey responses) | read only |
| `raw/` (everything else, e.g. `raw/sources/<run-id>/`) | Ingested sources, immutable. | `bin/binnacle-run` moves files here from the inbox, byte for byte | read only |
| `soundings/` | Hand-written notes. `soundings/notion/` holds the Notion slip box, imported once (`setup/notion/`); same rules. | Any device, by hand; `soundings/notion/` by the owner's import PR | read only, and link to them |
| `wiki/` | The wiki: pages, `index.md`, `log.md`. | Claude Code on shoyu only | read and write |
| `audit/` | One note per AI run, plus the `runs.base` table. | `bin/binnacle-run` and Claude Code on shoyu | write only the lint section of the current run's note |
| everything else (`CLAUDE.md`, `bin/`, `setup/`, `.github/`, `.obsidian/`, ...) | Template machinery. | The human | read only |

Rules that follow from the zones:

- `wiki/` and `audit/` are the only places the LLM writes. Never create,
  edit, move or delete anything in `raw/` or `soundings/`, even to fix a
  typo or a broken link. If a source or sounding looks wrong, flag it.
- Never write a secret (password, API key, token, private key, connection
  string) anywhere, and never copy one from a source into the wiki. If a
  source contains one, skip that source and say so in the run's audit note
  without repeating the secret.
- Never write company or member material into the vault. If a source looks
  like it, skip it the same way.
- The LLM never commits to `main`. AI changes reach `main` only through a
  pull request that passes the secret scan (`bin/binnacle-run` does this).
- Only shoyu (the clone with `git config binnacle.role wiki-writer`) runs AI
  writes. On any other machine, do not modify the vault at all.
- `wiki/people/` is written only while the people zone is on (see
  "People zone"); `bin/binnacle-run` reverts any other change there and
  fails the run.

## Wiki layout

```
wiki/
  index.md        catalog of every page (see below)
  log.md          append-only history of operations (see below)
  sources/        one page per ingested source
  concepts/       ideas, patterns, principles, architectural learnings
  entities/       named things: tools, systems, projects, books, people of public record
  syntheses/      comparisons, overviews and filed answers that span pages
  people/         optional, off by default: one page per survey subject
                  (see "People zone")
```

Page conventions:

- File names are kebab-case and unique across `wiki/`, e.g.
  `wiki/concepts/event-sourcing.md`.
- Every page starts with YAML frontmatter:

  ```yaml
  ---
  type: source | concept | entity | synthesis | person
  summary: one line, the same line used in index.md
  sources:
    - "[[raw/sources/<run-id>/<file>]]"
  created: YYYY-MM-DD
  updated: YYYY-MM-DD
  ---
  ```

- Link with Obsidian wikilinks using vault paths without `.md`, e.g.
  `[[wiki/concepts/event-sourcing]]`; for raw files keep the extension,
  e.g. `[[raw/sources/20261113T034700Z/talk.pdf]]`.
- Every factual claim cites the raw source it came from. Soundings may be
  cited as the owner's own view.
- Prefer updating an existing page over creating a near-duplicate.
- When a newer source disagrees with a page, keep both claims with their
  citations and flag the contradiction; do not silently overwrite.

## Form-response sources

`bin/binnacle-forms-to-inbox` turns a survey's responses export into one
note per form per collection window in `raw/inbox/forms/`, with
front-matter `type: form-responses` (form title, a hash of the form id,
platform, audience, an optional `subject`, the window, respondents and
invited counts, identity, consent notice version, retention review date).
Before the note was written it dropped respondent names, emails, ids and
timestamps, refused anything matching an email, phone or card pattern or
the local stop-list (the subject's name excepted), summarised ratings as a
distribution and a median, and labelled free-text answers R1..Rn in an
order that is random per note. Ingest such a source like any other, with
these rules:

- **One source page per survey window** in `wiki/sources/`: form title,
  window, audience, respondents of invited, identity, the rating
  summaries, and the themes of the free-text answers with how many
  respondents raised each.
- **Topic syntheses.** Themes that recur across surveys or windows go to
  one page per topic in `wiki/syntheses/`, updated window by window with a
  citation to each survey note, so trends stay visible.
- **Themes, not verbatim quotes, about a subject.** When the note names a
  `subject`, write about that person only in paraphrased themes with
  counts ("3 of 7 respondents ..."), never in quotes. Elsewhere quote
  sparingly, and never a passage that names or points to anyone.
- **Respondents stay anonymous.** Never guess or hint at who wrote an
  answer. R labels are random per note: never carry them into the wiki.

### People zone

`wiki/people/` is off by default. It is for a manager's surveys about
their own direct reports, and it is on only in a vault whose owner ran
`git config binnacle.peopleZone true` (turn it off again with
`git config --unset binnacle.peopleZone`); `bin/binnacle-run` tells the
LLM which in the run prompt. While it is on: one page per survey subject,
`wiki/people/<name>.md` with `type: person`, holding that person's themes
over time from the form-response sources whose `subject` names them, each
cited, under the theme rule above, and listed in `index.md` under People.
While it is off: never create or change anything in `wiki/people/`; a
subject's themes stay on the survey's source page.

## index.md

`wiki/index.md` is the content catalog and the first file to read for any
query. It lists every wiki page once, grouped under the headings Sources,
Concepts, Entities and Syntheses (and People, while the people zone is
on), one line each:

```
- [[wiki/concepts/event-sourcing]] - Storing state as an append-only log of events. (3 sources)
```

Update it in the same operation that creates a page or changes a page's
summary. Keep entries sorted alphabetically within each heading.

## log.md

`wiki/log.md` is the chronological record of what happened to the wiki.
Append only: never edit or delete an earlier entry. Each entry starts with
a heading in this exact form so the log stays greppable
(`grep '^## \[' wiki/log.md | tail -5`):

```
## [YYYY-MM-DD] <operation> | <title>
```

where `<operation>` is `ingest`, `query` or `lint`, followed by a few
bullets: sources, pages touched (as links), number of lint flags.

## Operations

### Ingest

Triggered by `bin/binnacle-run` on shoyu when `raw/inbox/` is not empty
(never on an empty inbox). The script branches, moves the inbox into
`raw/sources/<run-id>/`, then asks the LLM, per source:

1. Read the source fully. Skip it (with a reason in the audit note) if it
   holds secrets or company material.
2. Write a page in `wiki/sources/` summarising it: key points, notable
   quotes, and what it means for existing pages.
3. Create or update every concept and entity page the source touches; a
   single source may touch many pages. Add links in both directions.
4. Update `wiki/index.md`.
5. Run the lint pass below, then append one `ingest` entry to `wiki/log.md`.

The script then writes the audit note, opens a PR and enables auto-merge.

### Query

The owner asks a question, in Claude Code on shoyu. Read `wiki/index.md`
first, open the relevant pages, follow links, and answer with citations to
wiki pages and raw sources. Queries are read-only by default. If the owner
asks to keep an answer, file it as a page in `wiki/syntheses/` on a
`binnacle-query/<YYYY-MM-DD>-<slug>` branch with an `index.md` line and a
`query` entry in `wiki/log.md`, then open a PR with auto-merge; never
commit to `main`.

### Lint

Flag only, never fix. A lint pass looks for:

- **contradiction**: two pages, or a page and a source, disagree;
- **orphan**: a wiki page that no other wiki page links to;
- **stale**: a claim that a newer source supersedes.

Each flag is one bullet in the run's audit note:
`- **orphan** [[wiki/entities/foo]]: nothing links here`.
The owner decides what to do about flags.

## Audit notes

`audit/runs/<run-id>.md` records one AI run. `bin/binnacle-run` writes its
frontmatter and body; the LLM writes only between the
`<!-- binnacle:llm-begin -->` and `<!-- binnacle:llm-end -->` markers
(sections "Lint flags" and "Ingest notes"). Frontmatter fields:

| Field | Meaning |
|---|---|
| `date` | Run date (UTC) |
| `status` | `ok` or `failed` |
| `sources` | Links to the raw files processed |
| `pages` | Links to wiki pages created or changed |
| `lint_flags` | Number of lint flags |
| `pr` | Pull request URL |
| `merged` | `pending` (auto-merge on), `false` (failed, PR left open) or `true` (on `main`) |
| `reason` | Why the run failed, empty when ok |

`audit/runs.base` tables every run in Obsidian.
