// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Flight",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.1"),
        .package(url: "https://github.com/gonzalezreal/textual", from: "0.3.1"),
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "9.11.0"),
    ],
    targets: [
        .target(
            name: "FlightCore",
            path: "Sources/FlightCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The bulk of the app lives in this library so the test target can
        // import it (executableTargets aren't importable). The actual
        // executable below is a thin shim whose only job is to host @main.
        .target(
            name: "FlightApp",
            dependencies: [
                "FlightCore",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Textual", package: "textual"),
            ],
            path: "Sources",
            exclude: ["FlightBench", "FlightCore", "FlightExecutable"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Flight",
            dependencies: [
                "FlightApp",
                .product(name: "Sentry", package: "sentry-cocoa"),
            ],
            path: "Sources/FlightExecutable",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "FlightBench",
            dependencies: ["FlightCore"],
            path: "Sources/FlightBench",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "FlightCoreTests",
            dependencies: ["FlightCore"],
            path: "Tests/FlightCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Hosts NSHostingView-driven tests of the SwiftUI views in
        // FlightApp. Imports FlightApp via @testable so it can construct
        // ChatMessageListView with a synthetic AppState/Worktree without
        // making the entire view layer public.
        .testTarget(
            name: "FlightAppTests",
            dependencies: ["FlightApp", "FlightCore"],
            path: "Tests/FlightAppTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
