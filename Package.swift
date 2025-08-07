// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DriftDetector",
    platforms: [
        .macOS(.v12),
        .iOS(.v15)
    ],
    products: [
        .executable(
            name: "drift_detector",
            targets: ["DriftDetector"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.0.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.0.2"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.4.3"),
        .package(url: "https://github.com/swiftkube/model.git", from: "0.18.0"),
        .package(url: "https://github.com/sersoft-gmbh/semver.git", from: "5.3.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.26.0")
    ],
    targets: [
        .executableTarget(
            name: "DriftDetector",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "SwiftkubeModel", package: "model"),
                .product(name: "SemVer", package: "semver"),
                .product(name: "AsyncHTTPClient", package: "async-http-client")
            ]
        ),
        .testTarget(
            name: "DriftDetectorTests",
            dependencies: ["DriftDetector"]
        )
    ]
) 