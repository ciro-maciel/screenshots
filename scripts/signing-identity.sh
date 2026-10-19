#!/bin/bash
# Creates, once, a local code signing certificate in the login keychain, so every build of
# Screenshots carries the same signature. Without it (ad hoc), macOS ties Screen Recording to
# each build's exact hash and the grant stops working at every update.
# The official build signs with Developer ID instead (scripts/build.sh picks it first).
#   scripts/signing-identity.sh
set -euo pipefail

NAME="Screenshots Local Signing"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "Already in the keychain: $NAME"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
O = Ciro Cesar Maciel
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
PASS="$(openssl rand -hex 16)"
openssl pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
    -out "$WORK/identity.p12" -passout "pass:$PASS"
security import "$WORK/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" \
    -T /usr/bin/codesign -T /usr/bin/security
echo "Created: $NAME"
