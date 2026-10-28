// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Shocrot",
    platforms: [.macOS("14.4")],
    targets: [
        .executableTarget(
            name: "Shocrot",
            path: "Sources/Shocrot",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
                .linkedFramework("Carbon"),
            ]
        )
    ]
)
