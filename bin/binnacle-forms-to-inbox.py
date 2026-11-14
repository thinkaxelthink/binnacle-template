"""Helper for bin/binnacle-forms-to-inbox; run that script, not this file.

Turns a survey's responses export (Microsoft Forms xlsx or csv, Google
Forms or Sheets csv) into one scrubbed markdown note per form per
collection window in <vault>/raw/inbox/forms/. Standard library only
(Python 3.8+): an xlsx file is a zip of XML parts.
"""
import argparse
import csv
import datetime
import hashlib
import io
import os
import random
import re
import statistics
import sys
import tempfile
import urllib.parse
import xml.etree.ElementTree as ET
import zipfile

PROG = "binnacle-forms-to-inbox"
EXIT_ERROR = 1
EXIT_REFUSED = 3


class Stop(Exception):
    def __init__(self, msg, code=EXIT_ERROR):
        Exception.__init__(self, msg)
        self.code = code


# --- reading ---------------------------------------------------------------

MAIN_NS = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
DOCREL_NS = "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}"
PKGREL_NS = "{http://schemas.openxmlformats.org/package/2006/relationships}"
MAX_XML_BYTES = 64 * 1024 * 1024


def xml_part(z, name):
    try:
        info = z.getinfo(name)
    except KeyError:
        return None
    if info.file_size > MAX_XML_BYTES:
        raise Stop("%s: part %s is too large to read" % (z.filename, name))
    data = z.read(name)
    if b"<!DOCTYPE" in data or b"<!ENTITY" in data:
        raise Stop("%s: part %s declares a DTD; refusing to parse it" % (z.filename, name))
    return ET.fromstring(data)


def col_index(ref):
    n = 0
    for ch in ref:
        if not ch.isalpha():
            break
        n = n * 26 + (ord(ch.upper()) - 64)
    return n - 1


def number_text(s):
    try:
        x = float(s)
    except ValueError:
        return s
    if x.is_integer() and abs(x) < 1e15:
        return str(int(x))
    return "%.15g" % x


def si_text(si):
    t = si.find(MAIN_NS + "t")
    if t is not None:
        return t.text or ""
    return "".join((r.findtext(MAIN_NS + "t") or "") for r in si.findall(MAIN_NS + "r"))


def read_xlsx(path):
    try:
        z = zipfile.ZipFile(path)
    except zipfile.BadZipFile:
        raise Stop("%s: not a readable xlsx file" % path)
    with z:
        sheet = "xl/worksheets/sheet1.xml"
        wb = xml_part(z, "xl/workbook.xml")
        rels = xml_part(z, "xl/_rels/workbook.xml.rels")
        if wb is not None and rels is not None:
            first = wb.find("%ssheets/%ssheet" % (MAIN_NS, MAIN_NS))
            rid = first.get(DOCREL_NS + "id") if first is not None else None
            for rel in rels.findall(PKGREL_NS + "Relationship"):
                if rel.get("Id") == rid:
                    target = rel.get("Target", "")
                    sheet = target.lstrip("/") if target.startswith("/") else "xl/" + target
        shared = []
        sst = xml_part(z, "xl/sharedStrings.xml")
        if sst is not None:
            shared = [si_text(si) for si in sst.findall(MAIN_NS + "si")]
        root = xml_part(z, sheet)
        if root is None:
            raise Stop("%s: no worksheet found" % path)
        rows = []
        for row in root.iter(MAIN_NS + "row"):
            cells = {}
            pos = 0
            for c in row.findall(MAIN_NS + "c"):
                ref = c.get("r")
                if ref:
                    pos = col_index(ref)
                t = c.get("t", "n")
                v = c.findtext(MAIN_NS + "v")
                if t == "s":
                    val = shared[int(v)] if v is not None and v.strip().isdigit() and int(v) < len(shared) else ""
                elif t == "inlineStr":
                    isel = c.find(MAIN_NS + "is")
                    val = si_text(isel) if isel is not None else ""
                elif t == "b":
                    val = "TRUE" if v == "1" else "FALSE"
                elif t in ("str", "e", "d"):
                    val = v or ""
                else:
                    val = number_text(v) if v else ""
                cells[pos] = val
                pos += 1
            width = max(cells) + 1 if cells else 0
            rows.append([cells.get(i, "") for i in range(width)])
        return rows


def decode(data):
    if data.startswith(b"\xff\xfe") or data.startswith(b"\xfe\xff"):
        return data.decode("utf-16")
    try:
        return data.decode("utf-8-sig")
    except UnicodeDecodeError:
        return data.decode("cp1252", errors="replace")


def read_csv(path):
    with open(path, "rb") as f:
        text = decode(f.read())
    counts = {",": 0, ";": 0, "\t": 0}
    quoted = False
    for ch in text:
        if ch == '"':
            quoted = not quoted
        elif quoted:
            continue
        elif ch in counts:
            counts[ch] += 1
        elif ch in "\r\n":
            break
    delim = max([",", ";", "\t"], key=counts.get)
    if counts[delim] == 0:
        delim = ","
    return [row for row in csv.reader(io.StringIO(text, newline=""), delimiter=delim)]


def read_table(path):
    try:
        with open(path, "rb") as f:
            magic = f.read(4)
    except OSError as e:
        raise Stop("cannot read %s: %s" % (path, e.strerror))
    rows = read_xlsx(path) if magic == b"PK\x03\x04" else read_csv(path)
    rows = [r for r in rows if any(c.strip() for c in r)]
    if not rows:
        raise Stop("%s: no header row" % path)
    headers = [" ".join(h.split()) for h in rows[0]]
    while headers and not headers[-1]:
        headers.pop()
    out = []
    for i, r in enumerate(rows[1:], start=2):
        if any(c.strip() for c in r[len(headers):]):
            raise Stop("%s: row %d has more cells than the header row" % (path, i))
        out.append((i, (r + [""] * len(headers))[: len(headers)]))
    return headers, out


# --- columns ---------------------------------------------------------------

# Respondent identity and per-response metadata: never copied into a note.
DROP = {
    "id", "response id", "responseid", "responder", "respondent", "responder id",
    "respondent id", "name", "full name", "email", "email address", "e-mail",
    "e-mail address", "username", "start time", "completion time",
    "last modified time", "timestamp", "submit date", "submitdate", "submitted",
    "submitted at", "submission time",
}
# Where the response timestamps are, in order of preference.
TIME_COLUMNS = ["completion time", "timestamp", "submit date", "submitdate", "submitted",
                "submitted at", "submission time", "start time"]


def detect_platform(headers):
    low = [h.lower() for h in headers]
    if "completion time" in low or "start time" in low:
        return "msforms"
    if low and low[0] == "timestamp":
        return "google"
    return None


# --- dates -----------------------------------------------------------------

ISO_DATE = re.compile(r"^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})(?:$|[ T])")
LOCAL_DATE = re.compile(r"^(\d{1,2})[/.](\d{1,2})[/.](\d{2,4})(?:$|[ ,])")
SERIAL = re.compile(r"^\d{5}(?:\.\d+)?$")


def parse_dates(values, order, advice):
    """Dates of the given timestamp strings, in order, or None when one
    cannot be read.

    Day and month order for d/m/y forms: ORDER (dmy or mdy) when given, else
    told from a number over 12; refused, with ADVICE, when the data cannot
    tell."""
    out, local = [], []
    for v in values:
        v = v.strip()
        m = ISO_DATE.match(v)
        if m:
            out.append((int(m.group(1)), int(m.group(2)), int(m.group(3))))
            continue
        if SERIAL.match(v) and 20000 <= float(v) <= 80000:
            d = datetime.date(1899, 12, 30) + datetime.timedelta(days=int(float(v)))
            out.append((d.year, d.month, d.day))
            continue
        m = LOCAL_DATE.match(v)
        if not m:
            return None
        y = int(m.group(3))
        local.append((len(out), int(m.group(1)), int(m.group(2)), y + 2000 if y < 100 else y))
        out.append(None)
    if local:
        day_first = any(a > 12 for _, a, _, _ in local)
        month_first = any(b > 12 for _, _, b, _ in local)
        if day_first and month_first:
            return None
        if order:
            day_first = order == "dmy"
        elif not day_first and not month_first:
            raise Stop("cannot tell day from month in the response dates; %s" % advice, 2)
        for k, a, b, y in local:
            out[k] = (y, b, a) if day_first else (y, a, b)
    try:
        return [datetime.date(*t) for t in out]
    except ValueError:
        return None


def add_months(d, n):
    y, m = divmod(d.month - 1 + n, 12)
    y += d.year
    m += 1
    last = [31, 29 if (y % 4 == 0 and (y % 100 != 0 or y % 400 == 0)) else 28,
            31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1]
    return datetime.date(y, m, min(d.day, last))


# --- refusal scan ----------------------------------------------------------

EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}")
CARD = re.compile(r"(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)")
PHONES = [
    re.compile(r"(?<![\w+])\+\d{1,3}[ .-]?(?:\(\d{1,4}\)|\d{1,4})(?:[ .-]?\d{2,4}){2,4}(?!\d)"),
    re.compile(r"(?<![\d])\(?\d{3}\)?[ .-]?\d{3}[ .-]\d{4}(?!\d)"),
    re.compile(r"(?<![\d])\(\d{3}\)\d{3}\d{4}(?!\d)"),
    re.compile(r"(?<![\d])\d{10,15}(?!\d)"),
]


def luhn(digits):
    total = 0
    for i, ch in enumerate(reversed(digits)):
        d = int(ch)
        if i % 2:
            d *= 2
            if d > 9:
                d -= 9
        total += d
    return total % 10 == 0


def is_card(s):
    digits = re.sub(r"\D", "", s)
    return 13 <= len(digits) <= 19 and luhn(digits)


def word_pattern(terms):
    """Whole-word matches of the terms, the longest at every start (overlaps
    included), as group 1."""
    terms = sorted({t for t in terms if t}, key=len, reverse=True)
    if not terms:
        return None
    return re.compile(r"(?<!\w)(?=(%s)(?!\w))" % "|".join(re.escape(t) for t in terms), re.IGNORECASE)


def stop_hit(text, stop, subject):
    """A stop-list match not wholly inside a match of the subject's name."""
    spans = [m.span(1) for m in subject.finditer(text)] if subject is not None else []
    for m in stop.finditer(text):
        s, e = m.span(1)
        if not any(a <= s and e <= b for a, b in spans):
            return True
    return False


def classes_in(text, stop, subject):
    found = []
    if EMAIL.search(text):
        found.append("email")
    if any(is_card(m.group(0)) for m in CARD.finditer(text)):
        found.append("card")
    for p in PHONES:
        # A run of digits that is a card number counts once, as a card.
        if any(not is_card(m.group(0)) for m in p.finditer(text)):
            found.append("phone")
            break
    if stop is not None and stop_hit(text, stop, subject):
        found.append("stop-list")
    return found


def load_stop_list(path, explicit):
    if not os.path.exists(path):
        if explicit:
            raise Stop("stop-list %s not found" % path)
        sys.stderr.write("%s: note: no stop-list at %s (names and other terms to refuse, one per line)\n"
                         % (PROG, path))
        return []
    with open(path, encoding="utf-8") as f:
        return [ln.strip() for ln in f if ln.strip() and not ln.lstrip().startswith("#")]


# --- answers ---------------------------------------------------------------

LIKERT = [
    ["Strongly disagree", "Disagree", "Neither agree nor disagree", "Agree", "Strongly agree"],
    ["Strongly disagree", "Disagree", "Neutral", "Agree", "Strongly agree"],
    ["Very dissatisfied", "Dissatisfied", "Neutral", "Satisfied", "Very satisfied"],
    ["Very unsatisfied", "Unsatisfied", "Neutral", "Satisfied", "Very satisfied"],
    ["Never", "Rarely", "Sometimes", "Often", "Always"],
    ["Very poor", "Poor", "Fair", "Good", "Excellent"],
]
INT = re.compile(r"^-?\d+$")


def rating_of(values):
    """(labels, positions) when every answer is on one scale, else None."""
    if not values:
        return None
    if all(INT.match(v) and 0 <= int(v) <= 10 for v in values):
        nums = [int(v) for v in values]
        lo, hi = min(nums), max(nums)
        return [str(n) for n in range(lo, hi + 1)], [n - lo for n in nums], True
    low = [v.lower() for v in values]
    for scale in LIKERT:
        index = {s.lower(): i for i, s in enumerate(scale)}
        if all(v in index for v in low):
            return scale, [index[v] for v in low], False
    return None


def median_text(labels, positions, numeric):
    if numeric:
        m = statistics.median(int(labels[p]) for p in positions)
        return str(int(m)) if float(m).is_integer() else "%.1f" % m
    s = sorted(positions)
    n = len(s)
    a, b = s[(n - 1) // 2], s[n // 2]
    return labels[a] if a == b else "between %s and %s" % (labels[a], labels[b])


def yaml_str(s):
    s = " ".join(s.split())
    return '"%s"' % s.replace("\\", "\\\\").replace('"', '\\"')


def form_key(raw):
    """The form id inside a form link, or the value as given."""
    raw = raw.strip()
    u = urllib.parse.urlparse(raw)
    if u.scheme and u.netloc:
        q = urllib.parse.parse_qs(u.query).get("id")
        if q:
            return q[0]
        m = re.search(r"/forms/d/(?:e/)?([^/]+)", u.path)
        if m:
            return m.group(1)
    return raw


def render(a, form_hash, platform, d_from, d_to, n, questions):
    exported = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    lines = [
        "---",
        "type: form-responses",
        "form_title: %s" % yaml_str(a.form_title),
        "form_id_hash: %s" % form_hash,
        "platform: %s" % platform,
        "audience: %s" % yaml_str(a.audience),
        "subject: %s" % yaml_str(a.subject or ""),
        "collected_from: %s" % d_from.isoformat(),
        "collected_to: %s" % d_to.isoformat(),
        "exported_at: %s" % exported,
        "respondents: %d" % n,
        "invited: %s" % ("" if a.invited is None else a.invited),
        "identity: %s" % a.identity,
        "consent_notice_version: %s" % yaml_str(a.consent_notice_version),
        "retention_review: %s" % add_months(d_to, 12).isoformat(),
        "---",
        "",
        "# %s" % " ".join(a.form_title.split()),
        "",
        "Responses collected %s to %s: %d respondent%s%s." % (
            d_from.isoformat(), d_to.isoformat(), n, "" if n == 1 else "s",
            "" if a.invited is None else " of %d invited" % a.invited),
        "Audience: %s. Identity: %s.%s" % (
            " ".join(a.audience.split()), a.identity,
            " Subject: %s." % " ".join(a.subject.split()) if a.subject else ""),
        "",
        "Scrubbed by bin/binnacle-forms-to-inbox: respondent names, emails, ids",
        "and timestamps are dropped; R1..Rn label respondents in a random order",
        "that differs in every export.",
    ]
    for i, (title, kind, body) in enumerate(questions, start=1):
        lines += ["", "## %d. %s" % (i, " ".join(title.split()) or "(untitled question)"), ""]
        if kind == "rating":
            labels, positions, numeric = body
            lines += ["Rating: %d answer%s, median %s." % (
                len(positions), "" if len(positions) == 1 else "s", median_text(labels, positions, numeric)), "",
                "| Answer | Count |", "|---|---|"]
            for p, label in enumerate(labels):
                lines.append("| %s | %d |" % (label, positions.count(p)))
        elif not body:
            lines.append("(no answers)")
        else:
            for r, text in body:
                parts = [ln.strip() for ln in text.strip().splitlines() if ln.strip()]
                lines.append("- **R%d:** %s" % (r, parts[0]))
                lines += ["  %s" % ln for ln in parts[1:]]
    return "\n".join(lines) + "\n"


# --- main ------------------------------------------------------------------

def parse_args(argv):
    p = argparse.ArgumentParser(prog=PROG, add_help=False)
    p.add_argument("files", nargs="+")
    p.add_argument("--platform", choices=["msforms", "google"])
    p.add_argument("--form-title", required=True)
    p.add_argument("--form-id", required=True)
    p.add_argument("--audience", required=True)
    p.add_argument("--subject", default="")
    p.add_argument("--identity", choices=["anonymous", "pseudonymous", "attributed"], default="anonymous")
    p.add_argument("--consent-notice-version", required=True)
    p.add_argument("--invited", type=int)
    p.add_argument("--from", dest="date_from")
    p.add_argument("--to", dest="date_to")
    p.add_argument("--date-order", choices=["dmy", "mdy"])
    p.add_argument("--within-window", action="store_true")
    p.add_argument("--vault")
    p.add_argument("--stop-list")
    return p.parse_args(argv)


def iso_date(flag, s):
    try:
        return datetime.datetime.strptime(s, "%Y-%m-%d").date()
    except ValueError:
        raise Stop("%s must be a date like 2026-11-13, not %r" % (flag, s), 2)


def main(argv):
    a = parse_args(argv)
    for flag, v in (("--form-title", a.form_title), ("--form-id", a.form_id), ("--audience", a.audience),
                    ("--consent-notice-version", a.consent_notice_version)):
        if not v.strip():
            raise Stop("%s must not be empty" % flag, 2)
    if a.invited is not None and a.invited < 1:
        raise Stop("--invited must be a positive number", 2)
    vault = os.path.abspath(a.vault or os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    if not os.path.isdir(os.path.join(vault, "raw", "inbox")):
        raise Stop("%s is not a Binnacle vault (no raw/inbox/)" % vault)
    stop_path = a.stop_list or os.path.join(vault, ".binnacle", "forms-stoplist")

    # Read every file; they must share one header row.
    headers, rows = None, []
    for path in a.files:
        h, r = read_table(path)
        if headers is None:
            headers = h
        elif h != headers:
            raise Stop("%s: its header row differs from %s; one form per run" % (path, a.files[0]))
        rows += [(os.path.basename(path), i, cells) for i, cells in r]
    if not rows:
        raise Stop("no responses in %s" % ", ".join(a.files))

    platform = a.platform or detect_platform(headers)
    if platform is None:
        raise Stop("cannot tell the platform from the header row; pass --platform msforms or google", 2)
    if a.invited is not None and a.invited < len(rows):
        raise Stop("--invited %d is fewer than the %d responses" % (a.invited, len(rows)), 2)

    low = [h.lower() for h in headers]
    d_from = iso_date("--from", a.date_from) if a.date_from else None
    d_to = iso_date("--to", a.date_to) if a.date_to else None
    if a.within_window and (d_from is None or d_to is None):
        raise Stop("--within-window needs --from and --to", 2)
    if d_from is None or d_to is None or a.within_window:
        tcol = next((low.index(c) for c in TIME_COLUMNS if c in low), None)
        stamped = [] if tcol is None else [(name, n, cells[tcol]) for name, n, cells in rows if cells[tcol].strip()]
        advice = ("pass --date-order dmy or mdy (date_order= in the mover's form settings)" if a.within_window
                  else "pass --date-order dmy or mdy, or --from and --to (YYYY-MM-DD)")
        dates = parse_dates([v for _, _, v in stamped], a.date_order, advice) if stamped else None
        if not dates:
            raise Stop("cannot read the response timestamps"
                       + (", so the window cannot be checked" if a.within_window
                          else "; pass --from and --to (YYYY-MM-DD)"), 2)
        if a.within_window:
            inside = {(name, n) for (name, n, _), d in zip(stamped, dates) if d_from <= d <= d_to}
            outside = ["%s, row %d" % (name, n) for name, n, _ in rows if (name, n) not in inside]
            if outside:
                raise Stop("refused, nothing written: responses without a date in the window %s to %s:\n  %s"
                           % (d_from, d_to, "\n  ".join(outside)), EXIT_REFUSED)
        d_from = d_from or min(dates)
        d_to = d_to or max(dates)
    if d_from > d_to:
        raise Stop("the window starts (%s) after it ends (%s)" % (d_from, d_to), 2)

    keep = [i for i, h in enumerate(low) if h and h not in DROP]

    # Refuse before anything is written.
    stop = word_pattern(load_stop_list(stop_path, bool(a.stop_list)))
    subject = word_pattern([a.subject.strip()] + [w for w in a.subject.split() if len(w) > 1]) if a.subject.strip() else None
    findings = []

    def scan(text, where):
        for cls in classes_in(text, stop, subject):
            findings.append("%s pattern: %s" % (cls, where))

    scan(a.form_title, "--form-title")
    scan(a.audience, "--audience")
    scan(a.subject, "--subject")
    clean_header = {}
    for i in keep:
        before = len(findings)
        scan(headers[i], "column %d header" % (i + 1))
        clean_header[i] = len(findings) == before
    for name, rownum, cells in rows:
        for i in keep:
            if cells[i].strip():
                col = 'column %d "%s"' % (i + 1, headers[i]) if clean_header[i] else "column %d" % (i + 1)
                scan(cells[i], "%s, %s, row %d" % (name, col, rownum))
    if findings:
        raise Stop("refused, nothing written:\n  " + "\n  ".join(findings), EXIT_REFUSED)

    # One random order of respondents per file: R1..Rn.
    order = list(range(len(rows)))
    random.SystemRandom().shuffle(order)
    label = {row: r for r, row in enumerate(order, start=1)}
    questions = []
    for i in keep:
        answers = [(label[k], cells[i].strip()) for k, (_, _, cells) in enumerate(rows) if cells[i].strip()]
        rating = rating_of([t for _, t in answers])
        if rating:
            questions.append((headers[i], "rating", rating))
        else:
            questions.append((headers[i], "text", sorted(answers)))

    form_hash = hashlib.sha256(form_key(a.form_id).encode("utf-8")).hexdigest()
    note = render(a, form_hash, platform, d_from, d_to, len(rows), questions)
    outdir = os.path.join(vault, "raw", "inbox", "forms")
    os.makedirs(outdir, exist_ok=True)
    name = "form-%s-%s-to-%s.md" % (form_hash[:12], d_from.isoformat(), d_to.isoformat())
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", suffix=".md", dir=outdir)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(note)
        os.chmod(tmp, 0o644)
        os.replace(tmp, os.path.join(outdir, name))
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    print("%s: wrote raw/inbox/forms/%s (%d respondents, %s to %s)" % (PROG, name, len(rows), d_from, d_to))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Stop as e:
        sys.stderr.write("%s: %s\n" % (PROG, e))
        sys.exit(e.code)
