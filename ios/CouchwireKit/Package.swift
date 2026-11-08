// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CouchwireKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "CouchwireKit", targets: ["CouchwireKit"]),
    ],
    targets: [
        .target(
            name: "CouchwireKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CouchwireKitTests",
            dependencies: ["CouchwireKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
