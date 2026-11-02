// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FreeMyTVKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "FreeMyTVKit", targets: ["FreeMyTVKit"]),
    ],
    targets: [
        .target(
            name: "FreeMyTVKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "FreeMyTVKitTests",
            dependencies: ["FreeMyTVKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
