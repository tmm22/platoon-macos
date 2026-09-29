// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Platoon",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Platoon", targets: ["PlatoonApp"]),
        .executable(name: "platoon-headless", targets: ["platoon-headless"]),
        .library(name: "PlatoonCore", targets: ["PlatoonCore"]),
    ],
    targets: [
        .target(name: "PlatoonCore", swiftSettings: [.unsafeFlags(["-Ounchecked"])]),
        .executableTarget(name: "PlatoonApp", dependencies: ["PlatoonCore"]),
        .executableTarget(name: "platoon-headless", dependencies: ["PlatoonCore"]),
        .testTarget(name: "PlatoonCoreTests", dependencies: ["PlatoonCore"]),
    ]
)
