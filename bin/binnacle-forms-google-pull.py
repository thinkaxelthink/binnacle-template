"""Helper for bin/binnacle-forms-google-pull; run that script, not this file.

Fetches Google Forms responses over plain HTTPS (OAuth 2.0 for a desktop
app, Forms API v1) and hands each closed window's responses to
bin/binnacle-forms-to-inbox, which does all scrubbing, refusing and note
writing. Standard library only (Python 3.8+).
"""
import argparse
import base64
import csv
import datetime
import fcntl
import hashlib
import http.server
import json
import os
import re
import secrets
import shutil
import socketserver
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

PROG = "binnacle-forms-google-pull"
SCOPES = ["https://www.googleapis.com/auth/forms.body.readonly",
          "https://www.googleapis.com/auth/forms.responses.readonly"]
AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN_URL = "https://oauth2.googleapis.com/token"
FORMS_API = "https://forms.googleapis.com/v1/forms/"
DEFAULT_CLIENT = "~/.config/binnacle/google-oauth-client.json"
DEFAULT_TOKEN = "~/.config/binnacle/google-forms-token.json"
CHECKLIST = "setup/forms/GOOGLE-CHECKLIST.md"
CONSENT_WAIT = 300
REQUIRED = ["form_title", "form_id", "audience", "consent_notice_version", "from", "to"]
OPTIONAL = ["subject", "identity", "invited", "tz"]


class Stop(Exception):
    def __init__(self, msg, code=1):
        Exception.__init__(self, msg)
        self.code = code


def log(msg):
    print("==> %s" % msg, flush=True)


def ok(msg):
    print("  ok   %s" % msg, flush=True)


def warn(msg):
    sys.stdout.flush()
    sys.stderr.write("  WARN %s\n" % msg)
    sys.stderr.flush()


# --- vault and settings ----------------------------------------------------

def git_config(vault, key):
    p = subprocess.run(["git", "-C", vault, "config", "--get", key],
                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, universal_newlines=True)
    return p.stdout.strip() if p.returncode == 0 else ""


def tracked(vault, note):
    """NOTE in raw/inbox/forms/ is known to the vault's git (committed or staged)."""
    return subprocess.run(["git", "-C", vault, "ls-files", "--error-unmatch", "--",
                           "raw/inbox/forms/" + note], stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL).returncode == 0


def physical(path):
    return os.path.realpath(os.path.abspath(os.path.expanduser(path)))


def is_under(path, top):
    """PATH is TOP or inside it, compared case-insensitively (APFS default)
    after resolving symlinks."""
    p, d = physical(path).lower(), physical(top).lower().rstrip("/")
    return (p + "/").startswith(d + "/")


def read_conf(path):
    conf = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\r\n")
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                warn("%s: ignoring a line without '='" % path)
                continue
            key, value = line.split("=", 1)
            if key in REQUIRED or key in OPTIONAL:
                conf[key] = value
            else:
                warn("%s: ignoring unknown key '%s'" % (path, key))
    return conf


def iso(s):
    try:
        return datetime.datetime.strptime(s, "%Y-%m-%d").date()
    except ValueError:
        return None


def window_dates(w):
    a, _, b = w.partition("-to-")
    return iso(a), iso(b)


def load_tz(name):
    if not name:
        return None
    try:
        import zoneinfo
    except ImportError:
        raise Stop("tz=%s needs Python 3.9 or later (zoneinfo); leave tz unset to use this machine's time zone" % name)
    try:
        return zoneinfo.ZoneInfo(name)
    except (zoneinfo.ZoneInfoNotFoundError, ValueError):
        raise Stop("tz=%s: no such time zone here (an IANA name like America/New_York)" % name)


def api_form_id(raw):
    """The Forms API id: the id in the edit link /forms/d/<id>/edit."""
    raw = raw.strip()
    u = urllib.parse.urlparse(raw)
    if u.scheme and u.netloc:
        if re.search(r"/forms/d/e/", u.path):
            raise Stop("form_id is the form's respond link (/forms/d/e/...); use the id in its edit link, /forms/d/<id>/edit")
        m = re.search(r"/forms/d/([^/]+)", u.path)
        if not m:
            raise Stop("form_id: no /forms/d/<id> in that link")
        raw = m.group(1)
    if not re.match(r"^[A-Za-z0-9_-]+$", raw):
        raise Stop("form_id must be the id in the form's edit link, /forms/d/<id>/edit")
    return raw


# --- credential files ------------------------------------------------------

def check_secret_file(path, what, setting, vault):
    """Refuse PATH unless it is a regular file owned by us with mode 600 or
    400, outside the vault. Never reads it."""
    hint = "git -C %s config %s <file>; %s" % (vault, setting, CHECKLIST)
    if not os.path.lexists(path):
        raise Stop("no %s at %s (%s)" % (what, path, hint))
    st = os.lstat(path)
    if not stat.S_ISREG(st.st_mode):
        raise Stop("refusing the %s %s: not a regular file (a symlink or folder)" % (what, path))
    if st.st_uid != os.getuid() or stat.S_IMODE(st.st_mode) not in (0o600, 0o400):
        raise Stop("refusing the %s %s: it must be owned by you with mode 600 or 400 (chmod 600 it)" % (what, path))
    if is_under(path, vault):
        raise Stop("refusing the %s %s: it is inside the vault; keep it outside, e.g. in ~/.config/binnacle/" % (what, path))


def load_client(path):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        raise Stop("cannot read the OAuth client file %s as JSON" % path)
    c = data.get("installed") if isinstance(data, dict) else None
    if not isinstance(c, dict) or not c.get("client_id") or not c.get("client_secret"):
        raise Stop("%s is not a Desktop app OAuth client file (no \"installed\" client id and secret); %s"
                   % (path, CHECKLIST))
    return c


def load_token(path):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        raise Stop("cannot read the token file %s as JSON; run %s --consent again" % (path, PROG))
    if not isinstance(data, dict) or not data.get("refresh_token"):
        raise Stop("the token file %s holds no refresh token; run %s --consent again" % (path, PROG))
    return data


def write_private(path, text):
    """Write PATH atomically, mode 600 from the start."""
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=d)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


# --- HTTP ------------------------------------------------------------------

def request(method, url, form=None, bearer=None):
    """(status, body text). Errors say which host, never a token."""
    headers = {"Accept": "application/json"}
    if bearer:
        headers["Authorization"] = "Bearer " + bearer
    data = None
    if form is not None:
        data = urllib.parse.urlencode(form).encode("utf-8")
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    stub = os.environ.get("BINNACLE_GOOGLE_HTTP")
    if stub:
        req = json.dumps({"method": method, "url": url, "headers": headers, "form": form})
        p = subprocess.run([stub], input=req, stdout=subprocess.PIPE, universal_newlines=True)
        status, _, body = p.stdout.partition("\n")
        if p.returncode != 0 or not status.strip().isdigit():
            raise Stop("cannot reach %s (BINNACLE_GOOGLE_HTTP failed)" % urllib.parse.urlparse(url).netloc)
        return int(status), body
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            return resp.status, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except (urllib.error.URLError, OSError) as e:
        raise Stop("cannot reach %s: %s" % (urllib.parse.urlparse(url).netloc, getattr(e, "reason", e)))


def body_json(body):
    try:
        data = json.loads(body)
    except ValueError:
        return {}
    return data if isinstance(data, dict) else {}


def api_error(status, body):
    """A short reason from a Google error body: never the whole body."""
    err = body_json(body).get("error")
    if isinstance(err, dict):
        return "HTTP %d %s: %s" % (status, err.get("status", ""), err.get("message", ""))
    if isinstance(err, str):
        desc = body_json(body).get("error_description", "")
        return "HTTP %d %s%s" % (status, err, (": " + desc) if desc else "")
    return "HTTP %d" % status


def check_scopes(granted):
    got = set(granted.split())
    if got != set(SCOPES):
        raise Stop("refusing: Google granted the scopes [%s], not exactly [%s]; run --consent again and allow both "
                   "read-only scopes" % (" ".join(sorted(got)) or "none", " ".join(SCOPES)))


def access_token(client, token):
    if token.get("client_id") and token["client_id"] != client["client_id"]:
        raise Stop("the saved consent belongs to another OAuth client; run %s --consent again" % PROG)
    status, body = request("POST", TOKEN_URL, form={
        "client_id": client["client_id"], "client_secret": client["client_secret"],
        "refresh_token": token["refresh_token"], "grant_type": "refresh_token"})
    data = body_json(body)
    if status != 200:
        if data.get("error") == "invalid_grant":
            raise Stop("Google refused the saved consent (invalid_grant: expired or revoked). An app in Testing "
                       "mode gets consents that last 7 days; run %s --consent again (%s)" % (PROG, CHECKLIST))
        raise Stop("cannot refresh the access token: %s" % api_error(status, body))
    if not data.get("access_token"):
        raise Stop("cannot refresh the access token: no access token in Google's answer")
    check_scopes(data.get("scope", ""))
    return data["access_token"]


def api_get(path, bearer, query=None):
    url = FORMS_API + path + ("?" + urllib.parse.urlencode(query) if query else "")
    status, body = request("GET", url, bearer=bearer)
    if status != 200:
        raise Stop("Forms API: %s" % api_error(status, body))
    try:
        data = json.loads(body)
    except ValueError:
        data = None
    if not isinstance(data, dict):
        raise Stop("Forms API: the answer is not a JSON object")
    return data


def fetch(form_id, bearer):
    fid = urllib.parse.quote(form_id, safe="")
    form = api_get(fid, bearer)
    responses, page = [], None
    while True:
        q = {"pageSize": "5000"}
        if page:
            q["pageToken"] = page
        data = api_get(fid + "/responses", bearer, q)
        responses += data.get("responses", []) or []
        page = data.get("nextPageToken")
        if not page:
            return form, responses


# --- consent ---------------------------------------------------------------

def consent(vault, client_file, token_file):
    check_secret_file(client_file, "OAuth client file", "binnacle.googleClientFile", vault)
    client = load_client(client_file)
    if is_under(token_file, vault):
        raise Stop("refusing the token file %s: it is inside the vault; keep it outside, e.g. in ~/.config/binnacle/"
                   % token_file)
    if os.path.lexists(token_file) and not stat.S_ISREG(os.lstat(token_file).st_mode):
        raise Stop("refusing the token file %s: not a regular file (a symlink or folder)" % token_file)
    tdir = os.path.dirname(token_file)
    if not os.path.isdir(tdir):
        os.makedirs(tdir, mode=0o700)

    verifier = secrets.token_urlsafe(64)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode("ascii")).digest()).decode("ascii").rstrip("=")
    state = secrets.token_urlsafe(24)

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            if "code" not in q and "error" not in q:
                self.send_response(404)
                self.end_headers()
                return
            self.server.result = q
            page = b"<html><body><p>Binnacle: done. You can close this tab.</p></body></html>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(page)))
            self.end_headers()
            self.wfile.write(page)

        def log_message(self, *args):  # the request line holds the code: never log it
            pass

    # A plain TCPServer: HTTPServer would look the host name up in DNS.
    server = socketserver.TCPServer(("127.0.0.1", 0), Handler)
    server.result = None
    server.timeout = 1
    redirect = "http://127.0.0.1:%d" % server.server_address[1]
    url = AUTH_URL + "?" + urllib.parse.urlencode({
        "client_id": client["client_id"], "redirect_uri": redirect, "response_type": "code",
        "scope": " ".join(SCOPES), "code_challenge": challenge, "code_challenge_method": "S256",
        "state": state, "access_type": "offline", "prompt": "consent"})
    print("Open this link in a browser signed in to the Google account that owns the forms,\n"
          "and allow both read-only permissions (view forms, view responses):\n\n  %s\n" % url, flush=True)
    opener = os.environ.get("BINNACLE_BROWSER") or ("open" if sys.platform == "darwin" else "")
    if opener and shutil.which(opener):
        subprocess.Popen([opener, url], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL)
    deadline = time.time() + CONSENT_WAIT
    try:
        while server.result is None and time.time() < deadline:
            server.handle_request()
    finally:
        server.server_close()
    q = server.result
    if q is None:
        raise Stop("no answer from the browser within %d seconds; nothing saved" % CONSENT_WAIT)
    if q.get("state", [""])[0] != state:
        raise Stop("the browser's answer does not match this request (state); nothing saved")
    if "error" in q:
        raise Stop("consent not given (%s); nothing saved" % q["error"][0])
    status, body = request("POST", TOKEN_URL, form={
        "client_id": client["client_id"], "client_secret": client["client_secret"], "code": q["code"][0],
        "code_verifier": verifier, "redirect_uri": redirect, "grant_type": "authorization_code"})
    data = body_json(body)
    if status != 200:
        raise Stop("Google did not grant a token: %s; nothing saved" % api_error(status, body))
    if not data.get("refresh_token"):
        raise Stop("Google granted no refresh token; nothing saved")
    check_scopes(data.get("scope", ""))
    write_private(token_file, json.dumps({
        "client_id": client["client_id"], "refresh_token": data["refresh_token"], "scope": data["scope"],
        "granted_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")}, indent=2) + "\n")
    ok("consent saved to %s (mode 600): forms.body.readonly and forms.responses.readonly" % token_file)
    return 0


# --- one form --------------------------------------------------------------

def columns_of(form):
    """[(header, questionId)] in form order, and how many file-upload
    questions were left out."""
    cols, skipped = [], 0
    for n, item in enumerate(form.get("items", []) or [], start=1):
        title = " ".join((item.get("title") or "").split()) or "(untitled question %d)" % n
        qi = item.get("questionItem")
        if qi:
            q = qi.get("question", {})
            if "fileUploadQuestion" in q:
                skipped += 1
            elif q.get("questionId"):
                cols.append((title, q["questionId"]))
            continue
        for q in (item.get("questionGroupItem") or {}).get("questions", []) or []:
            row = " ".join(((q.get("rowQuestion") or {}).get("title") or "").split())
            if q.get("questionId"):
                cols.append(("%s [%s]" % (title, row) if row else title, q["questionId"]))
    return cols, skipped


STAMP = re.compile(r"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?Z$")


def submitted(resp, tz):
    """(UTC stamp for the csv, local date) of when RESP was first submitted."""
    m = STAMP.match(resp.get("createTime") or "")
    if not m:
        raise Stop("Forms API: a response without a readable createTime")
    dt = datetime.datetime(*(int(x) for x in m.groups()), tzinfo=datetime.timezone.utc)
    local = dt.astimezone(tz) if tz is not None else dt.astimezone()
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ"), local.date()


def answer_text(answer):
    vals = [a.get("value", "") for a in ((answer or {}).get("textAnswers") or {}).get("answers", []) or []]
    return ", ".join(v for v in vals if v)


class Form:
    def __init__(self, ctx, name):
        self.ctx, self.name = ctx, name
        self.state = os.path.join(ctx.state_root, name)

    def read_state(self):
        self.windows = []
        p = os.path.join(self.state, ".windows")
        if os.path.exists(p):
            with open(p, encoding="utf-8") as f:
                self.windows = [ln.strip() for ln in f if ln.strip()]
        self.last_window = self.last_note = self.last_fp = ""
        p = os.path.join(self.state, ".note")
        if os.path.exists(p):
            with open(p, encoding="utf-8") as f:
                parts = f.read().split()
            self.last_window, self.last_note, self.last_fp = (parts + ["", "", ""])[:3]

    def write_state(self, window, note, fp, widen):
        os.makedirs(self.state, mode=0o700, exist_ok=True)
        windows = [w for w in self.windows if w != widen]
        if window not in windows:
            windows.append(window)
        write_private(os.path.join(self.state, ".windows"), "".join(w + "\n" for w in windows))
        write_private(os.path.join(self.state, ".note"), "%s %s %s\n" % (window, note, fp))

    def pull(self):
        ctx = self.ctx
        conf_path = os.path.join(ctx.conf_dir, self.name + ".conf")
        log("form %s" % self.name)
        if not os.path.isfile(conf_path):
            raise Stop("no settings file %s (%s)" % (conf_path, CHECKLIST))
        conf = read_conf(conf_path)
        missing = [k for k in REQUIRED if not conf.get(k, "").strip()]
        if missing:
            raise Stop("%s needs %s; nothing pulled" % (conf_path, ", ".join(k + "=" for k in missing)))
        d_from, d_to = iso(conf["from"].strip()), iso(conf["to"].strip())
        if d_from is None or d_to is None:
            raise Stop("%s needs the window as from=YYYY-MM-DD and to=YYYY-MM-DD; nothing pulled" % conf_path)
        if d_from > d_to:
            raise Stop("%s: the window starts (%s) after it ends (%s)" % (conf_path, d_from, d_to))
        form_id = api_form_id(conf["form_id"])
        tz = load_tz(conf.get("tz", "").strip())
        window = "%s-to-%s" % (d_from, d_to)

        self.read_state()
        waiting = bool(self.last_note) and os.path.isfile(os.path.join(ctx.inbox, self.last_note))
        widen = ""
        if waiting and self.last_window != window:
            lf, lt = window_dates(self.last_window)
            if lf is None or d_from > lf or d_to < lt:
                raise Stop("the note for window %s, raw/inbox/forms/%s, is not ingested yet; until it is, from/to "
                           "may only widen to contain it, not change to %s; nothing pulled"
                           % (self.last_window, self.last_note, window))
            widen = self.last_window
        if window in self.windows and not waiting:
            ok("window %s is done (its note has left raw/inbox/forms/); set from= and to= for the next window"
               % window)
            return True
        skip = self.last_window if waiting else ""
        for w in self.windows:
            if w in (skip, window):
                continue
            wf, wt = window_dates(w)
            if wf is not None and not (d_from > wt or d_to < wf):
                raise Stop("window %s overlaps window %s, whose note has already left raw/inbox/forms/; set from= "
                           "and to= for a later window; nothing pulled" % (window, w))
        if waiting and tracked(ctx.vault, self.last_note):
            ok("raw/inbox/forms/%s is already committed and waiting for ingest; left as it is, nothing pulled"
               % self.last_note)
            return True

        today = (datetime.datetime.now(tz) if tz is not None else datetime.datetime.now()).date()
        if today <= d_to:
            ok("window %s is open until %s; nothing pulled until it has closed" % (window, d_to))
            return True

        bearer = ctx.bearer()
        form, responses = fetch(form_id, bearer)
        cols, skipped = columns_of(form)
        earlier = [window_dates(w) for w in self.windows if w not in (window, widen)]
        inside, before, after = [], 0, 0
        for r in responses:
            stamp, day = submitted(r, tz)
            if d_from <= day <= d_to:
                inside.append((stamp, r))
            elif any(a is not None and a <= day <= b for a, b in earlier):
                continue
            elif day < d_from:
                before += 1
            else:
                after += 1
        if before or after:
            raise Stop("refused, nothing written: %d response(s) dated outside window %s and every earlier window "
                       "(%d before it, %d after it). Close the form to new responses, then delete the stray "
                       "response(s) in Google Forms or widen from=/to= to take them in" % (
                           before + after, window, before, after))
        if not inside:
            if waiting:
                raise Stop("window %s has no responses left in Google Forms, but raw/inbox/forms/%s still holds "
                           "them; delete that note by hand if it should not be ingested" % (window, self.last_note))
            ok("no responses in window %s; nothing written" % window)
            return True
        if skipped:
            ok("%d file-upload question(s) left out (file names never reach the vault)" % skipped)

        args = ["--vault", ctx.vault, "--platform", "google", "--form-title", conf["form_title"],
                "--form-id", conf["form_id"], "--audience", conf["audience"],
                "--consent-notice-version", conf["consent_notice_version"],
                "--from", str(d_from), "--to", str(d_to), "--within-window"]
        for key, flag in (("subject", "--subject"), ("identity", "--identity"), ("invited", "--invited"),
                          ("tz", "--tz")):
            if conf.get(key, "").strip():
                args += [flag, conf[key].strip() if key != "subject" else conf[key]]
        inside.sort(key=lambda x: (x[0], x[1].get("responseId", "")))
        fp = hashlib.sha256(json.dumps([args, form.get("revisionId", ""), [h for h, _ in cols],
                                        [(r.get("responseId", ""), r.get("lastSubmittedTime", ""))
                                         for _, r in inside]]).encode("utf-8")).hexdigest()[:32]
        if waiting and not widen and self.last_fp == fp:
            ok("no change in window %s: raw/inbox/forms/%s is up to date" % (window, self.last_note))
            return True

        tmp = tempfile.mkdtemp(prefix="binnacle-forms-google-")
        try:
            if is_under(tmp, ctx.vault):
                raise Stop("refusing: the temporary folder %s is inside the vault (set TMPDIR elsewhere)" % tmp)
            path = os.path.join(tmp, "responses.csv")
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
                w = csv.writer(f, quoting=csv.QUOTE_ALL)
                w.writerow(["Timestamp"] + [h for h, _ in cols])
                for stamp, r in inside:
                    answers = r.get("answers") or {}
                    w.writerow([stamp] + [answer_text(answers.get(q)) for _, q in cols])
            p = subprocess.run([ctx.converter] + args + [path], stdout=subprocess.PIPE, universal_newlines=True)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        sys.stdout.write(p.stdout)
        if p.returncode != 0:
            raise Stop("not converted (bin/binnacle-forms-to-inbox exit %d); nothing written" % p.returncode)
        m = re.search(r"wrote raw/inbox/forms/([^ /]+\.md) ", p.stdout)
        if not m:
            raise Stop("cannot tell which note the converter wrote")
        note = m.group(1)
        self.write_state(window, note, fp, widen)
        if widen and self.last_note != note:
            os.unlink(os.path.join(ctx.inbox, self.last_note))
            ok("replaced raw/inbox/forms/%s with %s" % (self.last_note, note))
        ok("%d response(s) of window %s in raw/inbox/forms/%s" % (len(inside), window, note))
        return True


# --- main ------------------------------------------------------------------

class Context:
    def __init__(self, vault):
        self.vault = vault
        self.conf_dir = os.path.join(vault, ".binnacle", "forms-google")
        self.state_root = os.path.join(vault, ".binnacle", "forms-google-state")
        self.inbox = os.path.join(vault, "raw", "inbox", "forms")
        self.converter = os.path.join(vault, "bin", "binnacle-forms-to-inbox")
        self.client_file = os.path.abspath(os.path.expanduser(git_config(vault, "binnacle.googleClientFile") or DEFAULT_CLIENT))
        self.token_file = os.path.abspath(os.path.expanduser(git_config(vault, "binnacle.googleTokenFile") or DEFAULT_TOKEN))
        self._bearer = None

    def check_credentials(self):
        check_secret_file(self.client_file, "OAuth client file", "binnacle.googleClientFile", self.vault)
        check_secret_file(self.token_file, "token file", "binnacle.googleTokenFile", self.vault)

    def bearer(self):
        if self._bearer is None:
            self._bearer = access_token(load_client(self.client_file), load_token(self.token_file))
        return self._bearer


def main(argv):
    p = argparse.ArgumentParser(prog=PROG, add_help=False)
    p.add_argument("forms", nargs="*")
    p.add_argument("--vault")
    p.add_argument("--consent", action="store_true")
    a = p.parse_args(argv)
    vault = physical(a.vault or os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    if not os.path.isdir(os.path.join(vault, "raw", "inbox")):
        raise Stop("%s is not a Binnacle vault (no raw/inbox/)" % vault)
    ctx = Context(vault)
    if a.consent:
        if a.forms:
            raise Stop("--consent takes no FORM", 2)
        return consent(vault, ctx.client_file, ctx.token_file)

    if not os.access(ctx.converter, os.X_OK):
        raise Stop("%s not found" % ctx.converter)
    forms = a.forms
    if not forms:
        if os.path.isdir(ctx.conf_dir):
            forms = sorted(f[:-5] for f in os.listdir(ctx.conf_dir)
                           if f.endswith(".conf") and not f.startswith("."))
        if not forms:
            log("no form settings in %s: nothing to do (%s)" % (ctx.conf_dir, CHECKLIST))
            return 0
    for f in forms:
        if not f or f.startswith(".") or "/" in f:
            raise Stop("'%s' is not a form settings name" % f, 2)
    ctx.check_credentials()

    os.makedirs(ctx.state_root, mode=0o700, exist_ok=True)
    lock = open(os.path.join(ctx.state_root, ".lock"), "a")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        raise Stop("another %s is running for this vault; nothing done" % PROG)

    failed = 0
    for f in forms:
        try:
            Form(ctx, f).pull()
        except Stop as e:
            warn(str(e))
            failed = 1
            if "invalid_grant" in str(e) or "scopes" in str(e):
                break
    if failed:
        warn("some forms were not pulled (see above)")
        return 1
    log("done. Review raw/inbox/forms/; nothing was committed")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Stop as e:
        sys.stderr.write("%s: error: %s\n" % (PROG, e))
        sys.exit(e.code)
