import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

enum BackendDeckCoreTestPortSessionsDeviceFixtureSupport {
    typealias V = NativeRPCValue
    static let ios = "ios:AAAA-1111"
    static func o(_ fields: [(String, V)]) -> V { .object(fields.map { .init($0.0, $0.1) }) }
    static func context(_ kind: BackendDeckToolsMachinesContext.Kind = .local, machine: String = "") -> BackendDeckToolsMachinesContext {
        .init(kind: kind, attended: true, sessionID: kind == .session ? "s1" : nil, machineID: machine, deviceID: kind == .remote ? "d1" : nil,
              rpc: .init(caller: .nativeApp, ownerID: "fixture"), startedByCopilot: { _ in false }, noteStarted: { _ in })
    }
    static func spec(_ id: String) throws -> BackendMCPTool {
        let row = try XCTUnwrap(BackendDeckToolsMachinesCatalogue.rows().first { $0["id"].string == id })
        return try BackendMCPTool(id: id, wireName: row["wire"].string!, description: row["description"].string!, inputSchema: row["inputSchema"], tier: BackendMCPTier(rawValue: row["tier"].string!)!)
    }
    /// Prepare from the actual domain policy, then use the actual central gate,
    /// schema validator and persistent action log. The service itself is fake.
    static func call(_ id: String, args: V, fixture: BackendDeckCoreTestPortSessionsDeviceFixture,
                     context: BackendDeckToolsMachinesContext = context()) async throws -> BackendDeckCoreSecurityCallResult {
        let devices = BackendDeckToolsMachinesDevices(service: fixture), tool = try spec(id)
        var prepared: BackendDeckToolsMachinesPolicy?, failure: (any Error)?
        do { prepared = try await devices.policy(tool, args, context) } catch { failure = error }
        let policy = prepared, preflightError = failure
        let gatePolicy = BackendDeckCoreSecurityToolPolicy(tool: tool, spendsDeviceInput: policy?.spends == "device-input", summary: { _, _ in policy?.sentence ?? id },
            precheck: { _, _ in if let preflightError { throw preflightError } },
            redactArgs: { original in policy?.loggedArguments ?? original }, run: { arguments, _ in
                let output = try await devices.run(id, arguments, context)
                return .init(value: output.value, summary: output.summary)
            })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendDeckCoreTestPortSessions-device-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = BackendDeckCoreSecurityActionLog(directory: root, now: { 1000 })
        let consent = BackendDeckCoreSecurityConsentBroker(now: { 1000 }, ask: { _ in XCTFail("Device reads/input never ask here"); return false })
        let gate = try BackendDeckCoreSecurityControl(log: log, consent: consent, policies: [gatePolicy], now: { 1000 })
        let caller = BackendDeckCoreSecurityCaller(kind: BackendDeckCoreSecurityCaller.Kind(rawValue: context.kind.rawValue) ?? .local,
            tiers: [.read, .act, .alter], deviceID: context.deviceID, sessionID: context.sessionID, machineID: context.machineID)
        let result = await gate.call(name: id, arguments: args, options: .init(caller: caller))
        let logFile = await log.file
        fixture.logText = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
        return result
    }
    static func entry(_ id: String = ios, name: String = "iPhone 17 Pro", state: String = "ready", platform: String = "ios", kind: String = "simulator", available: Bool = true, canBoot: Bool = false, canShutdown: Bool = true) -> V {
        o([("id", .string(id)), ("name", .string(name)), ("state", .string(state)), ("platform", .string(platform)), ("kind", .string(kind)),
            ("available", .bool(available)), ("runtime", .string(platform == "ios" ? "iOS 27.0" : "")), ("canBoot", .bool(canBoot)), ("canShutDown", .bool(canShutdown)),
            ("buttons", .array(["home", "lock", "volume-up", "volume-down", "action"].map(V.string))), ("keys", .array(["return", "delete", "tab"].map(V.string))),
            ("text", .string("unicode")), ("canRotate", .bool(true)), ("note", .string(""))])
    }
    static func node(_ ref: String, role: String, name: String? = nil, id: String? = nil, x: Double, y: Double, w: Double, h: Double, children: [DeviceNode] = []) -> DeviceNode {
        .init(ref: ref, role: role, label: name, identifier: id, frame: .init(x: x, y: y, width: w, height: h), children: children)
    }
    static func checkout() -> DeviceNode {
        var password = node("r3", role: "AXTextField", name: "Password", id: "password-field", x: 0.1, y: 0.2, w: 0.8, h: 0.06)
        password.valueRedacted = true; password.focused = true
        var cancel = node("r6", role: "AXButton", name: "Cancel", x: 0.1, y: 0.9, w: 0.3, h: 0.06); cancel.enabled = false
        var hidden = node("r8", role: "AXGroup", x: 0, y: 0.5, w: 1, h: 0.5, children: [node("r9", role: "AXButton", name: "Secret menu", x: 0.1, y: 0.6, w: 0.3, h: 0.06)]); hidden.hidden = true
        return node("r0", role: "AXApplication", x: 0, y: 0, w: 1, h: 1, children: [node("r1", role: "AXGroup", x: 0, y: 0, w: 1, h: 1, children: [
            node("r2", role: "AXStaticText", name: "Checkout", x: 0.1, y: 0.05, w: 0.8, h: 0.05), password,
            node("r4", role: "AXButton", name: "Pay", id: "pay-button", x: 0.1, y: 0.8, w: 0.8, h: 0.08, children: [node("r5", role: "AXStaticText", name: "Pay", x: 0.4, y: 0.82, w: 0.2, h: 0.04)]),
            cancel, node("r7", role: "AXButton", x: 0.9, y: 0.05, w: 0.08, h: 0.05), hidden
        ])])
    }
    static func round(_ id: String, kind: String) -> V {
        let location = kind == "device" ? o([("kind", .string(kind)), ("place", .string("iOS Simulator")), ("name", .string("iPhone 17 Pro")), ("deviceId", .string(ios)), ("app", .string("com.example.Shop"))]) : o([("kind", .string(kind)), ("place", .string("browser page")), ("name", .string("Shop")), ("url", .string("https://shop.example.com/cart"))])
        return o([("id", .string(id)), ("createdAt", .number(1_790_000_000_000)), ("where", location), ("frame", o([("width", .number(1206)), ("height", .number(2622))])),
            ("annotations", .array([o([("id", .string("a1")), ("n", .number(1)), ("rect", o([("x", .number(0.1)), ("y", .number(0.8)), ("width", .number(0.8)), ("height", .number(0.08))])), ("element", o([("role", .string("button")), ("name", .string("Pay")), ("identifier", .string("pay-button"))]))]),
                o([("id", .string("a2")), ("n", .number(2)), ("rect", o([("x", .number(0)), ("y", .number(0)), ("width", .number(0.1)), ("height", .number(0.1))])), ("element", .null)])])),
            ("note", .string("Make #1 green and put #2 on the left.")), ("picture", o([("path", .string("/Users/someone/Pictures/App/\(id)-annotated.png")), ("width", .number(1206)), ("height", .number(2622))]))])
    }
}

final class BackendDeckCoreTestPortSessionsDeviceFixture: BackendDeckToolsMachinesDeviceService, @unchecked Sendable {
    typealias V = NativeRPCValue
    typealias S = BackendDeckCoreTestPortSessionsDeviceFixtureSupport
    struct Call { let name: String; let args: [V] }
    var calls: [Call] = [], reason: String?, logText = ""
    var devices: [V], details: V, screen: DeviceNode, stored: [V] = []
    var bootAnswer: V = .object([.init("ok", .bool(true)), .init("id", .string("android:emulator-5554"))])
    var shutAnswer: V = .object([.init("ok", .bool(true))]), source = "core-simulator-ax", fallback = "", engineTruncated = false
    init() {
        devices = [S.entry(), S.entry("avd:Pixel_9", name: "Pixel 9", state: "shutdown", platform: "android", kind: "emulator", available: false, canBoot: true, canShutdown: false).setting("buttons", .array([])).setting("keys", .array([])).setting("text", .string("none")).setting("canRotate", .bool(false)),
            S.entry("android:R58M123", name: "Galaxy S25", state: "unauthorized", platform: "android", kind: "physical", available: false).setting("note", .string("Unlock the phone and allow this computer when it asks."))]
        details = S.entry().setting("pointWidth", .number(402)).setting("pointHeight", .number(874)).setting("rawTouch", .bool(true)); screen = S.checkout()
    }
    var names: [String] { calls.map(\.name) }
    func note(_ name: String, _ args: [V] = []) { calls.append(.init(name: name, args: args)) }
    func unavailable() -> String? { reason }
    func list() -> [V] { note("list"); return devices }
    func boot(_ id: String) -> V { note("boot", [.string(id)]); return bootAnswer }
    func shutDown(_ id: String) -> V { note("shutDown", [.string(id)]); return shutAnswer }
    func open(_ id: String) -> V { note("open", [.string(id)]); return details.setting("id", .string(id)) }
    func screenshot(_ id: String) -> V { note("screenshot", [.string(id)]); return S.o([("path", .string("/Users/someone/Pictures/App/iPhone-17-Pro-20261003-142233.png")), ("width", .number(1206)), ("height", .number(2622))]) }
    func tap(_ id: String, x: Double, y: Double, holdMS: Int?) { note("tap", [.string(id), .number(x), .number(y), holdMS.map { .number(Double($0)) } ?? .missing]) }
    func swipe(_ id: String, from: V, to: V, durationMS: Int) { note("swipe", [.string(id), from, to, .number(Double(durationMS))]) }
    func type(_ id: String, text: String) { note("type", [.string(id), .string(text)]) }
    func key(_ id: String, key: String, modifiers: [String]) { note("key", [.string(id), .string(key), .array(modifiers.map(V.string))]) }
    func button(_ id: String, button: String) { note("button", [.string(id), .string(button)]) }
    func rotate(_ id: String, to: String) -> String { note("rotate", [.string(id), .string(to)]); return to }
    func tree(_ id: String, scope: String) -> BackendDeckToolsMachinesDeviceTreeAnswer { note("tree", [.string(id), .string(scope)]); return .init(tree: .init(source: source, capturedAt: "2026-10-03T10:00:00.000Z", root: screen, nodeCount: 10, truncated: engineTruncated), foreground: S.o([("app", .string("com.example.Shop")), ("screen", .string(""))]), fallback: fallback) }
    func rounds() -> [V] { stored }
}
