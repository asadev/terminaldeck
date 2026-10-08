import XCTest
@testable import TerminalDeckNativeCore

/// The Node-free standalone layout (D14) and the updater's acceptance of it.
final class NativeWebAssetsTests: XCTestCase {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NativeWebAssets-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func write(_ root: URL, _ relative: String, _ bytes: Data = Data("x".utf8), executable: Bool = false) throws {
        let file = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: file)
        if executable { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path) }
    }
    private func machO(cpu: UInt32) -> Data {
        var bytes = Data()
        for word in [UInt32(0xfeed_facf), cpu, 0, 2] { withUnsafeBytes(of: word.littleEndian) { bytes.append(contentsOf: $0) } }
        return bytes + Data(repeating: 0, count: 64)
    }
    private func app(_ root: URL, nativeOnly: Bool = true, cpu: UInt32 = 0x0100_000c) throws -> URL {
        let app = root.appendingPathComponent("Terminal Deck.app", isDirectory: true)
        for path in NativeWebAssets.required { try write(app, "Contents/Resources/" + path) }
        for helper in ["TerminalDeckNativeHelper", "TerminalDeckJSCorePluginHelper"] { try write(app, "Contents/MacOS/" + helper, machO(cpu: cpu), executable: true) }
        try write(app, "Contents/MacOS/TerminalDeckNative", machO(cpu: cpu), executable: true)
        let info: [String: Any] = ["CFBundleExecutable": "TerminalDeckNative", "TDNativeOnly": nativeOnly]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        return app
    }

    func testDiscoverFindsThePagesAndConfigurationRunsNoProgram() throws {
        let app = try app(try scratch())
        let resources = app.appendingPathComponent("Contents/Resources")
        let assets = try NativeWebAssets.discover(resources: resources)
        XCTAssertEqual(assets.renderer.lastPathComponent, "renderer"); XCTAssertEqual(assets.shim.lastPathComponent, "shim.js")
        let configuration = EngineConfiguration.resolve(environment: [:], applicationSupport: try scratch(), home: "/Users/x", installed: nil, resources: resources)
        guard case .nativeOnly = configuration.source else { return XCTFail("the standalone app must resolve to the Node-free source") }
        XCTAssertNil(configuration.executable); XCTAssertEqual(configuration.arguments, []); XCTAssertEqual(configuration.engineDataDirectory, configuration.dataRoot)
        try FileManager.default.removeItem(at: resources.appendingPathComponent("web/native-web/shim.js"))
        XCTAssertThrowsError(try NativeWebAssets.discover(resources: resources)) { XCTAssertEqual($0 as? NativeWebAssets.Problem, .missing("Contents/Resources/web/native-web/shim.js")) }
        let broken = EngineConfiguration.resolve(environment: [:], applicationSupport: try scratch(), home: "/Users/x", installed: nil, resources: resources)
        guard case .unavailable(.bundledEngine) = broken.source else { return XCTFail("an incomplete copy must say so, not start") }
    }

    func testUpdaterAcceptsBridgeMarkersButRejectsRuntimeAndEnginePayload() throws {
        let bundle = try app(try scratch())
        let node = Data("#!/bin/sh\nprintf '%s\\n' 'Terminal Deck no longer uses Node; this placeholder only lets older updaters accept this version'\nexit 1\n".utf8)
        let manifest = Data("{\"removed\":true,\"reason\":\"native app; placeholder for older updaters\"}\n".utf8)
        try write(bundle, "Contents/Resources/runtime/bin/node", node, executable: true)
        try write(bundle, "Contents/Resources/runtime/manifest.json", manifest)
        try write(bundle, "Contents/Resources/engine/manifest.json", manifest)
        XCTAssertNoThrow(try NativeWebAssets.validateApp(bundle, executableName: "TerminalDeckNative", architecture: "arm64"))
        let configuration = EngineConfiguration.resolve(environment: [:], applicationSupport: try scratch(), home: "/Users/x", installed: nil,
                                                        resources: bundle.appendingPathComponent("Contents/Resources"))
        guard case .nativeOnly = configuration.source else { return XCTFail("bridge markers must not select a Node engine") }
        XCTAssertNil(configuration.executable)
        try write(bundle, "Contents/Resources/runtime/bin/node", machO(cpu: 0x0100_000c), executable: true)
        XCTAssertThrowsError(try NativeWebAssets.validateApp(bundle, executableName: "TerminalDeckNative", architecture: "arm64"))
        try write(bundle, "Contents/Resources/runtime/bin/node", node, executable: true)
        try write(bundle, "Contents/Resources/engine/index.js")
        XCTAssertThrowsError(try NativeWebAssets.validateApp(bundle, executableName: "TerminalDeckNative", architecture: "arm64"))
    }

    func testUpdaterAcceptsOnlyTheNodeFreeLayoutForThisMac() throws {
        let root = try scratch()
        XCTAssertNoThrow(try NativeWebAssets.validateApp(try app(root), executableName: "TerminalDeckNative", architecture: "arm64"))
        let legacy = try app(try scratch())
        try write(legacy, "Contents/Resources/runtime/bin/node", executable: true)
        XCTAssertThrowsError(try NativeWebAssets.validateApp(legacy, executableName: "TerminalDeckNative", architecture: "arm64")) {
            XCTAssertEqual($0 as? NativeWebAssets.Problem, .legacyPayload("Contents/Resources/runtime"))
        }
        let undeclared = try app(try scratch(), nativeOnly: false)
        XCTAssertThrowsError(try NativeWebAssets.validateApp(undeclared, executableName: "TerminalDeckNative", architecture: "arm64")) {
            XCTAssertEqual($0 as? NativeWebAssets.Problem, .notNativeOnly)
        }
        let intel = try app(try scratch(), cpu: 0x0100_0007)
        XCTAssertThrowsError(try NativeWebAssets.validateApp(intel, executableName: "TerminalDeckNative", architecture: "arm64"))
        XCTAssertEqual(try NativeWebAssets.machOArchitectures(intel.appendingPathComponent("Contents/MacOS/TerminalDeckNative")), ["x64"])
        let helperless = try app(try scratch())
        try FileManager.default.removeItem(at: helperless.appendingPathComponent("Contents/MacOS/TerminalDeckJSCorePluginHelper"))
        XCTAssertThrowsError(try NativeWebAssets.validateApp(helperless, executableName: "TerminalDeckNative", architecture: "arm64"))
    }
}
