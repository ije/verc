# AGENTS.md

## Philosophy

Less is more. Keep code concise and changes focused. Performance matters.

- Keep one-use logic inline. Extract helpers only for shared logic.
- Add comments only to warn about constraints or unexpected behavior.
- Use direct, plain language in documentation and comments.

## Project

Verc is a media player for Apple silicon and macOS 26+. It uses Swift 6, SwiftUI, AppKit, Metal, and libVLC.

- `Sources/Verc/VercApp.swift`: app lifecycle, windows, menus, and keyboard shortcuts.
- `Sources/Verc/Playback.swift`: media types, playlists, `PlayerModel`, and the VLC queue wrapper.
- `Sources/Verc/ContentView.swift`: player interface and the shared video surface.
- `Sources/Verc/PictureInPicture.swift` and `SubtitleSurface.swift`: floating window and subtitle layout.
- `Sources/Verc/PrismBackground.swift`, `PrismScene.swift`, and `Prism.metal`: Metal renderer, scene geometry, and shaders.
- `Sources/CVLC/`: C bridge and subtitle plugin. Public headers are in `include/`.
- `Resources/Info.plist`: app metadata and file extensions that `MediaItem` reads.
- `scripts/build.sh` and `scripts/vlc-plugins.json`: app bundle assembly and VLC plugin selection.

## Code constraints

- Follow the existing four-space indentation and compact Swift and C style.
- Keep shared playback state in the `@MainActor @Observable` `PlayerModel`.
- Send playback commands through the serial VLC queue. Keep libVLC startup and metadata work off the main thread.
- Preserve media IDs in snapshots to reject updates from previous media.
- Wait for metadata work before you destroy the VLC handle.
- Reuse `PlayerModel.videoView` between the main window and Picture in Picture.
- Keep the C bridge compatible with the bundled VLC runtime. Do not unload VLC libraries after successful initialization.
- Keep `Vendor/VLC/include/` consistent with the VLC version in the build script.
- Keep Swift GPU buffer layouts identical to their Metal structs.
- Reuse GPU resources. Preserve animation suspension for hidden or inactive windows and support for Reduce Motion.
- Preserve third-party notices. Refer to `NOTICE` for distribution requirements.
- Do not commit generated files from `.build/` or `dist/`.

## Build and checks

Use Xcode 26+ on an Apple silicon Mac. Run commands from the repository root.

```sh
./scripts/build.sh --debug
open dist/Verc.app
```

The first build downloads VLC 3.0.24 and verifies its checksum. The script compiles the subtitle plugin separately from SwiftPM.
The app needs the bundled VLC runtime and resources. A plain `swift build` does not assemble the app bundle.

For release or bundle changes, run `./scripts/build.sh`.
The script checks ARM64 libraries, bundled dependencies, and the app signature. Release builds also enforce a 50 MiB limit.

There is no automated test target. After code changes, build the app and do manual checks for the affected behavior.
For documentation-only changes, check the diff and referenced paths. No app build is necessary.
