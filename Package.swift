// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "Flight",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Flight",
            path: "Sources"
        )
    ]
)
