// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Verc",
  platforms: [.macOS("26.0")],
  products: [.executable(name: "Verc", targets: ["Verc"])],
  dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1"),
  ],
  targets: [
    .target(
      name: "VLC", exclude: ["Subtitle.c", "Snapshot.c"], linkerSettings: [.linkedLibrary("dl")]),
    .executableTarget(
      name: "Verc", dependencies: ["VLC", .product(name: "Sparkle", package: "Sparkle")], exclude: ["Prism.metal"],
      linkerSettings: [.linkedLibrary("sqlite3")]),
  ],
  swiftLanguageModes: [.v6]
)
