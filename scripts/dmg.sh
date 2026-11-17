#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
root=$PWD
app="$root/dist/Verc.app"
[[ -d $app ]] || { printf 'Run ./scripts/build.sh first.\n' >&2; exit 1; }
codesign --verify --deep --strict "$app"
output="$root/dist/Verc.dmg"
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
# Gatekeeper rejects a DMG without a stapled notarization ticket on other Macs.
if [[ -n ${NOTARY_PROFILE:-} ]]; then
  credentials=(--keychain-profile "$NOTARY_PROFILE")
  if [[ -n ${NOTARY_KEYCHAIN:-} ]]; then credentials+=(--keychain "$NOTARY_KEYCHAIN"); fi
  xcrun notarytool submit "$work/Verc.dmg" "${credentials[@]}" --wait --timeout 30m
  xcrun stapler staple "$work/Verc.dmg"
  xcrun stapler validate "$work/Verc.dmg"
else
  printf 'NOTARY_PROFILE is not set, so this DMG is not notarized. Use it only on this Mac.\n' >&2
fi
mv "$work/Verc.dmg" "$output"
# GPL: publish the VLC source next to every DMG. NOTICE names this file and checksum.
source="$root/.build/vlc-3.0.24.tar.xz"
if [[ ! -f $source ]]; then
  curl --fail --location --silent --show-error --retry 3 \
    https://download.videolan.org/pub/videolan/vlc/3.0.24/vlc-3.0.24.tar.xz -o "$work/vlc.tar.xz"
  mv "$work/vlc.tar.xz" "$source"
fi
printf '%s  %s\n' e7cab503d1d7d5849b89d2cf0e1ee60d0ef6d012407791b644b9cfc0cc225fdf "$source" | shasum -a 256 -c - >/dev/null
cp "$source" "$root/dist/"
printf '\n%s\n%s\n' "$output" "$root/dist/vlc-3.0.24.tar.xz"
