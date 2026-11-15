#!/bin/sh
# Tests for the identity database's packages (geekdojo/geekdojo-brain#972):
# package/rasputin-postgresql, our own copy of Buildroot's postgresql package,
# and package/rasputin-identity-db, the wrapper that declares the static users.
#
# What is pinned here, because each can go wrong without anything noticing
# until a release build, or never:
#
#   * the major tripwire. PostgreSQL 18 cannot be replaced by 19 with a version
#     bump: a new major cannot open the data an older one wrote. The copy's .mk
#     refuses any VERSION whose major is not RASPUTIN_POSTGRESQL_MAJOR, and
#     MAJOR is 18. Minor bumps (18.10 included) must still read cleanly;
#   * that a Buildroot bump cannot reach the copy: Buildroot's POSTGRESQL_*
#     values do not leak into ours, and the files the copy installs come from
#     its own directory, never Buildroot's package/postgresql/;
#   * that the hash file covers the tarball the .mk asks for, and that every
#     @...@ placeholder in the copied pg_config has a sed line filling it;
#   * the wrapper's two static users.
#
# The .mk files are evaluated with REAL GNU make, through test/lib/mk-var.sh,
# so the values compared are the ones Buildroot would see. No make is a
# failure, not a skip.
#
# What this does NOT prove: that Buildroot selects the packages, the CPE the
# security watch sees, or what mkusers makes of the users. The Buildroot-backed
# test/identity-db-buildroot-test.sh covers those, and test/boot-smoke.sh the
# built image.
#
# Run:  sh test/identity-db-package-test.sh
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
PG="$ROOT/package/rasputin-postgresql"
MK="$PG/rasputin-postgresql.mk"
HASH="$PG/rasputin-postgresql.hash"
PGCONFIG="$PG/pg_config"
WRAP_MK="$ROOT/package/rasputin-identity-db/rasputin-identity-db.mk"
. "$ROOT/test/lib/mk-var.sh"
. "$ROOT/test/lib/checks.sh"

for f in "$MK" "$HASH" "$PGCONFIG" "$WRAP_MK"; do
	[ -f "$f" ] || { echo "FAIL — missing: $f"; exit 1; }
done
case "$(make --version 2>/dev/null)" in
	"GNU Make"*) ;;
	*) echo "FAIL — GNU make is not on PATH. This suite evaluates the package .mk files with it and never skips."; exit 1 ;;
esac

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# The major this release carries. A literal on purpose: the test must not read
# it from the file it is checking.
WANT_MAJOR=18

eq() { yes_if [ "$1" = "$2" ]; }

# with_version FILE VERSION — a scratch copy of the .mk with VERSION replaced.
with_version() {
	sed "s/^RASPUTIN_POSTGRESQL_VERSION = .*/RASPUTIN_POSTGRESQL_VERSION = $2/" "$MK" > "$1"
}

# guard_refuses FILE VERSION — prints 0 when reading FILE fails the way the
# guard fails it: non-zero exit, nothing on stdout, and the guard's sentence
# for VERSION on stderr. Prints 1 and writes what it saw to $TMP/why otherwise.
guard_refuses() {
	_major=${2%%.*}
	_want="The carried PostgreSQL is $2, major $_major, but this release carries major $WANT_MAJOR. A new major cannot open the data an older one wrote, so a major change is the planned upgrade item in geekdojo-brain lifecycle.md §1.5, never a bump.  Stop."
	_out=$(mk_var "$1" RASPUTIN_POSTGRESQL_VERSION 2> "$TMP/err"); _rc=$?
	_err=$(cat "$TMP/err")
	if [ "$_rc" -ne 0 ] && [ -z "$_out" ] && contains "$_want" "$_err"; then
		echo 0
	else
		printf 'exit %s, stdout "%s", stderr: %s' "$_rc" "$_out" "$_err" > "$TMP/why"
		echo 1
	fi
}

V=$(mk_var "$MK" RASPUTIN_POSTGRESQL_VERSION) || { echo "FAIL — Could not read the pin, so nothing below has anything to compare against."; exit 1; }
echo "rasputin-postgresql.mk pins $V"

echo "── the major tripwire (TC-972-03)"
# TC-972-03: the real file carries major 18, as a value and as the version's
# first field.
check "TC-972-03 RASPUTIN_POSTGRESQL_MAJOR is $WANT_MAJOR" \
	"$(eq "$(mk_var "$MK" RASPUTIN_POSTGRESQL_MAJOR)" "$WANT_MAJOR")" \
	"read: $(mk_var "$MK" RASPUTIN_POSTGRESQL_MAJOR 2>&1)"
check "TC-972-03 the pinned version's major is $WANT_MAJOR" "$(eq "${V%%.*}" "$WANT_MAJOR")" "pin: $V"
# TC-972-03: a minor bump is never blocked, two-digit minors included.
for v in 18.7 18.10; do
	with_version "$TMP/minor.mk" "$v"
	_out=$(mk_var "$TMP/minor.mk" RASPUTIN_POSTGRESQL_VERSION 2> "$TMP/err"); _rc=$?
	check "TC-972-03 VERSION $v reads cleanly" "$(eq "$_rc:$_out" "0:$v")" \
		"exit $_rc, stdout '$_out', stderr: $(cat "$TMP/err")"
done
# TC-972-03: any other major, a major that merely starts with 18, and an empty
# version are each refused with the guard's sentence.
for v in 19.0 17.9 180.1 ""; do
	with_version "$TMP/major.mk" "$v"
	r=$(guard_refuses "$TMP/major.mk" "$v")
	check "TC-972-03 VERSION '$v' is refused by the guard" "$r" "$(cat "$TMP/why" 2>/dev/null)"
done
# TC-972-03: with the guard lines deleted, the same check no longer sees a
# refusal, so a copy that loses its guard fails this suite.
with_version "$TMP/noguard.mk" 19.0
awk '/^ifneq \(\$\(firstword/ { skip = 1 } !skip { print } skip && /^endif/ { skip = 0 }' \
	"$TMP/noguard.mk" > "$TMP/noguard2.mk"
check "TC-972-03 the guard-less copy differs only by the guard" \
	"$(eq "$(diff "$TMP/noguard.mk" "$TMP/noguard2.mk" | grep -c '^<')" 3)" \
	"$(diff "$TMP/noguard.mk" "$TMP/noguard2.mk")"
r=$(guard_refuses "$TMP/noguard2.mk" 19.0)
check "TC-972-03 a copy without the guard reads 19.0 and is caught" "$(eq "$r" 1)" \
	"guard_refuses still saw a refusal without the guard"

echo "── a Buildroot bump cannot reach the copy (TC-972-04)"
# TC-972-04: Buildroot's own variables, forced on the command line the way a
# bumped Buildroot would set them, leave ours as they were.
for var in VERSION SOURCE SITE; do
	plain=$(mk_var "$MK" "RASPUTIN_POSTGRESQL_$var")
	forced=$(mk_var "$MK" "RASPUTIN_POSTGRESQL_$var" POSTGRESQL_VERSION=19.1 \
		POSTGRESQL_SOURCE=postgresql-19.1.tar.bz2 POSTGRESQL_SITE=https://example.invalid/v19.1)
	check "TC-972-04 RASPUTIN_POSTGRESQL_$var is unchanged by Buildroot's POSTGRESQL_*" \
		"$(yes_if eval '[ -n "$plain" ] && [ "$plain" = "$forced" ]')" "plain '$plain', forced '$forced'"
done
# Comments are left out: the header names Buildroot's directory as the source.
check "TC-972-04 the .mk's make text names no package/postgresql/ path" \
	"$(eq "$(grep -v '^[[:space:]]*#' "$MK" | grep -c 'package/postgresql/')" 0)" \
	"$(grep -v '^[[:space:]]*#' "$MK" | grep -n 'package/postgresql/')"
for f in pg_config S50postgresql postgresql.service; do
	check "TC-972-04 $f is installed from \$(RASPUTIN_POSTGRESQL_PKGDIR)" \
		"$(yes_if grep -qE "\\\$\(INSTALL\) .*\\\$\(RASPUTIN_POSTGRESQL_PKGDIR\)/$f " "$MK")" \
		"$(grep -n "$f" "$MK")"
	check "TC-972-04 $f is in the package directory" "$(yes_if test -f "$PG/$f")" "missing: $PG/$f"
done
# TC-972-04: the hash file covers the tarball the .mk asks for, exactly once.
SRC=$(mk_var "$MK" RASPUTIN_POSTGRESQL_SOURCE)
check "TC-972-04 RASPUTIN_POSTGRESQL_SOURCE is postgresql-$V.tar.bz2" "$(eq "$SRC" "postgresql-$V.tar.bz2")" "read: $SRC"
check "TC-972-04 rasputin-postgresql.hash has one sha256 line for postgresql-$V.tar.bz2" \
	"$(eq "$(grep -cE "^sha256[[:space:]]+[0-9a-f]{64}[[:space:]]+postgresql-$(printf '%s' "$V" | sed 's/\./\\./g')\.tar\.bz2\$" "$HASH")" 1)" \
	"$(cat "$HASH")"

# F-972-03: the copy renames make identifiers, never pg_config's placeholders.
# Every @NAME@ in pg_config must have a sed line substituting exactly that
# token, or the staging pg_config ships with it unfilled.
for tok in $(grep -oE '@[A-Z_]+@' "$PGCONFIG" | sort -u); do
	check "TC-972-04 pg_config placeholder $tok has a sed line in the .mk" \
		"$(yes_if grep -qF "\"s|$tok|" "$MK")" "$(grep -n 'SED' "$MK")"
done

echo "── the wrapper's static users (TC-972-06)"
USERS=$(mk_var "$WRAP_MK" RASPUTIN_IDENTITY_DB_USERS)
# The lines carry a literal * (no password); awk, not `set --`, so it is never
# globbed.
check "TC-972-06 RASPUTIN_IDENTITY_DB_USERS has exactly two lines" \
	"$(eq "$(printf '%s\n' "$USERS" | grep -c .)" 2)" "$USERS"
user_row() { printf '%s\n' "$USERS" | awk -v u="$1" '$1 == u { print $2, $3, $4, $5 }'; }
check "TC-972-06 keycloak: uid 991, group keycloak, gid 991, password *" \
	"$(eq "$(user_row keycloak)" "991 keycloak 991 *")" "row: $(user_row keycloak)"
check "TC-972-06 postgres: uid 992, group postgres, gid 992, password *" \
	"$(eq "$(user_row postgres)" "992 postgres 992 *")" "row: $(user_row postgres)"

echo
if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; exit 1; fi
echo "all identity database package checks passed"
