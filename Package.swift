// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "homelab-dashboard",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "HomelabCore"),
        .executableTarget(name: "Dashboard", dependencies: ["HomelabCore"]),
        // Самодостаточный test-runner (работает без Xcode/XCTest).
        .executableTarget(name: "Check", dependencies: ["HomelabCore"]),
    ]
)