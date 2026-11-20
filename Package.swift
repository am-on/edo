// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "edo",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .executable(name: "edo", targets: ["edo"]),
    ],
    targets: [
        .executableTarget(
            name: "edo"
        ),
        .testTarget(
            name: "edoTests",
            dependencies: ["edo"]
        ),
    ]
)
