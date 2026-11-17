#!/bin/bash
# Controlla le traduzioni dell'app: ogni testo passato a L("…") nel codice deve avere una
# traduzione in ogni lingua diversa dall'inglese, e ogni file .strings deve essere valido.
# Esce con errore se manca qualcosa; build-app.sh lo esegue prima di costruire il bundle.
#
# Uso: scripts/check-localization.sh
set -euo pipefail

cd "$(dirname "$0")/.."

SOURCES="Sources/MWBMacHost"
RESOURCES="$SOURCES/Resources"
# Chiavi usate in modo indiretto (L(nome) con un nome da una tabella): nomi dei tasti
# della scorciatoia di emergenza in Hotkey.keyNames che richiedono traduzione.
EXTRA_KEYS=$'Space\nReturn\nTab'

status=0
for file in "$RESOURCES"/*.lproj/*.strings; do
    plutil -lint -s "$file" || status=1
done

keys="$( { grep -ho 'L("[^"]*"' "$SOURCES"/*.swift | sed 's/^L("//; s/"$//'; echo "$EXTRA_KEYS"; } | sort -u)"

for dir in "$RESOURCES"/*.lproj; do
    language="$(basename "$dir" .lproj)"
    [ "$language" = "en" ] && continue
    defined="$(plutil -convert json -o - "$dir/Localizable.strings" | /usr/bin/python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)))' | sort -u)"
    missing="$(comm -23 <(echo "$keys") <(echo "$defined"))"
    unused="$(comm -13 <(echo "$keys") <(echo "$defined"))"
    if [ -n "$missing" ]; then
        echo "[$language] traduzioni mancanti:" >&2
        echo "$missing" | sed 's/^/    /' >&2
        status=1
    fi
    if [ -n "$unused" ]; then
        echo "[$language] chiavi non più usate nel codice:" >&2
        echo "$unused" | sed 's/^/    /' >&2
    fi
done

[ $status -eq 0 ] && echo "Localizzazione: tutte le chiavi tradotte."
exit $status
