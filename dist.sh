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

# Фон окна рисуется генератором (Tools/GenerateDMGBackground.swift); позиции
# иконок ниже обязаны совпадать с теми, что заложены в картинку.
#
# Иконки тома (.VolumeIcon.icns) в стейдже намеренно нет: Finder удаляет этот
# файл, как только открывает окно тома. Она кладётся ниже, уже после того, как
# Finder закончил с раскладкой.
mkdir -p .dmgstage/.background
cp Resources/DMG/background.tiff .dmgstage/.background/

# Раскладку Finder можно задать только в разрешённом на запись образе:
# .DS_Store с положением иконок пишется внутрь тома. Поэтому сначала UDRW,
# потом сжатие в UDZO.
RW=".dmgstage-rw.dmg"
rm -f "$RW"
SIZE_MB=$(( $(du -sm .dmgstage | cut -f1) + 20 ))
hdiutil create -volname "AudioMixer" -srcfolder .dmgstage -fs HFS+ \
  -format UDRW -size "${SIZE_MB}m" -ov "$RW" >/dev/null

# Точку монтирования берём из вывода hdiutil, а не подставляем /Volumes/AudioMixer:
# если том с таким именем уже смонтирован, система примонтирует как «AudioMixer 1»,
# и все дальнейшие действия уйдут в чужой образ.
MOUNT=$(hdiutil attach "$RW" -readwrite -noverify -noautoopen | grep -o '/Volumes/.*$' | tail -1)
[ -n "$MOUNT" ] || { echo "    не удалось смонтировать $RW"; exit 1; }
VOLUME=$(basename "$MOUNT")

# Finder управляется через Apple Events, а это отдельное разрешение TCC.
# Если его нет, образ всё равно соберётся — просто с видом по умолчанию,
# поэтому шаг не обязателен для успеха сборки.
#
# Проходов два, и это не лишняя осторожность: если задавать фон в том же
# проходе, что и размеры с позициями, Finder на macOS 26 записывает .DS_Store
# без ссылки на картинку. Отдельным проходом — записывает стабильно.
finder_layout() {
  osascript - "$VOLUME" >/dev/null 2>&1 <<'APPLESCRIPT'
on run argv
  tell application "Finder"
    tell disk (item 1 of argv)
      open
      set current view of container window to icon view
      set toolbar visible of container window to false
      set statusbar visible of container window to false
      set the bounds of container window to {240, 140, 880, 540}
      set viewOptions to the icon view options of container window
      set arrangement of viewOptions to not arranged
      set icon size of viewOptions to 96
      set text size of viewOptions to 12
      set label position of viewOptions to bottom
      set shows item info of viewOptions to false
      set position of item "AudioMixer.app" of container window to {170, 190}
      set position of item "Applications" of container window to {470, 190}
      update without registering applications
      delay 1
      close
    end tell
  end tell
end run
APPLESCRIPT
}

finder_background() {
  osascript - "$VOLUME" >/dev/null 2>&1 <<'APPLESCRIPT'
on run argv
  tell application "Finder"
    tell disk (item 1 of argv)
      open
      set viewOptions to the icon view options of container window
      set background picture of viewOptions to file ".background:background.tiff"
      update without registering applications
      delay 1
      close
    end tell
  end tell
end run
APPLESCRIPT
}

if finder_layout && sleep 1 && finder_background; then
  sleep 2
  # Доверять коду возврата osascript нельзя: он возвращает 0 и тогда, когда
  # Finder принял команду, но ничего не записал. Смотрим сам .DS_Store.
  LAYOUT_OK=$(strings "$MOUNT/.DS_Store" 2>/dev/null | grep -c "Iloc" || true)
  BG_OK=$(strings "$MOUNT/.DS_Store" 2>/dev/null | grep -c "backgroundImageAlias" || true)
  echo "    вид окна: позиции — $([ "$LAYOUT_OK" -ge 2 ] && echo ok || echo НЕ ЗАПИСАНЫ), фон — $([ "$BG_OK" -ge 1 ] && echo ok || echo НЕ ЗАПИСАН)"
else
  echo "    вид окна: пропущен (Finder не отдал управление — нужен доступ к автоматизации)"
fi

# Иконка тома — последним действием, чтобы Finder её уже не тронул.
cp "$APP/Contents/Resources/AppIcon.icns" "$MOUNT/.VolumeIcon.icns"
SetFile -a C "$MOUNT" 2>/dev/null || true

sync
hdiutil detach "$MOUNT" >/dev/null || hdiutil detach "$MOUNT" -force >/dev/null

hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -ov -o dist/AudioMixer.dmg >/dev/null
rm -f "$RW"
rm -rf .dmgstage

echo "==> Готово: dist/AudioMixer.dmg ($(du -h dist/AudioMixer.dmg | cut -f1))"
