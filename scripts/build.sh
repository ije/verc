#!/bin/bash
set -euo pipefail

fail() {
  printf '%s\n' "$*" >&2
  exit 1
}

cd "$(dirname "$0")/.."
root=$PWD
config=release
for arg in "$@"; do
  case "$arg" in
    --debug) config=debug ;;
    *) fail "Unknown argument: $arg. Use --debug for a debug build." ;;
  esac
done
[[ $(uname -sm) == "Darwin arm64" ]] || fail "Build Verc on an Apple silicon Mac."

app="$root/.build/Verc.app"
output="$root/dist/Verc.app"
vlc_version=3.0.24
runtime="$root/.build/vlc-$vlc_version-arm64"
if [[ ! -d $runtime ]]; then
  mkdir -p "$root/.build"
  download=$(mktemp -d "$root/.build/vlc.XXXXXX")
  mounted=false
  trap 'if ! $mounted || hdiutil detach "$download/mount" -quiet; then rm -rf "$download"; fi' EXIT
  printf 'Downloading VLC %s (ARM64)...\n' "$vlc_version"
  curl --fail --location --silent --show-error --retry 3 \
    "https://download.videolan.org/vlc/$vlc_version/macosx/vlc-$vlc_version-arm64.dmg" \
    -o "$download/vlc.dmg"
  printf '%s  %s\n' 64a89d93cdd30b0e97131743e246373db82d6826ea882d265d46d74b136da2b7 "$download/vlc.dmg" \
    | shasum -a 256 -c - || fail "VLC download checksum verification failed."
  hdiutil attach "$download/vlc.dmg" -readonly -nobrowse -mountpoint "$download/mount" -quiet
  mounted=true
  mkdir "$download/runtime"
  cp -R "$download/mount/VLC.app/Contents/MacOS/lib" "$download/mount/VLC.app/Contents/MacOS/plugins" "$download/runtime/"
  hdiutil detach "$download/mount" -quiet
  mounted=false
  mv "$download/runtime" "$runtime"
  rm -rf "$download"
  trap - EXIT
fi
export CLANG_MODULE_CACHE_PATH="$root/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
plugins=$(plutil -convert xml1 -o - scripts/vlc-plugins.json | sed -n 's:.*<string>\(.*\)</string>.*:\1:p')
[[ -z $(printf '%s\n' "$plugins" | sort | uniq -d) ]] || fail "Duplicate VLC plugin in the build profile."
plugin_count=0
while IFS= read -r name; do
  [[ -f "$runtime/plugins/lib${name}_plugin.dylib" ]] || fail "Required VLC plugin is missing: $name"
  plugin_count=$((plugin_count + 1))
done <<< "$plugins"

swift=(swift build --disable-sandbox --cache-path .build/cache -c "$config" --arch arm64)
if [[ $config == release ]]; then swift+=(-Xswiftc -Osize); fi
"${swift[@]}" || fail "Swift build failed."
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
location=$("${swift[@]}" --show-bin-path) || fail "Cannot locate the compiled app."
cp "$location/Verc" "$app/Contents/MacOS/Verc"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp Resources/app.icns Resources/Verc.png Resources/VercGlass.png Resources/VercPrism.png Resources/VercLibrary.icns Resources/TMDB.svg Resources/LineMD-LICENSE.txt Resources/Vgpu-LICENSE.txt LICENSE NOTICE "$app/Contents/Resources/"
xcrun -sdk macosx metal -mmacos-version-min=26.0 Sources/Verc/Prism.metal -o "$app/Contents/Resources/default.metallib" \
  || fail "Cannot compile the Metal shaders. Install the Metal Toolchain: xcodebuild -downloadComponent MetalToolchain"

destination="$app/Contents/Frameworks/VLC"
mkdir -p "$destination/plugins"
cp -R "$runtime/lib" "$destination/lib"
while IFS= read -r name; do
  cp "$runtime/plugins/lib${name}_plugin.dylib" "$destination/plugins/"
done <<< "$plugins"
clang -dynamiclib -arch arm64 -mmacosx-version-min=26.0 -Os \
  -D__PLUGIN__ -DMODULE_NAME=vercsub '-DMODULE_STRING="vercsub"' \
  -I Vendor/VLC/include -I Sources/VLC/include -undefined dynamic_lookup \
  -install_name @rpath/libvercsub_plugin.dylib \
  Sources/VLC/Subtitle.c -o "$destination/plugins/libvercsub_plugin.dylib" \
  || fail "Cannot build the subtitle layout plugin."
clang -dynamiclib -arch arm64 -mmacosx-version-min=26.0 -Os \
  -D__PLUGIN__ -DMODULE_NAME=vercsnapshot '-DMODULE_STRING="vercsnapshot"' \
  -I Vendor/VLC/include -undefined dynamic_lookup \
  -install_name @rpath/libvercsnapshot_plugin.dylib \
  Sources/VLC/Snapshot.c -o "$destination/plugins/libvercsnapshot_plugin.dylib" \
  || fail "Cannot build the snapshot conversion plugin."

while IFS= read -r -d '' file; do
  archs=$(lipo -archs "$file") || fail "ARM64 is missing: $file"
  [[ " $archs " == *" arm64 "* ]] || fail "ARM64 is missing: $file"
  if [[ $archs != arm64 ]]; then
    lipo "$file" -thin arm64 -output "$file" || fail "Cannot remove unused architectures: $file"
  fi
  dependencies=$(otool -L "$file") || fail "Cannot inspect dependencies: $file"
  while IFS= read -r dependency; do
    case "$dependency" in
      /System/Library/*|/usr/lib/*) continue ;;
      @rpath/*) [[ ! -f "$destination/lib/${dependency#@rpath/}" ]] || continue ;;
    esac
    fail "Unbundled dependency in $file: $dependency"
  done < <(printf '%s\n' "$dependencies" | sed '1,2d; s/^[[:space:]]*//; s/ (compatibility version.*//')
done < <(find "$destination" -type f -name '*.dylib' -print0)

if [[ $config == release ]]; then
  strip -S -x "$app/Contents/MacOS/Verc" || fail "Cannot strip the release executable."
fi
cp scripts/vlc-plugins.json "$app/Contents/Resources/VLC-plugins.json"
cat > "$app/Contents/Resources/VLC-runtime.txt" <<EOF
Selected playback runtime from $runtime
$plugin_count VLC plugins plus Verc's subtitle layout and snapshot conversion plugins. No VLC desktop UI, extensions, translations, capture, casting, or dedicated encoder modules.
Include corresponding VLC and dependency sources when you distribute this bundle. See NOTICE.
EOF
sign=(codesign --force --sign "${SIGNING_IDENTITY:--}")
if [[ ${SIGNING_IDENTITY:--} != - ]]; then
  sign+=(--timestamp --options runtime)
fi
while IFS= read -r -d '' file; do
  "${sign[@]}" "$file" || fail "Cannot sign library: $file"
done < <(find "$destination" -type f -name '*.dylib' -print0)
"${sign[@]}" "$app" || fail "Cannot sign the app."
codesign --verify --deep --strict "$app" || fail "App signature verification failed."
bytes=$(find "$app" -type f -exec stat -f '%z' {} + | awk '{ total += $1 } END { printf "%.0f", total }')
if [[ $config == release && $bytes -gt $((50 * 1048576)) ]]; then
  fail "The release exceeds 50 MiB. Review the playback plugin profile before distribution."
fi
mkdir -p "$root/dist"
rm -rf "$output"
mv "$app" "$output"
size=$(awk -v bytes="$bytes" 'BEGIN { printf "%.2f", bytes / 1048576 }')
printf '\n%s\nStandalone · ARM64 · macOS 26+ · %s MiB total · %s playback plugins\n' "$output" "$size" "$((plugin_count + 2))"
