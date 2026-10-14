// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "imtiredofthis",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "imtiredofthis", targets: ["imtiredofthis"]),
        .executable(name: "ImtiredofthisProxy", targets: ["ImtiredofthisProxy"]),
    ],
    targets: [
        .target(name: "ProxyCore"),
        .executableTarget(
            name: "imtiredofthis",
            dependencies: ["ProxyCore"]
        ),
        .executableTarget(
            name: "ImtiredofthisProxy",
            dependencies: ["ProxyCore"]
        ),
        .testTarget(
            name: "ProxyCoreTests",
            dependencies: ["ProxyCore"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
