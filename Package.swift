// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PixerateAccount",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(
            name: "PixerateAccount",
            targets: ["PixerateAccount"]
        )
    ],
    targets: [
        .target(
            name: "PixerateAccount"
        ),
        .testTarget(
            name: "PixerateAccountTests",
            dependencies: ["PixerateAccount"]
        )
    ]
)
