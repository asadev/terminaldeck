import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendOSTestPortRegistryPushTrace: BackendOSTestPortFixture {
    actor Heard { var values: [NativeRPCValue] = []; func append(_ value: NativeRPCValue) { values.append(value) }; func all() -> [NativeRPCValue] { values } }
    func testNativeRegistry25CallsSharedHandlerWithCaller() async throws {
        let registry = NativeChannelRegistry(); try await registry.register("sum", ownerID: "test") { context, args in .object([.init("who", .string(context.ownerID)), .init("total", .number((args[0].number ?? 0) + (args[1].number ?? 0)))]) }
        let has = await registry.has("sum"); XCTAssertTrue(has)
        let value = try await registry.invoke("sum", context: .init(caller: .nativeApp, ownerID: "me"), arguments: [.number(2), .number(3)]); XCTAssertEqual(value, .object([.init("who", .string("me")), .init("total", .number(5))]))
    }
    func testNativeRegistry34KeepsWrappedRegisteredHandler() async throws {
        let registry = NativeChannelRegistry(), heard = Heard(); try await registry.register("traced", ownerID: "test") { _, _ in await heard.append(.string("traced")); return .string("value") }
        let result = try await registry.invoke("traced", context: .init(caller: .nativeApp, ownerID: "test"), arguments: []), calls = await heard.all(); XCTAssertEqual(result, .string("value")); XCTAssertEqual(calls, [.string("traced")])
    }
    func testNativeRegistry50DuplicateAndRemoval() async throws {
        let registry = NativeChannelRegistry(); try await registry.register("once", ownerID: "test") { _, _ in .number(1) }
        do { try await registry.register("once", ownerID: "test") { _, _ in .number(2) }; XCTFail("Duplicate allowed") } catch { XCTAssertTrue(error.localizedDescription.contains("handler")) }
        let before = try await registry.invoke("once", context: .init(caller: .nativeApp, ownerID: "test"), arguments: []); XCTAssertEqual(before, .number(1))
        await registry.removeHandler("once"); let has = await registry.has("once"); XCTAssertFalse(has)
        do { _ = try await registry.invoke("once", context: .init(caller: .nativeApp, ownerID: "test"), arguments: []); XCTFail("Missing handler allowed") } catch { XCTAssertEqual(error.localizedDescription, "No handler registered for 'once'") }
    }
    func testNativeRegistry62EarlierRegistrationRemainsCallable() async throws {
        let registry = NativeChannelRegistry(); try await registry.register("early", ownerID: "test") { _, args in .string("early " + (args[0].string ?? "")) }
        let sender = BackendOSNativeSender(ownerID: "window", dispatcher: .init(registry: registry)) { _, _ in true }
        let result = try await sender.invoke("early", arguments: [.string("bird")]); XCTAssertEqual(result, .string("early bird"))
        // Electron's private-map/_reply fallback has no native counterpart;
        // the earlier shared handler's public return is the same bridge result.
    }
    func testNativeRegistry75EverySendListenerAndSilentBoolean() async throws {
        let registry = NativeChannelRegistry(), heard = Heard()
        let one = try await registry.onSend("typed", ownerID: "test") { _, args in await heard.append(args[0]) }, two = try await registry.onSend("typed", ownerID: "test") { _, args in await heard.append(.string("again " + (args[0].string ?? ""))) }
        let delivered = try await registry.send("typed", context: .init(caller: .nativeApp, ownerID: "test"), arguments: [.string("x")]), values = await heard.all(), silent = try await registry.send("silent", context: .init(caller: .nativeApp, ownerID: "test"), arguments: [])
        XCTAssertTrue(delivered); XCTAssertEqual(values, [.string("x"), .string("again x")]); XCTAssertFalse(silent)
        await one.cancelAndWait(); await two.cancelAndWait()
    }
    func testNativeRegistry87ChannelGateExactInputs() {
        for good in ["brand:get", "session:write", "debug:ipc-call", "browser-view:claim", "hoot-panel:pointer"] { XCTAssertTrue(NativeChannelRegistry.isBridgeChannel(good), good) }
        for bad in ["", "error", "newListener", "removeListener", "-ipc-invoke", "ELECTRON_BROWSER_X", "a b", String(repeating: "x", count: 201)] { XCTAssertFalse(NativeChannelRegistry.isBridgeChannel(bad), bad) }
        for body in [#"{"channel":5}"#, #"{"channel":null}"#] { XCTAssertThrowsError(try BackendOSNativeBridge.parseCall(Data(body.utf8))) }
    }
    func testNativeRegistry98NativeSenderPushAndBoundCaller() async throws {
        let registry = NativeChannelRegistry(), heard = Heard(); let dispatcher = BackendOSTraceDispatcher(registry: registry)
        let sender = BackendOSNativeSender(ownerID: "me", dispatcher: dispatcher) { channel, args in await heard.append(.array([.string(channel)] + args)); return true }
        let pushed = await sender.push("usage:update", arguments: [.string("s1"), .object([.init("tokens", .number(3))])]); XCTAssertTrue(pushed)
        let messages = await heard.all(); XCTAssertEqual(messages, [.array([.string("usage:update"), .string("s1"), .object([.init("tokens", .number(3))])])]); XCTAssertEqual(BackendOSNativeSender.legacyID, 1_000_000_000)
        try await registry.register("caller", ownerID: "test") { context, _ in .object([.init("owner", .string(context.ownerID)), .init("caller", .string(context.caller.rawValue))]) }
        let result = try await sender.invoke("caller", arguments: []); XCTAssertEqual(result, .object([.init("owner", .string("me")), .init("caller", .string("nativeApp"))]))
        // Electron WebContents identity/frame/session/evaluate methods are replaced
        // by the native context; arbitrary script refusal is NativeMode170.
    }
    func testNativeRegistry138WireBytesMissingErrorAndDecimal() throws {
        let value = try NativeRPCValue.fromFoundation(["a": Data("x".utf8), "b": Data([1, 2]), "c": [NSNull(), 1] as [Any], "d": NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "e"]), "e": "5"])
        let wire = try NativeRPCValue.parseJSON(value.encodedJSON())
        XCTAssertEqual(wire["a"], .object([.init("$bytes", .string("eA=="))])); XCTAssertEqual(wire["b"], .object([.init("$bytes", .string("AQI="))])); XCTAssertEqual(wire["c"], .array([.null, .number(1)]))
        XCTAssertEqual(wire["d"], .object([.init("name", .string("Error")), .init("message", .string("e"))])); XCTAssertEqual(wire["e"], .string("5"))
        let back = try NativeRPCValue.parseJSON(value.encodedJSON(), decodeBytes: true); XCTAssertEqual(back["a"], .bytes(Data("x".utf8))); XCTAssertEqual(back["b"], .bytes(Data([1, 2])))
    }
    func testNativeRegistry152PrototypeBytesDecoderDropsKey() throws { let result = try NativeRPCValue.parseJSON(Data(#"{"__proto__":{"polluted":true},"ok":1}"#.utf8), decodeBytes: true); XCTAssertEqual(result["ok"], .number(1)); XCTAssertEqual(result["polluted"], .missing); XCTAssertEqual(result["__proto__"], .missing) }
    private func subscriptions() throws -> [String] {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("src/preload/index.ts")
        let source = try text(file), regex = try NSRegularExpression(pattern: #"ipcRenderer\.on\(\s*'([^']+)'"#)
        return regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap { Range($0.range(at: 1), in: source).map { String(source[$0]) } }
    }
    func testLivePush42PreferencesSubscribed() throws { XCTAssertTrue(try subscriptions().contains(BackendOSLivePush.prefsChanged)); XCTAssertEqual(BackendOSLivePush.prefsChanged, "prefs:changed") }
    func testLivePush48SettingsSubscribed() throws { XCTAssertTrue(try subscriptions().contains(BackendOSLivePush.settingsChanged)); XCTAssertEqual(BackendOSLivePush.settingsChanged, "settings:changed") }
    func testLivePush54RemovedSubscribed() throws { XCTAssertTrue(try subscriptions().contains(BackendOSLivePush.sessionRemoved)); XCTAssertEqual(BackendOSLivePush.sessionRemoved, "session:removed") }
    func testLivePush60RenamedSubscribed() throws { XCTAssertTrue(try subscriptions().contains(BackendOSLivePush.sessionRenamed)); XCTAssertEqual(BackendOSLivePush.sessionRenamed, "session:renamed") }
    func testLivePush69RemovalIsNotExit() throws { XCTAssertNotEqual(BackendOSLivePush.sessionRemoved, "session:exit"); XCTAssertTrue(try subscriptions().contains("session:exit")) }
    func testLivePush81GuardActuallyReadsSubscriptions() throws { let channels = try subscriptions(); XCTAssertGreaterThan(channels.count, 5); XCTAssertTrue(channels.contains("session:data")) }
    func testLivePush89NativePublisherExactChannels() async throws {
        let registry = NativeChannelRegistry(), heard = Heard(); var subscriptions: [NativeRPCSubscription] = []
        let channels = [BackendOSLivePush.sessionRemoved, BackendOSLivePush.sessionRenamed, BackendOSLivePush.settingsChanged, BackendOSLivePush.prefsChanged]
        for channel in channels { subscriptions.append(try await registry.subscribe(channel, ownerID: "window") { event in await heard.append(.string(event.channel)) }) }
        for channel in channels { try await registry.publish(channel, arguments: []) }
        let values = await heard.all(); XCTAssertEqual(values, channels.map(NativeRPCValue.string)); for subscription in subscriptions { await subscription.cancelAndWait() }
    }
    func testTrace59DisabledHasNoHeaderOrFile() async throws { let root = try scratch(), trace = try BackendOSTrace(userData: root); _ = await trace.invokeStarted(channel: "session:create", arguments: [.object([.init("cwd", .string("/work"))])]); XCTAssertFalse(FileManager.default.fileExists(atPath: trace.file.path)) }
    func testTrace70EnabledRecordsRequestAndResult() async throws { let root = try scratch(), trace = try BackendOSTrace(userData: root, enabled: true); let started = await trace.invokeStarted(channel: "session:create", arguments: [.object([.init("cwd", .string("/work"))])]); await trace.invokeReturned(channel: "session:create", value: .string("made it"), started: started); let output = try text(trace.file); XCTAssertTrue(output.contains("trace started")); XCTAssertTrue(output.contains("→ session:create")); XCTAssertTrue(output.contains("← session:create ok")) }
    func testTrace83ToggleImmediately() async throws {
        let root = try scratch(), trace = try BackendOSTrace(userData: root); _ = await trace.invokeStarted(channel: "a:one", arguments: []); XCTAssertFalse(FileManager.default.fileExists(atPath: trace.file.path))
        await trace.setEnabled(true); _ = await trace.invokeStarted(channel: "a:one", arguments: []); XCTAssertTrue(try text(trace.file).contains("→ a:one")); await trace.setEnabled(false); let before = try text(trace.file); _ = await trace.invokeStarted(channel: "a:one", arguments: []); XCTAssertEqual(try text(trace.file), before)
    }
    func testTrace105ResultAndThrowUnchanged() async throws {
        let root = try scratch(), trace = try BackendOSTrace(userData: root), registry = NativeChannelRegistry(), dispatcher = BackendOSTraceDispatcher(registry: registry, trace: trace)
        try await registry.register("a:ok", ownerID: "test") { _, _ in .string("value") }; try await registry.register("a:bad", ownerID: "test") { _, _ in throw NativeRPCError(code: "test", message: "boom") }
        let value = try await dispatcher.invoke(channel: "a:ok", arguments: [], context: .init(caller: .nativeApp, ownerID: "window")); XCTAssertEqual(value, .string("value"))
        do { _ = try await dispatcher.invoke(channel: "a:bad", arguments: [], context: .init(caller: .nativeApp, ownerID: "window")); XCTFail("Throw hidden") } catch { XCTAssertEqual(error.localizedDescription, "boom") }
    }
    func testTrace118ExcludedChannelUntouched() async throws { let root = try scratch(), trace = try BackendOSTrace(userData: root, enabled: true, excluded: ["browser:bounds"]); _ = await trace.invokeStarted(channel: "browser:bounds", arguments: [.object([.init("x", .number(1))])]); _ = await trace.invokeStarted(channel: "session:list", arguments: []); let output = try text(trace.file); XCTAssertFalse(output.contains("→ browser:bounds")); XCTAssertTrue(output.contains("→ session:list")) }
    func testTrace135DisabledBootClearsBothOldGenerations() throws { let root = try scratch(); try put(root.appendingPathComponent("ipc-trace.log"), String(repeating: "x", count: 12 * 1024 * 1024)); try put(root.appendingPathComponent("ipc-trace.log.1"), "older"); let trace = try BackendOSTrace(userData: root); XCTAssertFalse(FileManager.default.fileExists(atPath: trace.file.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: trace.previousFile.path)) }
    func testTrace148EnabledBootKeepsOldTail() throws { let root = try scratch(); try put(root.appendingPathComponent("ipc-trace.log"), "earlier session\n"); let trace = try BackendOSTrace(userData: root, enabled: true); XCTAssertTrue(try text(trace.file).contains("earlier session")) }
    func testTrace159RotatesAtCap() async throws {
        let root = try scratch(); try put(root.appendingPathComponent("ipc-trace.log"), String(repeating: "z", count: BackendOSTrace.maximumBytes - 100)); let trace = try BackendOSTrace(userData: root, enabled: true)
        for _ in 0..<5 { let started = await trace.invokeStarted(channel: "big:call", arguments: [.string(String(repeating: "y", count: 4000))]); await trace.invokeReturned(channel: "big:call", value: .string(String(repeating: "y", count: 4000)), started: started) }
        XCTAssertLessThan(try Data(contentsOf: trace.file).count, BackendOSTrace.maximumBytes); XCTAssertGreaterThan(try Data(contentsOf: trace.previousFile).count, BackendOSTrace.maximumBytes - 1000)
    }
    func testTrace182OnlyTwoGenerations() async throws {
        let root = try scratch()
        for _ in 0..<3 { try put(root.appendingPathComponent("ipc-trace.log"), String(repeating: "z", count: BackendOSTrace.maximumBytes - 100)); let trace = try BackendOSTrace(userData: root, enabled: true); for _ in 0..<3 { let started = await trace.invokeStarted(channel: "c", arguments: []); await trace.invokeReturned(channel: "c", value: .string("x"), started: started) } }
        XCTAssertLessThanOrEqual(try names(root).filter { $0.hasPrefix("ipc-trace.log") }.count, 2)
    }
    func testTrace203PathsUnderUserData() throws { let root = try scratch(), trace = try BackendOSTrace(userData: root); XCTAssertEqual(trace.file.path, root.appendingPathComponent("ipc-trace.log").path); XCTAssertEqual(trace.previousFile.path, root.appendingPathComponent("ipc-trace.log.1").path) }
}
