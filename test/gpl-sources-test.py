#!/usr/bin/env python3
#
# gpl-sources-test.py — unit tests for scripts/gpl-sources.py
# (geekdojo/geekdojo-brain#970).
#
#   python3 -I test/gpl-sources-test.py
#
# Each test names the test case (TC-970-NN) it implements. Fixtures are built
# in a temporary directory: legal-info trees in the shape Buildroot 2026.08.1's
# `make legal-info` writes (manifest.csv columns from Makefile:871, source
# directories named <package>-<sanitised version> as pkg-generic.mk:517/676),
# and `docker save` tarballs in the layout bake-mesh-images.sh produces. The
# Headscale dpkg entries under test/fixtures/headscale-0.28.0-dpkg/ are copied
# verbatim from headscale/headscale:0.28.0@sha256:51b1b918... (linux/amd64),
# the image the control-plane pin at v2026.11.2-dev.220 bakes. Nothing here
# touches the network.

import contextlib
import csv
import gzip
import importlib.util
import io
import json
import os
import shutil
import sys
import tarfile
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "scripts", "gpl-sources.py")
HEADSCALE_DPKG = os.path.join(HERE, "fixtures", "headscale-0.28.0-dpkg")
HEADSCALE_REF = "headscale/headscale:0.28.0@sha256:51b1b9182bb6219e97374fa89af6b9320d6f87ecc739e328d5357ea4fa7a5ce3"
HEADSCALE_ID = "8432a58ca5afd4583b612b5b5090fd959d875c65132165851355368d2b06e102"

sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location("gpl_sources", SCRIPT)
gs = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gs)

HEADER = ["PACKAGE", "VERSION", "LICENSE", "LICENSE FILES", "SOURCE ARCHIVE", "SOURCE SITE", "DEPENDENCIES WITH LICENSES"]


def run(*argv):
    """Runs main(argv); returns (status, stdout, stderr)."""
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        status = gs.main(list(argv))
    return status, out.getvalue(), err.getvalue()


def errors(stderr):
    return [l for l in stderr.splitlines() if l.startswith("::error::gpl-sources: ")]


class Fixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp)

    # A legal-info dir. rows: (package, version, licence, archive, content);
    # content None saves nothing, b"" saves an empty file.
    def legal_info(self, rows, name="legal-info"):
        d = os.path.join(self.tmp, name)
        os.makedirs(os.path.join(d, "sources"), exist_ok=True)
        with open(os.path.join(d, "manifest.csv"), "w", newline="") as f:
            w = csv.writer(f, quoting=csv.QUOTE_ALL)
            w.writerow(HEADER)
            for pkg, ver, lic, archive, content in rows:
                w.writerow([pkg, ver, lic, "COPYING", archive, "https://example.invalid", ""])
                if content is not None:
                    p = os.path.join(d, gs.source_path(pkg, ver, archive))
                    os.makedirs(os.path.dirname(p), exist_ok=True)
                    with open(p, "wb") as g:
                        g.write(content)
        return d


def saved(pkg, ver, lic, archive=None):
    return (pkg, ver, lic, archive or f"{pkg}-{ver}.tar.gz", b"source bytes")


def unsaved(pkg, ver, lic, archive=None):
    return (pkg, ver, lic, archive or f"{pkg}-{ver}.tar.gz", None)


class LegalInfo(Fixture):
    def test_tc_970_01_missing_gpl_sources_each_reported(self):
        # TC-970-01
        d = self.legal_info([unsaved("busybox", "1.37.0", "GPL-2.0"), unsaved("glibc", "2.42", "LGPL-2.1+")])
        status, out, err = run("legal-info", d)
        self.assertEqual(status, 1)
        errs = errors(err)
        self.assertEqual(len(errs), 2, err)
        self.assertIn("busybox", errs[0])
        self.assertIn("sources/busybox-1.37.0/busybox-1.37.0.tar.gz", errs[0])
        self.assertIn("_REDISTRIBUTE", errs[0])
        self.assertIn("glibc", errs[1])
        self.assertIn("sources/glibc-2.42/glibc-2.42.tar.gz", errs[1])
        for e in errs:
            self.assertTrue(e.endswith("."), e)
        self.assertEqual(out, "")
        self.assertNotIn("each with its source saved", err)

    def test_tc_970_04_empty_not_saved_and_zero_byte_archives(self):
        # TC-970-04
        d = self.legal_info([
            ("aaa", "1.0", "GPL-2.0", "", None),
            ("bbb", "1.0", "GPL-2.0", "not saved", None),
            ("ccc", "1.0", "GPL-2.0", "ccc-1.0.tar.gz", b""),
        ])
        status, out, err = run("legal-info", d)
        self.assertEqual(status, 1)
        errs = errors(err)
        self.assertEqual(len(errs), 3, err)
        self.assertIn("aaa", errs[0])
        self.assertIn("'(empty)'", errs[0])
        self.assertIn("bbb", errs[1])
        self.assertIn("'not saved'", errs[1])
        self.assertIn("ccc", errs[2])
        self.assertIn("is empty", errs[2])
        self.assertEqual(out, "")

    def test_tc_970_05_unknown_licence_fails_closed_except_own_packages(self):
        # TC-970-05
        rows = [
            saved("foo", "1.0", "unknown"),
            saved("rasputin-api", "2026.11.2-dev.220", "unknown"),
            saved("rasputin-agent", "2026.11.2-dev.220", ""),
        ]
        status, out, err = run("legal-info", self.legal_info(rows))
        self.assertEqual(status, 1)
        errs = errors(err)
        self.assertEqual(len(errs), 1, err)
        self.assertIn("Package foo has licence 'unknown'", errs[0])
        self.assertEqual(out, "")

        rows = [saved("foo", "1.0", ""), saved("rasputin-api", "1", "unknown")]
        status, _, err = run("legal-info", self.legal_info(rows, "empty-licence"))
        self.assertEqual(status, 1)
        self.assertIn("Package foo has licence '(empty)'", err)

        own = [saved("rasputin-api", "1", "unknown"), saved("rasputin-agent", "1", "")]
        status, out, err = run("legal-info", self.legal_info(own, "own-only"))
        self.assertEqual(status, 0, err)
        self.assertEqual(errors(err), [])

    def test_tc_970_06_which_licences_need_source(self):
        # TC-970-06
        gpl = ["LGPL-2.1+", "GPL-2.0+ WITH Linux-syscall-note", "GPL-3.0-with-GCC-exception", "AGPL-3.0", "BSD-3-Clause, GPL-2.0"]
        other = ["MIT", "Apache-2.0", "MPL-2.0", "BSD-2-Clause"]
        rows = [unsaved(f"g{i}", "1", lic) for i, lic in enumerate(gpl)]
        rows += [unsaved(f"o{i}", "1", lic) for i, lic in enumerate(other)]
        status, _, err = run("legal-info", self.legal_info(rows))
        self.assertEqual(status, 1)
        named = sorted(e.split("Package ", 1)[1].split(" ", 1)[0] for e in errors(err))
        self.assertEqual(named, [f"g{i}" for i in range(len(gpl))])
        for lic in gpl:
            self.assertEqual(gs.classify(lic), "gpl", lic)
        for lic in other:
            self.assertEqual(gs.classify(lic), "other", lic)

    def test_tc_970_07_jre_ships_jdk_source_not_binary(self):
        # TC-970-07
        lic = "GPL-2.0 with Classpath exception"
        binary = "OpenJDK25U-jre_x64_linux_hotspot_25.0.5_8.tar.gz"
        source = "OpenJDK25U-jdk-sources_25.0.5_8.tar.gz"
        base = [saved("busybox", "1.37.0", "GPL-2.0")]

        status, _, err = run("legal-info", self.legal_info(base + [saved("temurin-jre", "25.0.5+8", lic, binary)], "a"))
        self.assertEqual(status, 1)
        errs = errors(err)
        self.assertEqual(len(errs), 1, err)
        self.assertIn("TEMURIN_JRE_ACTUAL_SOURCE_TARBALL", errs[0])
        self.assertIn(binary, errs[0])

        status, out, err = run("legal-info", self.legal_info(base + [saved("temurin-jre", "25.0.5+8", lic, source)], "b"))
        self.assertEqual(status, 0, err)
        self.assertIn("2 GPL-family packages", out)

        status, out, err = run("legal-info", self.legal_info(base, "none"))
        self.assertEqual(status, 0, err)
        self.assertIn("1 GPL-family packages", out)

    def test_tc_970_08_check_cannot_run(self):
        # TC-970-08: each input that stops the check, with the sentence that
        # names it.
        cases = {}
        d = os.path.join(self.tmp, "no-manifest")
        os.makedirs(d)
        cases["(a) no manifest.csv"] = (d, "is missing")

        d = self.legal_info([saved("busybox", "1", "GPL-2.0")], "unreadable")
        os.chmod(os.path.join(d, "manifest.csv"), 0)
        self.addCleanup(os.chmod, os.path.join(d, "manifest.csv"), 0o644)
        cases["(b) unreadable manifest.csv"] = (d, "Cannot read")

        d = os.path.join(self.tmp, "no-column")
        os.makedirs(d)
        with open(os.path.join(d, "manifest.csv"), "w") as f:
            f.write('"PACKAGE","VERSION","LICENSE","LICENSE FILES"\n"busybox","1","GPL-2.0","LICENSE"\n')
        cases["(c) no SOURCE ARCHIVE column"] = (d, "has no SOURCE ARCHIVE column")

        d = os.path.join(self.tmp, "not-csv")
        os.makedirs(d)
        with open(os.path.join(d, "manifest.csv"), "w") as f:
            f.write('{"packages": ["busybox"]}\n')
        cases["(d) non-CSV text"] = (d, "not a Buildroot legal-info manifest")

        d = os.path.join(self.tmp, "binary")
        os.makedirs(d)
        with open(os.path.join(d, "manifest.csv"), "wb") as f:
            f.write(b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\xff\xfe")
        cases["(d) binary file"] = (d, "Cannot read")

        cases["(e) no such dir"] = (os.path.join(self.tmp, "does-not-exist"), "does not exist")

        if os.geteuid() == 0:
            self.fail("TC-970-08 (b) needs a non-root user: root reads a mode-000 file")
        for what, (d, text) in cases.items():
            with self.subTest(what):
                status, out, err = run("legal-info", d)
                self.assertEqual(status, 2, err)
                self.assertEqual(len(errors(err)), 1, err)
                self.assertIn(text, errors(err)[0])
                self.assertTrue(errors(err)[0].endswith("."), err)
                self.assertEqual(out, "")

    def test_tc_970_08_short_row_cannot_run(self):
        # TC-970-08 (a row with fewer columns than the header)
        d = os.path.join(self.tmp, "short-row")
        os.makedirs(d)
        with open(os.path.join(d, "manifest.csv"), "w") as f:
            f.write(",".join(f'"{h}"' for h in HEADER) + '\n"busybox","1"\n')
        status, _, err = run("legal-info", d)
        self.assertEqual(status, 2)
        self.assertIn("fewer columns", err)

    def test_tc_970_09_pass_with_buildroot_directory_names(self):
        # TC-970-09
        rows = [
            # LINUX_VERSION = custom for a custom tarball: sources/linux-custom/
            ("linux", "custom", "GPL-2.0", "linux-6.12.tar.gz", b"k"),
            # A git-ref version with '/', ':' and ' ': sanitised to '_'.
            ("weird", "remotes/origin/1:2 3", "GPL-2.0+", "weird.tar.gz", b"w"),
            # No version: sources/<package>/
            ("noversion", "", "LGPL-2.1", "noversion.tar.gz", b"n"),
            ("busybox", "1.37.0", "GPL-2.0", "busybox-1.37.0.tar.bz2", b"b"),
            ("zlib", "1.3.1", "Zlib", "zlib-1.3.1.tar.xz", None),
            ("rasputin-api", "2026.11.2-dev.220", "unknown", "rasputin-api.tar.gz", b"x"),
        ]
        d = self.legal_info(rows)
        for rel in ("sources/linux-custom/linux-6.12.tar.gz",
                    "sources/weird-remotes_origin_1_2_3/weird.tar.gz",
                    "sources/noversion/noversion.tar.gz"):
            self.assertTrue(os.path.isfile(os.path.join(d, rel)), rel)
        status, out, err = run("legal-info", d)
        self.assertEqual(status, 0, err)
        self.assertEqual(out, "gpl-sources: 4 GPL-family packages, each with its source saved.\n")
        self.assertEqual(err, "")


# --- baked-images ----------------------------------------------------------


def layer_tar(files, gz=True):
    """A layer blob from {path: bytes}; a None value writes a whiteout entry."""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as t:
        for path, data in files.items():
            info = tarfile.TarInfo(path)
            data = data or b""
            info.size = len(data)
            t.addfile(info, io.BytesIO(data))
    raw = buf.getvalue()
    return gzip.compress(raw) if gz else raw


def headscale_files():
    out = {}
    for name in sorted(os.listdir(HEADSCALE_DPKG)):
        with open(os.path.join(HEADSCALE_DPKG, name), "rb") as f:
            out[f"var/lib/dpkg/status.d/{name}"] = f.read()
    return out


class BakedImages(Fixture):
    def image(self, layers, config_id=HEADSCALE_ID, name="img.tar", corrupt_layer=False):
        """Writes a docker-save tarball into images/; layers: list of {path: bytes}."""
        d = os.path.join(self.tmp, "images")
        os.makedirs(d, exist_ok=True)
        path = os.path.join(d, name)
        with tarfile.open(path, "w") as t:
            def add(member, data):
                info = tarfile.TarInfo(member)
                info.size = len(data)
                t.addfile(info, io.BytesIO(data))
            names = []
            for i, files in enumerate(layers):
                blob = layer_tar(files)
                if corrupt_layer:
                    blob = blob[: len(blob) // 2]
                n = f"blobs/sha256/{i:064x}"
                add(n, blob)
                names.append(n)
            cfg = f"blobs/sha256/{config_id}"
            add(cfg, json.dumps({"architecture": "amd64"}).encode())
            add("manifest.json", json.dumps([{"Config": cfg, "RepoTags": None, "Layers": names}]).encode())
        return d

    def ids(self, rows):
        d = os.path.join(self.tmp, "images")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "loaded-ids.tsv"), "w") as f:
            f.write("# ref\timage id — written by the rasputin-os build.\n")
            for ref, image_id in rows:
                f.write(f"{ref}\tsha256:{image_id}\n")
        return d

    def entries(self, data, raw=None):
        p = os.path.join(self.tmp, "entries.json")
        with open(p, "w") as f:
            f.write(raw if raw is not None else json.dumps(data))
        return p

    def headscale_entry(self, packages="debian", ref=HEADSCALE_REF):
        return [{"ref": ref, "packages": packages, "licence": "BSD-3-Clause"}]

    def test_tc_970_03_no_entry_or_stale_ref(self):
        # TC-970-03
        d = self.image([headscale_files()])
        self.ids([(HEADSCALE_REF, HEADSCALE_ID)])
        stale = "headscale/headscale:0.27.1@sha256:" + "a" * 64
        for what, data in {"no entry": [], "older ref": self.headscale_entry(ref=stale)}.items():
            with self.subTest(what):
                status, out, err = run("baked-images", "--images", d, "--entries", self.entries(data))
                self.assertEqual(status, 1, err)
                errs = errors(err)
                self.assertEqual(len(errs), 1, err)
                self.assertIn(HEADSCALE_REF, errs[0])
                self.assertIn("scripts/baked-image-sources.json", errs[0])
                self.assertEqual(out, "")

    def test_tc_970_10_inputs_missing_or_inconsistent(self):
        # TC-970-10 (a): a tarball whose config digest has no row.
        d = self.image([headscale_files()], config_id="b" * 64, name="stray.tar")
        self.ids([])
        status, out, err = run("baked-images", "--images", d, "--entries", self.entries([]))
        self.assertEqual(status, 1, err)
        self.assertIn("stray.tar", err)
        self.assertEqual(out, "")

        # (b) no loaded-ids.tsv
        os.remove(os.path.join(d, "loaded-ids.tsv"))
        status, out, err = run("baked-images", "--images", d, "--entries", self.entries([]))
        self.assertEqual(status, 2, err)
        self.assertIn("loaded-ids.tsv", err)

        # (c) no entries file; (d) entries not valid JSON
        self.ids([(HEADSCALE_REF, "b" * 64)])
        status, _, err = run("baked-images", "--images", d, "--entries", os.path.join(self.tmp, "nope.json"))
        self.assertEqual(status, 2, err)
        self.assertIn("is missing", err)
        status, _, err = run("baked-images", "--images", d, "--entries", self.entries(None, raw="[{"))
        self.assertEqual(status, 2, err)
        self.assertIn("not valid JSON", err)

    def test_tc_970_10_malformed_entries_and_ids(self):
        # TC-970-10 (the remaining refusals): a wrong shape or packages value
        # in the entries file, a malformed loaded-ids row, no images dir.
        d = self.image([headscale_files()])
        self.ids([(HEADSCALE_REF, HEADSCALE_ID)])
        for raw in ('{"ref": "x"}', '[{"ref": "x", "packages": "alpine", "licence": "MIT"}]', '[{"ref": "", "packages": "debian", "licence": "MIT"}]'):
            with self.subTest(raw):
                status, out, err = run("baked-images", "--images", d, "--entries", self.entries(None, raw=raw))
                self.assertEqual(status, 2, err)
                self.assertEqual(out, "")
        with open(os.path.join(d, "loaded-ids.tsv"), "w") as f:
            f.write(f"{HEADSCALE_REF} {HEADSCALE_ID}\n")
        status, _, err = run("baked-images", "--images", d, "--entries", self.entries(self.headscale_entry()))
        self.assertEqual(status, 2, err)
        self.assertIn("line 1", err)
        status, _, err = run("baked-images", "--images", os.path.join(self.tmp, "nodir"), "--entries", self.entries([]))
        self.assertEqual(status, 2, err)

    def test_tc_970_11_plan_from_headscale_status_d(self):
        # TC-970-11: the pinned image's own dpkg data, split across layers
        # as the image splits it, gives exactly its 8 source packages.
        files = headscale_files()
        layers = [{k: v} for k, v in files.items()]
        d = self.image(layers)
        self.ids([(HEADSCALE_REF, HEADSCALE_ID)])
        status, out, err = run("baked-images", "--images", d, "--entries", self.entries(self.headscale_entry()))
        self.assertEqual(status, 0, err)
        self.assertEqual(out, "".join(f"debian\t{s}\t{v}\n" for s, v in [
            ("base-files", "13.8+deb13u3"),
            ("glibc", "2.41-12+deb13u1"),
            ("libzstd", "1.5.7+dfsg-1"),
            ("media-types", "13.0.0"),
            ("netbase", "6.5"),
            ("openssl", "3.5.4-1~deb13u2"),
            ("tzdata", "2025b-4+deb13u1"),
            ("zlib", "1:1.3.dfsg+really1.3.1-1"),
        ]))
        self.assertIn("1 baked images, each with a reviewed source entry; 8 Debian source packages to fetch.", err)
        self.assertEqual(errors(err), [])

    def test_tc_970_11_plan_from_status_file(self):
        # TC-970-11: a classic var/lib/dpkg/status.
        status_text = "\n".join([
            "Package: foo-bin", "Status: install ok installed", "Source: foo (1.2-3)", "Version: 1.2-3+b1", "Description: x", " continued", "",
            "Package: gone", "Status: deinstall ok config-files", "Version: 9", "",
            "Package: bar-bin", "Status: install ok installed", "Source: bar", "Version: 4.5-6", "",
            "Package: plain", "Status: install ok installed", "Version: 7.0", "",
        ]).encode()
        d = self.image([{"var/lib/dpkg/status": status_text, "var/lib/dpkg/status-old": b"Package: old\nVersion: 1\n"}])
        self.ids([(HEADSCALE_REF, HEADSCALE_ID)])
        status, out, err = run("baked-images", "--images", d, "--entries", self.entries(self.headscale_entry()))
        self.assertEqual(status, 0, err)
        self.assertEqual(out, "debian\tbar\t4.5-6\ndebian\tfoo\t1.2-3\ndebian\tplain\t7.0\n")

    def test_tc_970_11_whiteouts_apply_across_layers(self):
        # TC-970-11: a later layer's whiteout removes an earlier entry.
        files = headscale_files()
        d = self.image([files, {"var/lib/dpkg/status.d/.wh.tzdata": None}])
        self.ids([(HEADSCALE_REF, HEADSCALE_ID)])
        status, out, err = run("baked-images", "--images", d, "--entries", self.entries(self.headscale_entry()))
        self.assertEqual(status, 0, err)
        self.assertNotIn("tzdata", out)
        self.assertEqual(len(out.splitlines()), 7)

        has_dpkg, _, src = gs.read_dpkg([list(files.items()), [("var/lib/dpkg/status.d/.wh..wh..opq", b"")]])
        self.assertFalse(has_dpkg)
        self.assertEqual(src, set())

    def test_tc_970_12_database_and_entry_must_agree(self):
        # TC-970-12
        self.ids([(HEADSCALE_REF, HEADSCALE_ID)])
        cases = [
            ("(a) debian entry, no dpkg database", [{"bin/headscale": b"\x7fELF"}], "debian", False, 1, "has no dpkg database"),
            ("(b) Alpine database", [{"lib/apk/db/installed": b"P:musl\nV:1.2\n"}], "none", False, 2, "Alpine"),
            ("(c) corrupt layer", [headscale_files()], "debian", True, 2, "not a readable docker save tarball"),
            ("(d) dpkg database, entry not debian", [headscale_files()], "none", False, 1, "carries a dpkg database"),
        ]
        for what, layers, packages, corrupt, want, text in cases:
            with self.subTest(what):
                d = self.image(layers, corrupt_layer=corrupt)
                status, out, err = run("baked-images", "--images", d, "--entries", self.entries(self.headscale_entry(packages)))
                self.assertEqual(status, want, err)
                self.assertIn(HEADSCALE_REF if want == 1 or "Alpine" in text else "img.tar", err)
                self.assertIn(text, err)
                self.assertEqual(out, "")

    def test_tc_970_12_none_entry_for_image_without_database(self):
        # TC-970-12: the agreeing case for an image with no package database.
        self.ids([(HEADSCALE_REF, HEADSCALE_ID)])
        d = self.image([{"bin/headscale": b"\x7fELF"}])
        status, out, err = run("baked-images", "--images", d, "--entries", self.entries(self.headscale_entry("none")))
        self.assertEqual(status, 0, err)
        self.assertEqual(out, "")

    def test_tc_970_12_not_a_single_image_save(self):
        # TC-970-12 (c): a tarball holding two images is refused.
        d = os.path.join(self.tmp, "images")
        os.makedirs(d, exist_ok=True)
        self.ids([(HEADSCALE_REF, HEADSCALE_ID)])
        with tarfile.open(os.path.join(d, "two.tar"), "w") as t:
            data = json.dumps([{"Config": "a", "Layers": []}, {"Config": "b", "Layers": []}]).encode()
            info = tarfile.TarInfo("manifest.json")
            info.size = len(data)
            t.addfile(info, io.BytesIO(data))
        status, _, err = run("baked-images", "--images", d, "--entries", self.entries(self.headscale_entry()))
        self.assertEqual(status, 2, err)
        self.assertIn("holds 2 images", err)


class Cli(unittest.TestCase):
    def test_tc_970_08_usage_is_a_refusal(self):
        # TC-970-08: no subcommand cannot run (status 2).
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(gs.main([]), 2)
            self.assertEqual(gs.main(["baked-images", "--images", "x"]), 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
