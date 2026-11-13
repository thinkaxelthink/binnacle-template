# Survey intake checklist (work brain)

Brings Microsoft Forms survey responses into a work brain
(`setup/work-brain/CHECKLIST.md`) as one scrubbed note per form per
collection window. A Power Automate flow writes each response as a small
CSV file into a OneDrive folder synced to the work machine; when a window
closes, you run `setup/forms/mover.sh`, which converts those files with
`bin/binnacle-forms-to-inbox` into `raw/inbox/forms/` and keeps them in a
`processed/` folder beside them until you purge them.
Nothing is committed for you: you review the note, then commit it, and
the pre-commit secret scan runs as usual.

The examples use the vault `~/binnacle-acme-engineering-jdoe` and a form
folder `team-pulse`; use your own.

## The vault rule change

A work brain's rule is that no company system connects to it. This adds
exactly one exception: **your own Microsoft Forms flow may feed
`raw/inbox/forms/`, and only through the converter's scrub, which runs
before anything is committed.** The scrub drops respondent names, emails,
ids and per-response timestamps, and refuses the whole form (writing
nothing) when an answer matches an email, phone or card number pattern or
a term on your local stop-list. The survey's subject, when you name one,
is the only name allowed through. Survey responses may cover HR topics
when you are the manager running the survey. Follow your employer's own
policies (HR, privacy, retention); they win over this checklist.

## The form

- [ ] **[browser, human]** Create the form in your own Microsoft Forms
      account (not a group form).
- [ ] **[browser, human]** Settings > Who can fill out this form: **Only
      people in my organization can respond**. **Record name: off**,
      unless the survey is meant to be attributed (`identity=attributed`
      below); even then the note never names respondents.
- [ ] **[browser, human]** Put a notice at the top of the form: what is
      asked, who reads the answers, that an AI assistant summarises them
      into your private notes, how long they are kept (the note carries a
      `retention_review` date 12 months after the window ends), and a
      version, e.g. "Notice v1" (`consent_notice_version` below). Have HR
      review it before first use.
- [ ] **[browser, human]** Ask for no names, emails or phone numbers.
      Use Rating questions (0-10) or Likert questions for scales; they
      become a distribution and a median.

## The flow (Power Automate)

- [ ] **[browser, human]** In OneDrive for Business, create the folder
      `Binnacle forms`, and in it one folder per form, e.g.
      `Binnacle forms/team-pulse`. Share it with no one.
- [ ] **[browser, human]** Power Automate > Create > Automated cloud
      flow, trigger **When a new response is submitted** (Microsoft
      Forms), Form Id: your form. Then add, in order:
  1. **Get response details** (Microsoft Forms): Form Id: the same form;
     Response Id: the trigger's Response Id. If Power Automate wraps it in
     an "Apply to each", put the next two actions inside that too.
  2. **Create CSV table** (Data Operation): From: the expression
     `createArray(body('Get_response_details'))`; Columns: Custom. One
     column `Completion time` with the response's submission date, then
     one column per question: header the question exactly as in the form,
     value that question's answer. Add no responder name, email or
     response id column.
  3. **Create file** (OneDrive for Business): Folder Path
     `/Binnacle forms/team-pulse`; File Name the expression
     `concat(guid(), '.csv')`; File Content: the output of Create CSV
     table.
- [ ] **[browser, human]** Save, submit one test response, and check that
      one `.csv` file appears in the folder. Delete the test file and the
      test response.

## The work machine

- [ ] **[work machine, human]** Sign in to the OneDrive app with your
      work account and sync `Binnacle forms` (right-click it > Always keep
      on this device). It appears under `~/Library/CloudStorage/`, e.g.
      `~/Library/CloudStorage/OneDrive-Acme/Binnacle forms`. It must be
      outside the vault; the mover refuses an overlap.
- [ ] **[work machine, human]** Point the vault at it (local git config,
      never committed):

      ```sh
      git -C ~/binnacle-acme-engineering-jdoe config binnacle.formsSyncDir \
        ~/Library/CloudStorage/OneDrive-Acme/"Binnacle forms"
      ```

- [ ] **[work machine, human]** Write the form's settings in the vault's
      gitignored `.binnacle/` folder, one file per form folder,
      `~/binnacle-acme-engineering-jdoe/.binnacle/forms/team-pulse.conf`:

      ```
      form_title=Team pulse
      form_id=<the id=... value from the form's link; only its hash reaches the vault>
      audience=Platform team
      consent_notice_version=v1
      identity=anonymous
      invited=8
      ```

      Add `subject=<their name>` only for a survey about one person.
      `platform` defaults to `msforms`. Optional: `from=` and `to=`
      (YYYY-MM-DD) declare the window instead of taking it from the
      response dates; `date_order=dmy` or `date_order=mdy` says how to
      read dates like `05/11/2026`. The converter refuses such dates when
      no day or month in them is over 12 and neither is set; it never
      guesses.
- [ ] **[work machine, human]** Write the stop-list,
      `~/binnacle-acme-engineering-jdoe/.binnacle/forms-stoplist`: one term
      per line (`#` starts a comment), matched as whole words, any case.
      List the names of everyone who might be mentioned in answers (your
      team, other colleagues, customers) and any other word that must
      never reach the vault. A survey's subject is exempt even when listed.

## Each collection window

One note covers one form for one window, so move responses once the window
has closed.

- [ ] **[browser, human]** Close the form to new responses (Forms >
      Settings > Accept responses: off, or an end date).
- [ ] **[work machine, human]** Wait for OneDrive to finish syncing, then:

      ```sh
      ~/binnacle-acme-engineering-jdoe/setup/forms/mover.sh            # every form folder
      ~/binnacle-acme-engineering-jdoe/setup/forms/mover.sh team-pulse # one form
      ```

      For each form with new `.csv` files it rebuilds the window's one
      note, `raw/inbox/forms/form-<hash>-<from>-to-<to>.md`, from the new
      files and every earlier export of the window, then moves the new
      files to `Binnacle forms/processed/<form>/`. Nothing is deleted, so
      responses that sync late are not lost: run the mover again and the
      note is rebuilt complete; if its window changed, the mover removes
      the note it replaces, so the inbox keeps one note per form and window.
- [ ] **[work machine, human]** If the converter refused a form, it names
      the pattern class (email, phone, card, stop-list) and the column and
      row, never the value; the files stay. Remove the value from that
      response's `.csv` file (your own copy, in the form's folder or in
      `processed/<form>/`), or delete the response in Forms and its file,
      then run the mover again.
- [ ] **[work machine, human]** Read the note. Then commit it (Obsidian
      Git, or `git add raw/inbox/forms` and `git commit`); the pre-commit
      secret scan runs. Then `bin/binnacle-run` as usual.
- [ ] **[work machine, human]** Once `bin/binnacle-run` has ingested the
      note, delete the window's exports before the next window opens
      (otherwise the mover refuses the form, so windows never mix):

      ```sh
      ~/binnacle-acme-engineering-jdoe/setup/forms/mover.sh --purge team-pulse
      ```

- [ ] **[browser, human]** Delete the window's responses in Microsoft Forms
      when your employer's retention policy allows (the note's
      `retention_review` date is your reminder), and reopen the form for
      the next window.

## Surveys about your direct reports (optional)

The vault's `CLAUDE.md` has an optional `wiki/people/` zone: one page per
survey subject, holding themes over time, never verbatim quotes. It is off
by default; `bin/binnacle-run` fails a run that writes there while it is
off.

- [ ] **[work machine, human]** Only for surveys about your own direct
      reports, and only if your employer's policies allow it, turn it on in
      this vault:

      ```sh
      git -C ~/binnacle-acme-engineering-jdoe config binnacle.peopleZone true
      ```

      Turn it off again with `git config --unset binnacle.peopleZone`.

## Personal vault (Google Forms)

The personal vault takes no company system. For your own Google Forms,
download the responses (Forms > Responses > Download responses, a .zip
holding the .csv, or the linked sheet > File > Download > CSV) and run the
converter by hand on the Mac where you capture:

```sh
~/binnacle/bin/binnacle-forms-to-inbox --form-title "Reading group" \
  --form-id "<the form link>" --audience "reading group" \
  --consent-notice-version v1 ~/Downloads/responses.csv
```

If it cannot tell day from month in the dates, add `--date-order mdy`
(or `dmy`). Then delete the download, review and commit the note.
