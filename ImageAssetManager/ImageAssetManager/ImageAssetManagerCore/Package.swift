// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ImageAssetManagerCore",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(
            name: "ImageAssetManagerCore",
            targets: ["ImageAssetManagerCore"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "ImageAssetManagerCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "ImageAssetManagerCoreTests",
            dependencies: ["ImageAssetManagerCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
