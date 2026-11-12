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
- `Sources/Verc/Favorites.swift`, `Library.swift`, and `LibraryDatabase.swift`: library items, the `FavoritePages` store, file import, and the SQLite database.
- `Sources/Verc/StartPage.swift`: start page, library, and item editor views.
- `Sources/Verc/PictureInPicture.swift` and `SubtitleSurface.swift`: floating window and subtitle layout.
- `Sources/Verc/PrismBackground.swift`, `PrismScene.swift`, and `Prism.metal`: Metal renderer, scene geometry, and shaders.
- `Sources/VLC/`: C bridge and subtitle plugin. Public headers are in `include/`.
- `Resources/Info.plist`: app metadata and file extensions that `MediaItem` reads.
- `scripts/build.sh` and `scripts/vlc-plugins.json`: app bundle assembly and VLC plugin selection.
- `Website/`: Cloudflare Worker for TMDB search and episode data.

## Code constraints

- Follow the existing four-space indentation and compact Swift and C style.
- Keep shared playback state in the `@MainActor @Observable` `PlayerModel`.
- Send playback commands through the serial VLC queue. Keep libVLC startup and metadata work off the main thread.
- Preserve media IDs in snapshots to reject updates from previous media.
- Wait for metadata work before you destroy the VLC handle.
- Reuse `PlayerModel.videoView` between the main window and Picture in Picture.
- Keep the C bridge compatible with the bundled VLC runtime. Do not unload VLC libraries after successful initialization.
- Keep `Vendor/VLC/include/` consistent with the VLC version in the build script.
- Load app resources from `Bundle.main`, and copy them into `Contents/Resources` in the build script. Do not use SwiftPM resources or `Bundle.module`.
- Use Liquid Glass for UI.
- Keep Swift GPU buffer layouts identical to their Metal structs.
- Reuse GPU resources. Preserve animation suspension for hidden or inactive windows and support for Reduce Motion.
- Preserve third-party notices. Refer to `NOTICE` for distribution requirements.
- Do not commit generated files from `.build/` or `dist/`.
- Do not update readme unless the user ask for.

## macOS build and checks

Use Xcode 26+ and the Metal Toolchain on an Apple silicon Mac. Install the toolchain with `xcodebuild -downloadComponent MetalToolchain`. Run commands from the repository root.

```sh
./scripts/build.sh --debug
open dist/Verc.app
```

The first build downloads VLC 3.0.24 and verifies its checksum. The script compiles the subtitle plugin and `Prism.metal` separately from SwiftPM.
The script writes the VLC plugin cache after it signs the plugins. A later change to a plugin makes libVLC ignore the cache and open every plugin at launch.
The app needs the bundled VLC runtime and resources. A plain `swift build` does not assemble the app bundle.

For release or bundle changes, run `./scripts/build.sh`.
The script checks ARM64 libraries, bundled dependencies, and the app signature. Release builds also enforce a 50 MiB limit.

The macOS app has no automated test target. After app code changes, build the app and do manual checks for the affected behavior.
For documentation-only changes, check the diff and referenced paths. No app build is necessary.

## Website

`Website/` uses TypeScript ES modules and Cloudflare Workers.

- `index.ts`: the `POST /tmdb` endpoint, request validation, TMDB requests, and response cache.
- `cloudflare.config.ts`: Worker name, entrypoint, compatibility date, and the `verc.download` custom domain. The Cache API does not work on `workers.dev`.
- `package.json`: commands that use the `cf` CLI. `cf` builds with the `wrangler` dependency.
- `index.test.ts`: Worker tests using `bun:test`.
- `.env.example`: local environment variables. The Worker uses `TMDB_API_READ_ACCESS_TOKEN` for authentication.

- Use four-space indentation and the current TypeScript style.
- Keep response fields compatible with `Sources/Verc/TMDB.swift`.
- Keep TMDB credentials in the Worker environment. Do not include secrets in source files, responses, or logs.
- Preserve request validation, the 4096-byte body limit, CORS headers, and the eight-second timeout for TMDB requests.
- Cache successful responses for one hour. Keep cache keys separate for each search or episode request.
- Preserve the `Retry-After` header on TMDB rate-limit errors. Do not cache error responses.
- Do not commit local `.env` files or generated `.cloudflare/` files.

Run commands from `Website/`. The scripts require the `cf` CLI on `PATH`.

```sh
bun install
bun run dev
bun run build
bun test
```

After Worker changes, check search, episode lookup, invalid requests, CORS, cache behavior, and upstream errors.
Use `bun run deploy` to deploy the Worker when the task requires deployment.
