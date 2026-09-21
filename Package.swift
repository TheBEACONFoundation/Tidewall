// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Tidewall",
    platforms: [.macOS(.v15)],
    dependencies: [
        // Automatic updates, from the app's GitHub releases.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.7.0"),
    ],
    targets: [
        .executableTarget(
            name: "Tidewall",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Tidewall",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreImage"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
                // Sparkle.framework is embedded in Contents/Frameworks.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(
            name: "TidewallTests",
            dependencies: ["Tidewall"],
            path: "Tests/TidewallTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
