# Notion import checklist

A one-time import of the Notion slip box into `soundings/notion/`, using
Obsidian Importer's Notion API import on shoyu. The import lands on a
branch and reaches `main` only through a pull request that passes the
`gitleaks` check; you review it and merge it yourself. After that, Notion
is frozen and the wiki ingests the imported notes later, in batches.
`soundings/notion/` follows the `soundings/` rules: read-only to the LLM.

Do `setup/shoyu/CHECKLIST.md` first. Every step names its device. Do them
in order and stop at any step that does not hold.

Checked on 2026-11-13 against Importer 3.2.0 (commit `fa9444a`) and
Obsidian Git 2.43.0. UI labels below are quoted from those sources;
Notion's own labels change often, so if a label differs, follow the
meaning, not the word.

## Sources

- Obsidian Help, Import from Notion:
  <https://obsidian.md/help/import/notion>
- Importer repository and releases:
  <https://github.com/obsidianmd/obsidian-importer>,
  <https://github.com/obsidianmd/obsidian-importer/releases>
  (Notion API import: `src/formats/notion-api.ts`; token handling:
  `addSecretSetting` in `src/format-importer.ts`; labels: `src/i18n/en.ts`)
- Notion capabilities: <https://developers.notion.com/reference/capabilities>
- Notion authorization (sharing pages with a connection):
  <https://developers.notion.com/docs/authorization>
- Notion Help, connections:
  <https://www.notion.com/help/add-and-manage-connections-with-the-api>
- Obsidian Git command "Pause/Resume automatic routines":
  <https://github.com/Vinzent03/obsidian-git> (`src/commands.ts`)

What those sources establish:

- The API import exists. In Importer 3.2.0 you choose **Notion**, then
  **Notion account (recommended)**; the Help page calls the same thing
  File format **Notion (API)**. The other Notion method is **Notion
  (.zip)**, an HTML export; it is not used here.
- It needs a Notion access token (starts with `ntn_`), and the connection
  must be given access to each page or database to import.
- The token goes into Obsidian's keychain (SecretStorage), which the
  Importer source describes as device-local. The plugin's own
  `data.json` keeps only the secret's id (and per-device folders);
  `.gitignore` keeps that file out of git anyway.
- Databases become folders with a `.base` file (a table view; boards also
  get a kanban view in Obsidian 1.14+, without filters or sorts); database
  properties become note properties; formulas are converted or kept as
  static values (**Convert formulas**).
- Child pages import as their own notes, linked from the parent. Page and
  database mentions become links once the target is imported; a target
  outside the import stays unresolved. User mentions become the person's
  name, or a `mailto:` link when the connection may read email addresses
  (the capability below forbids that).
- Notion-hosted files are always downloaded; external files only with
  **Download external attachments**.
- Not imported: database views other than boards, linked data sources,
  and some formula functions. Large workspaces are slow (Notion API rate
  limits). The API importer is new; report bugs on its GitHub issues page.

## A. Confirm the content may enter the vault - stop if not

- [ ] **[any device, owner]** The slip box lives in a **personal** Notion
      workspace that you own, **not an employer's** workspace (not a work
      account, not a workspace your employer pays for or administers).
- [ ] **[any device, owner]** The pages to import hold only your own
      thoughts and learnings: **no employer or company material, no member
      or customer data, no payment, contract or credential material**
      (passwords, API keys, tokens, connection strings).
- [ ] **[any device, owner]** If either answer is no, or you are not
      sure: **stop here.** Do not create a connection or a token. Move
      what belongs in the vault into the personal workspace by hand first,
      or leave it out.

## B. Create the Notion connection (personal workspace only)

- [ ] **[browser, owner]** Signed in to the **personal** workspace, open
      the Notion connections dashboard
      (<https://app.notion.com/developers/connections>) and create a new
      connection: name it e.g. `binnacle-import`, authentication method
      **Access token**, installable in the personal workspace only.
- [ ] **[browser, owner]** Capabilities: **Read content** only. Leave
      **Update content**, **Insert content**, **Read comments** and
      **Insert comments** off; user capabilities **No user information**.
- [ ] **[browser, owner]** Give it access to the slip-box pages and
      databases only (the connection's content access list, or on each
      page: `•••` > **Add connections**). Nothing else in the workspace.
      Notion does not document whether sharing a parent page shares its
      children with a connection, so check in step C that every page you
      expect is listed.
- [ ] **[browser, owner]** Copy the token from the connection's
      configuration. Do not paste it into a file, a note, a chat, a
      terminal or the vault. It goes straight into Obsidian in step C.

## C. Import on shoyu

- [ ] **[shoyu, owner]** Have a checkout of `binnacle-template` (public)
      for the script; it works on `~/binnacle` without changing the
      vault's own copy of the template:

      ```sh
      git clone https://github.com/thinkaxelthink/binnacle-template.git ~/binnacle-template
      # or, if it is already there:
      git -C ~/binnacle-template pull --ff-only
      ```
- [ ] **[shoyu, owner]** Make the vault ignore Importer's settings file
      (vaults made from this template before the Notion import need this
      once; `start` refuses otherwise):

      ```sh
      grep -qxF '.obsidian/plugins/obsidian-importer/data.json' ~/binnacle/.gitignore \
        || printf '%s\n' '.obsidian/plugins/obsidian-importer/data.json' >>~/binnacle/.gitignore
      ```
- [ ] **[shoyu, owner]** In Obsidian: Settings > Community plugins >
      Browse, install **Importer** (by Obsidian) and enable it. It needs
      Obsidian 1.13 or later.
- [ ] **[shoyu, owner]** Let Obsidian Git commit-and-sync once (command
      palette: **Obsidian Git: Commit-and-sync**), so the `.gitignore` line
      and the plugin install are on `main` before the import starts.
- [ ] **[shoyu, owner]** Pause Obsidian Git: command palette,
      **Obsidian Git: Pause/Resume automatic routines**. Obsidian shows
      "Paused automatic routines." The pause survives a restart and also
      stops the pull on startup, so nothing commits to the import branch
      or pulls into it behind your back.
- [ ] **[shoyu, owner]** Start the branch:

      ```sh
      ~/binnacle-template/bin/binnacle-import start
      ```

      It refuses unless `~/binnacle` is the wiki-writer clone, on `main`,
      clean and equal to `origin/main`. It creates
      `import/notion-<UTC timestamp>`, records it in
      `git config binnacle.importBranch` (while it is set,
      `bin/binnacle-run`, by hand or nightly, skips without doing
      anything) and is safe to re-run. `bin/binnacle-import status`
      shows where things stand.
- [ ] **[shoyu, owner]** Open Importer (command palette: **Importer:
      Import notes**, or the ribbon icon), choose **Notion**, then
      **Notion account (recommended)**.
- [ ] **[shoyu, owner]** **Notion API token**: link a new secret, give it
      the id `notion`, paste the token as the secret. It is stored in
      Obsidian's keychain on this Mac, never in the vault.
- [ ] **[shoyu, owner]** Load the pages and tick the slip-box pages and
      databases (**Pages to import**). If something is missing, give the
      connection access to it in Notion and load again.
- [ ] **[shoyu, owner]** Options:
      - **Output folder**: `soundings/notion`
      - **Attachment location**: **In the folder specified below**, with
        **Attachment folder** `soundings/notion/attachments`. Any other
        choice can put files outside `soundings/notion/`, and `finish`
        will refuse them.
      - **Import linked databases**: off (on, it imports pages you did not
        select).
      - **Download external attachments**: your choice. On copies linked
        files into the vault (watch the 10 MB cap); off keeps their URLs.
      - **Save Notion ID**: on (the default), so each note keeps the id
        of its original page.
      - **Convert formulas**, **Single line breaks**, **Cover property
        name**, **Database property name**: defaults are fine.
- [ ] **[shoyu, owner]** Click **Import**, review the preview, click
      **Import** again and wait. When it ends, use **Save report** and
      keep the report outside the vault (e.g. `~/Documents`): it names
      skipped and failed items, which you need for the fidelity notes.

## D. Finish: commit, push, PR

- [ ] **[shoyu, owner]** Run:

      ```sh
      ~/binnacle-template/bin/binnacle-import finish
      ```

      It refuses, and lists the paths, if anything changed outside
      `soundings/notion/`; move or revert those and re-run. The import
      may also change `.obsidian/types.json` (Obsidian's property types);
      that is expected, and `finish` commits it and names it in the PR. It stops and
      lists every file over 10 MB for your decision (delete or shrink it
      in `soundings/notion/`, then re-run; the cap is never bypassed).
      It commits through the normal pre-commit hook (gitleaks and the
      size cap). If the hook finds a secret, nothing is committed: delete
      the note or line it names (rotate the secret if it was real; and it
      means a page held material that step A says must not be there),
      then re-run. Never commit with `--no-verify`.

      On success it pushes the branch, opens a PR to `main` with counts
      (files, notes, attachments, bases, total size) and an empty
      "Fidelity notes" section, does **not** enable auto-merge, switches
      `~/binnacle` back to `main` and clears `binnacle.importBranch`.
      Many files still go in one PR. Re-running finds the existing PR.

## E. Review, merge, resume

- [ ] **[shoyu or browser, owner]** Do the fidelity spot-checks below on
      the import branch (on GitHub, or `git -C ~/binnacle switch
      import/notion-<timestamp>` and look in Obsidian, then switch back
      to `main`). Write the findings into the PR's "Fidelity notes".
- [ ] **[browser, owner]** Confirm the `gitleaks` check is green, then
      merge the PR yourself.
- [ ] **[shoyu, owner]** Resume Obsidian Git: command palette,
      **Obsidian Git: Pause/Resume automatic routines** ("Resumed
      automatic routines."). It pulls the merged import into `~/binnacle`.
- [ ] **[shoyu, owner]** Confirm on GitHub that the PR is merged, then
      delete the local branch:
      `git -C ~/binnacle branch -D import/notion-<timestamp>` (`-D`,
      because a squash merge makes `-d` refuse).

## F. Close the door on Notion

- [ ] **[browser, owner]** Revoke the token: delete the connection in the
      Notion connections dashboard, or in Notion Settings > Connections
      choose `•••` next to it and disconnect it. Either way the token stops
      working.
- [ ] **[shoyu, owner]** Remove the `notion` secret from Obsidian's
      keychain (Settings > Keychain), if your Obsidian version lets you;
      revoking the connection already made it useless.
- [ ] **[browser, owner]** Freeze Notion: stop editing the slip box there
      (e.g. lock the pages, or mark the top page "frozen, moved to
      binnacle"). New notes go into `soundings/` from now on.

## Fidelity notes

Spot-check before merging, and record what you find in the PR's "Fidelity
notes" section (one bullet per finding: page, what is wrong, how bad).
The PR is the record; the import report from step C backs it up.

- **Links.** Open 5-10 notes with internal links. Child pages and page
  mentions should be links to the imported notes (in the vault's link
  format, Settings > Files and links). Search the import for leftovers
  such as `NOTION_PAGE:` or `NOTION_DB:` placeholders: they mean the
  target was not imported (not shared with the connection, or not
  selected). Note external links that point back to `notion.so`; they stop
  working once Notion is frozen.
- **Properties.** For each database, open its `.base` file and two or
  three notes: property names and types (dates, selects, multi-selects,
  checkboxes, relations as links), and the Notion ID property. Note
  formulas that became static values, rollups, and lost board filters or
  sorts.
- **Attachments.** Images and files should be in
  `soundings/notion/attachments` and display in their notes. Note any
  that failed (the report lists them), external files that stayed URLs,
  and anything you removed for the 10 MB cap.
- **Structure.** Nested pages sit in folders under their parent; the
  page count is close to Notion's. Note skipped or failed items from the
  report.
- **People.** No email addresses should appear (the connection had **No
  user information**); if any do, remove them before merging.
