# Verc

A media player for Apple silicon and macOS 26+, built with SwiftUI and VLC.

## Build

Requires Xcode 26+, [Bun](https://bun.sh), and the Apple silicon version of [VLC 3.x](https://www.videolan.org/vlc/download-macosx.html) in `/Applications`.

```sh
bun scripts/build.js
open dist/Verc.app
```

The app includes the VLC runtime. The build checks library dependencies, verifies the app signature, and limits release builds to 50 MiB.
The plugin list is in [scripts/vlc-plugins.json](scripts/vlc-plugins.json).

Use `--debug` for a debug build. To use another VLC copy, set `VERC_VLC_PATH` to its `Contents/MacOS` directory.

## Use

Drop a media file onto the window, or double-click the empty window to open a file.
A new file replaces the current file. Use **Open URL** for a direct media stream.

Right-click for playback speed, repeat, and video size. Use the captions button for audio tracks, subtitles, and subtitle delay.
The playback controls also include volume, Picture in Picture, and full screen.

| Action | Shortcut |
| --- | --- |
| Open media | ⌘O |
| Open URL | ⇧⌘O |
| Add subtitles | ⇧⌘S |
| Play or pause | Space |
| Seek 10 seconds | ← / → |
| Change volume | ↑ / ↓ |
| Mute | M |
| Media information | ⌘I |
| Full screen | ⌃⌘F |
| Picture in Picture | ⇧⌘P |
| Stop | ⌘. |

## License

[GPL v2.0 only](LICENSE). See [NOTICE](NOTICE) for third-party licenses and source requirements before distribution.
