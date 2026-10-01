// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Filipendula",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MergeCore", targets: ["MergeCore"]),
        .executable(name: "filipendula", targets: ["filipendula"]),
        .executable(name: "FilipendulaApp", targets: ["FilipendulaApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .target(name: "MergeCore"),
        .executableTarget(
            name: "filipendula",
            dependencies: [
                "MergeCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(name: "FilipendulaApp", dependencies: ["MergeCore"]),
        .testTarget(name: "MergeCoreTests", dependencies: ["MergeCore"]),
    ]
)
