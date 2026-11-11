#!/bin/bash
# Creates onwin's own code-signing identity ("onwin Code Signing") in the login keychain, once.
#
# Why: an ad-hoc signature is identified by the hash of the binary, so macOS (TCC) treats every new
# build as a different app and asks again for the microphone, camera, folders… A stable certificate
# gives Onwin.app a stable designated requirement (bundle id + certificate), so the user's choices
# survive updates. It is self-signed: free, but not an Apple Developer ID — Gatekeeper still treats
# the app as unnotarized (install.sh avoids that by downloading with curl).
#
# The private key stays in this Mac's login keychain. Keep a backup (Keychain Access → My Certificates
# → "onwin Code Signing" → Export…) somewhere safe, NOT in a repository: releases signed with a
# different key make every user grant permissions once more.
#
#   scripts/make-signing-identity.sh          create (does nothing if it already exists)
set -euo pipefail

NAME="onwin Code Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if /usr/bin/security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "\"$NAME\""; then
    echo "identity \"$NAME\" already exists:"
    /usr/bin/security find-identity -p codesigning "$KEYCHAIN" | grep "\"$NAME\""
    exit 0
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/onwin-sign.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
O = onwin
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
/usr/bin/openssl req -x509 -newkey rsa:3072 -sha256 -days 7300 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" 2>/dev/null
PASS="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
    -out "$WORK/identity.p12" -passout "pass:$PASS"
# -T: codesign may use the key without asking every time.
/usr/bin/security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
echo "created:"
/usr/bin/security find-identity -p codesigning "$KEYCHAIN" | grep "\"$NAME\""
