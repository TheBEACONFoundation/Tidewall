// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Tidewall",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Tidewall",
            path: "Sources/Tidewall",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreImage"),
                .linkedFramework("IOKit"),
                .linkedFramework("ServiceManagement"),
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
