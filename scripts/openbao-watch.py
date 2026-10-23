#!/usr/bin/env python3
#
# openbao-watch.py — the OpenBao half of the weekly cve-watch job
# (geekdojo/geekdojo-brain#768).
#
#   openbao-watch.py --pin X.Y.Z --advisories FILE --releases FILE \
#                    --baseline FILE --out FILE
#
# OpenBao is the node secrets store, shipped as upstream's pre-built binary
# (package/openbao/openbao.mk). Buildroot's pkg-stats cannot see its
# advisories, and neither can the global GitHub advisory database: upstream
# publishes them only as repository advisories on openbao/openbao. The
# workflow fetches those and the release list with `gh api` and hands both
# files to this script, which reports:
#
#   - each advisory that affects the pin, decided from `patched_versions`
#     only (see affects() for why never from `vulnerable_version_range`);
#   - each published release newer than the pin, with its S17 class and the
#     SECURITY items from its release notes.
#
# Ids listed in the baseline file are suppressed. Detect-only: it never bumps
# anything. Standard library only; no network, no clock, no environment.
#
# Output: the issue section on --out (an empty file when nothing is new), the
# count of new findings on stdout, one summary line on stderr. Exit 0, or 2 on
# a refusal, which is one `::error::` sentence on stderr and no --out file.

import argparse
import json
import re
import sys

VERSION_RE = re.compile(r"v?([0-9]+)\.([0-9]+)\.([0-9]+)")
SECURITY_HEADING_RE = re.compile(r"^(#{1,6})\s*security\s*:?\s*$", re.IGNORECASE)
HEADING_RE = re.compile(r"^(#{1,6})(\s|$)")
BULLET_RE = re.compile(r"^\s*[*+-]\s+(.*)$")
MD_LINK_RE = re.compile(r"\[([^\]]*)\]\([^)]*\)")
AUTOLINK_RE = re.compile(r"<(https?://[^>\s]+)>")
# Trailing sentence punctuation is not part of the URL.
BARE_URL_RE = re.compile(r"(?<![`\w])(https?://[^\s`<>]*[^\s`<>.,;:!?)])")

NO_SECURITY_SECTION = "The release notes have no SECURITY section."

CLASS_PATCH = "patch of the current minor"
CLASS_MINOR_ZERO = (
    "new minor at x.y.0: move at x.y.1; x.y.0 only if it is the only release "
    "carrying a fix for a reachable critical or high"
)
CLASS_MINOR_LATER = "new minor at x.y.1 or later"

TRIAGE = "triage within 2 working days"
TARGET_URGENT = (
    "if reachable, a dev build within 7 days and an out-of-cycle stable "
    "release within 14 days, with an operator alert; otherwise the next "
    "scheduled update, within 30 days"
)
TARGET_SCHEDULED = "the next scheduled update, within 30 days"


class Refusal(Exception):
    """An input the watch cannot trust; the message is a sentence."""


def parse_version(s):
    """X.Y.Z with an optional leading v, as an int tuple; anything else None."""
    if not isinstance(s, str):
        return None
    m = VERSION_RE.fullmatch(s)
    if m is None:
        return None
    return tuple(int(part) for part in m.groups())


def fmt_version(v):
    return "%d.%d.%d" % v


def patched_list(patched_versions):
    """The parseable versions of a `patched_versions` string."""
    if not isinstance(patched_versions, str):
        return []
    parsed = (parse_version(p.strip()) for p in patched_versions.split(","))
    return [p for p in parsed if p is not None]


def affects(pin, patched_versions):
    """Whether an advisory entry with these patched versions affects pin.

    The pin is cleared only by a patched version on its own major.minor line
    at or below it, or when every patched version is on an older line.
    `vulnerable_version_range` is never consulted: upstream writes ranges
    such as `<2.7.1, <2.6.4`, which under GHSA's AND reading would clear a
    vulnerable 2.7.0. No parseable patched version means affected (fail
    closed).
    """
    patched = patched_list(patched_versions)
    if not patched:
        return True
    line = pin[:2]
    if any(p[:2] == line and p <= pin for p in patched):
        return False
    if all(p[:2] < line for p in patched):
        return False
    return True


def read_baseline(path):
    """Ids from the baseline file, ignoring blank lines and '#' lines."""
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except FileNotFoundError:
        raise Refusal("The baseline file %s does not exist." % path) from None
    except (OSError, UnicodeDecodeError) as e:
        raise Refusal("The baseline file %s could not be read: %s." % (path, e)) from None
    ids = set()
    for line in lines:
        line = line.strip()
        if line and not line.startswith("#"):
            ids.add(line)
    return ids


def read_list(path, what):
    """A JSON list from path, or a Refusal naming the file."""
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except FileNotFoundError:
        raise Refusal("The %s file %s does not exist." % (what, path)) from None
    except (OSError, UnicodeDecodeError) as e:
        raise Refusal("The %s file %s could not be read: %s." % (what, path, e)) from None
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        raise Refusal("The %s file %s is not valid JSON." % (what, path)) from None
    if not isinstance(data, list):
        raise Refusal("The %s file %s does not hold a JSON list." % (what, path))
    return data


def advisory_findings(advisories, pin, baseline):
    """One finding per affecting ghsa_id that is not baselined, in input order.

    An advisory is affected if any of its vulnerabilities[] entries is. One
    with no entries at all is affected (fail closed). An advisory is
    suppressed when its GHSA id or its CVE id is in the baseline.
    """
    by_id = {}
    for adv in advisories:
        ghsa = adv.get("ghsa_id")
        entries = adv.get("vulnerabilities") or []
        hit = not entries or any(affects(pin, e.get("patched_versions")) for e in entries)
        if ghsa in by_id:
            by_id[ghsa]["hit"] = by_id[ghsa]["hit"] or hit
            continue
        by_id[ghsa] = {"adv": adv, "hit": hit}
    findings = []
    for ghsa, rec in by_id.items():
        adv = rec["adv"]
        cve = adv.get("cve_id")
        if not rec["hit"] or ghsa in baseline or (cve and cve in baseline):
            continue
        findings.append(adv)
    return findings


def release_class(pin, version):
    if version[:2] == pin[:2]:
        return CLASS_PATCH
    if version[2] == 0:
        return CLASS_MINOR_ZERO
    return CLASS_MINOR_LATER


def strip_links(text):
    """Links reduced to plain text, so a public issue mentions no upstream PR."""
    text = MD_LINK_RE.sub(r"\1", text)
    text = AUTOLINK_RE.sub(r"\1", text)
    return BARE_URL_RE.sub(r"`\1`", text)


def security_items(body):
    """The bullet items under the release notes' SECURITY heading, links removed.

    The heading is matched at any level, in any case, with an optional colon
    (upstream has used `## SECURITY`, `### SECURITY` and `## SECURITY:`). The
    section ends at the next heading of the same or a higher level. None when
    there is no SECURITY heading.
    """
    lines = (body or "").splitlines()
    for i, line in enumerate(lines):
        m = SECURITY_HEADING_RE.match(line)
        if m is None:
            continue
        level = len(m.group(1))
        items = []
        for following in lines[i + 1:]:
            h = HEADING_RE.match(following)
            if h is not None and len(h.group(1)) <= level:
                break
            b = BULLET_RE.match(following)
            if b is not None:
                items.append(strip_links(b.group(1).strip()))
        return items
    return None


def release_findings(releases, pin, baseline):
    """Published, non-prerelease releases newer than pin and not baselined."""
    findings = []
    for rel in releases:
        if rel.get("draft") or rel.get("prerelease"):
            continue
        version = parse_version(rel.get("tag_name"))
        if version is None or version <= pin:
            continue
        rid = "openbao-v" + fmt_version(version)
        if rid in baseline:
            continue
        findings.append({
            "id": rid,
            "version": version,
            "class": release_class(pin, version),
            "url": rel.get("html_url") or "",
            "published": (rel.get("published_at") or "")[:10],
            "security": security_items(rel.get("body")),
        })
    findings.sort(key=lambda f: f["version"])
    return findings


def response_target(severity):
    """S17's response target; a missing severity is treated as critical."""
    if severity in ("medium", "low"):
        return "%s; %s." % (TRIAGE, TARGET_SCHEDULED)
    return "%s; %s." % (TRIAGE, TARGET_URGENT)


def ranges(adv, key):
    values = [str(e.get(key)) for e in adv.get("vulnerabilities") or [] if e.get(key)]
    return "; ".join(values) or "none listed"


def render(pin, adv, rel):
    """The issue section for these findings, as markdown."""
    v = "v" + fmt_version(pin)
    out = ["### OpenBao secrets store (pinned %s)" % v, ""]
    out.append(
        "openbao/openbao's repository advisories and releases, checked against "
        "the pin in `package/openbao/openbao.mk`. An advisory affects the pin "
        "unless one of its patched versions is on the pin's minor line at or "
        "below it, or all of them are on older lines."
    )
    out.append("")
    if adv:
        out += ["#### Advisories affecting %s" % v, ""]
        out.append("| Advisory | CVE | Severity | Published | Fixed in | Upstream range | Summary |")
        out.append("|---|---|---|---|---|---|---|")
        for a in adv:
            out.append("| [%s](%s) | %s | %s | %s | %s | %s | %s |" % (
                a.get("ghsa_id"), a.get("html_url") or "",
                a.get("cve_id") or "none",
                a.get("severity") or "not set",
                (a.get("published_at") or "")[:10],
                ranges(a, "patched_versions"),
                ranges(a, "vulnerable_version_range"),
                a.get("summary") or "",
            ))
        out.append("")
        out.append("S17 response target, the clock starting at publication:")
        out.append("")
        for a in adv:
            out.append("- %s (%s): %s" % (
                a.get("ghsa_id"), a.get("severity") or "severity not set",
                response_target(a.get("severity"))))
        out.append("")
    if rel:
        out += ["#### Releases newer than %s" % v, ""]
        for r in rel:
            out.append("- [v%s](%s), published %s (`%s`): %s." % (
                fmt_version(r["version"]), r["url"], r["published"], r["id"], r["class"]))
            if r["security"] is None:
                out.append("  - " + NO_SECURITY_SECTION)
            elif not r["security"]:
                out.append("  - The SECURITY section lists no items.")
            else:
                out += ["  - SECURITY: " + item for item in r["security"]]
        out.append("")
    out += ["#### What to do", ""]
    out.append(
        "1. Triage each finding within 2 working days: is the flaw reachable "
        "in the node's store configuration?"
    )
    out.append(
        "2. To move the pin, follow the bump procedure in the header of "
        "`package/openbao/openbao.mk`."
    )
    out.append(
        "3. After triage, add the id to `.github/cve-baseline.txt` on a line of "
        "its own: the `GHSA-…` id and its CVE id if it has one, or the "
        "release's `openbao-vX.Y.Z` id. Until then the finding re-reports "
        "every week; a bump past it also clears it."
    )
    out.append("")
    return "\n".join(out)


def actions_escape(s):
    """Escape a workflow-command message so input cannot start a new command."""
    return s.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        raise Refusal("The arguments are not usable: %s." % message)


def main(argv, stdout, stderr):
    parser = _Parser(prog="openbao-watch.py", add_help=False)
    for name in ("--pin", "--advisories", "--releases", "--baseline", "--out"):
        parser.add_argument(name, required=True)
    try:
        args = parser.parse_args(argv)
        pin = parse_version(args.pin)
        if pin is None:
            raise Refusal('The pin "%s" is not a version of the form X.Y.Z.' % args.pin)
        advisories = read_list(args.advisories, "advisories")
        if not advisories:
            raise Refusal(
                "The advisories file %s holds no advisories, so the fetch is "
                "taken to have failed." % args.advisories)
        releases = read_list(args.releases, "releases")
        if not any(isinstance(r, dict) and parse_version(r.get("tag_name")) for r in releases):
            raise Refusal(
                "The releases file %s has no release whose tag is a version of "
                "the form vX.Y.Z." % args.releases)
        baseline = read_baseline(args.baseline)
    except Refusal as e:
        stderr.write("::error::%s\n" % actions_escape(str(e)))
        return 2
    adv = advisory_findings(advisories, pin, baseline)
    rel = release_findings(releases, pin, baseline)
    total = len(adv) + len(rel)
    with open(args.out, "w", encoding="utf-8") as f:
        if total:
            f.write(render(pin, adv, rel))
    stdout.write("%d\n" % total)
    stderr.write("openbao watch: pin %s, %d new finding(s) (%d advisories, %d releases).\n" % (
        fmt_version(pin), total, len(adv), len(rel)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:], sys.stdout, sys.stderr))
