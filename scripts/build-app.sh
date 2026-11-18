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
        *) echo "unknown option: $argument" >&2; exit 2 ;;
    esac
done

APP_NAME="MWB Mac Host"
EXECUTABLE="MWBMacHost"
BUNDLE_ID="${MWB_BUNDLE_ID:-local.mwbmac.host}"
VERSION="${MWB_VERSION:-1.0.0}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
IDENTITY="${MWB_SIGN_IDENTITY:-mwbmac local signing}"
APP="build/$APP_NAME.app"

echo "==> Translations"
scripts/check-localization.sh

echo "==> Build ($CONFIGURATION)"
# Una sola compilazione per app e riga di comando. Con i soli Command Line Tools il linker
# segnala percorsi di ricerca di Xcode che non esistono ("search path ... not found"):
# sono avvisi innocui e vengono tolti dall'output; gli errori veri restano visibili e,
# grazie a pipefail, fermano lo script.
swift build -c "$CONFIGURATION" 2>&1 | { grep -v "ld: warning: search path .* not found" || true; }
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

echo "==> Bundle $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
# Lo strumento da riga di comando viaggia nel bundle (set-key, probe, diagnosi).
cp "$BIN_DIR/mwbmac" "$APP/Contents/MacOS/mwbmac"
# Una cartella .lproj per lingua: macOS sceglie quella delle preferenze di sistema,
# altrimenti l'inglese (CFBundleDevelopmentRegion).
cp -R Sources/MWBMacHost/Resources/*.lproj "$APP/Contents/Resources/"
# Icona dell'app (Finder, Launchpad, finestre dei permessi, "Informazioni su").
cp Sources/MWBMacHost/Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
LOCALIZATIONS="$(for dir in Sources/MWBMacHost/Resources/*.lproj; do printf '<string>%s</string>' "$(basename "$dir" .lproj)"; done)"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array>$LOCALIZATIONS</array>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>MWB Mac Host connects to the Windows PC on the local network to send it the keyboard and mouse through Mouse Without Borders.</string>
    <key>NSHumanReadableCopyright</key><string>macOS client for PowerToys Mouse Without Borders</string>
</dict>
</plist>
EOF
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> Signing"
if security find-certificate -c "$IDENTITY" >/dev/null 2>&1; then
    SIGN_AS="$IDENTITY"
    echo "    local identity: $IDENTITY"
else
    SIGN_AS="-"
    echo "    ad hoc signature (no \"$IDENTITY\" identity: see scripts/create-signing-cert.sh)"
fi
# Prima l'eseguibile annidato, poi il bundle.
# "replacing existing signature" è normale: il linker firma già ad hoc ogni eseguibile.
codesign --force --sign "$SIGN_AS" --identifier "$BUNDLE_ID.cli" "$APP/Contents/MacOS/mwbmac" 2>&1 | { grep -v "replacing existing signature" || true; }
codesign --force --sign "$SIGN_AS" --identifier "$BUNDLE_ID" "$APP" 2>&1 | { grep -v "replacing existing signature" || true; }
codesign --verify --strict --verbose=1 "$APP"

if $INSTALL; then
    DESTINATION="${MWB_INSTALL_DIR:-/Applications}"
    echo "==> Installing in $DESTINATION"
    pkill -x "$EXECUTABLE" 2>/dev/null || true
    rm -rf "$DESTINATION/$APP_NAME.app"
    cp -R "$APP" "$DESTINATION/"
    APP="$DESTINATION/$APP_NAME.app"
fi

echo "==> Ready: $APP"
if $RUN; then
    open "$APP"
fi
