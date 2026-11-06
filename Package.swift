// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Routey",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Routey", targets: ["Routey"]),
        .executable(name: "RouteyProxy", targets: ["RouteyProxy"]),
    ],
    targets: [
        .target(name: "ProxyCore"),
        .executableTarget(
            name: "Routey",
            dependencies: ["ProxyCore"]
        ),
        .executableTarget(
            name: "RouteyProxy",
            dependencies: ["ProxyCore"]
        ),
        .testTarget(
            name: "ProxyCoreTests",
            dependencies: ["ProxyCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
