// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ProtonVPNMenuBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ProtonVPNMenuBar", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "ProtonVPNMenuBarTests", dependencies: ["ProtonVPNMenuBar"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
