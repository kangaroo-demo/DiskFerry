// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiskFerry",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "DiskFerryCore", targets: ["DiskFerryCore"]),
        .executable(name: "DiskFerry", targets: ["DiskFerryApp"]),
        // A distinct build name avoids collisions with DiskFerry on macOS case-insensitive volumes.
        .executable(name: "diskferry-cli", targets: ["DiskFerryCLI"]),
    ],
    targets: [
        .target(name: "DiskFerryCore"),
        .executableTarget(name: "DiskFerryApp", dependencies: ["DiskFerryCore"]),
        .executableTarget(name: "DiskFerryCLI", dependencies: ["DiskFerryCore"]),
        .testTarget(name: "DiskFerryCoreTests", dependencies: ["DiskFerryCore"]),
        .testTarget(name: "DiskFerryAppTests", dependencies: ["DiskFerryApp"]),
    ]
)
