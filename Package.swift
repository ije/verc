// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Verc",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Verc", targets: ["Verc"])],
    targets: [
        .target(name: "VLC", exclude: ["Subtitle.c", "Snapshot.c"], linkerSettings: [.linkedLibrary("dl")]),
        .executableTarget(name: "Verc", dependencies: ["VLC"], exclude: ["Prism.metal"], linkerSettings: [.linkedLibrary("sqlite3")])
    ],
    swiftLanguageModes: [.v6]
)
