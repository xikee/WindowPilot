// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WindowPilot",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "WindowPilot", targets: ["WindowPilot"])],
    targets: [
        .target(name: "SwitchCore"),
        .executableTarget(name: "WindowPilot", dependencies: ["SwitchCore"]),
        .testTarget(name: "SwitchCoreTests", dependencies: ["SwitchCore"])
    ]
)
