#!/usr/bin/env python3
#
# rpi-kernel-watch.py — the rpi kernel pin half of the weekly cve-watch job
# (geekdojo/geekdojo-brain#1062).
#
#   rpi-kernel-watch.py --defconfig configs/rasputin_rpi_defconfig \
#                       --buildroot-defconfig buildroot/configs/raspberrypi5_defconfig \
#                       --br-tag BR_TAG --out FILE
#
# The rpi SKU builds the Raspberry Pi kernel fork (raspberrypi/linux) at a
# commit pinned by hand in configs/rasputin_rpi_defconfig. It does not follow a
# Buildroot bump, so the LTS-currency check cannot see it go stale. This
# script reports the pin's distance from two references:
#
#   - Buildroot's own Pi pin, in raspberrypi5_defconfig at BR_TAG, as one of
#     equal, behind, newer, diverged or unknown. The compare API decides: our
#     pin is behind when Buildroot's commit descends from it, or when the two
#     have diverged and Buildroot's kernel version is higher;
#   - the head of the pin's rpi-X.Y.y branch (the branch named by the pin's
#     own Makefile version): head SHA, its version, and commits behind.
#
# An upstream that cannot be reached, or answers in an unexpected form, reads
# "unknown", never as matching. Detect-only: it never bumps the pin.
#
# Output: the issue section on --out (always written), the Buildroot status
# word on stdout, the three summary lines on stderr, and one fixed
# `::warning::` sentence per comparison that could not be completed. Exit 0,
# or 2 on a refusal, which is one `::error::` sentence on stderr and no --out
# file. Standard library only; GitHub is reached through the injected fetch.

import argparse
import json
import re
import subprocess
import sys

PIN_RE = re.compile(
    r'^BR2_LINUX_KERNEL_CUSTOM_TARBALL_LOCATION="\$\(call github,raspberrypi,linux,([0-9a-f]{40})\)',
    re.MULTILINE)
SHA_RE = re.compile(r"[0-9a-f]{40}")
MAKE_VAR_RE = {
    name: re.compile(r"^%s\s*=\s*([0-9]+)\s*$" % name, re.MULTILINE)
    for name in ("VERSION", "PATCHLEVEL", "SUBLEVEL")
}

REPO = "repos/raspberrypi/linux"
OUR_DEFCONFIG = "configs/rasputin_rpi_defconfig"

REASON_FETCH = "a request to GitHub failed"
REASON_SHAPE = "GitHub's response was not in the expected form"


class Refusal(Exception):
    """An input the watch cannot trust; the message is a sentence."""


class FetchError(Exception):
    """An upstream request that did not return a usable response."""


class _Unknown(Exception):
    """A comparison that cannot be completed; the message is its reason class."""


def gh_fetch(path, raw):
    """GET path from the GitHub API through gh; the response text or FetchError.

    The token reaches gh through GH_TOKEN in the environment, never argv.
    gh's own stderr is left to reach the step log.
    """
    argv = ["gh", "api", path]
    if raw:
        argv += ["-H", "Accept: application/vnd.github.raw"]
    try:
        done = subprocess.run(argv, stdout=subprocess.PIPE, check=True)
        return done.stdout.decode("utf-8")
    except (subprocess.CalledProcessError, OSError, UnicodeDecodeError) as e:
        raise FetchError(str(e)) from None


def pin_sha(defconfig_text):
    """The 40-hex raspberrypi/linux commit a defconfig's tarball line pins, or None."""
    m = PIN_RE.search(defconfig_text)
    return m.group(1) if m else None


def kernel_version(makefile_text):
    """(VERSION, PATCHLEVEL, SUBLEVEL) from a kernel Makefile as ints, or None."""
    parts = []
    for name in ("VERSION", "PATCHLEVEL", "SUBLEVEL"):
        m = MAKE_VAR_RE[name].search(makefile_text)
        if m is None:
            return None
        parts.append(int(m.group(1)))
    return tuple(parts)


def branch_for(version):
    return "rpi-%d.%d.y" % version[:2]


def fmt_version(v):
    return "%d.%d.%d" % v if v else "version unknown"


def _get(fetch, path, raw):
    try:
        return fetch(path, raw)
    except FetchError:
        raise _Unknown(REASON_FETCH) from None


def _version_at(fetch, ref):
    v = kernel_version(_get(fetch, "%s/contents/Makefile?ref=%s" % (REPO, ref), True))
    if v is None:
        raise _Unknown(REASON_SHAPE)
    return v


def _compare(fetch, base, head):
    """(status, ahead_by, behind_by) of head relative to base."""
    text = _get(fetch, "%s/compare/%s...%s" % (REPO, base, head), False)
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        raise _Unknown(REASON_SHAPE) from None
    if not isinstance(data, dict):
        raise _Unknown(REASON_SHAPE)
    status, ahead, behind = data.get("status"), data.get("ahead_by"), data.get("behind_by")
    if status not in ("ahead", "behind", "diverged", "identical") \
            or not isinstance(ahead, int) or not isinstance(behind, int):
        raise _Unknown(REASON_SHAPE)
    return status, ahead, behind


def compare_buildroot(pin, br, fetch):
    """Our pin against Buildroot's: (status, facts).

    Equal SHAs are `equal` with no network call. Otherwise the compare API
    decides: Buildroot's commit `ahead` of ours is `behind`, `behind` is
    `newer`, and a divergence is `behind` only if Buildroot's kernel version
    is higher, else `diverged`. Anything that cannot be completed is
    `unknown`, with facts["reason"] saying why.
    """
    facts = {"pin": pin, "br": br}
    if pin == br:
        return "equal", facts
    try:
        status, ahead, behind = _compare(fetch, pin, br)
        facts.update(ahead_by=ahead, behind_by=behind)
        facts["pin_version"] = _version_at(fetch, pin)
        facts["br_version"] = _version_at(fetch, br)
    except _Unknown as e:
        facts["reason"] = str(e)
        return "unknown", facts
    if status == "identical":
        return "equal", facts
    if status == "ahead":
        return "behind", facts
    if status == "behind":
        return "newer", facts
    if facts["br_version"] > facts["pin_version"]:
        return "behind", facts
    return "diverged", facts


def compare_head(pin, fetch):
    """Our pin against the head of its rpi-X.Y.y branch: (status, facts).

    status is `ok` or `unknown`. The branch is named by the pin's Makefile
    version. facts carries pin_version, branch, head, head_version, ahead_by
    (commits on the branch not in the pin) and behind_by (commits in the pin
    not on the branch), as far as they were found.
    """
    facts = {}
    try:
        facts["pin_version"] = _version_at(fetch, pin)
        branch = facts["branch"] = branch_for(facts["pin_version"])
        try:
            head = json.loads(_get(fetch, "%s/commits/%s" % (REPO, branch), False)).get("sha")
        except (json.JSONDecodeError, AttributeError):
            raise _Unknown(REASON_SHAPE) from None
        if not isinstance(head, str) or not SHA_RE.fullmatch(head):
            raise _Unknown(REASON_SHAPE)
        facts["head"] = head
        facts["head_version"] = _version_at(fetch, head)
        _, facts["ahead_by"], facts["behind_by"] = _compare(fetch, pin, branch)
    except _Unknown as e:
        facts["reason"] = str(e)
        return "unknown", facts
    return "ok", facts


def _br_line(br_tag, status, bf, pin_version):
    """The Buildroot relation, as one markdown sentence."""
    theirs = "Buildroot `%s`'s `raspberrypi5_defconfig` pins `%s`" % (br_tag, bf["br"][:8])
    if status == "equal":
        return "✅ The pin matches Buildroot `%s`'s `raspberrypi5_defconfig`." % br_tag
    if status == "behind":
        return (
            "⚠️ **The rpi kernel pin is stale:** `%s` pins `%s` (%s); %s (%s), %d commits "
            "ahead. Bump `BR2_LINUX_KERNEL_CUSTOM_TARBALL_LOCATION` (then re-validate on "
            "hardware)." % (OUR_DEFCONFIG, bf["pin"][:8], fmt_version(bf["pin_version"]),
                            theirs, fmt_version(bf["br_version"]), bf["ahead_by"]))
    if status == "newer":
        return "The pin is newer: %s (%s), %d commits behind ours." % (
            theirs, fmt_version(bf["br_version"]), bf["behind_by"])
    if status == "diverged":
        return (
            "The pin has diverged from Buildroot's: %s (%s), with %d commits not in ours "
            "and %d of ours not in it, and its kernel version is not higher." % (
                theirs, fmt_version(bf["br_version"]), bf["ahead_by"], bf["behind_by"]))
    return "The comparison with Buildroot `%s`'s pin `%s` is unknown: %s." % (
        br_tag, bf["br"][:8], bf["reason"])


def _head_line(status, hf):
    if status == "unknown":
        name = "`%s`" % hf["branch"] if "branch" in hf else "rpi branch"
        return "The %s head comparison is unknown: %s." % (name, hf["reason"])
    line = "`%s` head `%s` (%s): the pin is %d commits behind." % (
        hf["branch"], hf["head"][:8], fmt_version(hf["head_version"]), hf["ahead_by"])
    if hf["behind_by"]:
        line += " The pin also has %d commits not on the branch." % hf["behind_by"]
    return line


def render(pin, br_tag, br_status, bf, head_status, hf):
    """The issue section, as markdown."""
    pin_version = hf.get("pin_version") or bf.get("pin_version")
    out = ["#### rpi kernel pin", ""]
    out.append(
        "`%s` pins raspberrypi/linux `%s` (%s). It moves only by a hand edit, so it is "
        "checked against Buildroot's Pi pin and against its branch head." % (
            OUR_DEFCONFIG, pin[:8], fmt_version(pin_version)))
    out.append("")
    out.append("- " + _br_line(br_tag, br_status, bf, pin_version))
    out.append("- " + _head_line(head_status, hf))
    out.append("")
    return "\n".join(out)


def _summary(pin, br_tag, br_status, bf, head_status, hf):
    """The three stderr summary lines a dry_run log shows."""
    pin_version = hf.get("pin_version") or bf.get("pin_version")
    br_version = pin_version if br_status == "equal" else bf.get("br_version")
    lines = [
        "rpi kernel watch: pin %s (%s)." % (pin, fmt_version(pin_version)),
        "rpi kernel watch: Buildroot %s pins %s (%s): %s." % (
            br_tag, bf["br"], fmt_version(br_version), br_status),
    ]
    if head_status == "ok":
        lines.append("rpi kernel watch: %s head %s (%s), pin %d commits behind." % (
            hf["branch"], hf["head"], fmt_version(hf["head_version"]), hf["ahead_by"]))
    else:
        lines.append("rpi kernel watch: %s head unknown." % hf.get("branch", "rpi branch"))
    return "".join(line + "\n" for line in lines)


def read_pin(path, what):
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except FileNotFoundError:
        raise Refusal("The %s %s does not exist." % (what, path)) from None
    except (OSError, UnicodeDecodeError) as e:
        raise Refusal("The %s %s could not be read: %s." % (what, path, e)) from None
    sha = pin_sha(text)
    if sha is None:
        raise Refusal(
            "The %s %s has no BR2_LINUX_KERNEL_CUSTOM_TARBALL_LOCATION pinning a "
            "40-hex raspberrypi/linux commit." % (what, path))
    return sha


class _Parser(argparse.ArgumentParser):
    def error(self, message):
        raise Refusal("The arguments are not usable: %s." % message)


def main(argv, stdout, stderr, fetch):
    parser = _Parser(prog="rpi-kernel-watch.py", add_help=False)
    for name in ("--defconfig", "--buildroot-defconfig", "--br-tag", "--out"):
        parser.add_argument(name, required=True)
    try:
        args = parser.parse_args(argv)
        pin = read_pin(args.defconfig, "defconfig")
        br = read_pin(args.buildroot_defconfig, "Buildroot defconfig")
    except Refusal as e:
        stderr.write("::error::%s\n" % str(e).replace("\n", " "))
        return 2
    br_status, bf = compare_buildroot(pin, br, fetch)
    head_status, hf = compare_head(pin, fetch)
    if br_status == "unknown":
        stderr.write("::warning::The Buildroot comparison could not be completed, "
                     "so it is reported as unknown.\n")
    if head_status == "unknown":
        stderr.write("::warning::The %s head comparison could not be completed, so it "
                     "is reported as unknown.\n" % hf.get("branch", "rpi branch"))
    with open(args.out, "w", encoding="utf-8") as f:
        f.write(render(pin, args.br_tag, br_status, bf, head_status, hf))
    stdout.write(br_status + "\n")
    stderr.write(_summary(pin, args.br_tag, br_status, bf, head_status, hf))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:], sys.stdout, sys.stderr, gh_fetch))
