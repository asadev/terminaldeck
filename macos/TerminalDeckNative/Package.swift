// swift-tools-version: 6.2
// Terminal Deck Native — proof shell.
// A SwiftUI window with the system (Liquid Glass) toolbar whose content is
// Terminal Deck's React screens in a WKWebView, served by Terminal Deck's own
// Electron main process running windowless underneath as the "engine".
import PackageDescription

// The bundled host and app must agree on the real production seams in release.
// The ShippedHost trait turns the same seams on in debug, so `swift test --traits ShippedHost`
// runs the path the shipped app runs (17 Oct; see macos/testing/README.md).
let hostFlags = ["TD_HOST_INTEGRATED", "TD_HOST_PTY_GATE_INTEGRATED", "TD_HOST_ACCOUNT_BRIDGE"]
let hostReleaseSettings: [SwiftSetting] =
    hostFlags.map { .define($0, .when(configuration: .release)) } +
    hostFlags.map { .define($0, .when(traits: ["ShippedHost"])) }

let package = Package(
    name: "TerminalDeckNative",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "TerminalDeckNative", targets: ["TerminalDeckNative"]),
        .executable(name: "TerminalDeckNativeHelper", targets: ["TerminalDeckNativeHelper"]),
        .executable(name: "TerminalDeckJSCorePluginHelper", targets: ["TerminalDeckJSCorePluginHelper"]),
        .executable(name: "TerminalDeckSessionHostHelper", targets: ["TerminalDeckSessionHostHelper"]),
    ],
    traits: [
        .trait(name: "ShippedHost", description: "Host seams on in every configuration, as in the shipped release build."),
    ],
    dependencies: [
        // The native session terminal (lane T). MIT.
        // The caret-in-place optimization relies on SwiftTerm 1.20.0's caret view.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.20.0"),
        // stream-anywhere (2 Nov): Google's WebRTC as LiveKit's prebuilt XCFramework (Chromium M150), BSD-3-Clause + the
        // WebRTC patent grant (THIRD-PARTY-LICENSES.md). Pinned to the tag; its binaryTarget checksum
        // 3b0aa4bee8d5596d6592b8d75bddc84391769849fd64c04b8e13c9e77ce6a82b makes the build refuse a changed binary.
        .package(url: "https://github.com/livekit/webrtc-xcframework", exact: "150.7871.04"),
    ],
    targets: [
        // Pure Foundation logic (engine protocol, origin policy, commands, paths).
        // No UI, so the test target can exercise it directly.
        .target(name: "TerminalDeckNativeCore", swiftSettings: hostReleaseSettings, linkerSettings: [.linkedLibrary("sqlite3")]),
        // Finding 3 (22 Oct): a device screen handed from a helper to the app as a Mach port. Public calls only.
        .target(name: "TerminalDeckDirectMach"),
        // The iOS Simulator's screen and input from CoreSimulator/SimulatorKit (private). Linked ONLY into
        // TerminalDeckNativeHelper (`--sim-direct`), so a fault there ends the helper, never the app.
        .target(name: "TerminalDeckSimDirect", dependencies: ["TerminalDeckDirectMach"],
                linkerSettings: [.linkedFramework("IOSurface")]),
        .target(name: "TerminalDeckBackend", dependencies: [
            "TerminalDeckNativeCore",
            .product(name: "SwiftTerm", package: "SwiftTerm"),
        ], swiftSettings: hostReleaseSettings, linkerSettings: [.linkedFramework("JavaScriptCore")]),
        .executableTarget(
            name: "TerminalDeckNativeHelper",
            dependencies: ["TerminalDeckNativeCore", "TerminalDeckBackend", "TerminalDeckSimDirect"],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("Security"), .linkedFramework("IOKit"), .linkedFramework("SystemConfiguration")]
        ),
        .executableTarget(
            name: "TerminalDeckSessionHostHelper",
            dependencies: ["TerminalDeckNativeCore", "TerminalDeckBackend"],
            swiftSettings: hostReleaseSettings,
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("Security"), .linkedFramework("IOKit"), .linkedFramework("SystemConfiguration")]
        ),
        // stream-anywhere: the screen's direct connection (WebRTC data channels). Linked into the app only; the helpers
        // and the session host never link WebRTC. Swift 5 mode: the library's Objective-C types carry no Sendable notes.
        .target(name: "TerminalDeckPeer", dependencies: [
            "TerminalDeckBackend",
            .product(name: "LiveKitWebRTC", package: "webrtc-xcframework"),
        ], swiftSettings: [.swiftLanguageMode(.v5)]),
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
                "TerminalDeckDirectMach",
                "TerminalDeckPeer",
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ],
            swiftSettings: hostReleaseSettings,
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("WebKit"),
                .linkedFramework("IOSurface"),
            ]
        ),
        // Tests see the same host seams as the code they test, or their `#if TD_HOST_*` blocks never compile.
        .testTarget(
            name: "TerminalDeckNativeUITests",
            dependencies: ["TerminalDeckNative", "TerminalDeckBackend", "TerminalDeckNativeCore"],
            swiftSettings: hostReleaseSettings
        ),
        .testTarget(
            name: "TerminalDeckNativeCoreTests",
            dependencies: ["TerminalDeckNativeCore"],
            swiftSettings: hostReleaseSettings
        ),
        .testTarget(
            name: "TerminalDeckBackendTests",
            dependencies: ["TerminalDeckBackend", "TerminalDeckNativeCore", "TerminalDeckPeer"],
            swiftSettings: hostReleaseSettings
        ),
        .testTarget(
            name: "TerminalDeckAccountSessionTests",
            dependencies: ["TerminalDeckNative", "TerminalDeckBackend", "TerminalDeckNativeCore"],
            swiftSettings: hostReleaseSettings
        ),
    ]
)
