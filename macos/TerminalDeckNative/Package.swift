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
        .executable(name: "TerminalDeckNativeHelper", targets: ["TerminalDeckNativeHelper"]),
        .executable(name: "TerminalDeckJSCorePluginHelper", targets: ["TerminalDeckJSCorePluginHelper"]),
    ],
    dependencies: [
        // The native session terminal (lane T). MIT.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.19.0"),
    ],
    targets: [
        // Pure Foundation logic (engine protocol, origin policy, commands, paths).
        // No UI, so the test target can exercise it directly.
        .target(name: "TerminalDeckNativeCore", linkerSettings: [.linkedLibrary("sqlite3")]),
        .target(name: "TerminalDeckBackend", dependencies: [
            "TerminalDeckNativeCore",
            .product(name: "SwiftTerm", package: "SwiftTerm"),
        ], linkerSettings: [.linkedFramework("JavaScriptCore")]),
        .executableTarget(
            name: "TerminalDeckNativeHelper",
            dependencies: ["TerminalDeckNativeCore", "TerminalDeckBackend"],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("Security"), .linkedFramework("IOKit"), .linkedFramework("SystemConfiguration")]
        ),
        .executableTarget(
            name: "TerminalDeckJSCorePluginHelper",
            dependencies: ["TerminalDeckBackend"],
            linkerSettings: [.linkedFramework("JavaScriptCore")]
        ),
        .executableTarget(
            name: "TerminalDeckNative",
            dependencies: [
                "TerminalDeckNativeCore",
                "TerminalDeckBackend",
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
        .testTarget(
            name: "TerminalDeckBackendTests",
            dependencies: ["TerminalDeckBackend", "TerminalDeckNativeCore"]
        ),
    ]
)
