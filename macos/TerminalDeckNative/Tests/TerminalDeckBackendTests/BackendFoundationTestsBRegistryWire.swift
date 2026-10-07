import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private final class BackendFoundationTestsBHeard: @unchecked Sendable {
    private let lock = NSLock(); private var values: [String] = []
    func append(_ value: String) { lock.withLock { values.append(value) } }
    func read() -> [String] { lock.withLock { values } }
}
final class BackendFoundationTestsBRegistryWire: XCTestCase {
    func testRegistersInvokesRemovesAndPreservesOriginalMissingHandlerSentence() async throws {
        let registry = NativeChannelRegistry(), context = NativeRPCContext(caller: .nativeApp, ownerID: "fixture")
        try await registry.register("plus", ownerID: "fixture") { _, args in .number((args[0].number ?? 0) + (args[1].number ?? 0)) }
        let answer = try await registry.invoke("plus", context: context, arguments: [.number(2), .number(3)]); XCTAssertEqual(answer, .number(5))
        let exists = await registry.has("plus"); XCTAssertTrue(exists)
        do { try await registry.register("plus", ownerID: "fixture") { _, _ in .number(9) }; XCTFail("Second registration must fail") } catch {}
        await registry.removeHandler("plus", ownerID: "fixture"); let gone = await registry.has("plus"); XCTAssertFalse(gone)
        do { _ = try await registry.invoke("plus", context: context, arguments: []); XCTFail("Removed handler must fail") } catch { XCTAssertEqual(error.localizedDescription, "No handler registered for 'plus'") }
    }
    func testOrderedSendListenersAndNoListenerBoolean() async throws {
        let registry = NativeChannelRegistry(), heard = BackendFoundationTestsBHeard(), context = NativeRPCContext(caller: .nativeApp, ownerID: "fixture")
        let one = try await registry.onSend("typed", ownerID: "one") { _, args in heard.append(args[0].string ?? "") }
        let two = try await registry.onSend("typed", ownerID: "two") { _, args in heard.append("again " + (args[0].string ?? "")) }
        let delivered = try await registry.send("typed", context: context, arguments: [.string("x")]); XCTAssertTrue(delivered); XCTAssertEqual(heard.read(), ["x", "again x"])
        let silent = try await registry.send("silent", context: context, arguments: []); XCTAssertFalse(silent)
        await one.cancelAndWait(); await two.cancelAndWait(); await registry.shutdown()
    }
    func testChannelNamesAndExactNativeFlag() {
        for good in ["brand:get", "session:write", "debug:ipc-call", "browser-view:claim", "hoot-panel:pointer"] { XCTAssertTrue(NativeChannelRegistry.isBridgeChannel(good), good) }
        for bad in ["", "error", "newListener", "removeListener", "-ipc-invoke", "ELECTRON_BROWSER_X", "a b", String(repeating: "x", count: 201)] { XCTAssertFalse(NativeChannelRegistry.isBridgeChannel(bad), bad) }
        XCTAssertTrue(BackendOSNativeMode.enabled(arguments: ["/Electron", "/repo", "--native-shell", "--user-data-dir=/x"]))
        XCTAssertFalse(BackendOSNativeMode.enabled(arguments: ["/Electron", "/repo"]))
        XCTAssertFalse(BackendOSNativeMode.enabled(arguments: ["/Electron", "/repo", "--native-shell=1"]))
    }
    func testWireBytesUndefinedArrayAndPrototypeKeysStayValues() throws {
        let value = NativeRPCValue.object([.init("a", .bytes(Data("x".utf8))), .init("b", .bytes(Data([1, 2]))), .init("c", .array([.missing, .number(1)]))])
        let encoded = try value.encodedJSON(), raw = try NativeRPCValue.parseJSON(encoded)
        XCTAssertEqual(raw["a"]["$bytes"].string, "eA=="); XCTAssertEqual(raw["b"]["$bytes"].string, "AQI="); XCTAssertEqual(raw["c"], .array([.null, .number(1)]))
        let decoded = try NativeRPCValue.parseJSON(encoded, decodeBytes: true); XCTAssertEqual(decoded["a"], .bytes(Data("x".utf8))); XCTAssertEqual(decoded["b"], .bytes(Data([1, 2])))
        let hostile = try NativeRPCValue.parseJSON(Data("{\"__proto__\":{\"polluted\":true},\"ok\":1}".utf8), decodeBytes: true)
        XCTAssertEqual(hostile["ok"], .number(1)); XCTAssertEqual(hostile["polluted"], .missing); XCTAssertEqual(NativeRPCValue.object([])["polluted"], .missing)
    }
}
