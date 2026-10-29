#!/bin/bash
# Creates a self-signed code-signing certificate, "Shocrot Local Signing", in the login keychain.
# Builds signed with it keep their Screen Recording / Accessibility grants across rebuilds.
# Remove it any time in Keychain Access.
set -euo pipefail
NAME="Shocrot Local Signing"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then echo "“$NAME” already exists."; exit 0; fi

DIR=$(mktemp -d)
trap 'rm -rf "$DIR"' EXIT
cat > "$DIR/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$DIR/cert.cnf" \
  -keyout "$DIR/key.pem" -out "$DIR/cert.pem" 2>/dev/null
PASS=$(openssl rand -hex 12)
openssl pkcs12 -export -legacy -inkey "$DIR/key.pem" -in "$DIR/cert.pem" -name "$NAME" \
  -passout "pass:$PASS" -out "$DIR/id.p12" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$DIR/key.pem" -in "$DIR/cert.pem" -name "$NAME" \
       -passout "pass:$PASS" -out "$DIR/id.p12"
security import "$DIR/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign
echo "Created “$NAME”. Run scripts/build_app.sh --install, then grant permissions once more."
