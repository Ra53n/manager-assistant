#!/bin/bash
# Собирает release-бинарь и упаковывает его в ManagerAssistant.app,
# чтобы приложение запускалось как обычное Mac-приложение (с окном и в Dock).
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="ManagerAssistant"
APP_DIR="${APP_NAME}.app"
BIN_NAME="ManagerAssistant"

# Если лицензия Xcode не принята (`sudo xcodebuild -license accept`),
# можно собрать тулчейном Command Line Tools, раскомментировав строку:
# export DEVELOPER_DIR=/Library/Developer/CommandLineTools

echo "▶ Сборка (release)…"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)/${BIN_NAME}"

echo "▶ Упаковка в ${APP_DIR}…"
rm -rf "${APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BIN_PATH}" "${APP_DIR}/Contents/MacOS/${BIN_NAME}"

# Ресурс-бандл SwiftPM (AppIcon.icns и др.): без него Bundle.module в
# AppDelegate.loadAppIcon() делает fatalError на старте .app. Аксессор
# executable-таргета ищет его в Bundle.main.bundleURL — то есть в КОРНЕ .app
# (не в Contents/Resources!); фолбэк на путь .build у установленного
# приложения не работает (TCC не пускает в ~/Desktop).
RES_BUNDLE="$(swift build -c release --show-bin-path)/${APP_NAME}_${APP_NAME}.bundle"
if [ -d "${RES_BUNDLE}" ]; then
    rm -rf "${APP_DIR}/${APP_NAME}_${APP_NAME}.bundle"
    cp -R "${RES_BUNDLE}" "${APP_DIR}/"
fi

# Иконка приложения (если собрана).
ICON_SRC="Sources/ManagerAssistant/Resources/AppIcon.icns"
if [ -f "${ICON_SRC}" ]; then
    cp "${ICON_SRC}" "${APP_DIR}/Contents/Resources/AppIcon.icns"
fi

cat > "${APP_DIR}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Manager assistant</string>
    <key>CFBundleDisplayName</key>
    <string>Manager assistant</string>
    <key>CFBundleExecutable</key>
    <string>${BIN_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.manager-assistant</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

echo "✅ Готово: ${APP_DIR}"
echo "   Запуск:  open \"${APP_DIR}\""
