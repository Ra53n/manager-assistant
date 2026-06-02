#!/bin/bash
# Генерирует Resources/AppIcon.icns из render_icon.swift.
set -euo pipefail
cd "$(dirname "$0")"

MASTER="icon_1024.png"
ICONSET="AppIcon.iconset"
OUT_DIR="../Sources/ManagerAssistant/Resources"

echo "▶ Рендер мастер-PNG (1024×1024)…"
swift render_icon.swift "$MASTER"

echo "▶ Сборка iconset…"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# size@1x  size@2x для каждого базового размера
gen() { sips -z "$2" "$2" "$MASTER" --out "$ICONSET/$1" >/dev/null; }
gen icon_16x16.png        16
gen icon_16x16@2x.png     32
gen icon_32x32.png        32
gen icon_32x32@2x.png     64
gen icon_128x128.png     128
gen icon_128x128@2x.png  256
gen icon_256x256.png     256
gen icon_256x256@2x.png  512
gen icon_512x512.png     512
gen icon_512x512@2x.png 1024

echo "▶ iconutil → .icns…"
mkdir -p "$OUT_DIR"
iconutil -c icns "$ICONSET" -o "$OUT_DIR/AppIcon.icns"

rm -rf "$ICONSET" "$MASTER"
echo "✅ Готово: $OUT_DIR/AppIcon.icns"
