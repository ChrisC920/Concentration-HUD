// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DATSignaling",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "DATSignaling", targets: ["DATSignaling"]),
    ],
    targets: [
        .target(name: "DATSignaling"),
        .testTarget(name: "DATSignalingTests", dependencies: ["DATSignaling"]),
    ]
)
