// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacPilot",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacPilot", targets: ["MacPilot"])
    ],
    targets: [
        .executableTarget(
            name: "MacPilot",
            path: "Sources/MacPilot"
        )
    ]
)
