#!/bin/sh
# Buildroot-backed tests for the identity database's packages
# (geekdojo/geekdojo-brain#972), against the pinned Buildroot checkout and
# both real defconfigs. test/identity-db-package-test.sh reads the .mk files
# on their own; this runs them where they live, inside Buildroot's kconfig and
# make, because what goes wrong here only shows there:
#
#   * a `depends on` the defconfig does not meet makes kconfig drop the
#     wrapper without a word, and the image ships with no database;
#   * the TLS and notify build options come from OpenSSL and systemd being on
#     in the same .config, not from anything in the .mk alone;
#   * the security watch (make pkg-stats) matches by the CPE Buildroot
#     computes, and without CPE_ID_PRODUCT the product would be the package's
#     own name, which matches no advisory;
#   * the static users meet every other package's users in Buildroot's own
#     mkusers, and 991 and 992 must be free and must move nobody else;
#   * the major guard must stop Buildroot itself, not only a bare make.
#
# Every Buildroot run uses its own output directory under a scratch dir, and
# the negative controls use scratch copies of the external tree or of a
# defconfig, never the real ones.
#
# What this does NOT prove: that the package builds, that the binary runs, or
# that the mask survives the real preset-all. test/boot-smoke.sh checks those
# on the built image.
#
# Needs: the pinned Buildroot checkout (./scripts/init-buildroot.sh), GNU make,
# a host C compiler for Buildroot's kconfig, and bash 4+ and GNU sed for
# Buildroot's own mkusers. All are present on the CI runner. A missing one is a
# failure, never a skip.
#
# Run:  sh test/identity-db-buildroot-test.sh
set -u

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
BR="$ROOT/buildroot"
MKUSERS="$BR/support/scripts/mkusers"
PG_MK="$ROOT/package/rasputin-postgresql/rasputin-postgresql.mk"
. "$ROOT/test/lib/mk-var.sh"
. "$ROOT/test/lib/checks.sh"

if [ ! -f "$BR/Makefile" ] || [ ! -f "$MKUSERS" ]; then
	echo "FAIL: the pinned Buildroot checkout is not at $BR. This test runs Buildroot's own kconfig, make and mkusers. Run ./scripts/init-buildroot.sh first." >&2
	exit 1
fi
if ! bash -c 'type -t mapfile >/dev/null' 2>/dev/null; then
	echo "FAIL: Buildroot's mkusers needs bash 4 or later (it uses mapfile). Install a modern bash or run this on Linux or CI." >&2
	exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

V=$(mk_var "$PG_MK" RASPUTIN_POSTGRESQL_VERSION) || { echo "FAIL: Could not read the carried PostgreSQL version, so nothing below has anything to compare against." >&2; exit 1; }
echo "rasputin-postgresql.mk pins $V"

# br EXTERNAL OUT ARGS... — Buildroot's make for one output directory.
br() {
	_ext="$1"; _out="$2"; shift 2
	make -s --no-print-directory -C "$BR" BR2_EXTERNAL="$_ext" O="$_out" "$@"
}

# value_of OUT EXTERNAL VAR — one variable's value through printvars.
value_of() {
	br "$2" "$1" printvars VARS="$3" 2> "$TMP/printvars.err" | sed -n "s/^$3=//p"
}

# scratch_tree NAME — a copy of the parts of the external tree Buildroot reads
# to configure and evaluate it. Prints its path.
scratch_tree() {
	_t="$TMP/tree-$1"
	mkdir -p "$_t"
	cp -R "$ROOT/external.desc" "$ROOT/external.mk" "$ROOT/Config.in" \
		"$ROOT/package" "$ROOT/configs" "$ROOT/board" "$_t/"
	printf '%s\n' "$_t"
}

# check_selection SKU OUT EXTERNAL — TC-972-07 for one configured output dir.
check_selection() {
	_cfg="$2/.config"
	for sym in BR2_PACKAGE_RASPUTIN_IDENTITY_DB BR2_PACKAGE_RASPUTIN_POSTGRESQL \
		BR2_PACKAGE_OPENSSL BR2_PACKAGE_SYSTEMD BR2_INIT_SYSTEMD; do
		check "TC-972-07 $1: $sym=y" "$(yes_if grep -qx "$sym=y" "$_cfg")" \
			"$sym is not y in the $1 .config: $(grep -E "^# $sym is not set|^$sym=" "$_cfg")"
	done
	check "TC-972-07 $1: Buildroot's own BR2_PACKAGE_POSTGRESQL is not set" \
		"$(yes_if grep -qx '# BR2_PACKAGE_POSTGRESQL is not set' "$_cfg")" \
		"$(grep 'BR2_PACKAGE_POSTGRESQL[ =]' "$_cfg")"
	_opts=$(value_of "$2" "$3" RASPUTIN_POSTGRESQL_CONF_OPTS)
	for opt in -Dssl=openssl -Dsystemd=enabled; do
		check "TC-972-07 $1: RASPUTIN_POSTGRESQL_CONF_OPTS has $opt" \
			"$(yes_if contains " $opt " " $_opts ")" "read: $_opts $(cat "$TMP/printvars.err")"
	done
}

# check_cpe SKU OUT EXTERNAL — TC-972-08: the CPE pkg-stats matches by. The
# update field is Buildroot's default '-' (package/pkg-generic.mk).
check_cpe() {
	_cpe=$(value_of "$2" "$3" RASPUTIN_POSTGRESQL_CPE_ID)
	_want="cpe:2.3:a:postgresql:postgresql:$V:-:*:*:*:*:*:*"
	check "TC-972-08 $1: RASPUTIN_POSTGRESQL_CPE_ID is $_want" "$(yes_if [ "$_cpe" = "$_want" ])" \
		"read: $_cpe $(cat "$TMP/printvars.err")"
}

# users_table OUT FILE — the package users table fs/common.mk feeds mkusers:
# PACKAGES_USERS, one user per line. printvars prints it multi-line, so only
# the first line carries the "PACKAGES_USERS=" prefix.
users_table() {
	br "$ROOT" "$1" printvars VARS=PACKAGES_USERS 2> "$TMP/printvars.err" \
		| sed '1s/^PACKAGES_USERS=//' > "$2"
}

# run_mkusers TABLE TARGET OUT — Buildroot's own mkusers over a target dir
# seeded with the pinned skeleton's account files, the way fs/common.mk runs
# it: BR2_CONFIG in the environment, stdout (the fakeroot script) discarded.
run_mkusers() {
	rm -rf "$2"
	mkdir -p "$2/etc"
	for f in passwd group shadow; do cp "$BR/system/skeleton/etc/$f" "$2/etc/$f"; done
	BR2_CONFIG="$3/.config" bash "$MKUSERS" "$1" "$2" 2>&1 > /dev/null
}

# rows FILE — name:id[:gid] of every account, sorted. passwd gives
# name:uid:gid, group name:gid.
passwd_rows() { awk -F: '{ print $1 ":" $3 ":" $4 }' "$1" | sort; }
group_rows() { awk -F: '{ print $1 ":" $3 }' "$1" | sort; }

# check_users SKU OUT — TC-972-01. "Before" is the same .config with the
# wrapper turned off; "after" is the real one. The copy is turned off with it:
# kconfig keeps a selected symbol at y as a user value once its select goes,
# so turning off the wrapper alone would leave the copy's postgres user in
# "before".
check_users() {
	_off="$TMP/out-$1-off"
	mkdir -p "$_off"
	sed -e 's/^BR2_PACKAGE_RASPUTIN_IDENTITY_DB=y$/# BR2_PACKAGE_RASPUTIN_IDENTITY_DB is not set/' \
		-e 's/^BR2_PACKAGE_RASPUTIN_POSTGRESQL=y$/# BR2_PACKAGE_RASPUTIN_POSTGRESQL is not set/' \
		"$2/.config" > "$_off/.config"
	br "$ROOT" "$_off" olddefconfig > /dev/null 2>&1
	for sym in BR2_PACKAGE_RASPUTIN_IDENTITY_DB BR2_PACKAGE_RASPUTIN_POSTGRESQL; do
		check "TC-972-01 $1: the before .config has $sym off" \
			"$(yes_if grep -qx "# $sym is not set" "$_off/.config")" \
			"$(grep "$sym" "$_off/.config")"
	done
	users_table "$2" "$TMP/users-after"
	users_table "$_off" "$TMP/users-before"
	_err=$(run_mkusers "$TMP/users-before" "$TMP/before" "$_off")
	check "TC-972-01 $1: mkusers runs over the wrapper-off users" "$(yes_if [ -z "$_err" ])" "$_err"
	_err=$(run_mkusers "$TMP/users-after" "$TMP/after" "$2")
	check "TC-972-01 $1: mkusers runs over the real users" "$(yes_if [ -z "$_err" ])" "$_err"
	passwd_rows "$TMP/before/etc/passwd" > "$TMP/pw-before"
	passwd_rows "$TMP/after/etc/passwd" > "$TMP/pw-after"
	group_rows "$TMP/before/etc/group" > "$TMP/gr-before"
	group_rows "$TMP/after/etc/group" > "$TMP/gr-after"

	_taken=$(awk -F: '$2 == 991 || $2 == 992 || $3 == 991 || $3 == 992' "$TMP/pw-before"; \
		awk -F: '$2 == 991 || $2 == 992' "$TMP/gr-before")
	check "TC-972-01 $1: no user or group used 991 or 992 before" "$(yes_if [ -z "$_taken" ])" "$_taken"
	_moved=$(comm -23 "$TMP/pw-before" "$TMP/pw-after"; comm -23 "$TMP/gr-before" "$TMP/gr-after")
	check "TC-972-01 $1: every user and group keeps its number" "$(yes_if [ -z "$_moved" ])" \
		"changed or gone: $_moved"
	_added=$(comm -13 "$TMP/pw-before" "$TMP/pw-after" | tr '\n' ' ')
	check "TC-972-01 $1: the users added are exactly keycloak 991:991 and postgres 992:992" \
		"$(yes_if [ "$_added" = "keycloak:991:991 postgres:992:992 " ])" "added: $_added"
	_added=$(comm -13 "$TMP/gr-before" "$TMP/gr-after" | tr '\n' ' ')
	check "TC-972-01 $1: the groups added are exactly keycloak 991 and postgres 992" \
		"$(yes_if [ "$_added" = "keycloak:991 postgres:992 " ])" "added: $_added"
}

for sku in n100 rpi; do
	echo "── $sku"
	out="$TMP/out-$sku"
	if ! br "$ROOT" "$out" "rasputin_${sku}_defconfig" > "$TMP/defconfig.log" 2>&1; then
		check "$sku: rasputin_${sku}_defconfig configures" 1 "$(tail -20 "$TMP/defconfig.log")"
		continue
	fi
	check_selection "$sku" "$out" "$ROOT"
	check_cpe "$sku" "$out" "$ROOT"
	check_users "$sku" "$out"
done

echo "── negative controls"
# TC-972-07: a defconfig without the wrapper line fails the selection check,
# naming the symbol and the SKU.
grep -v '^BR2_PACKAGE_RASPUTIN_IDENTITY_DB=y$' "$ROOT/configs/rasputin_n100_defconfig" > "$TMP/no-wrapper_defconfig"
br "$ROOT" "$TMP/out-no-wrapper" defconfig BR2_DEFCONFIG="$TMP/no-wrapper_defconfig" > /dev/null 2>&1
_neg=$(fails=0; check_selection n100 "$TMP/out-no-wrapper" "$ROOT"; echo "fails=$fails")
check "TC-972-07 a defconfig without the wrapper fails the selection check" \
	"$(yes_if contains "FAIL TC-972-07 n100: BR2_PACKAGE_RASPUTIN_IDENTITY_DB=y" "$_neg")" "$_neg"

# TC-972-08: a copy without CPE_ID_PRODUCT gets Buildroot's default product,
# the package's own name, and the CPE check fails on it.
T=$(scratch_tree no-cpe)
grep -v '^RASPUTIN_POSTGRESQL_CPE_ID_PRODUCT = ' "$ROOT/package/rasputin-postgresql/rasputin-postgresql.mk" \
	> "$T/package/rasputin-postgresql/rasputin-postgresql.mk"
br "$T" "$TMP/out-no-cpe" rasputin_n100_defconfig > /dev/null 2>&1
_neg=$(fails=0; check_cpe n100 "$TMP/out-no-cpe" "$T"; echo "fails=$fails")
check "TC-972-08 a copy without CPE_ID_PRODUCT fails the CPE check" \
	"$(yes_if contains "FAIL TC-972-08 n100" "$_neg")" "$_neg"
check "TC-972-08 ... because its product is rasputin-postgresql" \
	"$(yes_if contains "read: cpe:2.3:a:postgresql:rasputin-postgresql:$V:" "$_neg")" "$_neg"

# TC-972-05: under real Buildroot, a carried major 19 stops make with the
# guard's sentence; the real tree in the same run reads its version.
T=$(scratch_tree major19)
sed 's/^RASPUTIN_POSTGRESQL_VERSION = .*/RASPUTIN_POSTGRESQL_VERSION = 19.0/' "$PG_MK" \
	> "$T/package/rasputin-postgresql/rasputin-postgresql.mk"
br "$T" "$TMP/out-major19" rasputin_n100_defconfig > /dev/null 2>&1
br "$T" "$TMP/out-major19" printvars VARS=RASPUTIN_POSTGRESQL_VERSION > "$TMP/m19.out" 2> "$TMP/m19.err"; rc=$?
echo "  (major 19: make exited $rc; stderr: $(cat "$TMP/m19.err"))"
check "TC-972-05 major 19: make exits non-zero" "$(yes_if [ "$rc" -ne 0 ])" "exit $rc"
check "TC-972-05 major 19: stderr carries the guard's sentence and make's Stop" \
	"$(yes_if contains "The carried PostgreSQL is 19.0, major 19, but this release carries major 18. A new major cannot open the data an older one wrote, so a major change is the planned upgrade item in geekdojo-brain lifecycle.md §1.5, never a bump.  Stop." "$(cat "$TMP/m19.err")")" \
	"$(cat "$TMP/m19.err")"
br "$ROOT" "$TMP/out-n100" printvars VARS=RASPUTIN_POSTGRESQL_VERSION > "$TMP/ctl.out" 2> "$TMP/ctl.err"; rc=$?
check "TC-972-05 control: the real tree exits 0 and prints $V" \
	"$(yes_if [ "$rc" -eq 0 ] && [ "$(cat "$TMP/ctl.out")" = "RASPUTIN_POSTGRESQL_VERSION=$V" ])" \
	"exit $rc, stdout: $(cat "$TMP/ctl.out"), stderr: $(cat "$TMP/ctl.err")"

echo
if [ "$fails" -gt 0 ]; then echo "$fails check(s) failed"; exit 1; fi
echo "all identity database Buildroot checks passed"
