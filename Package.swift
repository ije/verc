// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Verc",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Verc", targets: ["Verc"])],
    targets: [
        .target(name: "CVLC", exclude: ["Subtitle.c"], linkerSettings: [.linkedLibrary("dl")]),
        .executableTarget(name: "Verc", dependencies: ["CVLC"], resources: [.copy("Prism.metal")])
    ],
    swiftLanguageModes: [.v6]
)
