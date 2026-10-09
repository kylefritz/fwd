// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "fwd",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "FwdCore", targets: ["FwdCore"]),
        .executable(name: "fwd", targets: ["fwd"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        .target(name: "FwdCore", dependencies: ["Yams"]),
        .executableTarget(name: "fwd", dependencies: ["FwdCore"]),
        .testTarget(name: "FwdCoreTests", dependencies: ["FwdCore"]),
    ],
    swiftLanguageModes: [.v5]
)
