// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CloudDiskKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        
        .library(
            name: "CloudDiskKit",
            type: .static,
            targets: ["CloudDiskKit"]
        )
    ],
    targets: [
        .target(
            name: "CloudDiskKit",
            swiftSettings: [
                // Matches SWIFT_VERSION = 5.0 of the app and extension targets. The
                // File Provider protocols hand back non-Sendable completion handlers,
                // so Swift 6 strict mode would fight the bridged APIs here.
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "CloudDiskKitTests",
            dependencies: ["CloudDiskKit"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
