// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CurvedLayoutKit",
    platforms: [.visionOS(.v1)],
    products: [
        .library(name: "CurvedLayoutKit", targets: ["CurvedLayoutKit"])
    ],
    targets: [
        .target(name: "CurvedLayoutKit")
    ]
)

