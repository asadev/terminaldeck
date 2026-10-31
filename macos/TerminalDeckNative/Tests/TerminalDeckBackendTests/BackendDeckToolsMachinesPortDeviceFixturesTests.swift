import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

actor BackendDeckToolsMachinesPortDevices: BackendDeckToolsMachinesDeviceService {
    typealias V = NativeRPCValue
    var reason: String?
    var devices: [V]
    var details: V
    var root: DeviceNode
    var stored: [V] = []
    var booted: V = BackendDeckToolsMachinesPortObject(["ok": .bool(true), "id": .string("android:emulator-5554")])
    var shut: V = BackendDeckToolsMachinesPortObject(["ok": .bool(true)])
    var engineTruncated = false
    var source = "core-simulator-ax"
    var fallback = ""
    var calls: [(String, [V])] = []
    init() { devices = Self.inventory(); details = Self.deviceDetails(); root = Self.checkout() }
    static func entry(_ over: V = .object([])) -> V {
        var entry = BackendDeckToolsMachinesPortObject(["id": .string("ios:AAAA-1111"), "platform": .string("ios"), "kind": .string("simulator"), "state": .string("ready"), "available": .bool(true), "name": .string("iPhone 17 Pro"), "runtime": .string("iOS 27.0"), "canBoot": .bool(false), "canShutDown": .bool(true), "buttons": .array(["home", "lock", "volume-up", "volume-down", "action"].map(V.string)), "keys": .array(["return", "delete", "tab"].map(V.string)), "text": .string("unicode"), "canRotate": .bool(true), "note": .string("")])
        for field in over.fields ?? [] { entry = entry.setting(field.key, field.value) }; return entry
    }
    static func inventory() -> [V] { [entry(), entry(BackendDeckToolsMachinesPortObject(["id": .string("avd:Pixel_9"), "platform": .string("android"), "kind": .string("emulator"), "state": .string("shutdown"), "available": .bool(false), "name": .string("Pixel 9"), "runtime": .string(""), "canBoot": .bool(true), "canShutDown": .bool(false), "buttons": .array([]), "keys": .array([]), "text": .string("none"), "canRotate": .bool(false)])), entry(BackendDeckToolsMachinesPortObject(["id": .string("android:R58M123"), "platform": .string("android"), "kind": .string("physical"), "state": .string("unauthorized"), "available": .bool(false), "name": .string("Galaxy S25"), "note": .string("Unlock the phone and allow this computer when it asks.")]))] }
    static func deviceDetails() -> V { BackendDeckToolsMachinesPortObject(["id": .string("ios:AAAA-1111"), "name": .string("iPhone 17 Pro"), "platform": .string("ios"), "kind": .string("simulator"), "pointWidth": .number(402), "pointHeight": .number(874), "buttons": .array(["home", "lock", "volume-up", "volume-down", "action"].map(V.string)), "keys": .array(["return", "delete", "tab"].map(V.string)), "text": .string("unicode"), "canRotate": .bool(true), "rawTouch": .bool(true)]) }
    static func checkout() -> DeviceNode {
        var password = DeviceNode(ref: "r3", role: "AXTextField", label: "Password", identifier: "password-field", focused: true, frame: .init(x: 0.1, y: 0.2, width: 0.8, height: 0.06)); password.valueRedacted = true
        return DeviceNode(ref: "r0", role: "AXApplication", frame: .init(x: 0, y: 0, width: 1, height: 1), children: [DeviceNode(ref: "r1", role: "AXGroup", children: [
            DeviceNode(ref: "r2", role: "AXStaticText", label: "Checkout", value: "Checkout", frame: .init(x: 0.1, y: 0.05, width: 0.8, height: 0.05)), password,
            DeviceNode(ref: "r4", role: "AXButton", label: "Pay", identifier: "pay-button", frame: .init(x: 0.1, y: 0.8, width: 0.8, height: 0.08), children: [DeviceNode(ref: "r5", role: "AXStaticText", label: "Pay", frame: .init(x: 0.4, y: 0.82, width: 0.2, height: 0.04))]),
            DeviceNode(ref: "r6", role: "AXButton", label: "Cancel", enabled: false, frame: .init(x: 0.1, y: 0.9, width: 0.3, height: 0.06)),
            DeviceNode(ref: "r7", role: "AXButton", frame: .init(x: 0.9, y: 0.05, width: 0.08, height: 0.05)),
            DeviceNode(ref: "r8", role: "AXGroup", hidden: true, children: [DeviceNode(ref: "r9", role: "AXButton", label: "Secret menu", frame: .init(x: 0.1, y: 0.6, width: 0.3, height: 0.06))])])])
    }
    func unavailable() -> String? { reason }
    func list() -> [V] { calls.append(("list", [])); return devices }
    func boot(_ id: String) -> V { calls.append(("boot", [.string(id)])); return booted }
    func shutDown(_ id: String) -> V { calls.append(("shutDown", [.string(id)])); return shut }
    func open(_ id: String) -> V { calls.append(("open", [.string(id)])); return details.setting("id", .string(id)) }
    func screenshot(_ id: String) -> V { calls.append(("screenshot", [.string(id)])); return BackendDeckToolsMachinesPortObject(["path": .string("/Users/someone/Pictures/App/iPhone-17-Pro-20261003-142233.png"), "width": .number(1_206), "height": .number(2_622)]) }
    func tap(_ id: String, x: Double, y: Double, holdMS: Int?) { calls.append(("tap", [.string(id), .number(x), .number(y), holdMS.map { .number(Double($0)) } ?? .missing])) }
    func swipe(_ id: String, from: V, to: V, durationMS: Int) { calls.append(("swipe", [.string(id), from, to, .number(Double(durationMS))])) }
    func type(_ id: String, text: String) { calls.append(("type", [.string(id), .string(text)])) }
    func key(_ id: String, key: String, modifiers: [String]) { calls.append(("key", [.string(id), .string(key), .array(modifiers.map(V.string))])) }
    func button(_ id: String, button: String) { calls.append(("button", [.string(id), .string(button)])) }
    func rotate(_ id: String, to: String) -> String { calls.append(("rotate", [.string(id), .string(to)])); return to }
    func tree(_ id: String, scope: String) -> BackendDeckToolsMachinesDeviceTreeAnswer { calls.append(("tree", [.string(id), .string(scope)])); return .init(tree: .init(source: source, capturedAt: "2026-10-03T10:00:00.000Z", root: root, nodeCount: 10, truncated: engineTruncated), foreground: BackendDeckToolsMachinesPortObject(["app": .string("com.example.Shop"), "screen": .string("")]), fallback: fallback) }
    func rounds() -> [V] { stored }
    func names() -> [String] { calls.map(\.0) }
    func seen(_ name: String) -> [[V]] { calls.filter { $0.0 == name }.map(\.1) }
    func clear() { calls = [] }
    func configure(reason: String?) { self.reason = reason }
    func inventory(_ value: [V]) { devices = value }
    func detail(_ key: String, _ value: V) { details = details.setting(key, value) }
    func setRoot(_ root: DeviceNode) { self.root = root }
    func store(_ value: [V]) { stored = value }
    func setBoot(_ value: V) { booted = value }
    func setShut(_ value: V) { shut = value }
    func treeMeta(source: String? = nil, truncated: Bool? = nil, fallback: String? = nil) { if let source { self.source = source }; if let truncated { engineTruncated = truncated }; if let fallback { self.fallback = fallback } }
}
func BackendDeckToolsMachinesPortRound(_ id: String, _ kind: String) -> NativeRPCValue {
    let o = BackendDeckToolsMachinesPortObject
    return o(["id": .string(id), "createdAt": .number(1_790_000_000_000), "where": kind == "device" ? o(["kind": .string(kind), "place": .string("iOS Simulator"), "name": .string("iPhone 17 Pro"), "deviceId": .string("ios:AAAA-1111"), "app": .string("com.example.Shop")]) : o(["kind": .string(kind), "place": .string("browser page"), "name": .string("Shop"), "url": .string("https://shop.example.com/cart")]), "frame": o(["width": .number(1_206), "height": .number(2_622)]), "annotations": .array([o(["id": .string("a1"), "n": .number(1), "rect": o(["x": .number(0.1), "y": .number(0.8), "width": .number(0.8), "height": .number(0.08)]), "element": o(["role": .string("button"), "name": .string("Pay"), "identifier": .string("pay-button")])]), o(["id": .string("a2"), "n": .number(2), "rect": o(["x": .number(0), "y": .number(0), "width": .number(0.1), "height": .number(0.1)]), "element": .null])]), "note": .string("Make #1 green and put #2 on the left."), "picture": o(["path": .string("/Users/someone/Pictures/App/\(id)-annotated.png"), "width": .number(1_206), "height": .number(2_622)])])
}
func BackendDeckToolsMachinesPortDeviceCall(_ fake: BackendDeckToolsMachinesPortDevices, _ id: String, _ args: NativeRPCValue,
                                         context: BackendDeckToolsMachinesContext = BackendDeckToolsMachinesPortContext(),
                                         environment: BackendDeckToolsMachinesPortEnvironment? = nil) async throws -> BackendMCPToolReply {
    let env = environment ?? BackendDeckToolsMachinesPortEnvironment(context), area = BackendDeckToolsMachinesDevices(service: fake)
    let definitions = try area.definitions(environment: env)
    guard let tool = definitions.first(where: { $0.spec.id == id }) else { throw BackendDeckToolsArgs.bad("no fixture device tool") }
    return try await tool.handler(BackendDeckToolsMachinesPortNativeContext(), args)
}
