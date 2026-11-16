#!/bin/bash
# Costruisce "MWB Mac Host.app" da riga di comando, senza Xcode, e lo firma localmente.
#
# Uso: scripts/build-app.sh [--debug] [--install] [--run]
#   --debug     compila in configurazione debug (predefinita: release)
#   --install   copia il bundle in /Applications (o in $MWB_INSTALL_DIR)
#   --run       avvia l'app al termine
#
# Firma: usa l'identità "$MWB_SIGN_IDENTITY" (predefinita "mwbmac local signing", creata
# da scripts/create-signing-cert.sh); se non esiste ripiega sulla firma ad hoc.
# Con la firma ad hoc macOS considera ogni build un'app diversa: i permessi Accessibilità
# e Monitoraggio input vanno tolti e riconcessi dopo ogni ricompilazione.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIGURATION=release
INSTALL=false
RUN=false
for argument in "$@"; do
    case "$argument" in
        --debug) CONFIGURATION=debug ;;
        --install) INSTALL=true ;;
        --run) RUN=true ;;
        *) echo "opzione sconosciuta: $argument" >&2; exit 2 ;;
    esac
done

APP_NAME="MWB Mac Host"
EXECUTABLE="MWBMacHost"
BUNDLE_ID="${MWB_BUNDLE_ID:-local.mwbmac.host}"
VERSION="${MWB_VERSION:-0.5.0}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
IDENTITY="${MWB_SIGN_IDENTITY:-mwbmac local signing}"
APP="build/$APP_NAME.app"

echo "==> Compilazione ($CONFIGURATION)"
swift build -c "$CONFIGURATION" --product "$EXECUTABLE"
swift build -c "$CONFIGURATION" --product mwbmac
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

echo "==> Bundle $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
# Lo strumento da riga di comando viaggia nel bundle (set-key, probe, diagnosi).
cp "$BIN_DIR/mwbmac" "$APP/Contents/MacOS/mwbmac"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleDevelopmentRegion</key><string>it</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>MWB Mac Host si collega al PC Windows sulla rete locale per inviargli mouse e tastiera tramite Mouse Without Borders.</string>
    <key>NSHumanReadableCopyright</key><string>Client macOS per PowerToys Mouse Without Borders</string>
</dict>
</plist>
EOF
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> Firma"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    SIGN_AS="$IDENTITY"
    echo "    identità locale: $IDENTITY"
else
    SIGN_AS="-"
    echo "    firma ad hoc (nessuna identità \"$IDENTITY\": vedi scripts/create-signing-cert.sh)"
fi
# Prima l'eseguibile annidato, poi il bundle.
codesign --force --sign "$SIGN_AS" --identifier "$BUNDLE_ID.cli" "$APP/Contents/MacOS/mwbmac"
codesign --force --sign "$SIGN_AS" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict --verbose=1 "$APP"

if $INSTALL; then
    DESTINATION="${MWB_INSTALL_DIR:-/Applications}"
    echo "==> Installazione in $DESTINATION"
    pkill -x "$EXECUTABLE" 2>/dev/null || true
    rm -rf "$DESTINATION/$APP_NAME.app"
    cp -R "$APP" "$DESTINATION/"
    APP="$DESTINATION/$APP_NAME.app"
fi

echo "==> Pronto: $APP"
if $RUN; then
    open "$APP"
fi
