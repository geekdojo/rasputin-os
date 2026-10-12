#!/bin/sh
#
# store-policy-fixture.sh — give a fixture target dir what post-build.sh's
# secrets-store policy guard reads (geekdojo/geekdojo-brain#804). Sourced,
# never run. The suites that run the real post-build.sh over a fixture
# (rootfs-shadow, machine-id, persistent-journal and firewall-manifest) share
# it; what the guard itself does is test/check-store-policy-test.sh's.
#
#   store_policy_fixture ROOT TARGET BUILD_DIR [COPY_ROOT]
#       Copies ROOT's overlay init.json into TARGET, writes a synthetic policy
#       file for every policy file init.json names into TARGET's
#       /usr/share/rasputin/openbao-policy/, and the same files into
#       BUILD_DIR/rasputin-api-2099.01.0/openbao-policy/, the extracted
#       tarball the guard compares against. The names come from init.json, so
#       a policy added there is covered here with no edit. With COPY_ROOT, a
#       suite that runs a scratch copy of post-build.sh, the guard and the
#       drift script are copied beside it there, where the copy looks for
#       them. Returns non-zero with a sentence on stderr on any failure.

store_policy_fixture() {
	_spf_init="$1/board/rasputin/common/rootfs-overlay/etc/rasputin/openbao/init.json"
	_spf_api="$3/rasputin-api-2099.01.0/openbao-policy"
	mkdir -p "$2/etc/rasputin/openbao" "$2/usr/share/rasputin/openbao-policy" "$_spf_api" \
		&& cp "$_spf_init" "$2/etc/rasputin/openbao/init.json" \
		|| { echo "store_policy_fixture: could not build the store policy fixture in $2 and $3." >&2; return 1; }
	_spf_names=$(sed -n 's|.*"path"[[:space:]]*:[[:space:]]*"/usr/share/rasputin/openbao-policy/\([^"/]*\)".*|\1|p' "$_spf_init")
	[ -n "$_spf_names" ] || { echo "store_policy_fixture: $_spf_init names no policy file." >&2; return 1; }
	for _spf_n in $_spf_names; do
		printf 'path "fixture/%s" {\n  capabilities = ["read"]\n}\n' "$_spf_n" >"$2/usr/share/rasputin/openbao-policy/$_spf_n" \
			&& cp "$2/usr/share/rasputin/openbao-policy/$_spf_n" "$_spf_api/$_spf_n" \
			|| { echo "store_policy_fixture: could not write the policy file $_spf_n." >&2; return 1; }
	done
	if [ -n "${4:-}" ]; then
		mkdir -p "$4/board/rasputin/common" "$4/scripts" \
			&& cp "$1/board/rasputin/common/check-store-policy.sh" "$4/board/rasputin/common/" \
			&& cp "$1/scripts/store-policy-drift.sh" "$4/scripts/" \
			|| { echo "store_policy_fixture: could not copy the guard and the drift script into $4." >&2; return 1; }
	fi
	return 0
}
