#!/usr/bin/env python3
#
# rpi-kernel-watch-test.py — unit tests for scripts/rpi-kernel-watch.py, the
# rpi kernel pin half of the weekly cve-watch job
# (geekdojo/geekdojo-brain#1062).
#
#   python3 -I test/rpi-kernel-watch-test.py
#
# Each test names the test case (TC-1062-NN) it implements. GitHub is a fake
# fetch over a dict of API paths; a path missing from the dict raises
# FetchError, as an unreachable upstream does. The fixtures are excerpts of
# raspberrypi/linux's live responses, fetched 2026-11-03 with the same
# `gh api` calls the script makes. Nothing here touches the network.

import importlib.util
import io
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..")
SCRIPT = os.path.join(ROOT, "scripts", "rpi-kernel-watch.py")

# Loading the script must not leave a __pycache__ in scripts/.
sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location("rpi_kernel_watch", SCRIPT)
watch = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(watch)

REPO = "repos/raspberrypi/linux"
PIN_612 = "21b410140c47ffab5668399f6f143c7d7b935c8b"   # 6.12.61, the pin today
PIN_66 = "576cc10e1ed50a9eacffc7a05c796051d7343ea4"    # 6.6.28, the previous pin
HEAD_612 = "2569533d6c33c15231fbc21704c87fcebc67173c"  # rpi-6.12.y head, 6.12.115
HEAD_66 = "0123456789abcdef0123456789abcdef01234567"   # synthetic rpi-6.6.y head
OTHER = "fedcba9876543210fedcba9876543210fedcba98"     # synthetic Buildroot pin

REFUSAL_RE = re.compile(r"::error::[A-Z][^\n]*\.\n")
WARNING_RE = re.compile(r"^::warning::[A-Z][^\n]*\.$", re.MULTILINE)


def defconfig(sha):
    return (
        "BR2_LINUX_KERNEL=y\n"
        "BR2_LINUX_KERNEL_CUSTOM_TARBALL=y\n"
        'BR2_LINUX_KERNEL_CUSTOM_TARBALL_LOCATION="$(call github,raspberrypi,linux,%s)'
        '/linux-%s.tar.gz"\n' % (sha, sha))


def makefile(version):
    v, p, s = version
    return ("# SPDX-License-Identifier: GPL-2.0\nVERSION = %d\nPATCHLEVEL = %d\n"
            "SUBLEVEL = %d\nEXTRAVERSION =\nNAME = Baby Opossum Posse\n" % (v, p, s))


def mk_path(ref):
    return "%s/contents/Makefile?ref=%s" % (REPO, ref)


def cmp_path(base, head):
    return "%s/compare/%s...%s" % (REPO, base, head)


def compare(status, ahead, behind):
    # The fields the script reads, in the live response's shape.
    return json.dumps({"url": "https://api.github.com/repos/raspberrypi/linux/compare/x",
                       "status": status, "ahead_by": ahead, "behind_by": behind,
                       "total_commits": ahead})


def head_responses(pin, version, branch, head, head_version, ahead, behind=0):
    """The fixtures compare_head fetches for a pin."""
    return {
        mk_path(pin): makefile(version),
        "%s/commits/%s" % (REPO, branch): json.dumps({"sha": head, "commit": {}}),
        mk_path(head): makefile(head_version),
        cmp_path(pin, branch): compare("ahead" if not behind else "diverged", ahead, behind),
    }


HEAD_612_RESPONSES = head_responses(PIN_612, (6, 12, 61), "rpi-6.12.y",
                                    HEAD_612, (6, 12, 115), 14958)


class FakeFetch:
    def __init__(self, responses):
        self.responses = responses
        self.calls = []

    def __call__(self, path, raw):
        self.calls.append((path, raw))
        if path not in self.responses:
            raise watch.FetchError("no fixture for " + path)
        return self.responses[path]

    def paths(self):
        return [p for p, _ in self.calls]


class Run:
    """Writes the defconfigs into a scratch dir and runs main() on them."""

    def __init__(self, test):
        self.dir = tempfile.mkdtemp()
        test.addCleanup(self._cleanup)
        self.out = os.path.join(self.dir, "rpi-kernel.md")

    def _cleanup(self):
        for name in os.listdir(self.dir):
            os.remove(os.path.join(self.dir, name))
        os.rmdir(self.dir)

    def write(self, name, text):
        path = os.path.join(self.dir, name)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        return path

    def argv(self, ours, theirs):
        return [
            "--defconfig", self.write("ours_defconfig", ours),
            "--buildroot-defconfig", self.write("raspberrypi5_defconfig", theirs),
            "--br-tag", "2026.08.1",
            "--out", self.out,
        ]

    def main(self, argv, fetch):
        stdout, stderr = io.StringIO(), io.StringIO()
        rc = watch.main(argv, stdout, stderr, fetch)
        return rc, stdout.getvalue(), stderr.getvalue()

    def output(self):
        with open(self.out, encoding="utf-8") as f:
            return f.read()


class RpiKernelWatchTest(unittest.TestCase):
    maxDiff = None

    def run_main(self, pin, br, responses):
        run = Run(self)
        fetch = FakeFetch(responses)
        rc, out, err = run.main(run.argv(defconfig(pin), defconfig(br)), fetch)
        self.assertEqual(rc, 0, err)
        return out, err, run.output(), fetch

    # TC-1062-01: the real defconfig's pin parses; malformed lines are None.
    def test_tc_1062_01_pin_sha(self):
        with open(os.path.join(ROOT, "configs", "rasputin_rpi_defconfig"), encoding="utf-8") as f:
            self.assertRegex(watch.pin_sha(f.read()), r"^[0-9a-f]{40}$")
        self.assertEqual(watch.pin_sha(defconfig(PIN_612)), PIN_612)
        for text in (
            "BR2_LINUX_KERNEL=y\n",
            defconfig(PIN_612[:12]),
            defconfig(PIN_612).replace("raspberrypi,linux", "torvalds,linux"),
            defconfig(PIN_612).replace("BR2_LINUX_KERNEL_CUSTOM_TARBALL_LOCATION",
                                       "# BR2_LINUX_KERNEL_CUSTOM_TARBALL_LOCATION"),
        ):
            with self.subTest(text=text):
                self.assertIsNone(watch.pin_sha(text))

    # TC-1062-02: an equal pin is `equal` with no compare and no fetch of
    # Buildroot's pin, and says it matches.
    def test_tc_1062_02_equal(self):
        out, err, section, fetch = self.run_main(PIN_612, PIN_612, HEAD_612_RESPONSES)
        self.assertEqual(out, "equal\n")
        self.assertIn("matches Buildroot `2026.08.1`", section)
        self.assertNotIn("stale", section)
        paths = fetch.paths()
        self.assertFalse([p for p in paths if "/compare/%s...%s" % (PIN_612, PIN_612) in p])
        # The pin's Makefile is fetched once, for the branch head; Buildroot's
        # pin (the same commit) is never fetched on its own.
        self.assertEqual(paths.count(mk_path(PIN_612)), 1)
        self.assertNotIn("::warning::", err)

    # TC-1062-03: Buildroot's commit descends from ours, so the pin is stale.
    def test_tc_1062_03_behind_by_ancestry(self):
        responses = dict(HEAD_612_RESPONSES)
        responses[cmp_path(PIN_612, OTHER)] = compare("ahead", 812, 0)
        responses[mk_path(OTHER)] = makefile((6, 12, 75))
        out, _, section, _ = self.run_main(PIN_612, OTHER, responses)
        self.assertEqual(out, "behind\n")
        self.assertIn("**The rpi kernel pin is stale:** `configs/rasputin_rpi_defconfig` "
                      "pins `21b41014` (6.12.61); Buildroot `2026.08.1`'s "
                      "`raspberrypi5_defconfig` pins `fedcba98` (6.12.75), 812 commits ahead. "
                      "Bump `BR2_LINUX_KERNEL_CUSTOM_TARBALL_LOCATION`", section)

    # TC-1062-04: the old 6.6 pin against Buildroot's 6.12 pin: diverged, but
    # Buildroot's version is higher, so behind.
    def test_tc_1062_04_behind_across_series(self):
        responses = head_responses(PIN_66, (6, 6, 28), "rpi-6.6.y", HEAD_66, (6, 6, 127), 90000)
        responses[cmp_path(PIN_66, PIN_612)] = compare("diverged", 108273, 7077)
        responses[mk_path(PIN_612)] = makefile((6, 12, 61))
        out, _, section, _ = self.run_main(PIN_66, PIN_612, responses)
        self.assertEqual(out, "behind\n")
        self.assertIn("**The rpi kernel pin is stale:**", section)
        self.assertIn("`576cc10e` (6.6.28)", section)
        self.assertIn("`21b41014` (6.12.61), 108273 commits ahead", section)

    # TC-1062-05: diverged with Buildroot's version not higher is `diverged`.
    def test_tc_1062_05_diverged(self):
        for br_version in ((6, 12, 61), (6, 12, 40)):
            with self.subTest(br_version=br_version):
                responses = dict(HEAD_612_RESPONSES)
                responses[cmp_path(PIN_612, OTHER)] = compare("diverged", 5, 9)
                responses[mk_path(OTHER)] = makefile(br_version)
                out, _, section, _ = self.run_main(PIN_612, OTHER, responses)
                self.assertEqual(out, "diverged\n")
                self.assertNotIn("stale", section)
                self.assertNotIn("matches", section)
                self.assertNotIn("current", section)

    # TC-1062-06: Buildroot's commit is an ancestor of ours: `newer`.
    def test_tc_1062_06_newer(self):
        responses = dict(HEAD_612_RESPONSES)
        responses[cmp_path(PIN_612, OTHER)] = compare("behind", 0, 30)
        responses[mk_path(OTHER)] = makefile((6, 12, 58))
        out, _, section, _ = self.run_main(PIN_612, OTHER, responses)
        self.assertEqual(out, "newer\n")
        self.assertNotIn("stale", section)

    # TC-1062-07: the distance from the head of the branch the pin's Makefile
    # names, in the section and the stderr summary.
    def test_tc_1062_07_branch_head(self):
        _, err, section, fetch = self.run_main(PIN_612, PIN_612, HEAD_612_RESPONSES)
        self.assertIn("`rpi-6.12.y` head `2569533d` (6.12.115): the pin is 14958 commits behind.",
                      section)
        self.assertIn("rpi kernel watch: rpi-6.12.y head %s (6.12.115), pin 14958 commits "
                      "behind." % HEAD_612, err)
        self.assertIn("%s/commits/rpi-6.12.y" % REPO, fetch.paths())
        self.assertIn(cmp_path(PIN_612, "rpi-6.12.y"), fetch.paths())
        # The three summary lines a dry_run log shows.
        self.assertIn("rpi kernel watch: pin %s (6.12.61)." % PIN_612, err)
        self.assertIn("rpi kernel watch: Buildroot 2026.08.1 pins %s (6.12.61): equal." % PIN_612,
                      err)

        # A 6.6 pin is compared with rpi-6.6.y, and commits off the branch are named.
        responses = head_responses(PIN_66, (6, 6, 28), "rpi-6.6.y", HEAD_66, (6, 6, 127), 90000, 12)
        _, _, section, fetch = self.run_main(PIN_66, PIN_66, responses)
        self.assertIn("%s/commits/rpi-6.6.y" % REPO, fetch.paths())
        self.assertNotIn("%s/commits/rpi-6.12.y" % REPO, fetch.paths())
        self.assertIn("`rpi-6.6.y` head `01234567` (6.6.127): the pin is 90000 commits behind. "
                      "The pin also has 12 commits not on the branch.", section)

    # TC-1062-08: nothing reachable and a differing pin: unknown, never matching.
    def test_tc_1062_08_unreachable_differing(self):
        out, err, section, _ = self.run_main(PIN_66, PIN_612, {})
        self.assertEqual(out, "unknown\n")
        self.assertIn("unknown", section)
        self.assertIn("unknown", err)
        for text in (section, err):
            self.assertNotIn("matches", text)
            self.assertNotIn("current", text)
        warnings = WARNING_RE.findall(err)
        self.assertEqual(warnings, [
            "::warning::The Buildroot comparison could not be completed, so it is "
            "reported as unknown.",
            "::warning::The rpi branch head comparison could not be completed, so it is "
            "reported as unknown.",
        ])
        self.assertNotIn("no fixture", err)

    # TC-1062-09: nothing reachable and an equal pin: still equal (a local
    # fact), the branch head unknown, one warning.
    def test_tc_1062_09_unreachable_equal(self):
        out, err, section, _ = self.run_main(PIN_612, PIN_612, {})
        self.assertEqual(out, "equal\n")
        self.assertIn("- The rpi branch head comparison is unknown: a request to GitHub failed.",
                      section)
        self.assertEqual(len(WARNING_RE.findall(err)), 1)
        self.assertIn("head comparison could not be completed", err)

    # TC-1062-10: malformed responses make the comparison they feed unknown.
    def test_tc_1062_10_malformed(self):
        base = dict(HEAD_612_RESPONSES)
        base[cmp_path(PIN_612, OTHER)] = compare("ahead", 812, 0)
        base[mk_path(OTHER)] = makefile((6, 12, 75))
        cases = {
            "compare not JSON": (cmp_path(PIN_612, OTHER), "<html>rate limited</html>", "br"),
            "compare without status": (cmp_path(PIN_612, OTHER),
                                       json.dumps({"ahead_by": 812, "behind_by": 0}), "br"),
            "Makefile without a version": (mk_path(OTHER), "# empty\n", "br"),
            "head compare not JSON": (cmp_path(PIN_612, "rpi-6.12.y"), "not json", "head"),
            "commits without a sha": ("%s/commits/rpi-6.12.y" % REPO,
                                      json.dumps({"sha": "abc"}), "head"),
            "commits not an object": ("%s/commits/rpi-6.12.y" % REPO, "[]", "head"),
            "head Makefile without a version": (mk_path(HEAD_612), "VERSION = 6\n", "head"),
        }
        for name, (path, text, which) in cases.items():
            with self.subTest(case=name):
                responses = dict(base)
                responses[path] = text
                out, err, section, _ = self.run_main(PIN_612, OTHER, responses)
                if which == "br":
                    self.assertEqual(out, "unknown\n")
                    self.assertIn("is unknown: GitHub's response was not in the expected form.",
                                  section)
                    self.assertIn("14958 commits behind", section)
                else:
                    self.assertEqual(out, "behind\n")
                    self.assertIn("The `rpi-6.12.y` head comparison is unknown: GitHub's "
                                  "response was not in the expected form.", section)
                self.assertNotIn("matches", section)

    # TC-1062-11: every refusal exits 2 with one ::error:: sentence, no
    # --out file and nothing on stdout.
    def test_tc_1062_11_refusals(self):
        run = Run(self)
        good = run.write("good", defconfig(PIN_612))
        bad = run.write("bad", "BR2_LINUX_KERNEL=y\n")
        unreadable = run.write("unreadable", defconfig(PIN_612))
        os.chmod(unreadable, 0)
        missing = os.path.join(run.dir, "missing")
        out = run.out

        def argv(ours, theirs):
            return ["--defconfig", ours, "--buildroot-defconfig", theirs,
                    "--br-tag", "2026.08.1", "--out", out]

        cases = {
            "defconfig missing": argv(missing, good),
            "defconfig with no pin": argv(bad, good),
            "Buildroot defconfig missing": argv(good, missing),
            "Buildroot defconfig with no pin": argv(good, bad),
            "missing required argument": argv(good, good)[:-2],
            "unknown argument": argv(good, good) + ["--extra", "x"],
        }
        if os.geteuid() != 0:  # root reads a mode-0 file
            cases["defconfig unreadable"] = argv(unreadable, good)
        for name, args in cases.items():
            with self.subTest(case=name):
                rc, stdout, stderr = run.main(args, FakeFetch(HEAD_612_RESPONSES))
                self.assertEqual(rc, 2)
                self.assertEqual(stdout, "")
                self.assertEqual(stderr.count("::error::"), 1)
                self.assertRegex(stderr, REFUSAL_RE)
                self.assertFalse(os.path.exists(out))
        os.chmod(unreadable, stat.S_IRUSR | stat.S_IWUSR)

    # TC-1062-12: gh_fetch passes the raw Accept header only when asked,
    # turns a failing gh into FetchError, and never puts the token in argv.
    def test_tc_1062_12_gh_fetch(self):
        bindir = tempfile.mkdtemp()
        log = os.path.join(bindir, "argv")
        gh = os.path.join(bindir, "gh")

        def cleanup():
            for name in os.listdir(bindir):
                os.remove(os.path.join(bindir, name))
            os.rmdir(bindir)
        self.addCleanup(cleanup)

        def stub(code):
            with open(gh, "w", encoding="utf-8") as f:
                f.write('#!/bin/sh\nprintf "%%s\\n" "$@" > "%s"\necho response\nexit %d\n'
                        % (log, code))
            os.chmod(gh, 0o755)

        def argv():
            with open(log, encoding="utf-8") as f:
                return f.read().splitlines()

        old_env = dict(os.environ)
        self.addCleanup(lambda: (os.environ.clear(), os.environ.update(old_env)))
        os.environ["PATH"] = bindir + os.pathsep + os.environ.get("PATH", "")
        os.environ["GH_TOKEN"] = "ghs_secretTokenValue123"

        stub(0)
        self.assertEqual(watch.gh_fetch("repos/x/y/contents/Makefile?ref=z", True), "response\n")
        self.assertEqual(argv(), ["api", "repos/x/y/contents/Makefile?ref=z",
                                  "-H", "Accept: application/vnd.github.raw"])
        self.assertNotIn("ghs_secretTokenValue123", " ".join(argv()))
        watch.gh_fetch("repos/x/y/commits/b", False)
        self.assertEqual(argv(), ["api", "repos/x/y/commits/b"])
        self.assertNotIn("ghs_secretTokenValue123", " ".join(argv()))

        stub(1)
        with self.assertRaises(watch.FetchError):
            watch.gh_fetch("repos/x/y/commits/b", False)

    # The real CLI: the composition root wires gh_fetch and exits 2 on a refusal.
    def test_cli_refusal_exit_code(self):
        done = subprocess.run([sys.executable, "-I", SCRIPT, "--defconfig", "x"],
                              capture_output=True, text=True)
        self.assertEqual(done.returncode, 2)
        self.assertRegex(done.stderr, REFUSAL_RE)


if __name__ == "__main__":
    # Loaded from the class, as openbao-watch-test.py does, so it also runs
    # under `python3 -m trace`.
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(RpiKernelWatchTest)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    sys.exit(0 if result.wasSuccessful() else 1)
