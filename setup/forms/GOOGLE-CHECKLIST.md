# Survey intake checklist (personal vault, Google Forms)

Brings your own Google Forms' responses into the personal vault as one
scrubbed note per form per collection window. On shoyu,
`bin/binnacle-forms-google-pull` reads the responses through the Google
Forms API, read-only, with an OAuth client you create in your own Google
Cloud project, and hands each closed window to `bin/binnacle-forms-to-inbox`,
which scrubs them and writes the note into `raw/inbox/forms/` (or refuses
and writes nothing). Once you opt in, `bin/binnacle-nightly` runs the pull
just before the nightly AI run. Nothing is on until you do the steps below.
No Obsidian plugin is needed.

What the scrub does and refuses is in `setup/forms/CHECKLIST.md` ("The
vault rule change"); it is the same converter. To convert a downloaded
export by hand instead, see "Personal vault (Google Forms)" there.

The examples use the vault `~/binnacle` and a form named `reading-group`;
use your own.

## Google Cloud (once)

All in the browser, signed in to the Google account that owns the forms.

- [ ] **[browser, human]** console.cloud.google.com > project picker >
      **New project**, e.g. `binnacle-forms`, with no organization.
- [ ] **[browser, human]** APIs & Services > Library > **Google Forms
      API** > **Enable**. Enable nothing else.
- [ ] **[browser, human]** Google Auth Platform (APIs & Services > OAuth
      consent screen) > **Get started**: app name e.g. `Binnacle forms
      pull`, support and contact email your own, audience **External**.
- [ ] **[browser, human]** **Audience**: publishing status **Testing**;
      under Test users, **Add users**: your own Google address only.
- [ ] **[browser, human]** **Data access** > Add or remove scopes: add
      exactly these two, nothing else, and save:
      - `https://www.googleapis.com/auth/forms.body.readonly`
      - `https://www.googleapis.com/auth/forms.responses.readonly`
- [ ] **[browser, human]** **Clients** > **Create client**, application
      type **Desktop app**, name e.g. `binnacle shoyu` > Create >
      **Download JSON**. The file holds the client secret: keep it out of
      the vault, mail and chat.

## shoyu (once)

- [ ] **[shoyu, human]** Move the client file next to the GitHub token
      files, readable by you only:

      ```sh
      mkdir -p ~/.config/binnacle && chmod 700 ~/.config/binnacle
      mv ~/Downloads/client_secret_*.json ~/.config/binnacle/google-oauth-client.json
      chmod 600 ~/.config/binnacle/google-oauth-client.json
      ```

      Elsewhere is fine, outside the vault, mode 600:
      `git -C ~/binnacle config binnacle.googleClientFile <file>`. The pull
      refuses a missing file, a symlink, one inside the vault, or one
      anyone else can read.
- [ ] **[shoyu, human]** Give consent, at shoyu's desktop:

      ```sh
      ~/binnacle/bin/binnacle-forms-google-pull --consent
      ```

      It opens Google's consent page (or prints the link). Choose your
      account; Google warns that it has not verified the app, which is
      expected for your own app in Testing: **Continue**. Tick **both**
      permissions (see your forms, see responses), then Continue. The
      terminal says `consent saved to ~/.config/binnacle/google-forms-token.json
      (mode 600)`. It refuses, saving nothing, unless Google granted
      exactly the two read-only scopes. The token is never printed; to keep
      it elsewhere, set `git -C ~/binnacle config binnacle.googleTokenFile
      <file>` (outside the vault) first.
- [ ] **[shoyu, human]** Know the 7-day limit: Google documents that an
      External app in Testing gets consents that expire after 7 days. The
      pull only uses the consent once a window has closed, so when your
      last consent is more than 7 days old, run `--consent` again on a
      window's last day; if a pull fails with `invalid_grant` (the nightly
      log shows it), run `--consent` and then the pull by hand. Moving the app to "In production" lifts the limit under
      Google's own review rules; check Google's current OAuth verification
      docs before you do.
- [ ] **[shoyu, human]** Write the stop-list, if you have none yet:
      `~/binnacle/.binnacle/forms-stoplist`, one term per line (names that
      might come up in answers, and any other word that must never reach
      the vault), as in `setup/forms/CHECKLIST.md`.

## Each form

- [ ] **[browser, human]** Settings > Responses: **Collect email
      addresses: Do not collect**. Put a notice at the top of the form:
      what is asked, who reads the answers, that an AI assistant
      summarises them into your private notes, how long they are kept (the
      note carries a `retention_review` date 12 months after the window
      ends), and a version, e.g. "Notice v1". Ask for no names, emails or
      phone numbers. Linear scale (0-10 or 1-5) and Likert-style choices
      become a distribution and a median. File-upload questions are left
      out of the note.
- [ ] **[shoyu, human]** Write the form's settings, one file per form, in
      the gitignored `~/binnacle/.binnacle/forms-google/reading-group.conf`:

      ```
      form_title=Reading group check-in
      form_id=<the id in the form's edit link, docs.google.com/forms/d/<id>/edit>
      audience=reading group
      consent_notice_version=v1
      from=2026-11-02
      to=2026-11-13
      tz=America/New_York
      invited=8
      ```

      `form_id` is the id from the editor's address bar (or that whole
      link), not the `/forms/d/e/...` link you send to respondents; only
      its hash reaches the vault. `from=` and `to=` (YYYY-MM-DD, both
      included, local dates in `tz=`, default shoyu's own zone) are the
      collection window and are required. Add `subject=<their name>` only
      for a survey about one person, and `identity=` when not anonymous.
- [ ] **[shoyu, human]** Try it by hand: `~/binnacle/bin/binnacle-forms-google-pull`
      (or `... reading-group` for one form). While the window is open it
      says so and fetches nothing.

## Nightly (opt in)

- [ ] **[shoyu, human]** Once the steps above work by hand, turn the pull
      on for this vault; it then runs just before every nightly run
      (`setup/shoyu/CHECKLIST.md`, "Nightly runs"):

      ```sh
      git -C ~/binnacle config binnacle.googleFormsPull true
      ```

      Turn it off with `git -C ~/binnacle config --unset
      binnacle.googleFormsPull`. In `~/Library/Logs/binnacle/nightly.log`
      the pull sits between `--- <date> forms pull start` and `--- <date>
      forms pull end: exit <status>`. A failed pull never stops the run;
      when the run itself succeeds, the night exits with the pull's
      status and its end line says `forms pull failed`.

## Each collection window

- [ ] **[browser, human]** On the window's last day, after the last
      response you will take, close the form: Responses > **Accepting
      responses** off.
- [ ] **[shoyu]** The first pull after the window's last day (the
      nightly one that morning, or one by hand) fetches every response, takes those first submitted inside
      the window, and writes `raw/inbox/forms/form-<hash>-<from>-to-<to>.md`.
      It refuses the form, writing nothing, when a response is dated
      outside this window and every earlier one (it gives the count, never
      the answers): delete the stray response in Forms or widen `from=` or
      `to=`, then run it again. A converter refusal names the pattern
      class and the row; delete that response in Forms and run it again.
- [ ] **[shoyu, human]** Read the note the next morning. Obsidian Git
      commits and pushes it on its next sync, and the following night's
      run ingests it. If it should not be ingested, delete it from
      `raw/inbox/forms/` (and from `main`, if it was pushed) before then.
- [ ] **[shoyu, human]** While the note waits in `raw/inbox/forms/` and
      is not yet committed, a pull rebuilds it whole when a response, the
      form or the settings changed, and leaves it alone otherwise.
      `from=`/`to=` may only widen to contain the old window then (the
      note is rebuilt under the wider window and the old-named one
      removed). Once Obsidian Git has committed it, a pull leaves it and
      the window as they are and says it is committed and waiting for
      ingest; later changes in Forms do not reach it. Once it has been
      ingested, that window is done.
- [ ] **[shoyu, human]** Set `from=` and `to=` for the next window (it
      must not overlap an ingested one), then reopen the form in the
      browser.
- [ ] **[browser, human]** Delete the window's responses in Google Forms
      when your retention review allows (the note's `retention_review`
      date is your reminder).

## Revoke or remove

- [ ] **[browser, human]** myaccount.google.com > Security > Your
      connections to third-party apps & services > the app > **Delete all
      connections**. Then on shoyu delete
      `~/.config/binnacle/google-forms-token.json` and unset
      `binnacle.googleFormsPull`. To remove everything, also delete the
      client file and the Google Cloud project.
