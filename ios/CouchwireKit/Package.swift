// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CouchwireKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "CouchwireKit", targets: ["CouchwireKit"]),
        // Installing the TV app over SSH (LG Developer Mode). Kept apart so CouchwireKit stays dependency-free.
        .library(name: "CouchwireTVSetup", targets: ["CouchwireTVSetup"]),
        .executable(name: "couchwire-tv", targets: ["couchwire-tv"]),
    ],
    dependencies: [
        // SSH in Swift (swift-nio-ssh underneath). Pinned below 0.12: 0.12 switched swift-nio-ssh to a personal fork.
        .package(url: "https://github.com/orlandos-nl/Citadel.git", "0.11.1" ..< "0.12.0"),
        // The same swift-nio-ssh Citadel 0.11 uses (for the terminal request type), and NIO for its byte buffers.
        .package(url: "https://github.com/Joannis/swift-nio-ssh.git", "0.3.4" ..< "0.4.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3"),
    ],
    targets: [
        .target(
            name: "CouchwireKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "CouchwireTVSetup",
            dependencies: [
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The first test on the Mac: does Swift SSH talk to the TV?  swift run couchwire-tv 192.168.1.34
        .executableTarget(
            name: "couchwire-tv",
            dependencies: ["CouchwireTVSetup"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CouchwireKitTests",
            dependencies: ["CouchwireKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CouchwireTVSetupTests",
            dependencies: ["CouchwireTVSetup"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
