#!/bin/bash
# One-shot install on any Mac that has this folder (e.g. via Syncthing):
#   ./scripts/install.sh
# Needs only the Command Line Tools (Swift), not Xcode. Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")/.."

# 1. Swift toolchain.
if ! xcode-select -p >/dev/null 2>&1 || ! command -v swift >/dev/null 2>&1; then
    echo "Swift isn't installed. Run:  xcode-select --install   then re-run this script."
    exit 1
fi
echo "Swift: $(swift --version 2>&1 | head -1)"

# 2. A permanent local signing identity, so macOS keeps Full Disk Access and Photos permission across rebuilds.
IDENTITY="Reclaim Dev"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
    echo "Signing identity '$IDENTITY' already present."
else
    echo "Creating the '$IDENTITY' signing identity in your login keychain (macOS will ask for your password once)…"
    T="$(mktemp -d)"
    cat > "$T/ext.cnf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = Reclaim Dev
O = Reclaim
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
    openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/key.pem" -out "$T/cert.pem" -days 3650 -config "$T/ext.cnf" >/dev/null 2>&1
    P="$(openssl rand -hex 16)"
    openssl pkcs12 -export -inkey "$T/key.pem" -in "$T/cert.pem" -name "$IDENTITY" -out "$T/id.p12" -passout "pass:$P" -legacy 2>/dev/null \
        || openssl pkcs12 -export -inkey "$T/key.pem" -in "$T/cert.pem" -name "$IDENTITY" -out "$T/id.p12" -passout "pass:$P"
    KC="$HOME/Library/Keychains/login.keychain-db"
    security import "$T/id.p12" -k "$KC" -P "$P" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
    security add-trusted-cert -r trustRoot -p codeSign -k "$KC" "$T/cert.pem"
    rm -rf "$T"
    echo "Identity created. When codesign first asks to use the key, choose 'Always Allow'."
fi

# 3. A .build folder synced from another Mac holds that Mac's paths; start clean if so.
if [ -d .build ] && ! grep -rqs "$(pwd)" .build/arm64-apple-macosx/debug/*.json 2>/dev/null; then
    echo "Clearing a build folder from another machine…"
    rm -rf .build
fi

# 4. Build, sign and install to ~/Applications, then open.
./scripts/build_app.sh
open "$HOME/Applications/Reclaim.app"
cat <<'EOF'

Installed to ~/Applications/Reclaim.app.
Next, in System Settings › Privacy & Security:
  • Full Disk Access  → add Reclaim (needed to see Mail, Messages, Safari and some system data)
  • Photos            → Reclaim appears after the first library search; allow Full Access
EOF
