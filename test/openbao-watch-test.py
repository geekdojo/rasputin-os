#!/usr/bin/env python3
#
# openbao-watch-test.py — unit tests for scripts/openbao-watch.py, the OpenBao
# half of the weekly cve-watch job (geekdojo/geekdojo-brain#768).
#
#   python3 -I test/openbao-watch-test.py
#
# Each test names the test case (TC-768-NN) it implements. The fixtures below
# are excerpts of openbao/openbao's live responses, fetched 2026-10-23 with the
# same `gh api` calls the workflow makes: all 47 repository advisories (only
# the fields the script reads) and all 36 releases (bodies kept for v2.7.1,
# v2.4.1, v2.2.2 and v2.6.1, the four the SECURITY extraction is tested on).
# Nothing here touches the network.

import importlib.util
import io
import json
import os
import re
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "..", "scripts", "openbao-watch.py")

# Loading the script must not leave a __pycache__ in scripts/.
sys.dont_write_bytecode = True
_spec = importlib.util.spec_from_file_location("openbao_watch", SCRIPT)
watch = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(watch)

ADVISORIES = json.loads(r'''
[
{"ghsa_id":"GHSA-gf3j-hm38-jhh5","cve_id":null,"severity":"medium","published_at":"2026-10-01T14:26:36Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-gf3j-hm38-jhh5","summary":"OpenBao's Kubernetes Auth Method Allows Renewal on Revoked Tokens","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao/v2"},"vulnerable_version_range":"<2.7.1, <2.6.4","patched_versions":"2.7.1, 2.6.4"}]},
{"ghsa_id":"GHSA-q74w-hv5x-6hxf","cve_id":null,"severity":"low","published_at":"2026-10-01T14:36:11Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-q74w-hv5x-6hxf","summary":"Improper Audit Logging of OpenBao's Root Token Generation and Unauthenticated Rekey Operations","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao/v2"},"vulnerable_version_range":"<2.7.1, <2.6.4","patched_versions":"2.7.1, 2.6.4"}]},
{"ghsa_id":"GHSA-8xxq-mq9m-xmhw","cve_id":null,"severity":"low","published_at":"2026-09-23T19:22:17Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-8xxq-mq9m-xmhw","summary":"OpenBao Plugins May Leak Malformed TypeKVPair and TypeHeader Parameters in Audit Log","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao/sdk/v2"},"vulnerable_version_range":"<2.6.3","patched_versions":"2.6.3, 2.7.1"},{"package":{"name":"github.com/openbao/openbao/v2"},"vulnerable_version_range":"<2.6.3","patched_versions":"2.6.3, 2.7.0"}]},
{"ghsa_id":"GHSA-5v22-543h-wg96","cve_id":null,"severity":"medium","published_at":"2026-10-01T14:27:27Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-5v22-543h-wg96","summary":"OpenBao's Request Parsing Allow Bypassing Role-Based Rate Limit Quotas","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao/v2"},"vulnerable_version_range":"<2.7.1, <2.6.4","patched_versions":"2.7.1, 2.6.4"}]},
{"ghsa_id":"GHSA-x8fg-h69x-p28f","cve_id":"CVE-2026-104092","severity":"high","published_at":"2026-09-23T19:19:11Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-x8fg-h69x-p28f","summary":"OpenBao's PKI ACME Issues Certificate With Unvalidated SANs","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao/v2"},"vulnerable_version_range":"<2.6.3","patched_versions":"2.6.3, 2.7.0"}]},
{"ghsa_id":"GHSA-2cjw-94fw-wqjx","cve_id":null,"severity":"medium","published_at":"2026-09-23T19:20:45Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-2cjw-94fw-wqjx","summary":"Open Redirect in OpenBao's OIDC UI","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao/v2"},"vulnerable_version_range":"<2.6.3","patched_versions":"2.6.3, 2.7.0"}]},
{"ghsa_id":"GHSA-hr5j-3j78-4vh2","cve_id":null,"severity":"low","published_at":"2026-09-23T19:21:02Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-hr5j-3j78-4vh2","summary":"Denied Wildcard Allows Limited ACL Bypass in OpenBao","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao/v2"},"vulnerable_version_range":"<2.6.3","patched_versions":"2.6.3, 2.7.0"}]},
{"ghsa_id":"GHSA-7m59-mp95-w6ph","cve_id":null,"severity":"low","published_at":"2026-10-01T14:29:38Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-7m59-mp95-w6ph","summary":"OpenBao's AppRole SecretID is Usable Past Expiration","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao/v2"},"vulnerable_version_range":"<2.7.1, <2.6.4","patched_versions":"2.7.1, 2.6.4"}]},
{"ghsa_id":"GHSA-3237-j65r-m5rp","cve_id":null,"severity":"low","published_at":"2026-10-01T14:19:40Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-3237-j65r-m5rp","summary":"OpenBao's Sanitized Configuration Discloses ACME EAB MAC Key","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao/v2"},"vulnerable_version_range":"<2.7.1, <2.6.4","patched_versions":"2.7.1, 2.6.4"}]},
{"ghsa_id":"GHSA-8gmq-wv9h-fcwp","cve_id":null,"severity":"low","published_at":"2026-09-23T19:21:21Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-8gmq-wv9h-fcwp","summary":"OpenBao's Agent/Proxy Allows Exiting Without Required Header","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao/v2"},"vulnerable_version_range":"<2.6.3","patched_versions":"2.6.3, 2.7.0"}]},
{"ghsa_id":"GHSA-mjch-vcw3-hhmf","cve_id":null,"severity":"high","published_at":"2026-09-23T19:19:27Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-mjch-vcw3-hhmf","summary":"OpenBao's Policy Cache Allows Incorrect Authorization via Namespace Traversal","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao/v2"},"vulnerable_version_range":"<2.6.3","patched_versions":"2.6.3, 2.7.0"}]},
{"ghsa_id":"GHSA-j6wc-jpvg-xfxq","cve_id":"CVE-2026-104090","severity":"critical","published_at":"2026-09-23T19:18:53Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-j6wc-jpvg-xfxq","summary":"Remote Code Execution via `sys/storage/raft/snapshot-force` Plugin Catalog Replacement in OpenBao","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao/v2"},"vulnerable_version_range":"<2.6.3","patched_versions":"2.6.3, 2.7.0"}]},
{"ghsa_id":"GHSA-fg5x-7whg-6c28","cve_id":"CVE-2026-104093","severity":"high","published_at":"2026-09-23T19:19:55Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-fg5x-7whg-6c28","summary":"ACL Bypass via Non-Canonical URL Access in OpenBao","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao/v2"},"vulnerable_version_range":"<2.6.3","patched_versions":"2.6.3, 2.7.0"}]},
{"ghsa_id":"GHSA-cg72-x35g-xfp8","cve_id":null,"severity":"low","published_at":"2026-09-23T19:21:55Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-cg72-x35g-xfp8","summary":"OpenBao's Plugin Registration APIs Are Not Limited to the Root Namespace","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao/v2"},"vulnerable_version_range":"<2.6.3","patched_versions":"2.6.3, 2.7.0"}]},
{"ghsa_id":"GHSA-rh46-vc3j-w2w3","cve_id":"CVE-2026-104088","severity":"critical","published_at":"2026-08-18T16:33:13Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-rh46-vc3j-w2w3","summary":"OpenBao - Internal Operation Dispatching Leads to Token Creation","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao"},"vulnerable_version_range":"<2.6.2","patched_versions":"2.6.2"}]},
{"ghsa_id":"GHSA-g892-p242-8g86","cve_id":null,"severity":"low","published_at":"2026-08-18T16:33:28Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-g892-p242-8g86","summary":"PKI allowed_ip_sans_cidr not enforced for CSR IP SANs when use_csr_sans=true","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao"},"vulnerable_version_range":"<2.6.2","patched_versions":"2.6.2"}]},
{"ghsa_id":"GHSA-444v-8vxr-p36h","cve_id":"CVE-2026-77285","severity":"low","published_at":"2026-07-14T17:30:55Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-444v-8vxr-p36h","summary":"OpenBao Agent Writes Secrets to Stdout","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao"},"vulnerable_version_range":"<2.6.0","patched_versions":"2.6.0"}]},
{"ghsa_id":"GHSA-59w7-v8rr-pr4p","cve_id":"CVE-2026-71543","severity":"high","published_at":"2026-07-14T17:36:14Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-59w7-v8rr-pr4p","summary":" OpenBao's Templated Policies Allow Privilege Escalation via Wildcard Characters","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao"},"vulnerable_version_range":"<2.6.0","patched_versions":"2.6.0"}]},
{"ghsa_id":"GHSA-34fc-gh42-pj53","cve_id":"CVE-2026-63132","severity":"critical","published_at":"2026-07-14T17:38:26Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-34fc-gh42-pj53","summary":"OpenBao's Recovery Mode Vulnerable To Token Leakage via Timing Attack","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao"},"vulnerable_version_range":"<2.6.0","patched_versions":"2.6.0"}]},
{"ghsa_id":"GHSA-xp3c-3jw3-4vcr","cve_id":"CVE-2026-63131","severity":"medium","published_at":"2026-07-14T17:38:45Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-xp3c-3jw3-4vcr","summary":"OpenBao Skips Stricter Deny Policy for LIST operations","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao"},"vulnerable_version_range":"<2.6.0","patched_versions":"2.6.0"}]},
{"ghsa_id":"GHSA-mwr2-wmgp-crj6","cve_id":"CVE-2026-55775","severity":"low","published_at":"2026-06-19T11:28:42Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-mwr2-wmgp-crj6","summary":"OpenBao's System Backend allows Unauthorized Management of the containing Namespace","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao"},"vulnerable_version_range":"<=2.5.4","patched_versions":"2.5.5"}]},
{"ghsa_id":"GHSA-8w8f-r2xv-4q4j","cve_id":"CVE-2026-55776","severity":"medium","published_at":"2026-06-19T11:28:26Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-8w8f-r2xv-4q4j","summary":"OpenBao crashes on Transit engine key creation with derived=true for RSA key types","vulnerabilities":[{"package":{"name":"OpenBao"},"vulnerable_version_range":"<=2.5.4","patched_versions":"2.5.5"}]},
{"ghsa_id":"GHSA-c36x-h252-g9x2","cve_id":"CVE-2026-55774","severity":"low","published_at":"2026-06-19T11:28:14Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-c36x-h252-g9x2","summary":"Cross-namespace lease revocation via lease ID in path bypasses ACL","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao"},"vulnerable_version_range":"<=2.5.4","patched_versions":"2.5.5"}]},
{"ghsa_id":"GHSA-6mwx-4547-5vc9","cve_id":"CVE-2026-55770","severity":"medium","published_at":"2026-06-19T11:28:09Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-6mwx-4547-5vc9","summary":"LDAPi ldaputil (wrong escape func)","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao"},"vulnerable_version_range":"<=2.5.4","patched_versions":"2.5.5"}]},
{"ghsa_id":"GHSA-q8cj-789h-vg24","cve_id":"CVE-2026-46358","severity":"medium","published_at":"2026-05-21T10:47:04Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-q8cj-789h-vg24","summary":"OpenBao's Inline Auth Incorrectly Redacted Headers","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao"},"vulnerable_version_range":"<=2.5.3","patched_versions":"2.5.4"}]},
{"ghsa_id":"GHSA-7j6w-vvw2-5f9c","cve_id":"CVE-2026-46405","severity":"medium","published_at":"2026-05-21T10:47:34Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-7j6w-vvw2-5f9c","summary":"OpenBao's Kerberos Auth Method Accumulates Unaccessible Tokens","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao"},"vulnerable_version_range":"<=2.5.3","patched_versions":"2.5.4"}]},
{"ghsa_id":"GHSA-v8v8-cm84-m686","cve_id":"CVE-2026-45808","severity":"low","published_at":"2026-05-21T11:25:19Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-v8v8-cm84-m686","summary":"Cross-namespace lease revocation via legacy sys/revoke path bypasses ACL","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao"},"vulnerable_version_range":"<= 2.5.3","patched_versions":"2.5.4"}]},
{"ghsa_id":"GHSA-vv66-6rp4-wr4f","cve_id":"CVE-2026-42186","severity":"low","published_at":"2026-04-30T13:23:35Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-vv66-6rp4-wr4f","summary":"OpenBao's Namespace Deletion May Not Delete Data Properly","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao"},"vulnerable_version_range":"<=2.5.2","patched_versions":"2.5.3"}]},
{"ghsa_id":"GHSA-p49j-v9wc-wg57","cve_id":"CVE-2026-40264","severity":"low","published_at":"2026-04-20T23:13:25Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-p49j-v9wc-wg57","summary":"OpenBao's Token Store Allows Cross-Namespace Renewal, Revocation","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao"},"vulnerable_version_range":"<=2.5.2","patched_versions":"2.5.3"}]},
{"ghsa_id":"GHSA-7ccv-rp6m-rffr","cve_id":"CVE-2026-39388","severity":"low","published_at":"2026-04-20T23:13:29Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-7ccv-rp6m-rffr","summary":"OpenBao's Certificate Authentication Allows Token Renewal With Different Certificate","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao"},"vulnerable_version_range":"<=2.5.2","patched_versions":"2.5.3"}]},
{"ghsa_id":"GHSA-6vgr-cp5c-ffx3","cve_id":"CVE-2026-39946","severity":"medium","published_at":"2026-04-20T23:13:51Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-6vgr-cp5c-ffx3","summary":"OpenBao allows SQL Injection in PostgreSQL database secrets engine","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao"},"vulnerable_version_range":"<=2.5.2","patched_versions":"2.5.3"}]},
{"ghsa_id":"GHSA-r65v-xgwc-g56j","cve_id":"CVE-2026-39396","severity":"low","published_at":"2026-04-20T23:14:00Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-r65v-xgwc-g56j","summary":"Decompression Bomb via Unbounded Copy in OCI Plugin Extraction (DoS)","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao"},"vulnerable_version_range":"<=2.5.2","patched_versions":"2.5.3"}]},
{"ghsa_id":"GHSA-7q7g-x6vg-xpc3","cve_id":"CVE-2026-33757","severity":"critical","published_at":"2026-03-25T14:15:53Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-7q7g-x6vg-xpc3","summary":"Lack of user confirmation for OpenBao OIDC direct callback mode","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao"},"vulnerable_version_range":"<=2.5.1","patched_versions":"2.5.2"}]},
{"ghsa_id":"GHSA-cpj3-3r2f-xj59","cve_id":"CVE-2026-33758","severity":"critical","published_at":"2026-03-25T14:15:55Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-cpj3-3r2f-xj59","summary":"Reflected XSS in OpenBao OIDC authentication error message","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao"},"vulnerable_version_range":"<=2.5.1","patched_versions":"2.5.2"}]},
{"ghsa_id":"GHSA-7ff4-jw48-3436","cve_id":"CVE-2025-64761","severity":"high","published_at":"2025-11-24T13:55:50Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-7ff4-jw48-3436","summary":"OpenBao Privileged Operator Identity Group Root Escalation","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao"},"vulnerable_version_range":"<2.4.3","patched_versions":"2.4.4"}]},
{"ghsa_id":"GHSA-rc54-2g2c-g36g","cve_id":"CVE-2025-62705","severity":"medium","published_at":"2025-10-22T19:41:14Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-rc54-2g2c-g36g","summary":"OpenBao and Vault Leak []byte Fields in Audit Logs ","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao"},"vulnerable_version_range":"<=2.4.1","patched_versions":"2.4.2"}]},
{"ghsa_id":"GHSA-ghfh-fmx4-26h8","cve_id":"CVE-2025-62513","severity":"medium","published_at":"2025-10-22T17:07:09Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-ghfh-fmx4-26h8","summary":"OpenBao leaks HTTPRawBody in Audit Logs","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao"},"vulnerable_version_range":">=2.2.0,<2.4.1","patched_versions":"2.4.2"}]},
{"ghsa_id":"GHSA-g46h-2rq9-gw5m","cve_id":"CVE-2025-59043","severity":"high","published_at":"2025-10-17T14:25:55Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-g46h-2rq9-gw5m","summary":"Potential Denial of Service when processing malicious unauthenticated JSON requests","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao"},"vulnerable_version_range":"< 2.4.0","patched_versions":"2.4.1"}]},
{"ghsa_id":"GHSA-2q8q-8fgw-9p6p","cve_id":"CVE-2025-55001","severity":"medium","published_at":"2025-08-08T10:30:46Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-2q8q-8fgw-9p6p","summary":"OpenBao LDAP MFA Enforcement Bypass When Using Username As Alias","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao"},"vulnerable_version_range":"<2.3.2","patched_versions":"2.3.2"}]},
{"ghsa_id":"GHSA-rxp7-9q75-vj3p","cve_id":"CVE-2025-55003","severity":"medium","published_at":"2025-08-08T10:32:24Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-rxp7-9q75-vj3p","summary":"OpenBao Login MFA Bypass of Rate Limiting and TOTP Token Reuse","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao"},"vulnerable_version_range":"<2.3.2","patched_versions":"2.3.2"}]},
{"ghsa_id":"GHSA-f7c3-mhj2-9pvg","cve_id":"CVE-2025-55000","severity":"medium","published_at":"2025-08-08T10:31:09Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-f7c3-mhj2-9pvg","summary":"OpenBao TOTP Secrets Engine Code Reuse","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao"},"vulnerable_version_range":"<2.3.2","patched_versions":"2.3.2"}]},
{"ghsa_id":"GHSA-j3xv-7fxp-gfhx","cve_id":"CVE-2025-54998","severity":"medium","published_at":"2025-08-08T10:31:48Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-j3xv-7fxp-gfhx","summary":"OpenBao Userpass and LDAP User Lockout Bypass","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao"},"vulnerable_version_range":"<2.3.2","patched_versions":"2.3.2"}]},
{"ghsa_id":"GHSA-hh28-h22f-8357","cve_id":"CVE-2025-54999","severity":"low","published_at":"2025-08-08T10:31:31Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-hh28-h22f-8357","summary":"Timing Side-Channel in OpenBao’s Userpass Auth Method","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao"},"vulnerable_version_range":"<2.3.2","patched_versions":"2.3.2"}]},
{"ghsa_id":"GHSA-xp75-r577-cvhp","cve_id":"CVE-2025-54997","severity":"critical","published_at":"2025-08-08T10:32:08Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-xp75-r577-cvhp","summary":"Privileged OpenBao Operator May Execute Code on the Underlying Host","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao"},"vulnerable_version_range":"<2.3.2","patched_versions":"2.3.2"}]},
{"ghsa_id":"GHSA-vf84-mxrq-crqc","cve_id":"CVE-2025-54996","severity":"high","published_at":"2025-08-08T10:32:32Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-vf84-mxrq-crqc","summary":"OpenBao Operator May Elevate Token Privileges","vulnerabilities":[{"package":{"name":"github.com/openbao/openbao"},"vulnerable_version_range":"<2.3.2","patched_versions":"2.3.2"}]},
{"ghsa_id":"GHSA-8f5r-8cmq-7fmq","cve_id":"CVE-2025-52893","severity":"medium","published_at":"2025-06-25T14:27:46Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-8f5r-8cmq-7fmq","summary":"May Leak Sensitive Information in Logs When Processing Malformed Data","vulnerabilities":[{"package":{"name":"openbao"},"vulnerable_version_range":"<2.3.0","patched_versions":"2.3.0"}]},
{"ghsa_id":"GHSA-prpj-rchp-9j5h","cve_id":"CVE-2025-52894","severity":"medium","published_at":"2025-06-25T14:27:42Z","html_url":"https://github.com/openbao/openbao/security/advisories/GHSA-prpj-rchp-9j5h","summary":"Unauthenticated Rekey Operation Cancellation","vulnerabilities":[{"package":{"name":"openbao"},"vulnerable_version_range":"<2.3.0","patched_versions":"2.3.0"}]}
]
''')

RELEASES = json.loads(r'''
[
{"tag_name":"v2.7.1","draft":false,"prerelease":false,"published_at":"2026-10-01T14:03:19Z","html_url":"https://github.com/openbao/openbao/releases/tag/v2.7.1","body":"## SECURITY\r\n\r\n* core: Prevent disclosure of `tls_acme_eab_mac_key` from `sys/config/state/sanitized`. GHSA-3237-j65r-m5rp. [[GH-4148](https://github.com/openbao/openbao/pull/4148)]\r\n* core/audit: The unauthenticated \"Root Token Generation\" and \"Rekey\" endpoints (which are disabled by default) returned their response, even if audit logging failed. GHSA-q74w-hv5x-6hxf. [[GH-4148](https://github.com/openbao/openbao/pull/4148)]\r\n* auth/approle: Ensure Secret ID cannot be used for authentication after expiration but before tidy is called. GHSA-7m59-mp95-w6ph. [[GH-4148](https://github.com/openbao/openbao/pull/4148)]\r\n* auth/approle: Fix incorrect JSON-decode path when parsing login requests with form data bodies. GHSA-5v22-543h-wg96. [[GH-4148](https://github.com/openbao/openbao/pull/4148)]\r\n* auth/cert: Fix omission of TLS connection propagation when calculating role-based quota. GHSA-5v22-543h-wg96. [[GH-4148](https://github.com/openbao/openbao/pull/4148)]\r\n* auth/kubernetes: Ensure Service Account JWT is validated on renewal, preventing post-revoke usage. GHSA-gf3j-hm38-jhh5. [[GH-4148](https://github.com/openbao/openbao/pull/4148)]\r\n\r\n## CHANGES\r\n\r\n* packaging: Update the default server config included in Linux packages to use the `pebbledb` backend instead of the removed `file` backend. [[GH-4088](https://github.com/openbao/openbao/pull/4088)]\r\n\r\n## BUG FIXES\r\n\r\n* core/barrier: Persist updates to key rotation config on changes to `disabled` field. [[GH-4107](https://github.com/openbao/openbao/pull/4107)]\r\n* core/grpc-invalidation: Ensure dispatcher lifecycle correctly handles active, standby state changes without locking conflicts. Resolves GRPC invalidation drops and pre-seal active node hangs. [[GH-4117](https://github.com/openbao/openbao/pull/4117)]\r\n* storage/raft: Fix `auto_join` breaking on providers that include ports with their discovered addresses. [[GH-4113](https://github.com/openbao/openbao/pull/4113)]\r\n* storage/postgresql: Switch to `pg_last_wal_replay_lsn()` for applied index value checks. [[GH-4118](https://github.com/openbao/openbao/pull/4118)]\r\n* api: Honor the error backoff interval after failed `LifetimeWatcher` renewal attempts. [[GH-4036](https://github.com/openbao/openbao/pull/4036)]\r\n\r\n<details>\r\n<summary>\r\n\r\n## What's Changed\r\n\r\n</summary>\r\n\r\n* docs(guides): add migration guide for File to PebbleDB storage backends on Kubernetes (#4092 by @pree) backported by @pree in https://github.com/openbao/openbao/pull/4109\r\n* Update default config included in linux packages (#4088 by @satoqz) backported by @satoqz in https://github.com/openbao/openbao/pull/4121\r\n* `KeyRotationConfig` equals() method should compare `disabled` field (#4107 by @wslabosz-reply) backported by @satoqz in https://github.com/openbao/openbao/pull/4122\r\n* Use persistent JobManager in GRPC Invalidation (#4117 by @cipherboy) backported by @satoqz in https://github.com/openbao/openbao/pull/4123\r\n* Fix Auto Join with provider-specified port (#4113 by @satoqz) backported by @satoqz in https://github.com/openbao/openbao/pull/4124\r\n* Honor backoff after failed LifetimeWatcher renewals (#4036 by @haxonittech) backported by @satoqz in https://github.com/openbao/openbao/pull/4125\r\n* Swap to pg_last_wal_replay_lsn() (#4118 by @cipherboy) backported by @satoqz in https://github.com/openbao/openbao/pull/4126\r\n* Ensure release artifact signatures are verified on creation (#3838 by @cipherboy) backported by @satoqz in https://github.com/openbao/openbao/pull/4128\r\n* Bump ubi10-minimal from `e3a5632` to `204e153` (#4129 by @dependabot) backported by @satoqz in https://github.com/openbao/openbao/pull/4138\r\n* Bump github.com/hashicorp/cap from 0.13.0 to 0.14.0 (#4133 by @dependabot) backported by @satoqz in https://github.com/openbao/openbao/pull/4143\r\n* v2.7.1 - Security Fixes against release/v2.7.x (#4146 by @06kellyjac, @cipherboy, @phil9909, @satoqz, @wslabosz-reply) backported by @cipherboy in https://github.com/openbao/openbao/pull/4147\r\n* Add release notes for v2.7.1 by @satoqz in https://github.com/openbao/openbao/pull/4149\r\n\r\n</details>\r\n\r\n**Full Changelog**: https://github.com/openbao/openbao/compare/v2.7.0...v2.7.1"},
{"tag_name":"v2.6.4","draft":false,"prerelease":false,"published_at":"2026-10-01T13:59:14Z","html_url":"https://github.com/openbao/openbao/releases/tag/v2.6.4"},
{"tag_name":"v2.7.0","draft":false,"prerelease":false,"published_at":"2026-09-23T17:39:54Z","html_url":"https://github.com/openbao/openbao/releases/tag/v2.7.0"},
{"tag_name":"v2.6.3","draft":false,"prerelease":false,"published_at":"2026-09-23T17:06:02Z","html_url":"https://github.com/openbao/openbao/releases/tag/v2.6.3"},
{"tag_name":"v2.7.0-beta20260909","draft":false,"prerelease":true,"published_at":"2026-09-09T12:58:28Z","html_url":"https://github.com/openbao/openbao/releases/tag/v2.7.0-beta20260909"},
{"tag_name":"v2.6.2","draft":false,"prerelease":false,"published_at":"2026-08-18T16:21:00Z","html_url":"https://github.com/openbao/openbao/releases/tag/v2.6.2"},
{"tag_name":"v2.6.1","draft":false,"prerelease":false,"published_at":"2026-07-22T14:37:36Z","html_url":"https://github.com/openbao/openbao/releases/tag/v2.6.1","body":"## CHANGES\r\n\r\n* packaging/container: Revert removal of legacy, non-opencontainers image labels for maximum compatibility. [[GH-3504](https://github.com/openbao/openbao/pull/3504)]\r\n\r\n## IMPROVEMENTS\r\n\r\n* core: Warn on `sys/` key with no explicit invalidation handler; please report if you see a log line with `no mechanism to invalidate cache`. [[GH-3555](https://github.com/openbao/openbao/pull/3555)]\r\n* core/policies: Introduce PATCH operation support for modifying the values of specific parameters. [[GH-3506](https://github.com/openbao/openbao/pull/3506)]\r\n\r\n## BUG FIXES\r\n\r\n* core/expiration: Ensure leases are not inadvertently cached on standby nodes. [[GH-3555](https://github.com/openbao/openbao/pull/3555)]\r\n* core/policies: Allow removal of `expiration` from policies on POST/PUT to `sys/policies/acl/<name>` by eliding the parameter; use PATCH to update policies without modifying unnecessary parameters. [[GH-3506](https://github.com/openbao/openbao/pull/3506)]\r\n* core/policies: Fix `limit=0` and negative limits bypassing the `pagination_limit` ACL option. [[GH-3518](https://github.com/openbao/openbao/pull/3518)]\r\n* core/policies: Fix persistence of new `allow_wildcards_in_identity_templates`, `allow_slashes_in_identity_templates` parameters in storage. [[GH-3506](https://github.com/openbao/openbao/pull/3506)]\r\n* auth/approle: Ensure initial salt is created without transaction to avoid deadlocks. [[GH-3556](https://github.com/openbao/openbao/pull/3556)]\r\n* auth/jwt: Fix patch operation of CEL roles losing existing data (`bound_audiences` `not_before_leeway`, `clock_skew_leeway` and `expiration_leeway`). [[GH-3551](https://github.com/openbao/openbao/pull/3551)]\r\n* auth/token: Ensure salt cache is invalidated properly on standby nodes. [[GH-3555](https://github.com/openbao/openbao/pull/3555)]\r\n* sdk/plugin: Ensure all log messages are visible under `plugin.ServeMultiplex(...)` by default to align with `plugin.Serve(...)`. [[GH-3536](https://github.com/openbao/openbao/pull/3536)]\r\n* sdk: Better support non-usr-merged distributions in containerized testing. [[GH-3554](https://github.com/openbao/openbao/pull/3554)]\r\n* packaging/container: Ensure that labels on UBI-based images comply with Red Hat's certification requirements. [[GH-3504](https://github.com/openbao/openbao/pull/3504)]\r\n\r\n<details>\r\n<summary>\r\n\r\n## What's Changed\r\n\r\n</summary>\r\n\r\n* Set user=root when invoking OpenBao for Alpine (#3499 by @cipherboy) backported by @cipherboy in https://github.com/openbao/openbao/pull/3501\r\n* Add OVHcloud KMS seal documentation (#3503 by @Sakutaroo) backported by @satoqz in https://github.com/openbao/openbao/pull/3524\r\n* Restore container image labels & fix UBI-specific ones (#3504 by @pree) backported by @satoqz in https://github.com/openbao/openbao/pull/3525\r\n* Fix policy persistence issue, introduce PATCH support for policies (#3506 by @cipherboy) backported by @phil9909 in https://github.com/openbao/openbao/pull/3538\r\n* Allow all log messages in multiplexed plugins (#3536 by @cipherboy) backported by @phil9909 in https://github.com/openbao/openbao/pull/3537\r\n* Fix limit=0 and negative limits bypassing pagination_limit ACL cap (#3518 by @RealFakeAccount) backported by @phil9909 in https://github.com/openbao/openbao/pull/3548\r\n* Fix profile source headings, response field (#3550 by @cipherboy) backported by @phil9909 in https://github.com/openbao/openbao/pull/3553\r\n* auth/jwt: fix patch operation of CEL roles lost data (#3551 by @phil9909) backported by @phil9909 in https://github.com/openbao/openbao/pull/3552\r\n* Fix lease renewal cache invalidation (#3555 by @cipherboy) backported by @phil9909 in https://github.com/openbao/openbao/pull/3566\r\n* Ensure AppRole salt is created without transaction (#3556 by @cipherboy) backported by @phil9909 in https://github.com/openbao/openbao/pull/3565\r\n* Copy binary to additional path in test container (#3554 by @cipherboy) backported by @cipherboy in https://github.com/openbao/openbao/pull/3568\r\n* Bump dependencies for v2.6.1 by @satoqz in https://github.com/openbao/openbao/pull/3570\r\n* Add changelog for v2.6.1 by @satoqz in https://github.com/openbao/openbao/pull/3571\r\n\r\n</details>\r\n\r\n**Full Changelog**: https://github.com/openbao/openbao/compare/v2.6.0...v2.6.1"},
{"tag_name":"v2.6.0","draft":false,"prerelease":false,"published_at":"2026-07-14T17:06:32Z","html_url":"https://github.com/openbao/openbao/releases/tag/v2.6.0"},
{"tag_name":"v2.6.0-beta20260622","draft":false,"prerelease":true,"published_at":"2026-06-22T19:58:29Z","html_url":"https://github.com/openbao/openbao/releases/tag/v2.6.0-beta20260622"},
{"tag_name":"v2.5.5","draft":false,"prerelease":false,"published_at":"2026-06-17T11:27:10Z","html_url":"https://github.com/openbao/openbao/releases/tag/v2.5.5"},
{"tag_name":"v2.5.4","draft":false,"prerelease":false,"published_at":"2026-05-20T16:15:07Z","html_url":"https://github.com/openbao/openbao/releases/tag/v2.5.4"},
{"tag_name":"v2.5.3","draft":false,"prerelease":false,"published_at":"2026-04-20T19:35:06Z","html_url":"https://github.com/openbao/openbao/releases/tag/v2.5.3"},
{"tag_name":"v2.5.2","draft":false,"prerelease":false,"published_at":"2026-03-25T16:23:32Z","html_url":"https://github.com/openbao/openbao/releases/tag/v2.5.2"},
{"tag_name":"v2.5.1","draft":false,"prerelease":false,"published_at":"2026-02-23T17:34:23Z","html_url":"https://github.com/openbao/openbao/releases/tag/v2.5.1"},
{"tag_name":"v2.5.0","draft":false,"prerelease":false,"published_at":"2026-02-04T16:26:04Z","html_url":"https://github.com/openbao/openbao/releases/tag/v2.5.0"},
{"tag_name":"v2.5.0-beta20251125","draft":false,"prerelease":true,"published_at":"2025-11-25T19:36:21Z","html_url":"https://github.com/openbao/openbao/releases/tag/v2.5.0-beta20251125"},
{"tag_name":"v2.4.4","draft":false,"prerelease":false,"published_at":"2025-11-24T20:01:19Z","html_url":"https://github.com/openbao/openbao/releases/tag/v2.4.4"},
{"tag_name":"v2.4.3","draft":false,"prerelease":false,"published_at":"2025-10-22T20:27:25Z","html_url":"https://github.com/openbao/openbao/releases/tag/v2.4.3"},
{"tag_name":"v2.4.1","draft":false,"prerelease":false,"published_at":"2025-09-11T20:32:45Z","html_url":"https://github.com/openbao/openbao/releases/tag/v2.4.1","body":"### SECURITY\r\n\r\n* http: Limit the complexity of JSON in HTTP request bodies through max_request_json_memory and max_request_json_strings. HCSEC-2025-24 / CVE-2025-6203 / CVE-2025-59043. [[GH-1756](https://github.com/openbao/openbao/pull/1756)]\r\n\r\n### BUG FIXES\r\n\r\n* auth/jwt: Add missing OIDC flow in JWK validator construction [[GH-1779](https://github.com/openbao/openbao/pull/1779)]\r\n* auth/jwt: Support token renewal with CEL roles. [[GH-1776](https://github.com/openbao/openbao/pull/1776)]\r\n* auth/mfa: Allow single-flow MFA to work with inline authentication. [[GH-1753](https://github.com/openbao/openbao/pull/1753)]\r\n* auth/mfa: Correctly persist tokens created through two-step MFA login enforcement. [[GH-1753](https://github.com/openbao/openbao/pull/1753)]\r\n* command: fix `operator init` not allowing for 0 as `recovery_shares` value. [[GH-1754](https://github.com/openbao/openbao/pull/1754)]\r\n* command: fix `operator rotate-keys` not returning recovery keys when server is initialized with 0 `recovery_shares`. [[GH-1754](https://github.com/openbao/openbao/pull/1754)]\r\n\r\n<details>\r\n\r\n<summary><h2> What's Changed</h2></summary>\r\n\r\n\r\n## What's Changed\r\n* Use RFC 5612 Private Enterprise Number (#1788) by @cipherboy  in https://github.com/openbao/openbao/pull/1788\r\n* fix(backend): Missing OIDCFlow (#1779) by @mase-informaticon  in https://github.com/openbao/openbao/pull/1779\r\n* Fix login renewal with CEL (#1776) by @cipherboy  in https://github.com/openbao/openbao/pull/1776\r\n* fix release-dist checkout failure (#1745) by @DrDaveD  in https://github.com/openbao/openbao/pull/1745\r\n* add {LICENSE|SPDX|VERSION}_NODE_MODULES.txt to the release dist tarball (#1764) by @DrDaveD  in https://github.com/openbao/openbao/pull/1764\r\n* reject JSON bodies which consume large amounts of RAM (#1756) by @phil9909 and @satoqz in https://github.com/openbao/openbao/pull/1756\r\n* Recovery rotation init CLI operation returns the recovery keys (#1754) by @wslabosz-reply  in https://github.com/openbao/openbao/pull/1754\r\n* Fix persistence of tokens created through LoginMFA (#1753) by @cipherboy in https://github.com/openbao/openbao/pull/1753\r\n* Limit maximum number of strings, memory in JSON input (#1784) by @cipherboy @wslabosz-reply @phil9909 @satoqz and @saracen in https://github.com/openbao/openbao/pull/1784\r\n* Release v2.4.1 by @JanMa in https://github.com/openbao/openbao/pull/1806\r\n\r\n\r\n**Full Changelog**: https://github.com/openbao/openbao/compare/v2.4.0...v2.4.1\r\n</details>"},
{"tag_name":"v2.4.0","draft":false,"prerelease":false,"published_at":"2025-08-28T20:39:37Z","html_url":"https://github.com/openbao/openbao/releases/tag/v2.4.0"},
{"tag_name":"v2.3.2","draft":false,"prerelease":false,"published_at":"2025-08-08T04:11:06Z","html_url":"https://github.com/openbao/openbao/releases/tag/v2.3.2"},
{"tag_name":"v2.3.1","draft":false,"prerelease":false,"published_at":"2025-06-25T19:26:24Z","html_url":"https://github.com/openbao/openbao/releases/tag/v2.3.1"},
{"tag_name":"v2.2.2","draft":false,"prerelease":false,"published_at":"2025-05-29T19:43:18Z","html_url":"https://github.com/openbao/openbao/releases/tag/v2.2.2","body":"## SECURITY:\r\n\r\n* sdk/framework: prevent information disclosure on invalid request. HCSEC-2025-09 / CVE-2025-4166. [[GH-1323](https://github.com/openbao/openbao/pull/1323)] @cipherboy \r\n\r\n## BUG FIXES:\r\n\r\n* ui: Fix description of Organizational Unit (OU) field in PKI. [[GH-1333](https://github.com/openbao/openbao/pull/1333)] @cipherboy\r\n\r\n<details>\r\n\r\n<summary><h2> What's Changed </h2></summary>\r\n\r\n* Prevent information disclosure on invalid request (#1323) by @JanMa in https://github.com/openbao/openbao/pull/1374\r\n* Bump ubi9-minimal from 9.5 to 9.6 (#1329) by @JanMa in https://github.com/openbao/openbao/pull/1376\r\n* Fix description of OU field in UI (#1333) by @JanMa in https://github.com/openbao/openbao/pull/1377\r\n* Renew `goodcertbadroot.pem` (#1351) by @JanMa in https://github.com/openbao/openbao/pull/1378\r\n* Bump to Go 1.24.3 (#1324) by @JanMa in https://github.com/openbao/openbao/pull/1375\r\n* Bump github.com/ebitengine/purego to v0.8.4 (#1373) by @JanMa in https://github.com/openbao/openbao/pull/1379\r\n* Release 2.2.2 by @JanMa in https://github.com/openbao/openbao/pull/1380\r\n\r\n</details>\r\n\r\n**Full Changelog**: https://github.com/openbao/openbao/compare/v2.2.1...v2.2.2"},
{"tag_name":"v2.3.0-beta20250528","draft":false,"prerelease":true,"published_at":"2025-05-28T21:56:16Z","html_url":"https://github.com/openbao/openbao/releases/tag/v2.3.0-beta20250528"},
{"tag_name":"v2.2.1","draft":false,"prerelease":false,"published_at":"2025-04-22T20:39:12Z","html_url":"https://github.com/openbao/openbao/releases/tag/v2.2.1"},
{"tag_name":"v2.2.0","draft":false,"prerelease":false,"published_at":"2025-03-05T13:10:23Z","html_url":"https://github.com/openbao/openbao/releases/tag/v2.2.0"},
{"tag_name":"v2.2.0-beta20250213","draft":false,"prerelease":false,"published_at":"2025-02-13T21:43:35Z","html_url":"https://github.com/openbao/openbao/releases/tag/v2.2.0-beta20250213"},
{"tag_name":"v2.1.1","draft":false,"prerelease":false,"published_at":"2025-01-21T21:28:27Z","html_url":"https://github.com/openbao/openbao/releases/tag/v2.1.1"},
{"tag_name":"v2.1.0","draft":false,"prerelease":false,"published_at":"2024-11-29T15:37:48Z","html_url":"https://github.com/openbao/openbao/releases/tag/v2.1.0"},
{"tag_name":"v2.0.3","draft":false,"prerelease":false,"published_at":"2024-11-15T16:56:53Z","html_url":"https://github.com/openbao/openbao/releases/tag/v2.0.3"},
{"tag_name":"v2.1.0-beta20241114.3","draft":false,"prerelease":true,"published_at":"2024-11-14T15:47:30Z","html_url":"https://github.com/openbao/openbao/releases/tag/v2.1.0-beta20241114.3"},
{"tag_name":"v2.0.2","draft":false,"prerelease":false,"published_at":"2024-10-05T19:28:58Z","html_url":"https://github.com/openbao/openbao/releases/tag/v2.0.2"},
{"tag_name":"v2.0.1","draft":false,"prerelease":false,"published_at":"2024-09-03T19:59:54Z","html_url":"https://github.com/openbao/openbao/releases/tag/v2.0.1"},
{"tag_name":"v2.0.0","draft":false,"prerelease":false,"published_at":"2024-07-17T22:08:30Z","html_url":"https://github.com/openbao/openbao/releases/tag/v2.0.0"},
{"tag_name":"v2.0.0-beta20240618","draft":false,"prerelease":true,"published_at":"2024-06-18T14:37:41Z","html_url":"https://github.com/openbao/openbao/releases/tag/v2.0.0-beta20240618"},
{"tag_name":"v2.0.0-alpha20240329","draft":false,"prerelease":true,"published_at":"2024-04-01T14:51:27Z","html_url":"https://github.com/openbao/openbao/releases/tag/v2.0.0-alpha20240329"}
]
''')

QUIET_LINE = "openbao watch: pin 2.7.1, 0 new finding(s) (0 advisories, 0 releases).\n"
REFUSAL_RE = re.compile(r"::error::[A-Z][^\n]*\.\n")


def advisory(ghsa):
    return next(a for a in ADVISORIES if a["ghsa_id"] == ghsa)


def release(tag):
    return next(r for r in RELEASES if r["tag_name"] == tag)


def patched(ghsa):
    return advisory(ghsa)["vulnerabilities"][0]["patched_versions"]


J6WC = "GHSA-j6wc-jpvg-xfxq"


class Run:
    """Writes the inputs into a scratch dir and runs main() on them."""

    def __init__(self, test):
        self.dir = tempfile.mkdtemp()
        test.addCleanup(self._cleanup)
        self.out = os.path.join(self.dir, "openbao.md")

    def _cleanup(self):
        for name in os.listdir(self.dir):
            os.remove(os.path.join(self.dir, name))
        os.rmdir(self.dir)

    def path(self, name):
        return os.path.join(self.dir, name)

    def write(self, name, text):
        with open(self.path(name), "w", encoding="utf-8") as f:
            f.write(text)
        return self.path(name)

    def argv(self, pin, advisories, releases, baseline=""):
        return [
            "--pin", pin,
            "--advisories", self.write("advisories.json", json.dumps(advisories)),
            "--releases", self.write("releases.json", json.dumps(releases)),
            "--baseline", self.write("baseline.ids", baseline),
            "--out", self.out,
        ]

    def main(self, argv):
        stdout, stderr = io.StringIO(), io.StringIO()
        rc = watch.main(argv, stdout, stderr)
        return rc, stdout.getvalue(), stderr.getvalue()

    def output(self):
        with open(self.out, encoding="utf-8") as f:
            return f.read()


def rel(tag, draft=False, prerelease=False, body=""):
    return {"tag_name": tag, "draft": draft, "prerelease": prerelease,
            "published_at": "2026-10-20T00:00:00Z",
            "html_url": "https://github.com/openbao/openbao/releases/tag/" + tag,
            "body": body}


def adv(ghsa, severity, patched_versions="9.9.9", cve=None):
    return {"ghsa_id": ghsa, "cve_id": cve, "severity": severity,
            "published_at": "2026-10-20T00:00:00Z",
            "html_url": "https://github.com/openbao/openbao/security/advisories/" + ghsa,
            "summary": "Synthetic advisory",
            "vulnerabilities": [{"package": {"name": "github.com/openbao/openbao/v2"},
                                 "vulnerable_version_range": "<9.9.9",
                                 "patched_versions": patched_versions}]}


class OpenBaoWatchTest(unittest.TestCase):
    maxDiff = None

    # TC-768-01: X.Y.Z with an optional v parses; everything else is None.
    def test_tc_768_01_parse_version(self):
        table = [
            ("2.7.1", (2, 7, 1)),
            ("v2.7.1", (2, 7, 1)),
            ("2.7.0-beta20260909", None),
            ("2.7", None),
            ("", None),
            ("x.y.z", None),
        ]
        for text, want in table:
            with self.subTest(text=text):
                self.assertEqual(watch.parse_version(text), want)

    # TC-768-02: versions order numerically, not as strings.
    def test_tc_768_02_version_ordering(self):
        p = watch.parse_version
        self.assertGreater(p("2.10.0"), p("2.9.9"))
        self.assertGreater(p("3.0.0"), p("2.99.99"))
        self.assertEqual(p("2.7.1"), p("2.7.1"))

    # TC-768-03: affects() on the real patched lists. The 2.7.0 row against
    # GHSA-3237 is the one the AND reading of `<2.7.1, <2.6.4` would clear.
    def test_tc_768_03_affects_real_entries(self):
        j6wc = patched(J6WC)
        g3237 = patched("GHSA-3237-j65r-m5rp")
        g46h = patched("GHSA-g46h-2rq9-gw5m")
        self.assertEqual(j6wc, "2.6.3, 2.7.0")
        self.assertEqual(g3237, "2.7.1, 2.6.4")
        self.assertEqual(advisory("GHSA-3237-j65r-m5rp")["vulnerabilities"][0]
                         ["vulnerable_version_range"], "<2.7.1, <2.6.4")
        self.assertEqual(g46h, "2.4.1")
        table = [
            (j6wc, "2.6.2", True), (j6wc, "2.5.5", True),
            (j6wc, "2.6.3", False), (j6wc, "2.7.0", False),
            (j6wc, "2.7.1", False), (j6wc, "2.8.0", False),
            (g3237, "2.7.0", True), (g3237, "2.6.3", True),
            (g3237, "2.7.1", False), (g3237, "2.6.4", False),
            (g46h, "2.4.0", True), (g46h, "2.4.1", False),
        ]
        for patched_versions, pin, want in table:
            with self.subTest(patched=patched_versions, pin=pin):
                self.assertIs(watch.affects(watch.parse_version(pin), patched_versions), want)

    # TC-768-04: no parseable patched version means affected.
    def test_tc_768_04_affects_fails_closed(self):
        pin = watch.parse_version("2.7.1")
        for patched_versions in (None, "", "2.8.0-rc1"):
            with self.subTest(patched=patched_versions):
                self.assertIs(watch.affects(pin, patched_versions), True)

    # TC-768-05: GHSA-8xxq has two entries; any affecting entry is enough, and
    # the advisory is reported once.
    def test_tc_768_05_dedup_and_any_entry(self):
        g8xxq = advisory("GHSA-8xxq-mq9m-xmhw")
        names = [e["package"]["name"] for e in g8xxq["vulnerabilities"]]
        self.assertEqual(names, ["github.com/openbao/openbao/sdk/v2",
                                 "github.com/openbao/openbao/v2"])
        found = watch.advisory_findings([g8xxq, g8xxq], (2, 7, 0), set())
        self.assertEqual([a["ghsa_id"] for a in found], ["GHSA-8xxq-mq9m-xmhw"])
        self.assertEqual(watch.advisory_findings([g8xxq], (2, 7, 1), set()), [])

    # TC-768-06: a baselined id does not fire again; the counts are 2, 0, 1.
    def test_tc_768_06_baseline_prevents_repeat(self):
        advisories = [advisory(J6WC)]
        releases = [release("v2.6.3")]

        run = Run(self)
        rc, out, _ = run.main(run.argv("2.6.2", advisories, releases))
        self.assertEqual((rc, out), (0, "2\n"))
        self.assertIn(J6WC, run.output())
        self.assertIn("openbao-v2.6.3", run.output())

        run = Run(self)
        baseline = "GHSA-j6wc-jpvg-xfxq\nopenbao-v2.6.3\n\n# triaged 2026-10-23\n"
        rc, out, _ = run.main(run.argv("2.6.2", advisories, releases, baseline))
        self.assertEqual((rc, out), (0, "0\n"))
        self.assertEqual(run.output(), "")

        run = Run(self)
        rc, out, _ = run.main(run.argv("2.6.2", advisories, releases, "openbao-v2.6.3\n"))
        self.assertEqual((rc, out), (0, "1\n"))
        self.assertIn(J6WC, run.output())
        self.assertNotIn("openbao-v2.6.3", run.output())

        # The advisory's CVE id suppresses it too, so a flaw already
        # baselined from pkg-stats under its CVE id is not triaged twice
        # (F-768-07).
        run = Run(self)
        baseline = "CVE-2026-104090\nopenbao-v2.6.3\n"
        rc, out, _ = run.main(run.argv("2.6.2", advisories, releases, baseline))
        self.assertEqual((rc, out), (0, "0\n"))

    # TC-768-07: drafts, prereleases, junk tags and older releases are dropped.
    def test_tc_768_07_release_filtering(self):
        beta = release("v2.2.0-beta20250213")
        self.assertIs(beta["prerelease"], False)
        releases = [
            rel("v2.7.2"), rel("v2.8.0"), rel("v2.9.0", draft=True),
            rel("v2.9.0-beta1", prerelease=True), beta, rel("nightly"), rel("v2.6.5"),
        ]
        found = watch.release_findings(releases, (2, 7, 1), set())
        self.assertEqual([f["id"] for f in found], ["openbao-v2.7.2", "openbao-v2.8.0"])

    # TC-768-08: the three S17 release classes, as rendered.
    def test_tc_768_08_release_classes(self):
        found = watch.release_findings([rel("v2.7.2"), rel("v2.8.0"), rel("v2.8.1")],
                                       (2, 7, 1), set())
        text = watch.render((2, 7, 1), [], found)
        lines = {f["id"]: next(l for l in text.splitlines() if "`%s`" % f["id"] in l)
                 for f in found}
        self.assertTrue(lines["openbao-v2.7.2"].endswith(": patch of the current minor."))
        self.assertIn("new minor at x.y.0", lines["openbao-v2.8.0"])
        self.assertIn("move at x.y.1; x.y.0 only if it is the only release carrying "
                      "a fix for a reachable critical or high", lines["openbao-v2.8.0"])
        self.assertTrue(lines["openbao-v2.8.1"].endswith(": new minor at x.y.1 or later."))

    # TC-768-09: the SECURITY section is found at any heading level, in any
    # case, with or without a colon; only v2.6.1 has none. No rendered item
    # keeps a link or an unwrapped URL (F-768-08).
    def test_tc_768_09_security_extraction(self):
        tags = ["v2.7.1", "v2.4.1", "v2.2.2", "v2.6.1"]
        heads = [release(t)["body"].splitlines()[0] for t in tags]
        self.assertEqual(heads[:3], ["## SECURITY", "### SECURITY", "## SECURITY:"])
        found = {f["id"]: f for f in watch.release_findings(
            [release(t) for t in tags], (2, 2, 1), set())}
        items = {i: f["security"] for i, f in found.items()}

        self.assertEqual(len(items["openbao-v2.7.1"]), 6)
        self.assertTrue(any("GHSA-3237-j65r-m5rp" in s for s in items["openbao-v2.7.1"]))
        self.assertTrue(any("CVE-2025-6203" in s for s in items["openbao-v2.4.1"]))
        self.assertTrue(any("CVE-2025-4166" in s for s in items["openbao-v2.2.2"]))
        # The section ends at the next heading: no BUG FIXES item is carried.
        self.assertEqual(len(items["openbao-v2.4.1"]), 1)
        self.assertEqual(len(items["openbao-v2.2.2"]), 1)
        self.assertIsNone(items["openbao-v2.6.1"])

        text = watch.render((2, 2, 1), [], list(found.values()))
        lines = text.splitlines()
        no_section = [l for l in lines if watch.NO_SECURITY_SECTION in l]
        self.assertEqual(len(no_section), 1)
        v261 = lines.index(next(l for l in lines if "`openbao-v2.6.1`" in l))
        self.assertEqual(lines[v261 + 1], "  - " + watch.NO_SECURITY_SECTION)

        # A bare URL and an autolink, which the real items do not have.
        synthetic = rel("v2.7.2", body="## Security\n\n* a. See https://example.org/x "
                        "and <https://example.org/y>.\n## Other\n* b\n")
        extra = watch.release_findings([synthetic], (2, 7, 1), set())[0]["security"]
        self.assertEqual(extra, ["a. See `https://example.org/x` and `https://example.org/y`."])

        rendered = [l for l in lines if l.startswith("  - SECURITY: ")] + extra
        self.assertEqual(len(rendered), 9)
        for item in rendered:
            with self.subTest(item=item):
                self.assertNotIn("](http", item)
                for m in re.finditer(r"https?://", item):
                    self.assertEqual(item[m.start() - 1], "`")

    # TC-768-10: the acceptance render for the known past advisory, GHSA-j6wc,
    # at pin 2.6.2.
    def test_tc_768_10_acceptance_render(self):
        run = Run(self)
        rc, out, _ = run.main(run.argv("2.6.2", [advisory(J6WC)], RELEASES))
        self.assertEqual(rc, 0)
        self.assertGreaterEqual(int(out), 1)
        text = run.output()
        self.assertTrue(text.startswith("### OpenBao secrets store (pinned v2.6.2)\n"))
        row = next(l for l in text.splitlines() if l.startswith("| [GHSA-j6wc"))
        self.assertIn("(https://github.com/openbao/openbao/security/advisories/"
                      "GHSA-j6wc-jpvg-xfxq)", row)
        cells = [c.strip() for c in row.strip("|").split("|")]
        self.assertEqual(cells[1:6], ["CVE-2026-104090", "critical", "2026-09-23",
                                      "2.6.3, 2.7.0", "<2.6.3"])
        self.assertIn("triage within 2 working days", text)
        self.assertIn("a dev build within 7 days and an out-of-cycle stable release "
                      "within 14 days, with an operator alert", text)
        self.assertIn("bump procedure in the header of `package/openbao/openbao.mk`", text)
        self.assertIn("`.github/cve-baseline.txt`", text)

    # TC-768-11: the S17 target by severity; a missing severity is urgent.
    def test_tc_768_11_target_by_severity(self):
        severities = {"GHSA-crit": "critical", "GHSA-high": "high", "GHSA-medi": "medium",
                      "GHSA-lowx": "low", "GHSA-null": None}
        advs = [adv(g, s) for g, s in severities.items()]
        found = watch.advisory_findings(advs, (2, 7, 1), set())
        self.assertEqual(len(found), 5)
        lines = watch.render((2, 7, 1), found, []).splitlines()
        for ghsa, severity in severities.items():
            with self.subTest(severity=severity):
                line = next(l for l in lines if l.startswith("- %s " % ghsa))
                self.assertIn("triage within 2 working days", line)
                urgent = "a dev build within 7 days and an out-of-cycle stable release " \
                         "within 14 days, with an operator alert"
                if severity in ("medium", "low"):
                    self.assertNotIn(urgent, line)
                    self.assertIn("the next scheduled update, within 30 days", line)
                else:
                    self.assertIn(urgent, line)
        # A null cve_id renders as `none` (F-768-07).
        row = next(l for l in lines if l.startswith("| [GHSA-null]"))
        self.assertEqual(row.strip("|").split("|")[1].strip(), "none")

    # TC-768-12: the quiet case at the current pin, on the full live excerpt.
    def test_tc_768_12_quiet_case(self):
        self.assertEqual((len(ADVISORIES), len(RELEASES)), (47, 36))
        run = Run(self)
        rc, out, err = run.main(run.argv("2.7.1", ADVISORIES, RELEASES))
        self.assertEqual((rc, out, err), (0, "0\n", QUIET_LINE))
        self.assertEqual(os.path.getsize(run.out), 0)

    # TC-768-13: every refusal exits 2, writes no --out and nothing on stdout,
    # and says what is wrong in one ::error:: sentence naming the fault.
    def test_tc_768_13_refusals(self):
        def bad_pin(pin):
            return lambda run: (run.argv(pin, ADVISORIES, RELEASES), pin)

        def missing(flag):
            def build(run):
                argv = run.argv("2.7.1", ADVISORIES, RELEASES)
                path = argv[argv.index(flag) + 1]
                os.remove(path)
                return argv, path
            return build

        def contents(flag, text):
            def build(run):
                argv = run.argv("2.7.1", ADVISORIES, RELEASES)
                path = argv[argv.index(flag) + 1]
                run.write(os.path.basename(path), text)
                return argv, path
            return build

        def no_out(run):
            argv = run.argv("2.7.1", ADVISORIES, RELEASES)
            return argv[:-2], "--out"

        rows = {
            "pin 2.7": bad_pin("2.7"),
            "pin beta": bad_pin("2.7.0-beta20260909"),
            "pin empty": bad_pin(""),
            "pin injected": bad_pin("2.7.1;id"),
            "pin with a newline": bad_pin("2.7.1\n::warning::x"),
            "advisories missing": missing("--advisories"),
            "releases missing": missing("--releases"),
            "invalid JSON": contents("--advisories", "[{"),
            "object not list": contents("--releases", '{"tag_name": "v2.7.1"}'),
            "empty advisories": contents("--advisories", "[]"),
            "no tag parses": contents("--releases", json.dumps([rel("nightly")])),
            "baseline missing": missing("--baseline"),
            "argument missing": no_out,
        }
        for name, build in rows.items():
            with self.subTest(row=name):
                run = Run(self)
                argv, fault = build(run)
                rc, out, err = run.main(argv)
                self.assertEqual(rc, 2)
                self.assertEqual(out, "")
                self.assertFalse(os.path.exists(run.out))
                self.assertRegex(err, REFUSAL_RE)
                self.assertEqual(err.count("\n"), 1)
                self.assertIn(watch.actions_escape(fault), err)

    # TC-768-14: the real CLI's exit codes.
    def test_tc_768_14_cli_exit_codes(self):
        for pin, want in (("2.7.1", 0), ("2.7", 2)):
            with self.subTest(pin=pin):
                run = Run(self)
                argv = run.argv(pin, ADVISORIES, RELEASES)
                done = subprocess.run([sys.executable, "-I", SCRIPT] + argv,
                                      capture_output=True, text=True)
                self.assertEqual(done.returncode, want, done.stderr)


if __name__ == "__main__":
    # The suite is loaded from the class, not by unittest.main()'s search of
    # sys.modules["__main__"], so it also runs under `python3 -m trace`, where
    # __main__ is the trace module (TC-768-16's coverage command).
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(OpenBaoWatchTest)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    sys.exit(0 if result.wasSuccessful() else 1)
