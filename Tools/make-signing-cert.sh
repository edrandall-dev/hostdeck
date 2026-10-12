#!/bin/zsh
# Make a self-signed code signing certificate for HostDeck in the login keychain. Run it one time.
# Usage: Tools/make-signing-cert.sh
#
# Why: an ad hoc signature changes with each build, so macOS treats each build as a new app and
# drops its Local Network permission. With this certificate, build.sh makes the same signature
# identity for each build, and macOS keeps the permission.
#
# The certificate and its private key stay in your login keychain. They are valid for 10 years.
# To use another name, set HOSTDECK_SIGN_ID here and for build.sh.

set -euo pipefail

NAME="${HOSTDECK_SIGN_ID:-HostDeck Local Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "The certificate \"$NAME\" is already in the login keychain."
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# The password protects only the temporary .p12 file, which the script deletes.
PASS=$(openssl rand -hex 16)

cat > "$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -new -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
# OpenSSL 3 (for example from Homebrew) encrypts a .p12 file with AES and a SHA-256 MAC by default.
# The security tool cannot read that and reports "MAC verification failed". So ask for SHA-1 and 3DES,
# which the security tool reads. LibreSSL in macOS and OpenSSL 3 both accept these options.
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
    -passout "pass:$PASS" -out "$TMP/cert.p12"

# -T lets codesign use the private key.
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null

echo "Added the certificate \"$NAME\" to the login keychain."
echo "The first time build.sh signs with it, macOS asks to let codesign use the key. Click Always Allow."
