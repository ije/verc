# Verc

A media player for Apple silicon and macOS 26+, built with SwiftUI and VLC.

## Build

Requires Xcode 26+ on an Apple silicon Mac.
The first build downloads VLC 3.0.24 and verifies its checksum. The app includes the VLC runtime.

```sh
./scripts/build.sh
open dist/Verc.app
```

Use `--debug` for a debug build.

The build verifies the app signature and limits release builds to 50 MiB.
The plugin list is in [scripts/vlc-plugins.json](scripts/vlc-plugins.json).

## Use

Drop media files or a folder onto the window. Double-click the empty window to open files or a folder.

Multiple files form a playlist. A folder adds its audio and video files in filename order.
Each new selection replaces the playlist. Playback continues with the next item unless repeat is on.

Use the playlist button to select an item. Press Escape or click outside the playlist to close it.
Use **Open URL** for a direct media stream.

Right-click for playback speed, repeat, and video size. Use the captions button for audio tracks and subtitles.
The playback controls also include volume, Picture in Picture, and full screen.

| Action | Shortcut |
| --- | --- |
| Open media | ⌘O |
| Open URL | ⇧⌘O |
| Add subtitles | ⇧⌘S |
| Play or pause | Space |
| Seek 10 seconds | ← / → |
| Change volume (playlist closed) | ↑ / ↓ |
| Previous or next media (playlist open) | ↑ / ↓ |
| Mute | M |
| Media information | ⌘I |
| Full screen | ⌃⌘F |
| Picture in Picture | ⇧⌘P |
| Stop | ⌘. |

## License

[GPL v2.0 only](LICENSE). See [NOTICE](NOTICE) for third-party licenses and source requirements before distribution.
