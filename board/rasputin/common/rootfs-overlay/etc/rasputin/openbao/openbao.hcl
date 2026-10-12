# The node secrets store's main config (ADR-0010; geekdojo/geekdojo-brain#756).
# openbao.service's ExecStart names this file as its first -config. It is on the
# read-only rootfs and holds no secret.
#
# No seal stanza here. The seal comes from the per-cluster fragment that
# rasputin-seal-key.sh writes (S10), which reaches bao as the seal.hcl
# credential through the second -config. A rotation (#830) rewrites that
# fragment, never this file.
#
# bao expands no variable in its config (#679 Q3), so every credential is named
# by its literal path under /run/credentials/openbao.service/. Those copies come
# from the unit's LoadCredential= lines (#754).
#
# The self-init stanzas are NOT here: they are init.json beside this file, the
# second -config, because hcl-keys.sh reads flat HCL and refuses the request
# maps (#804). The audit device IS here, as a declarative stanza: created as a
# self-init request it fails the first start and leaves a store that never
# unseals (#680 Q1, Q8), and a stanza is re-applied on every start.
#
# Left out on purpose: telemetry, cluster_addr and a unix listener.
#
# test/store-config-test.sh asserts every key here; test/store-unit-functional.sh
# runs this file, byte for byte, on the real pinned bao under real systemd.

# The listener below, as a URL. Port 8200 is the api's RASPUTIN_SECRETSTORE_ADDR
# (#757); test/api-store-wiring-test.sh ties the two.
api_addr = "https://127.0.0.1:8200"
# PebbleDB is a single-node backend (S6), so the store never clusters.
disable_clustering = true
ui = false
log_level = "info"

# S8: loopback only, TLS with a required client certificate, and the store CA
# alone as client trust.
listener "tcp" {
  address = "127.0.0.1:8200"
  tls_cert_file = "/run/credentials/openbao.service/server.pem"
  tls_key_file = "/run/credentials/openbao.service/server.key"
  tls_client_ca_file = "/run/credentials/openbao.service/store-ca.pem"
  tls_require_and_verify_client_cert = true
  # Listener options: at the top level bao ignores them (D679-05).
  disable_unauthed_rekey_endpoints = true
  disable_unauthed_generate_root_endpoints = true
}

storage "pebbledb" {
  path = "/var/lib/rasputin/openbao"
}

# S11 (#684, #804): the audit log is a file on the persistent partition, in the
# store's own 0700 directory (a ReadWritePaths= entry of the unit), never
# stdout or journald, which drop lines. mode keeps it owner-only; the at-rest
# inventory declares it 0600 990:990 and sweeps the directory. log_raw = false
# HMACs every string value with the store's own key, and hmac_accessor does
# the same for token accessors, so no secret or token reaches the file. The
# path is the contract #799's rotation job reads.
audit "file" "rasputin" {
  options {
    file_path = "/var/lib/rasputin/openbao-audit/audit.log"
    mode = "0600"
    log_raw = "false"
    hmac_accessor = "true"
  }
}
