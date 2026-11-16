#!/bin/bash
# Crea un certificato autofirmato per la firma del codice ("firma locale") e lo importa
# in un portachiavi. Con un'identità stabile i permessi Accessibilità e Monitoraggio
# input sopravvivono alle ricompilazioni; con la firma ad hoc vanno riconcessi ogni volta.
#
# Uso: scripts/create-signing-cert.sh [portachiavi]
#   portachiavi: predefinito il portachiavi di login dell'utente.
# Il certificato non è attendibile per nessun altro: serve solo su questo Mac.
set -euo pipefail

IDENTITY="${MWB_SIGN_IDENTITY:-mwbmac local signing}"
KEYCHAIN="${1:-$HOME/Library/Keychains/login.keychain-db}"

if security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "Il certificato \"$IDENTITY\" esiste già in $KEYCHAIN."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

# /usr/bin/openssl (LibreSSL) produce un PKCS#12 che `security import` sa leggere.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/openssl.cnf" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
P12_PASSWORD="$(/usr/bin/openssl rand -hex 16)"
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$IDENTITY" \
    -out "$WORK/identity.p12" -passout "pass:$P12_PASSWORD"

# -T autorizza codesign a usare la chiave privata senza chiedere ogni volta.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign >/dev/null

echo "Certificato \"$IDENTITY\" creato in $KEYCHAIN."
echo "scripts/build-app.sh lo userà automaticamente."
