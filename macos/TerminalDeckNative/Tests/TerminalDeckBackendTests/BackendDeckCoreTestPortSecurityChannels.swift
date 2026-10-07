import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private struct BackendDeckCoreTestPortSecurityChannelSurface: BackendDeckCoreEventsDetectionSurface {
    let surface: BackendDeckCoreTestPortSecuritySurface
    let clock: BackendDeckCoreTestPortSecurityClock
    func notificationSessions() async -> [NativeRPCValue] { surface.listSessions() }
    func notificationScreen(sessionId: String) async -> String? { surface.screen }
    func notificationAnswer(session: NativeRPCValue) async -> NativeRPCValue? {
        .object([.init("at", .number(clock.now())), .init("text", .string("answer 1")), .init("truncated", .bool(false))])
    }
}

final class BackendDeckCoreTestPortSecurityChannels: BackendDeckCoreTestPortSecurityCase {
    func testMcpEventsCallbackL57() {
        XCTAssertNil(BackendDeckCoreEventsCallback.urlProblem("https://callbacks.chatgpt.com/mcp/events/abc")); XCTAssertNil(BackendDeckCoreEventsCallback.urlProblem("https://8.8.8.8/hook"))
        for bad in ["http://callbacks.chatgpt.com/x", "ftp://example.com/x", "https://user:pass@example.com/x", "https://localhost/x", "https://api.localhost/x", "https://printer.local/x", "https://metadata.google.internal/x", "https://router/x", "https://127.0.0.1/x", "https://[::1]/x", "https://169.254.169.254/latest/meta-data", "not a url"] {
            XCTAssertNotNil(BackendDeckCoreEventsCallback.urlProblem(bad), bad)
        }
    }
    func testMcpEventsCallbackL80() async {
        for bad in ["http://example.com/x", "https://127.0.0.1:9/x", "https://[::1]:9/x", "https://localhost:9/x", "https://10.0.0.1/x"] {
            do { _ = try await BackendDeckCoreEventsCallback.post(bad, [:], "{}"); XCTFail(bad) }
            catch let refusal as BackendDeckCoreEventsCallbackRefused { XCTAssertEqual(refusal.reason, "not_public", bad) }
            catch { XCTFail("Expected CallbackRefused for \(bad), got \(error)") }
        }
    }
    func testMcpEventsCallbackL91() {
        do { _ = try BackendDeckCoreEventsCallback.publicLookup("localhost", resolve: { host in XCTAssertEqual(host, "localhost"); return ["127.0.0.1"] }); XCTFail("Private DNS answer must refuse") }
        catch let refusal as BackendDeckCoreEventsCallbackRefused { XCTAssertEqual(refusal.code, "ENOTPUBLIC") }
        catch { XCTFail("Expected source DNS refusal") }
    }
    func testChannelTapL28() throws { throw XCTSkip("Electron-only IpcMain structural type assignment has no native Electron type; NativeChannelRegistry registration is exercised by the portable cases below.") }
    func testChannelTapL36() async throws {
        let registry = NativeChannelRegistry(), tap = BackendDeckCoreEventsChannelTap(), seen = BackendDeckCoreSecurityTestBox<[NativeRPCContext?]>([])
        try await tap.attach(registry)
        try await tap.register("machines:rename", in: registry, ownerID: "window") { context, args in seen.edit { $0.append(context) }; return .object([.init("renamed", .string((args[0].string ?? "") + "=" + (args[1].string ?? "")))]) }
        let tool = try await tap.invoke("machines:rename", arguments: [.string("m1"), .string("Office")]); assertValue(tool, o([("renamed", .string("m1=Office"))]))
        let window = try await registry.invoke("machines:rename", context: .init(caller: .nativeApp, ownerID: "window"), arguments: [.string("m2"), .string("Mac")]); assertValue(window, o([("renamed", .string("m2=Mac"))]))
        XCTAssertEqual(seen.get().count, 2); XCTAssertNil(seen.get()[0]); XCTAssertEqual(seen.get()[1]?.ownerID, "window")
    }
    func testChannelTapL51() async throws {
        let registry = NativeChannelRegistry(), tap = BackendDeckCoreEventsChannelTap(), calls = BackendDeckCoreSecurityTestBox<[String]>([]); try await tap.attach(registry)
        let token = try await tap.onSend("github:clear-cache", in: registry, ownerID: "owner") { _, args in calls.edit { $0.append(args[0].string ?? "") }; return .missing }
        _ = try await tap.invoke("github:clear-cache", arguments: [.string("/repo")]); XCTAssertEqual(calls.get(), ["/repo"]); await token.cancelAndWait()
    }
    func testChannelTapL61() async throws { let tap = BackendDeckCoreEventsChannelTap(); try await tap.attach(.init()); await assertAsyncError({ _ = try await tap.invoke("machines:nothing") }, contains: "Nothing in this app answers \"machines:nothing\"") }
    func testChannelTapL67() async throws { let tap = BackendDeckCoreEventsChannelTap(), registry = NativeChannelRegistry(); try await tap.attach(registry); await assertAsyncError({ try await tap.attach(registry) }, contains: "already attached") }
    func testChannelTapL74() async throws {
        let tap = BackendDeckCoreEventsChannelTap(), registry = NativeChannelRegistry(), order = BackendDeckCoreSecurityTestBox<[String]>([]); try await tap.attach(registry)
        try await tap.register("machines:attach", in: registry, ownerID: "window") { _, _ in order.edit { $0.append("handler") }; return .bool(true) }
        _ = await tap.onInvoke { channel, args in order.edit { $0.append(channel + "(" + args.map { $0.string ?? $0.compact }.joined(separator: ",") + ")") } }
        _ = try await registry.invoke("machines:attach", context: .init(caller: .nativeApp, ownerID: "window"), arguments: [.string("m1"), .string("s1"), .number(80), .number(24)])
        _ = try await tap.invoke("machines:attach", arguments: [.string("m1"), .string("s1"), .number(120), .number(30)])
        XCTAssertEqual(order.get(), ["machines:attach(m1,s1,80,24)", "handler", "machines:attach(m1,s1,120,30)", "handler"])
    }
    func testChannelTapL89() async throws {
        let tap = BackendDeckCoreEventsChannelTap(), registry = NativeChannelRegistry(); try await tap.attach(registry)
        try await tap.register("machines:list", in: registry, ownerID: "window") { _, _ in .string("the list") }
        _ = await tap.onInvoke { _, _ in throw NativeRPCError(code: "listener", message: "a broken listener") }
        let result = try await registry.invoke("machines:list", context: .init(caller: .nativeApp, ownerID: "window"), arguments: []); XCTAssertEqual(result, .string("the list"))
    }
    func testChannelTapL102() async {
        let tap = BackendDeckCoreEventsChannelTap(), heard = BackendDeckCoreSecurityTestBox<[V]>([])
        let id = await tap.onPush("machines:output") { value in heard.edit { $0.append(value) } }
        let a = o([("data", .string("a"))]), b = o([("data", .string("b"))]); await tap.pushed("machines:output", arguments: [a]); await tap.removeListener(id); await tap.pushed("machines:output", arguments: [b]); assertValue(.array(heard.get()), .array([a]))
    }
    func testChannelTapL112() async throws {
        let tap = BackendDeckCoreEventsChannelTap(clock: BackendDeckCoreTestPortSecurityClock())
        let next = try await tap.nextPush("machines:state", matches: { $0["n"].number == 2 }, ceilingMs: 1000) {
            await tap.pushed("machines:state", arguments: [.object([.init("n", .number(1))])]); await tap.pushed("machines:state", arguments: [.object([.init("n", .number(2))])])
        }
        assertValue(next ?? .null, o([("n", .number(2))]))
    }
    func testChannelTapL123() async throws {
        let clock = BackendDeckCoreTestPortSecurityClock(), tap = BackendDeckCoreEventsChannelTap(clock: clock), heard = BackendDeckCoreSecurityTestBox<[V]>([])
        let next = Task { try await tap.nextPush("machines:state", matches: { _ in true }, ceilingMs: 500) }; await clock.scheduled.wait(1); clock.advance(501)
        let value = try await next.value; XCTAssertNil(value)
        _ = await tap.onPush("machines:state") { value in heard.edit { $0.append(value) } }; await tap.pushed("machines:state", arguments: [.number(1)]); assertValue(.array(heard.get()), .array([.number(1)]))
    }
    func testChannelTapL140() async throws {
        let tap = BackendDeckCoreEventsChannelTap(), registry = NativeChannelRegistry(); try await tap.attach(registry)
        try await tap.register("machines:ports", in: registry, ownerID: "owner") { _, args in .bool(args[0].string == "m1") }
        let call = tap.call(allowing: ["machines:ports"]), result = try await call("machines:ports", [.string("m1")]); XCTAssertEqual(result, .bool(true))
    }
    func testNotifyChannelL97() throws {
        var root = URL(fileURLWithPath: #filePath); for _ in 0..<5 { root.deleteLastPathComponent() }
        let page = try String(contentsOf: root.appendingPathComponent("src/renderer/settings/sections/ai-apps-setup.ts"), encoding: .utf8)
        XCTAssertEqual(BackendDeckCoreEventsChannelBridge.serverName, "terminaldeck-notify"); XCTAssertTrue(page.contains("export const CHANNEL_SERVER = `${BRAND.id}-notify`"))
        XCTAssertEqual(BackendDeckCoreEventsChannelBridge.urlEnvironment, "NOTIFY_URL"); XCTAssertEqual(BackendDeckCoreEventsChannelBridge.keyEnvironment, "NOTIFY_KEY")
    }
    func testNotifyChannelL107() throws { throw XCTSkip("Node-only generated .mjs artifact and source-byte equality were retired when notify-channel became the native helper. Portable name/environment/capability/channel/ack behavior is retained in97/115; no fake script writer is claimed.") }
    func testNotifyChannelL115() async throws {
        let f = try rig(), clock = f.clock, caller = BackendDeckCoreSecurityCaller(kind: .key, tiers: [.read, .act], keyID: "app", keyName: "Claude Code")
        let started = await f.call("sessions.start", o([("cwd", .string("/work/api"))]), .init(caller: caller)), session = try XCTUnwrap(started.value["session"]["id"].string)
        let hub = BackendDeckCoreEventsHub(settings: { _ in .object([.init("mode", .string("wait"))]) }, clock: clock)
        let detector = BackendDeckCoreEventsDetector(surface: BackendDeckCoreTestPortSecurityChannelSurface(surface: f.surface, clock: clock),
            starterOf: { await f.control.starterOf(sessionID: $0) }, enqueue: { await hub.enqueue(keyId: $0, event: $1, turn: $2) }, clock: clock)
        let capture = BackendDeckCoreSecurityTestBox<[V]>([]), sent = BackendDeckCoreTestPortSecuritySignal(), waits = BackendDeckCoreTestPortSecuritySignal(), acked = BackendDeckCoreTestPortSecuritySignal()
        let bridge = BackendDeckCoreEventsChannelBridge(url: "http://127.0.0.1:47821/mcp", key: "ak_fake_source_key", clock: clock,
            wait: { _, _, ids in if !ids.isEmpty { _ = await hub.ack(keyId: "app", ids: ids); acked.signal() }; waits.signal(); return await hub.wait(keyId: "app", timeoutMs: 50_000) },
            send: { value in capture.edit { $0.append(value) }; sent.signal() })
        try await bridge.receive(rpc("initialize", params: o([("protocolVersion", .string("2026-07-28")), ("capabilities", .object([])), ("clientInfo", o([("name", .string("claude-code")), ("version", .string("2"))]))])))
        let initialized = capture.get()[0]; assertValue(initialized["result"]["capabilities"]["experimental"]["claude/channel"], .object([])); XCTAssertNotEqual(initialized["result"]["protocolVersion"], .string("2026-07-28"))
        try await bridge.receive(rpc("notifications/initialized", id: .missing)); await waits.wait(1); await clock.scheduled.wait(1); XCTAssertEqual(waits.value(), 1)
        await detector.noteStatus(sessionId: session, status: "working"); await detector.noteStatus(sessionId: session, status: "completed"); await detector.awaitIdle(); clock.advance(0); await sent.wait(2)
        let pushed = capture.get()[1]; XCTAssertEqual(pushed["method"], .string("notifications/claude/channel")); XCTAssertTrue(pushed["params"]["content"].string?.contains("finished its turn") == true); XCTAssertEqual(pushed["params"]["meta"]["session_id"], .string(session)); XCTAssertEqual(pushed["params"]["meta"]["kind"], .string("finished"))
        for field in pushed["params"]["meta"].fields ?? [] { XCTAssertNotNil(field.key.range(of: #"^[A-Za-z0-9_]+$"#, options: .regularExpression)) }
        await acked.wait(1); let remaining = await hub.list(keyId: "app"); XCTAssertFalse(remaining.contains { $0["id"] == pushed["params"]["meta"]["notification_id"] })
        await bridge.stop(); await hub.stop(); await detector.stop()
    }
}
