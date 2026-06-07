#!/bin/bash
# Собирает приложение и устанавливает его в /Applications,
# чтобы оно было в Spotlight / Launchpad / Dock как обычная программа.
set -euo pipefail
cd "$(dirname "$0")"

# Сборка тулчейном Command Line Tools (не требует принятия лицензии Xcode).
export DEVELOPER_DIR=/Library/Developer/CommandLineTools

echo "▶ Сборка и упаковка .app…"
bash run.sh

DEST="/Applications/ManagerAssistant.app"
echo "▶ Установка в ${DEST}…"
rm -rf "${DEST}"
cp -R "ManagerAssistant.app" "${DEST}"

# Снять карантин (на случай, если появится) и обновить Launch Services,
# чтобы иконка и Spotlight сразу подхватили приложение.
xattr -dr com.apple.quarantine "${DEST}" 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "${DEST}" 2>/dev/null || true

echo "✅ Установлено: ${DEST}"
echo "   Запуск: Spotlight (⌘Space → «Manager assistant») или папка «Программы»."
