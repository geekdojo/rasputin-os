#!/usr/bin/env python3
#
# gpl-sources.py — the two checks that stand between a rasputin-os release and
# a GPL component shipped without its source (geekdojo/geekdojo-brain#970).
#
#   gpl-sources.py legal-info DIR
#   gpl-sources.py baked-images --images DIR --entries FILE
#
# legal-info DIR reads Buildroot's DIR/manifest.csv (the target packages; the
# host tools are not in the image) and refuses a release in which:
#
#   - a GPL-family package (licence matching \b(A|L)?GPL) has no saved source:
#     an empty SOURCE ARCHIVE, "not saved", or no non-empty file at
#     sources/<package>[-<version, sanitised as Buildroot does>]/<archive>;
#   - a package's licence is "unknown" or empty, so nobody can say whether its
#     source must ship. rasputin-api and rasputin-agent are the exception:
#     Geekdojo is their licensor, and the bundle README links their source at
#     the control-plane tag their .mk files pin;
#   - temurin-jre's saved archive is not Adoptium's JDK source tarball. It is
#     a prebuilt binary, and Buildroot saves whatever TEMURIN_JRE_SOURCE names
#     unless TEMURIN_JRE_ACTUAL_SOURCE_TARBALL points at the source
#     (pkg-generic.mk, "_ACTUAL_SOURCE_TARBALL"). With no temurin-jre row this
#     rule does nothing.
#
# baked-images --images DIR --entries FILE checks the container images that
# scripts/bake-mesh-images.sh saved into DIR, against the reviewed record in
# FILE (scripts/baked-image-sources.json):
#
#   - every DIR/*.tar matches a DIR/loaded-ids.tsv row by its config digest;
#   - every row's exact ref has an entry in FILE;
#   - the image's package database agrees with the entry's "packages" field:
#     "debian" for an image with a dpkg database, "none" for one without;
#   - an image with an Alpine database (lib/apk/db/installed) cannot be read
#     yet, so it fails closed.
#
# On a pass it prints the fetch plan on stdout, one "debian<TAB>source<TAB>
# version" line per Debian source package across all images, sorted, for
# scripts/source-bundle.sh fetch.
#
# Exit status (as scripts/release-manifest-gate.sh):
#   0  pass; one count line (on stdout for legal-info, on stderr for
#      baked-images, whose stdout is the plan)
#   1  a defect; one "::error::gpl-sources: <sentence>" line per defect on
#      stderr, every defect reported, and no count line or plan
#   2  the check cannot run: a missing or unreadable input, or one that does
#      not parse; one ::error:: sentence
#
# Standard library only. No network, no clock, no environment: every input is
# a path argument. main() reads the files and hands parsed data to the pure
# functions below. test/gpl-sources-test.py covers every status.

import argparse
import csv
import io
import json
import os
import posixpath
import re
import sys
import tarfile

GPL_RE = re.compile(r"\b(A|L)?GPL")
# Packages Geekdojo licenses; their source is linked, not saved by Buildroot.
OWN_PACKAGES = frozenset({"rasputin-api", "rasputin-agent"})
JRE_PACKAGE = "temurin-jre"
JRE_SOURCE_RE = re.compile(r"OpenJDK\d+U-jdk-sources_[0-9.]+_[0-9]+\.tar\.gz")
REQUIRED_COLUMNS = ("PACKAGE", "VERSION", "LICENSE", "SOURCE ARCHIVE")
ENTRIES_HINT = "scripts/baked-image-sources.json"
PACKAGE_KINDS = ("debian", "none")

DPKG_STATUS = "var/lib/dpkg/status"
DPKG_STATUS_D = "var/lib/dpkg/status.d/"
APK_INSTALLED = "lib/apk/db/installed"


class Refusal(Exception):
    """The check cannot run (exit 2). The message is one sentence."""


# --- legal-info ------------------------------------------------------------


def classify(licence):
    """'unknown' (no decision possible), 'gpl' (source must ship) or 'other'."""
    text = (licence or "").strip()
    if text == "" or text.lower() == "unknown":
        return "unknown"
    if GPL_RE.search(text):
        return "gpl"
    return "other"


def sanitise(version):
    """Buildroot's `sanitize` (support/misc/utils.mk): '/', ':' and ' ' -> '_'."""
    return version.strip().replace("/", "_").replace(":", "_").replace(" ", "_")


def source_path(package, version, archive):
    """Where `make legal-info` saves a target package's source archive."""
    v = sanitise(version)
    d = f"{package}-{v}" if v else package
    return posixpath.join("sources", d, archive)


def check_legal_info(rows, size_of):
    """Returns (gpl_count, defects). size_of(relpath) is the saved file's size
    in bytes, or None when there is no such file."""
    defects = []
    gpl = 0
    for row in rows:
        pkg = row["PACKAGE"].strip()
        version = row["VERSION"]
        archive = row["SOURCE ARCHIVE"].strip()
        kind = classify(row["LICENSE"])
        if kind == "unknown" and pkg not in OWN_PACKAGES:
            defects.append(
                f"Package {pkg} has licence '{row['LICENSE'].strip() or '(empty)'}' in manifest.csv, "
                f"so nobody can tell whether its source must ship; set its _LICENSE in the package's .mk"
            )
        if pkg == JRE_PACKAGE and not JRE_SOURCE_RE.fullmatch(archive):
            defects.append(
                f"Package {pkg} saves '{archive or '(nothing)'}', which is not Adoptium's JDK source tarball; "
                f"set TEMURIN_JRE_ACTUAL_SOURCE_TARBALL and TEMURIN_JRE_ACTUAL_SOURCE_SITE in "
                f"package/temurin-jre/temurin-jre.mk to the OpenJDK<N>U-jdk-sources tarball and add its hash"
            )
        if kind != "gpl":
            continue
        gpl += 1
        if archive == "" or archive == "not saved":
            defects.append(
                f"Package {pkg} is {row['LICENSE'].strip()} but Buildroot saved no source for it "
                f"(SOURCE ARCHIVE is '{archive or '(empty)'}'); give it a source tarball and keep _REDISTRIBUTE at YES"
            )
            continue
        rel = source_path(pkg, version, archive)
        size = size_of(rel)
        if size is None:
            defects.append(
                f"Package {pkg} is {row['LICENSE'].strip()} but its source {rel} is not in legal-info; "
                f"check that the package downloads and that _REDISTRIBUTE is not NO"
            )
        elif size == 0:
            defects.append(f"Package {pkg} is {row['LICENSE'].strip()} but its source {rel} is empty; delete it from dl/ and rebuild legal-info")
    return gpl, defects


def read_manifest_csv(text):
    """Parses manifest.csv text into row dicts; Refusal when it is not one."""
    try:
        reader = csv.DictReader(io.StringIO(text))
        header = reader.fieldnames or []
        missing = [c for c in REQUIRED_COLUMNS if c not in header]
        if missing:
            raise Refusal(f"The manifest.csv has no {', '.join(missing)} column, so it is not a Buildroot legal-info manifest")
        rows = []
        for row in reader:
            if any(row.get(c) is None for c in REQUIRED_COLUMNS):
                raise Refusal(f"The manifest.csv line {reader.line_num} has fewer columns than its header")
            rows.append(row)
        return rows
    except csv.Error as e:
        raise Refusal(f"The manifest.csv does not parse as CSV ({e})") from e


def run_legal_info(directory):
    if not os.path.isdir(directory):
        raise Refusal(f"The legal-info directory {directory} does not exist")
    path = os.path.join(directory, "manifest.csv")
    if not os.path.isfile(path):
        raise Refusal(f"The file {path} is missing, so there is nothing to check")
    try:
        with open(path, encoding="utf-8", newline="") as f:
            text = f.read()
    except (OSError, UnicodeDecodeError) as e:
        raise Refusal(f"Cannot read {path} ({e})") from e
    rows = read_manifest_csv(text)

    def size_of(rel):
        p = os.path.join(directory, rel)
        return os.path.getsize(p) if os.path.isfile(p) else None

    return check_legal_info(rows, size_of)


# --- baked-images ----------------------------------------------------------


def parse_stanzas(text):
    """Debian control stanzas -> list of {field: value} (first line only)."""
    stanzas, cur = [], {}
    for line in text.splitlines():
        if not line.strip():
            if cur:
                stanzas.append(cur)
                cur = {}
            continue
        if line[0] in " \t":
            continue  # a continuation line; no field read here spans lines
        key, sep, value = line.partition(":")
        if sep:
            cur[key.strip()] = value.strip()
    if cur:
        stanzas.append(cur)
    return stanzas


def source_of(stanza):
    """(source package, source version) of an installed binary package."""
    pkg, ver = stanza.get("Package", ""), stanza.get("Version", "")
    src = stanza.get("Source", "")
    if not src:
        return pkg, ver
    m = re.fullmatch(r"(\S+)\s*\(([^)]+)\)", src)
    if m:
        return m.group(1), m.group(2).strip()
    return src, ver


def read_dpkg(layers):
    """layers: the image's layers in order, each a list of (path, bytes).
    Applies whiteouts across layers and returns (has_dpkg, has_apk, sources),
    sources being a set of (source, version) of the installed packages."""
    files = {}
    for layer in layers:
        for path, data in layer:
            path = path[2:] if path.startswith("./") else path.lstrip("/")
            d, base = posixpath.split(path)
            if base == ".wh..wh..opq":
                prefix = d + "/"
                for p in [p for p in files if p.startswith(prefix)]:
                    del files[p]
            elif base.startswith(".wh."):
                gone = posixpath.join(d, base[len(".wh."):])
                for p in [p for p in files if p == gone or p.startswith(gone + "/")]:
                    del files[p]
            else:
                files[path] = data
    has_apk = APK_INSTALLED in files
    sources = set()
    has_dpkg = False
    for path, data in files.items():
        if path == DPKG_STATUS:
            only_installed = True
        elif path.startswith(DPKG_STATUS_D) and "/" not in path[len(DPKG_STATUS_D):]:
            if path.endswith(".md5sums"):
                continue
            only_installed = False  # distroless status.d stanzas carry no Status
        else:
            continue
        has_dpkg = True
        for st in parse_stanzas(data.decode("utf-8", "replace")):
            status = st.get("Status")
            if only_installed or status is not None:
                if status != "install ok installed":
                    continue
            src, ver = source_of(st)
            if src and ver:
                sources.add((src, ver))
    return has_dpkg, has_apk, sources


def plan(entries, ids, images):
    """entries: [{ref, packages, licence}]; ids: [(ref, image id)];
    images: {tarball name: (image id, has_dpkg, has_apk, sources)}.
    Returns (plan lines, defects); raises Refusal for an Alpine image."""
    defects = []
    by_ref = {e["ref"]: e for e in entries}
    ref_by_id = {}
    for ref, image_id in ids:
        ref_by_id[image_id] = ref
        if ref not in by_ref:
            defects.append(f"The baked image {ref} has no entry in {ENTRIES_HINT}; add one with its ref, packages and licence after reviewing the image")
    lines = set()
    for name in sorted(images):
        image_id, has_dpkg, has_apk, sources = images[name]
        ref = ref_by_id.get(image_id)
        if ref is None:
            defects.append(f"The tarball {name} has config digest {image_id}, which no loaded-ids.tsv row names, so nothing says which ref it is")
            continue
        if has_apk:
            raise Refusal(f"The baked image {ref} carries an Alpine package database, which this check cannot read yet, so its sources cannot be collected")
        entry = by_ref.get(ref)
        if entry is None:
            continue  # reported above
        want = entry["packages"]
        if has_dpkg and want != "debian":
            defects.append(f"The baked image {ref} carries a dpkg database but {ENTRIES_HINT} says packages '{want}'; set it to 'debian'")
        elif not has_dpkg and want == "debian":
            defects.append(f"The baked image {ref} has no dpkg database but {ENTRIES_HINT} says packages 'debian'; check the image and the entry")
        elif has_dpkg:
            lines.update(sources)
    return [f"debian\t{s}\t{v}" for s, v in sorted(lines)], defects


def read_entries(path):
    if not os.path.isfile(path):
        raise Refusal(f"The entries file {path} is missing")
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, UnicodeDecodeError) as e:
        raise Refusal(f"Cannot read {path} ({e})") from e
    except json.JSONDecodeError as e:
        raise Refusal(f"The entries file {path} is not valid JSON ({e.msg} at line {e.lineno})") from e
    if not isinstance(data, list):
        raise Refusal(f"The entries file {path} is not a list of entries")
    for i, e in enumerate(data):
        ok = (
            isinstance(e, dict)
            and all(isinstance(e.get(k), str) and e.get(k) for k in ("ref", "packages", "licence"))
            and e["packages"] in PACKAGE_KINDS
        )
        if not ok:
            raise Refusal(f"The entries file {path} entry {i} needs a non-empty ref and licence and packages set to one of {', '.join(PACKAGE_KINDS)}")
    return data


def read_ids(path):
    if not os.path.isfile(path):
        raise Refusal(f"The file {path} is missing, so the baked tarballs cannot be named")
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except (OSError, UnicodeDecodeError) as e:
        raise Refusal(f"Cannot read {path} ({e})") from e
    ids = []
    for n, line in enumerate(text.splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) != 2 or not parts[0] or not parts[1].startswith("sha256:"):
            raise Refusal(f"The file {path} line {n} is not '<ref><TAB>sha256:<id>'")
        ids.append((parts[0], parts[1]))
    return ids


def read_image(path):
    """(image id, layers) of a `docker save` tarball; Refusal when unreadable."""
    name = os.path.basename(path)
    try:
        with tarfile.open(path) as t:
            manifest = json.load(t.extractfile("manifest.json"))
            if not isinstance(manifest, list) or len(manifest) != 1:
                raise Refusal(f"The tarball {name} holds {len(manifest) if isinstance(manifest, list) else 'no'} images; bake-mesh-images.sh saves exactly one")
            cfg = manifest[0]["Config"]
            layers = []
            for layer in manifest[0]["Layers"]:
                with tarfile.open(fileobj=t.extractfile(layer), mode="r:*") as lt:
                    members = []
                    # Whiteouts (.wh.<name>, .wh..wh..opq) are empty regular
                    # files in a layer tar, so they arrive here too.
                    for m in lt.getmembers():
                        if m.isfile():
                            members.append((m.name, lt.extractfile(m).read()))
                    layers.append(members)
    except Refusal:
        raise
    except (OSError, tarfile.TarError, KeyError, TypeError, ValueError, EOFError) as e:
        raise Refusal(f"The tarball {name} is not a readable docker save tarball ({type(e).__name__}: {e})") from e
    return "sha256:" + posixpath.basename(cfg), layers


def run_baked_images(images_dir, entries_path):
    if not os.path.isdir(images_dir):
        raise Refusal(f"The images directory {images_dir} does not exist")
    ids = read_ids(os.path.join(images_dir, "loaded-ids.tsv"))
    entries = read_entries(entries_path)
    images = {}
    for name in sorted(os.listdir(images_dir)):
        if not name.endswith(".tar"):
            continue
        image_id, layers = read_image(os.path.join(images_dir, name))
        images[name] = (image_id, *read_dpkg(layers))
    lines, defects = plan(entries, ids, images)
    return len(images), lines, defects


# --- composition root ------------------------------------------------------


def error(msg):
    print(f"::error::gpl-sources: {msg}.", file=sys.stderr)


def main(argv):
    ap = argparse.ArgumentParser(prog="gpl-sources.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    li = sub.add_parser("legal-info")
    li.add_argument("dir")
    bi = sub.add_parser("baked-images")
    bi.add_argument("--images", required=True)
    bi.add_argument("--entries", required=True)
    try:
        args = ap.parse_args(argv)
    except SystemExit as e:
        return 2 if e.code else 0
    try:
        if args.cmd == "legal-info":
            count, defects = run_legal_info(args.dir)
        else:
            count, lines, defects = run_baked_images(args.images, args.entries)
    except Refusal as r:
        error(str(r))
        return 2
    for d in defects:
        error(d)
    if defects:
        return 1
    if args.cmd == "legal-info":
        print(f"gpl-sources: {count} GPL-family packages, each with its source saved.")
    else:
        for line in lines:
            print(line)
        print(f"gpl-sources: {count} baked images, each with a reviewed source entry; {len(lines)} Debian source packages to fetch.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
