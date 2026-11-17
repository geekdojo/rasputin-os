#!/bin/sh
#
# check-build-options.sh — fail the build when the options Keycloak persisted
# differ from the build conf it was given (geekdojo/geekdojo-brain#971;
# platform.md §2.3). kc.sh build accepts an unknown or misspelt option and
# exits 0 without persisting it (probed at 26.8.2), so without this an image
# could ship a Keycloak whose security options differ from what the api
# assumes. Run by keycloak.mk right after kc.sh build.
#
#   [UNZIP=<unzip>] check-build-options.sh CONF JAR
#
# CONF is keycloak-build.conf: blank lines, # comments and key=value lines.
# JAR is the built lib/quarkus/generated-bytecode.jar, whose
# META-INF/keycloak-persisted.properties Keycloak writes at build. Each conf
# line is read as kc.<key>=<value>, and the two sets must be equal. Ignored on
# the persisted side: comments (the timestamp line among them), blank lines,
# and the three lines Keycloak always writes, kc.optimized=true,
# kc.profile=prod and quarkus.profile=prod.
#
# Success: one stdout line, exit 0. A difference: one stderr sentence per
# line present on one side only (or with two values), then a summary, exit 1.
# FAILS CLOSED, exit 1 with a sentence: CONF missing or unreadable, a CONF line
# that is not key=value, JAR missing or not a zip, no persisted file in JAR
# (an unbuilt dist), or UNZIP failing.

set -u

fail() {
	echo "$*" >&2
	exit 1
}

[ "$#" -eq 2 ] || fail "check-build-options.sh needs the build conf and the built generated-bytecode.jar."
KC_CONF_LIB="$(dirname "$0")/kc-conf.sh"
[ -f "$KC_CONF_LIB" ] || fail "Cannot check Keycloak's build options, because the conf parser $KC_CONF_LIB does not exist."
# shellcheck source=package/keycloak/kc-conf.sh
. "$KC_CONF_LIB"
CONF="$1"
JAR="$2"
UNZIP="${UNZIP:-unzip}"
MEMBER=META-INF/keycloak-persisted.properties

[ -f "$CONF" ] || fail "Cannot check Keycloak's build options, because the conf $CONF does not exist."
[ -r "$CONF" ] || fail "Cannot check Keycloak's build options, because the conf $CONF cannot be read."
[ -f "$JAR" ] || fail "Cannot check Keycloak's build options, because $JAR does not exist."

WORK=$(mktemp -d) || fail "Cannot check Keycloak's build options, because a scratch directory could not be created."
trap 'rm -rf "$WORK"' EXIT

"$UNZIP" -p "$JAR" "$MEMBER" > "$WORK/persisted" 2>/dev/null
rc=$?
case "$rc" in
	0) ;;
	9) fail "Cannot check Keycloak's build options, because $JAR is not a zip archive." ;;
	11) fail "Cannot check Keycloak's build options, because $JAR holds no $MEMBER, so kc.sh build has not run on it." ;;
	*) fail "Cannot check Keycloak's build options, because $UNZIP exited $rc reading $MEMBER from $JAR." ;;
esac

# The conf as kc.<key>=<value>, refusing any line that is not key=value. The
# grammar is read by kc-conf.sh, the one parser of it (F-974-09).
kc_conf_lines "$CONF" "$WORK/badline" > "$WORK/conf.lines" \
	|| fail "Cannot check Keycloak's build options, because line $(cat "$WORK/badline") of $CONF is not blank, a # comment or key=value."
sed 's/^/kc./' "$WORK/conf.lines" > "$WORK/conf"

awk '
	/^[[:space:]]*$/ || /^[[:space:]]*#/ { next }
	$0 == "kc.optimized=true" || $0 == "kc.profile=prod" || $0 == "quarkus.profile=prod" { next }
	{ print }
' "$WORK/persisted" > "$WORK/kept"

# Compare by key: conf-only, persisted-only, and one key with two values.
awk -v conf="$CONF" -v jar="$JAR" '
	{ i = index($0, "="); k = substr($0, 1, i - 1); v = substr($0, i + 1) }
	FILENAME == ARGV[1] { c[k] = v; next }
	{ p[k] = v }
	END {
		for (k in c) {
			if (!(k in p))
				printf "%s sets %s=%s, which Keycloak did not persist: an unknown or misspelt option.\n", conf, substr(k, 4), c[k]
			else if (c[k] != p[k])
				printf "%s sets %s=%s, but Keycloak persisted %s=%s.\n", conf, substr(k, 4), c[k], k, p[k]
		}
		for (k in p)
			if (!(k in c))
				printf "Keycloak persisted %s=%s in %s, which %s does not set.\n", k, p[k], jar, conf
	}
' "$WORK/conf" "$WORK/kept" | LC_ALL=C sort > "$WORK/diffs"

if [ -s "$WORK/diffs" ]; then
	cat "$WORK/diffs" >&2
	fail "Keycloak's persisted build options differ from $CONF ($(wc -l < "$WORK/diffs" | tr -d ' ') difference(s)), so the image would ship options the api does not assume."
fi
echo "check-build-options: the $(wc -l < "$WORK/conf" | tr -d ' ') options Keycloak persisted equal $CONF."
