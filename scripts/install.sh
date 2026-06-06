#!/bin/bash
# Corvin Installer — copies app to /Applications and removes quarantine
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_SRC="$SCRIPT_DIR/Corvin.app"

if [ ! -d "$APP_SRC" ]; then
    echo "Ошибка: Corvin.app не найден рядом со скриптом"
    exit 1
fi

# Kill running instance
if pgrep -x "Corvin" > /dev/null 2>&1; then
    echo "Закрываю запущенный Corvin..."
    pkill -x "Corvin" 2>/dev/null
    sleep 1
fi

echo "Устанавливаю Corvin в /Applications..."
rm -rf "/Applications/Corvin.app"
cp -R "$APP_SRC" "/Applications/Corvin.app"

# Remove quarantine attribute so Gatekeeper doesn't block it
xattr -cr "/Applications/Corvin.app" 2>/dev/null || true

echo "Запускаю Corvin..."
open "/Applications/Corvin.app"

echo ""
echo "Готово! Corvin установлен."
