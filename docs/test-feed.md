# Cloud-only HTTPS test feed

This fixture serves owner-supplied files over TLS on IPv4 loopback only. It does not sign or modify release artifacts. Use an isolated cloud Mac; do not install its test CA on another Mac or the System Keychain.

## Create a temporary CA and leaf certificate

Requires Python 3.9+ and OpenSSL 1.1.1 or newer (including OpenSSL 3+), with `-addext` and `-verify_ip` support. Check the executables with `python3 --version` and `openssl version`. macOS may provide LibreSSL instead of OpenSSL; use a compatible OpenSSL binary if the system command lacks those options.

```sh
TEST_ROOT=$(mktemp -d "$HOME/bawan-rc-test-feed.XXXXXXXX") || {
  printf '%s\n' 'Could not create a unique test-feed directory.' >&2
  exit 1
}
export TEST_ROOT
export TLS="$TEST_ROOT/tls"
export PUBLIC="$TEST_ROOT/public"
printf 'TEST_ROOT=%s\n' "$TEST_ROOT"
```

Keep the TLS files outside the public root. Run all generation commands in this fail-fast subshell; it refuses to overwrite existing CA, leaf, or extension files:

```sh
(
  set -eu
  umask 077
  mkdir -p "$TLS" "$PUBLIC/baseline" "$PUBLIC/v2.0.0-rc.1"
  test ! -e "$TLS/ca.key"
  test ! -e "$TLS/ca.crt"
  test ! -e "$TLS/server.key"
  test ! -e "$TLS/server.crt"
  test ! -e "$TLS/server.csr"
  test ! -e "$TLS/server-ext.cnf"
  test ! -e "$TLS/ca.srl"
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$TLS/ca.key"
  openssl req -x509 -new -key "$TLS/ca.key" -sha256 -days 30 -subj '/CN=Bawan cloud test CA' -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' -out "$TLS/ca.crt"
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$TLS/server.key"
  openssl req -new -key "$TLS/server.key" -subj '/CN=127.0.0.1' -out "$TLS/server.csr"
  printf '%s\n' '[server_ext]' 'basicConstraints=critical,CA:FALSE' 'keyUsage=critical,digitalSignature,keyEncipherment' 'extendedKeyUsage=serverAuth' 'subjectAltName=IP:127.0.0.1' > "$TLS/server-ext.cnf"
  openssl x509 -req -in "$TLS/server.csr" -CA "$TLS/ca.crt" -CAkey "$TLS/ca.key" -CAcreateserial -out "$TLS/server.crt" -days 30 -sha256 -extfile "$TLS/server-ext.cnf" -extensions server_ext
  chmod 600 "$TLS/ca.key" "$TLS/server.key"
  openssl verify -CAfile "$TLS/ca.crt" -verify_ip 127.0.0.1 "$TLS/server.crt"
)
```

From the repository root, only the harmless health response is needed to check setup:

```sh
printf '%s\n' 'Bawan loopback test feed is healthy.' > "$PUBLIC/health.txt"
python3 scripts/serve-test-feed.py --root "$PUBLIC" --cert "$TLS/server.crt" --key "$TLS/server.key"
```

The helper defaults to port 8443 and always binds 127.0.0.1. Stop it with Ctrl-C. Verify the listener is on 127.0.0.1:8443, not a wildcard address. It serves regular files under the explicit root, does not list directories, and rejects traversal and symlinks.

Environment variables do not carry over to another terminal. Copy the exact `TEST_ROOT` path printed above and set all three variables there before curl, trust, or cleanup; keep using that terminal for those commands:

```sh
export TEST_ROOT='/paste-the-exact-TEST_ROOT-printed-above'
export TLS="$TEST_ROOT/tls"
export PUBLIC="$TEST_ROOT/public"
```

Then verify TLS without weakening verification:

```sh
if curl --noproxy '*' --silent --show-error --output /dev/null https://127.0.0.1:8443/health.txt; then
  printf '%s\n' 'Unexpectedly trusted the test CA.' >&2
  exit 1
fi
curl --noproxy '*' --cacert "$TLS/ca.crt" https://127.0.0.1:8443/health.txt
if curl --noproxy '*' --resolve wrong-host.example:8443:127.0.0.1 --cacert "$TLS/ca.crt" https://wrong-host.example:8443/health.txt; then
  printf '%s\n' 'Unexpectedly accepted the wrong hostname.' >&2
  exit 1
fi
```

The first request must reject the untrusted CA, the second must return the health text, and the wrong-host request must fail hostname verification. Do not use curl -k or a Sparkle trust delegate override.

## Temporary cloud-user trust for the actual Sparkle gate

Only after approval, add the unique CA to the cloud user's login keychain in the terminal with the variables above. If using a new terminal, re-export them first. Do not use -d, System Keychain, or another user's Mac:

```sh
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
CA_SHA256=$(openssl x509 -in "$TLS/ca.crt" -noout -fingerprint -sha256 | sed 's/.*=//;s/://g')
security add-trusted-cert -r trustRoot -p ssl -k "$LOGIN_KEYCHAIN" "$TLS/ca.crt"
```

After the test, remove trust and the exact certificate from that login keychain:

```sh
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
CA_SHA256=$(openssl x509 -in "$TLS/ca.crt" -noout -fingerprint -sha256 | sed 's/.*=//;s/://g')
security remove-trusted-cert "$TLS/ca.crt"
security delete-certificate -Z "$CA_SHA256" "$LOGIN_KEYCHAIN"
```

Explicit curl CA verification is only setup proof. Normal Sparkle/macOS trust is pending until the real signed app update succeeds with this temporary cloud-user trust. Do not add the CA to trust on Yu's Mac.

## Owner artifacts and feed paths

The baseline and RC must be real same-team Developer ID-signed and notarized ZIPs, built with SUFeedURL https://127.0.0.1:8443/appcast.xml and the same embedded Sparkle public key. Read the public key from the baseline app; no separate secret request is needed:

```sh
/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' '/path/to/Bawan.app/Contents/Info.plist'
```

Use these exact enclosure prefixes:

- Baseline: https://127.0.0.1:8443/baseline/
- RC: https://127.0.0.1:8443/v2.0.0-rc.1/

Place the unchanged owner artifacts at:

- public/baseline/Bawan-2.0.0-macOS-arm64.zip and public/baseline/SHA256SUMS
- public/v2.0.0-rc.1/Bawan-2.0.0-macOS-arm64.zip and public/v2.0.0-rc.1/SHA256SUMS
- public/appcast.xml containing the real signed RC enclosure

Transfer only those signed artifacts through a session-private attachment or another authorized private channel. Do not transfer private signing keys, the model, or the owner's Keychain. The public Sparkle key can be read from the signed baseline app's SUPublicEDKey; no separate secret request is needed.

Before public publication, the stable latest-feed appcast is expected to return 404. This is independent of the private loopback feed. The loopback /appcast.xml path also returns 404 until the owner's RC appcast is placed there; a health response does not mean the RC feed is ready.
