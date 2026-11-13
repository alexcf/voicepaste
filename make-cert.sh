#!/bin/zsh
# Creates a self-signed code-signing identity ("VoicePaste Local Signing") in your
# login keychain. build.sh uses it automatically, so every rebuild has the same
# signature and macOS remembers the Microphone/Accessibility permissions.
# Remove it later with:  security delete-identity -c "VoicePaste Local Signing"
set -euo pipefail

NAME="VoicePaste Local Signing"
if security find-identity -p codesigning | grep -q "\"$NAME\""; then
  echo "\"$NAME\" already exists."; exit 0
fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cs.cnf" <<EOF
[req]
distinguished_name=dn
prompt=no
x509_extensions=ext
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF

PW=$(uuidgen)
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/k.pem" -out "$TMP/c.pem" \
  -days 3650 -config "$TMP/cs.cnf" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/k.pem" -in "$TMP/c.pem" -out "$TMP/id.p12" \
  -passout "pass:$PW" -name "$NAME"
security import "$TMP/id.p12" -k ~/Library/Keychains/login.keychain-db -P "$PW" -T /usr/bin/codesign
echo "Created \"$NAME\". Now run ./build.sh"
