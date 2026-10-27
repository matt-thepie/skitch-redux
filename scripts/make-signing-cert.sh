#!/bin/bash
# Creates a self-signed "Skitch Redux Local Signing" code-signing identity in your login keychain.
set -euo pipefail
D=$(mktemp -d); cd "$D"
cat > c.cnf <<'CNF'
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=Skitch Redux Local Signing
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout k.pem -out c.pem -days 3650 -config c.cnf
openssl pkcs12 -export -legacy -inkey k.pem -in c.pem -out id.p12 -passout pass:skitch 2>/dev/null \
  || openssl pkcs12 -export -inkey k.pem -in c.pem -out id.p12 -passout pass:skitch
security import id.p12 -k ~/Library/Keychains/login.keychain-db -P skitch -T /usr/bin/codesign
rm -rf "$D"
echo "Done."
