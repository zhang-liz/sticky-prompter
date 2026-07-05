#!/bin/bash
# One-time (per machine) local signing setup.
#
# Ad-hoc signatures change on every build, so macOS treats each rebuild as a
# brand-new app and asks for microphone/speech permission again. Signing with
# one self-signed certificate keeps the signature stable, so permissions
# granted once survive rebuilds.
#
# The certificate anchors no trust (Gatekeeper still treats the app as
# unidentified) — it exists only so TCC can recognize the app across builds.
set -euo pipefail

NAME="Sticky Prompter Dev"
KEYCHAIN="$HOME/Library/Keychains/sticky-prompter-dev.keychain-db"
# Locks only this throwaway keychain; the key inside signs local dev builds
# and is worthless to an attacker, hence a fixed password.
PASS="sticky-prompter-local"

if [ -f "$KEYCHAIN" ] && security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$NAME"; then
  echo "✅ '$NAME' identity already set up"
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:false
EOF

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.cnf" 2>/dev/null
# legacy PBE/MAC algorithms: the only ones `security import` accepts
openssl pkcs12 -export -out "$TMP/dev.p12" -inkey "$TMP/key.pem" \
  -in "$TMP/cert.pem" -passout "pass:$PASS" \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1

rm -f "$KEYCHAIN"
security create-keychain -p "$PASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN"   # never auto-lock
security unlock-keychain -p "$PASS" "$KEYCHAIN"
security import "$TMP/dev.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
# let codesign use the key without a GUI confirmation prompt
security set-key-partition-list -S apple-tool:,apple: -s -k "$PASS" "$KEYCHAIN" >/dev/null
# mark the cert trusted for code signing only — macOS asks for your login
# password once to confirm; that is the only trust this cert ever gets
security add-trusted-cert -p codeSign -k "$HOME/Library/Keychains/login.keychain-db" "$TMP/cert.pem"
# codesign only finds identities in keychains on the search list
if ! security list-keychains -d user | grep -q "sticky-prompter-dev"; then
  # shellcheck disable=SC2046
  security list-keychains -d user -s $(security list-keychains -d user | sed 's/^ *"//; s/" *$//') "$KEYCHAIN"
fi

echo "✅ '$NAME' identity created — build.sh will use it automatically"
echo "   (the next launch will ask for mic/speech permission once more,"
echo "    then rebuilds keep it)"
