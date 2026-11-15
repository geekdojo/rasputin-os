################################################################################
#
# rasputin-identity-db
#
# The identity database wrapper (geekdojo/geekdojo-brain#972). It selects the
# carried PostgreSQL (package/rasputin-postgresql) and OpenSSL, and declares
# the two static users the identity service runs as. It has no source and
# installs nothing, the same shape as Buildroot's package/initscripts.
#
# The copy declares `postgres -1 ...` too. mkusers creates the static ids
# first and a later -1 line for the same name keeps the id it already has, so
# postgres ends up 992:992 with the copy's home and shell, and a locked
# password. test/identity-db-buildroot-test.sh runs Buildroot's own mkusers to
# prove it, and that 991 and 992 were free.
#
################################################################################

RASPUTIN_IDENTITY_DB_LICENSE = AGPL-3.0

define RASPUTIN_IDENTITY_DB_USERS
	keycloak 991 keycloak 991 * - - - Identity service
	postgres 992 postgres 992 * - - - Identity database
endef

$(eval $(generic-package))
