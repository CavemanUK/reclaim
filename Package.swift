// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Reclaim",
    platforms: [.macOS("15.0")],
    products: [
        .executable(name: "Reclaim", targets: ["Reclaim"]),
    ],
    targets: [
        .executableTarget(
            name: "Reclaim",
            path: "Sources/Reclaim"
        ),
        .testTarget(
            name: "ReclaimTests",
            dependencies: ["Reclaim"],
            path: "Tests/ReclaimTests"
        ),
    ]
)
