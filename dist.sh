#!/bin/bash
# Собрать раздаваемый DMG: dist/AudioMixer.dmg
#
# Отличия от run.sh (тот только для локальной итерации):
#   ONLY_ACTIVE_ARCH=NO            — universal, иначе выйдет только arm64 без Intel
#   CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO — убирает отладочный get-task-allow,
#                                    который отклонила бы нотаризация
set -euo pipefail
cd "$(dirname "$0")"

echo "==> Сборка Release (universal)"
xcodebuild -project AudioMixer.xcodeproj -scheme AudioMixer \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath ./.build \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual \
  CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES \
  DEVELOPMENT_TEAM="" PROVISIONING_PROFILE_SPECIFIER="" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO ONLY_ACTIVE_ARCH=NO \
  build 2>&1 | grep -E "error:|BUILD" | grep -v appintents || true

APP=".build/Build/Products/Release/AudioMixer.app"
[ -d "$APP" ] || { echo "Сборка не удалась"; exit 1; }

echo "==> Проверки"
lipo -info "$APP/Contents/MacOS/AudioMixer" | sed 's/^/    /'
codesign --verify --strict "$APP" && echo "    подпись: ok"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "get-task-allow" \
    && { echo "    ОШИБКА: в сборке остался get-task-allow"; exit 1; } \
    || echo "    entitlements: ok"

echo "==> Упаковка DMG"
rm -rf .dmgstage && mkdir -p .dmgstage dist
cp -R "$APP" .dmgstage/
ln -s /Applications .dmgstage/Applications
hdiutil create -volname "AudioMixer" -srcfolder .dmgstage -ov -format UDZO dist/AudioMixer.dmg >/dev/null
rm -rf .dmgstage

echo "==> Готово: dist/AudioMixer.dmg ($(du -h dist/AudioMixer.dmg | cut -f1))"
