#!/bin/bash
# Пересобрать, переустановить и перезапустить AudioMixer.
#
# Ad-hoc подпись: сертификата разработчика нет, для локального запуска не нужен.
# CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO убирает отладочный get-task-allow.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-Release}"

echo "==> Сборка ($CONFIG)"
xcodebuild -project AudioMixer.xcodeproj -scheme AudioMixer \
  -configuration "$CONFIG" -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath ./.build \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual \
  CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER="" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  build 2>&1 | grep -E "error:|warning:|BUILD" | grep -v appintents || true

APP=".build/Build/Products/$CONFIG/AudioMixer.app"
[ -d "$APP" ] || { echo "Сборка не удалась: $APP не найден"; exit 1; }

echo "==> Перезапуск"
# Корректный выход, а не pkill: приложение успевает сбросить громкости
# в UserDefaults (запись дебаунсится), иначе настройки теряются при пересборке.
if pgrep -x AudioMixer >/dev/null; then
    osascript -e 'quit app "AudioMixer"' 2>/dev/null || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x AudioMixer >/dev/null || break
        sleep 0.3
    done
    pkill -x AudioMixer 2>/dev/null || true
fi
sleep 0.5
rm -rf /Applications/AudioMixer.app
cp -R "$APP" /Applications/
open /Applications/AudioMixer.app

sleep 2
if pgrep -x AudioMixer >/dev/null; then
    echo "==> Запущено (pid $(pgrep -x AudioMixer)). Иконка в строке меню."
else
    echo "==> Не запустилось. Логи: log show --predicate 'process == \"AudioMixer\"' --last 2m --info"
    exit 1
fi
