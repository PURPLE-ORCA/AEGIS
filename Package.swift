// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Aegis",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/simibac/ConfettiSwiftUI.git", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "Aegis",
            dependencies: [
                "AegisBridgeSupport",
                .product(name: "ConfettiSwiftUI", package: "ConfettiSwiftUI"),
            ],
            path: "Sources/Aegis",
            resources: [
                .copy("../../Resources/cli-icons"),
                .copy("../../Resources/branding"),
                .copy("../../Resources/companion"),
                .copy("../../Resources/sounds"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Carbon"),
                .linkedFramework("AVFoundation"),
            ]
        ),
        .executableTarget(
            name: "AegisBridge",
            dependencies: ["AegisBridgeSupport"],
            path: "Sources/AegisBridge"
        ),
        .target(
            name: "AegisBridgeSupport",
            path: "Sources/AegisBridgeSupport"
        ),
        .testTarget(
            name: "AegisTests",
            dependencies: ["Aegis", "AegisBridgeSupport"],
            path: "Tests/AegisTests"
        ),
    ]
)
