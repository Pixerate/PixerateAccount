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
        ),
        .library(
            name: "PixerateStore",
            targets: ["PixerateStore"]
        )
    ],
    targets: [
        .target(
            name: "PixerateAccount"
        ),
        .target(
            name: "PixerateStore",
            dependencies: ["PixerateAccount"]
        ),
        .testTarget(
            name: "PixerateAccountTests",
            dependencies: ["PixerateAccount"]
        ),
        .testTarget(
            name: "PixerateStoreTests",
            dependencies: ["PixerateStore", "PixerateAccount"],
            resources: [.copy("PixerateStoreTests.storekit")]
        )
    ]
)
