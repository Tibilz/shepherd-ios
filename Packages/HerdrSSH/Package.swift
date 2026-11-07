// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HerdrSSH",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "HerdrSSH", targets: ["HerdrSSH"])],
    dependencies: [
        .package(path: "../HerdrKit"),
        .package(url: "https://github.com/orlandos-nl/Citadel", exact: "0.12.1"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.12.3"..<"4.0.0"),
    ],
    targets: [
        .target(name: "HerdrSSH", dependencies: ["HerdrKit", .product(name: "Citadel", package: "Citadel"),
                                            .product(name: "Crypto", package: "swift-crypto")]),
        .testTarget(name: "HerdrSSHTests", dependencies: ["HerdrSSH"], resources: [.copy("Fixtures")]),
        .testTarget(name: "IntegrationTests", dependencies: ["HerdrSSH"]),
    ]
)
