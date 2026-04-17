// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ImageAssetManagerCore",
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "ImageAssetManagerCore",
            targets: ["ImageAssetManagerCore"]
        ),
    ],
    targets: [
        .target(
            name: "ImageAssetManagerCore"
        ),
        .testTarget(
            name: "ImageAssetManagerCoreTests",
            dependencies: ["ImageAssetManagerCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
