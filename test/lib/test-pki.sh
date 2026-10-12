#!/bin/sh
#
# test-pki.sh — mint a throwaway CA and leaves with openssl. Sourced, never run
# (geekdojo/geekdojo-brain#756, F-756-03). TEST HARNESS: these stand in for the
# store CA and the server leaf the api mints (#758), and for foreign
# certificates the store must refuse. test/store-unit-functional.sh and
# test/update-smoke.sh share it.
#
#   mint_ca KEY PEM CN
#       A self-signed P-256 CA: its key to the file KEY, its certificate to PEM.
#   mint_leaf KEY PEM CN CA_PEM CA_KEY USAGE [SAN]
#       A P-256 leaf signed by the CA in CA_PEM and CA_KEY, with
#       extendedKeyUsage USAGE (serverAuth or clientAuth) and, if given, the
#       subjectAltName SAN (for example IP:127.0.0.1).
#
# KEYS ARE FILES. Every private key is written by openssl to a file under
# umask 077 and read back by path (-keyout, -CAkey); none is ever an argument
# value, printed, or piped. openssl's own output goes to /dev/null, so nothing
# here can put key material in a log. Each returns non-zero with a sentence on
# stderr on any failure.
#
# Needs: openssl.

mint_ca() {
	(
		umask 077
		openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 2 \
			-subj "/CN=$3" -keyout "$1" -out "$2" \
			-addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign
	) >/dev/null 2>&1 || { echo "openssl could not mint the test CA $3." >&2; return 1; }
}

mint_leaf() {
	case "${6:-}" in
		serverAuth|clientAuth) ;;
		*) echo "mint_leaf needs a usage of serverAuth or clientAuth, not '${6:-}'." >&2; return 2 ;;
	esac
	(
		umask 077
		_ml_ext="$1.ext" _ml_csr="$1.csr"
		trap 'rm -f "$_ml_ext" "$_ml_csr"' EXIT
		{
			printf 'extendedKeyUsage=%s\n' "$6"
			[ -n "${7:-}" ] && printf 'subjectAltName=%s\n' "$7"
		} >"$_ml_ext"
		openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=$3" \
			-keyout "$1" -out "$_ml_csr" &&
		openssl x509 -req -in "$_ml_csr" -CA "$4" -CAkey "$5" -set_serial "0x$(openssl rand -hex 8)" \
			-days 2 -extfile "$_ml_ext" -out "$2"
	) >/dev/null 2>&1 || { echo "openssl could not mint the test leaf $3." >&2; return 1; }
}
