// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Verc",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Verc", targets: ["Verc"])],
    targets: [
        .target(name: "CVLC", linkerSettings: [.linkedLibrary("dl")]),
        .executableTarget(name: "Verc", dependencies: ["CVLC"])
    ],
    swiftLanguageModes: [.v6]
)
