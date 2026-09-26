// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Skryba",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Skryba",
            path: "Sources/Skryba"
        ),
        .testTarget(
            name: "SkrybaTests",
            dependencies: ["Skryba"],
            path: "Tests/SkrybaTests"
        ),
    ]
)
