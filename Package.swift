// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "fwd",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "FwdCore", targets: ["FwdCore"]),
        .executable(name: "fwd", targets: ["fwd"]),
        .executable(name: "fwd-cli", targets: ["fwd-cli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        .target(name: "FwdCore", dependencies: ["Yams"]),
        .executableTarget(name: "fwd", dependencies: ["FwdCore"]),
        // The `fwd` terminal command, installed in the bundle as Resources/bin/fwd.
        .executableTarget(name: "fwd-cli", dependencies: ["FwdCore"]),
        .testTarget(name: "FwdCoreTests", dependencies: ["FwdCore"]),
    ],
    swiftLanguageModes: [.v5]
)
