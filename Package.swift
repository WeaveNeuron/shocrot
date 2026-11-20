// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Shocrot",
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Shocrot",
            path: "Sources/Shocrot",
            // en.lproj / zh-Hans.lproj (Localizable.strings, InfoPlist.strings). scripts/build_app.sh copies the
            // same folders into Shocrot.app/Contents/Resources.
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Vision"),
                .linkedFramework("Carbon"),
            ]
        ),
        .testTarget(
            name: "ShocrotTests",
            dependencies: ["Shocrot"],
            path: "Tests/ShocrotTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
