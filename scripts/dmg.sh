#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
root=$PWD
app="$root/dist/Verc.app"
[[ -d $app ]] || { printf 'Run ./scripts/build.sh first.\n' >&2; exit 1; }
codesign --verify --deep --strict "$app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
output="$root/dist/Verc-$version-arm64.dmg"
mkdir -p "$root/.build"
work=$(mktemp -d "$root/.build/dmg.XXXXXX")
trap 'rm -rf "$work"' EXIT

if command -v uv >/dev/null; then
  dmgbuild=(uv tool run --from dmgbuild==1.6.7 dmgbuild)
elif command -v dmgbuild >/dev/null; then
  dmgbuild=(dmgbuild)
else
  printf 'Install uv or dmgbuild to create the DMG.\n' >&2
  exit 1
fi
CLANG_MODULE_CACHE_PATH="$root/.build/ModuleCache" swift scripts/dmg-background.swift "$work"
cat > "$work/settings.py" <<'PYTHON'
format = "ULFO"
files = [defines["app"]]
symlinks = {"Applications": "/Applications"}
background = defines["background"]
window_rect = ((200, 200), (680, 340))
default_view = "icon-view"
icon_size = 160
text_size = 13
icon_locations = {"Verc.app": (160, 178), "Applications": (520, 178)}
PYTHON

"${dmgbuild[@]}" -s "$work/settings.py" -D "app=$app" -D "background=$work/background.tiff" Verc "$work/Verc.dmg"
if [[ ${SIGNING_IDENTITY:--} != - ]]; then
  codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$work/Verc.dmg"
fi
hdiutil verify "$work/Verc.dmg"
mv "$work/Verc.dmg" "$output"
cp "$work/background.png" "$root/dist/Verc-DMG-background.png"
printf '\n%s\n' "$output"
