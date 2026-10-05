// swift-tools-version: 6.2
// Terminal Deck Native — proof shell.
// A SwiftUI window with the system (Liquid Glass) toolbar whose content is
// Terminal Deck's React screens in a WKWebView, served by Terminal Deck's own
// Electron main process running windowless underneath as the "engine".
import PackageDescription

let package = Package(
    name: "TerminalDeckNative",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "TerminalDeckNative", targets: ["TerminalDeckNative"]),
    ],
    dependencies: [
        // The native session terminal (lane T). MIT.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.19.0"),
    ],
    targets: [
        // Pure Foundation logic (engine protocol, origin policy, commands, paths).
        // No UI, so the test target can exercise it directly.
        .target(name: "TerminalDeckNativeCore"),
        .executableTarget(
            name: "TerminalDeckNative",
            dependencies: [
                "TerminalDeckNativeCore",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
            ]
        ),
        .testTarget(
            name: "TerminalDeckNativeCoreTests",
            dependencies: ["TerminalDeckNativeCore"]
        ),
    ]
)
