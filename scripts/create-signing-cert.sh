#!/bin/bash
# Creates the self-signed code-signing identity "Featherweight Self-Signed" in the login keychain
# and trusts it for code signing. Signing every build with the same identity keeps the app's
# designated requirement stable across updates, so macOS permissions survive them.
# Prompts for your login password once (the trust step). Safe to re-run: exits if it exists.
set -euo pipefail

NAME="Featherweight Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
OPENSSL=/usr/bin/openssl   # LibreSSL: its PKCS#12 output imports cleanly (OpenSSL 3 needs -legacy)

# Capture before grepping so an early grep exit cannot SIGPIPE security under pipefail.
IDENTITIES="$(security find-identity -v -p codesigning || true)"
if grep -q "$NAME" <<<"$IDENTITIES"; then
    echo "\"$NAME\" already exists; nothing to do."
    echo "$IDENTITIES"
    exit 0
fi

WORK="$(mktemp -d)"
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT   # the private key never outlives this script outside the keychain

# A throwaway passphrase only protects the temporary .p12 between openssl and security.
P12_PASS="$("$OPENSSL" rand -hex 16)"
export P12_PASS

echo "==> Generating certificate (valid 10 years)"
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -subj "/CN=$NAME" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
"$OPENSSL" pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -out "$WORK/cert.p12" -passout env:P12_PASS

echo "==> Importing into the login keychain"
security import "$WORK/cert.p12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign

echo "==> Trusting for code signing (macOS will ask for your password)"
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo "==> Code-signing identities"
security find-identity -p codesigning
