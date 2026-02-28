// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SharedProtocol",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(name: "SharedProtocol", targets: ["SharedProtocol"])
    ],
    targets: [
        .target(
            name: "SharedProtocol",
            path: "Sources/SharedProtocol"
        ),
        .testTarget(
            name: "SharedProtocolTests",
            dependencies: ["SharedProtocol"],
            path: "Tests/SharedProtocolTests"
        )
    ]
)
