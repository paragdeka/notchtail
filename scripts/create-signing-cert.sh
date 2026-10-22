#!/bin/sh
# Creates a self-signed code-signing identity in the login keychain.
# Ad-hoc signatures change with every build, so macOS forgets the
# "Always Allow" Keychain approval for Claude credentials after each rebuild;
# a stable identity keeps that approval. Remove it with:
#   security delete-identity -c "notchtail local signing"
set -eu

NAME="notchtail local signing"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
    echo "Signing identity \"$NAME\" already exists."
    exit 0
fi

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

cat > "$workdir/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$workdir/cert.cnf" -keyout "$workdir/key.pem" -out "$workdir/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$workdir/key.pem" -in "$workdir/cert.pem" \
    -out "$workdir/identity.p12" -passout pass:notchtail
security import "$workdir/identity.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
    -P notchtail -T /usr/bin/codesign >/dev/null

echo "Created signing identity \"$NAME\". Run \`make restart\`, then choose Always Allow once."
