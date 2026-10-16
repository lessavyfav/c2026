// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "C6",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "C6Core", targets: ["C6Core"]),
        .executable(name: "C2026App", targets: ["C6App"]),
        .executable(name: "c2026", targets: ["c6cli"]),
    ],
    targets: [
        .target(
            name: "C6Core",
            linkerSettings: [.linkedFramework("CoreMIDI"), .linkedFramework("AudioToolbox")]
        ),
        .executableTarget(name: "C6App", dependencies: ["C6Core"]),
        .executableTarget(name: "c6cli", dependencies: ["C6Core"]),
        .testTarget(name: "C6CoreTests", dependencies: ["C6Core"]),
    ],
    swiftLanguageModes: [.v5]
)
