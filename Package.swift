// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Routey",
    platforms: [.macOS(.v15), .iOS(.v26)],
    products: [
        .executable(name: "Routey", targets: ["Routey"]),
        .executable(name: "RouteyProxy", targets: ["RouteyProxy"]),
        .library(name: "ProxyCore", targets: ["ProxyCore"]),
        .library(name: "PacketStack", targets: ["PacketStack"]),
    ],
    targets: [
        .target(name: "ProxyCore"),
        .target(
            name: "CLwIP",
            exclude: ["COPYING", "PATCHES.md"],
            cSettings: [
                .define("LWIP_NOASSERT", .when(configuration: .release)),
            ]
        ),
        .target(
            name: "PacketStack",
            dependencies: ["CLwIP", "ProxyCore"]
        ),
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
            dependencies: ["ProxyCore", "PacketStack"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
