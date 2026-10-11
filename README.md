# Verc

A media player for Apple silicon and macOS 26+, built with SwiftUI and VLC.

With a subtitle track selected, use Font Size and Y Position to adjust the text. Slider handles appear on hover and stay visible while dragging.

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

## License

[GPL v2.0 only](LICENSE). See [NOTICE](NOTICE) for third-party licenses and source requirements before distribution.
