// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MacPilot",
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
