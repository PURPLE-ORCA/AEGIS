// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CaesuraIsland",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/simibac/ConfettiSwiftUI.git", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "CaesuraIsland",
            dependencies: [
                .product(name: "ConfettiSwiftUI", package: "ConfettiSwiftUI"),
            ],
            path: "Sources/CaesuraIsland",
            resources: [
                .copy("../../Resources/Sounds"),
                .copy("../../Resources/cli-icons"),
                .copy("../../Resources/branding"),
            ]
        ),
        .executableTarget(
            name: "CaesuraIslandBridge",
            path: "Sources/CaesuraIslandBridge"
        ),
    ]
)
