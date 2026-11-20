#!/bin/zsh
# Creates the self-signed "Edo Local Signing" certificate in the login keychain.
# Builds signed with it keep the same identity, so macOS remembers Edo's
# microphone and screen-recording permission across rebuilds.
set -euo pipefail

name="Edo Local Signing"
if security find-identity -p codesigning | grep -q "\"$name\""; then
    echo "$name is already in the keychain."
    exit 0
fi

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
cat > "$dir/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$dir/cert.cnf" \
    -keyout "$dir/key.pem" -out "$dir/cert.pem" 2>/dev/null
# The keychain only reads PKCS#12 files with the older SHA-1 and 3DES algorithms.
openssl pkcs12 -export -inkey "$dir/key.pem" -in "$dir/cert.pem" -out "$dir/cert.p12" \
    -name "$name" -passout pass:edo -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1
security import "$dir/cert.p12" -k ~/Library/Keychains/login.keychain-db -P edo -T /usr/bin/codesign
echo "Created $name."
