import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Fake operations, clock and submission gap; the actual binding store is used.
@MainActor
final class BackendRemoteServeBrowserPortRig: BackendRemoteServeBrowserOperations {
    struct Typed: Equatable { let session: String, data: String }
    struct Point: Equatable { let id: String, x: Double, y: Double, up: Int }
    static let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
    static let shotPath = "/Pictures/Terminal Deck/example.com-20260823-120000.png"
    let bindings = BackendBrowserBindings()
    var windows: [BackendRemoteServeBrowserWindow] = [], hostSessions: [BackendRemoteServeBrowserSession] = []
    var typed: [Typed] = [], did: [String] = [], pickedAt: [Point] = [], waited: [Int] = []
    var steps: [BrowserRecordedStep] = [], breaks: Set<String> = [], without: Set<String> = []
    var openReturnsNil = false, openReason: String?
    var shot = BackendRemoteServeBrowserCapture(path: BackendRemoteServeBrowserPortRig.shotPath, width: 1280, height: 800, preview: BackendRemoteServeBrowserPortRig.png)
    var picked = BackendRemoteServeBrowserPicked(found: true, tag: "button", selector: "#save", label: "Save changes", labelSource: "text",
        x: 24, y: 1180, width: 128, height: 40, depth: 0, maxUp: 6)
    var canRecord: Bool { !without.contains("recorder") }
    var canRepartition: Bool { !without.contains("repartition") }
    var canPick: Bool { !without.contains("pick") }
    func add(_ window: BackendRemoteServeBrowserWindow) {
        windows.append(window)
        bindings.observe(.init(tabID: window.id, viewID: window.viewID ?? "", url: window.url, title: window.title))
    }
    func guardOperation(_ name: String) throws { if breaks.contains(name) { throw NativeRPCError(code: "unavailable", message: "the \(name) dep is unwell") } }
    func isMine(_ deviceID: String) async -> Bool { true }
    func list(context: NativeRPCContext) async throws -> [BackendRemoteServeBrowserWindow] { try guardOperation("list"); return windows }
    func sessions(context: NativeRPCContext) async throws -> [BackendRemoteServeBrowserSession] { try guardOperation("sessions"); return hostSessions }
    func open(url: String, profile: String, isolated: Bool, context: NativeRPCContext) async throws -> String? {
        try guardOperation("open"); if openReturnsNil { return nil }
        let id = "browser:\(1000 + windows.count):aa"
        add(.init(id: id, url: url.isEmpty ? "about:blank" : url, viewID: "view-\(id)", profile: profile, isolated: isolated)); return id
    }
    func whyNotOpen() -> String? { openReason }
    func go(id: String, url: String, context: NativeRPCContext) async throws {
        try guardOperation("go"); did.append("go \(id) \(url)")
        if let index = windows.firstIndex(where: { $0.id == id }) { windows[index].url = url }
    }
    func history(id: String, move: String, context: NativeRPCContext) async throws { try guardOperation("history"); did.append("\(move) \(id)") }
    func close(id: String, context: NativeRPCContext) async throws { try guardOperation("close"); did.append("close \(id)"); windows.removeAll { $0.id == id } }
    func attach(id: String, sessionID: String, context: NativeRPCContext) async throws -> BrowserBoundWindow { try bindings.attach(id, to: .init(sessionId: sessionID)) }
    func detach(id: String, context: NativeRPCContext) async throws { bindings.detach(id) }
    func repartition(id: String, isolated: Bool, context: NativeRPCContext) async throws -> BackendRemoteServeBrowserMove? {
        try guardOperation("repartition"); did.append("repartition \(id) \(isolated ? "isolated" : "shared")")
        guard let index = windows.firstIndex(where: { $0.id == id }) else { return nil }
        windows[index].isolated = isolated; windows[index].viewID = "view-\(id)-\(isolated ? "iso" : "shared")"
        return .init(viewID: windows[index].viewID)
    }
    func setRecording(id: String, on: Bool, context: NativeRPCContext) async throws {
        try guardOperation("recorder"); did.append("record \(on ? "on" : "off") \(id)")
        if let index = windows.firstIndex(where: { $0.id == id }) { windows[index].recording = on }
    }
    func recordedSteps(id: String, context: NativeRPCContext) async throws -> [BrowserRecordedStep] { try guardOperation("recorder"); did.append("steps \(id)"); return steps }
    func capture(id: String, context: NativeRPCContext) async throws -> BackendRemoteServeBrowserCapture { try guardOperation("capture"); did.append("capture \(id)"); return shot }
    func pick(id: String, x: Double, y: Double, up: Int, context: NativeRPCContext) async throws -> BackendRemoteServeBrowserPicked {
        try guardOperation("pick"); pickedAt.append(.init(id: id, x: x, y: y, up: up)); return picked
    }
    func write(sessionID: String, data: String, context: NativeRPCContext) async throws { try guardOperation("write"); typed.append(.init(session: sessionID, data: data)) }
    func now() -> Double { 1_700_000_000_000 }
    func wait(milliseconds: Int) async throws { waited.append(milliseconds) }
    func answer(_ tag: String, _ fields: [NativeRPCValue.Field] = []) async -> NativeRPCValue {
        let frame = BackendRemoteClientMessage(.object([.init("t", .string(tag))] + fields))
        let context = NativeRPCContext(caller: .pairedDevice, ownerID: "phone")
        return await BackendRemoteServeBrowserControl(operations: self).answer(frame, deviceID: "phone", kind: .mine, context: context).value
    }
    func held(_ session: String) -> [BrowserBoundWindow] { bindings.bindings(for: .init(ownerID: "test", managesWindows: true)).of(.init(sessionId: session)) }
    func step(kind: BrowserRecordedStep.Kind = .click, selector: String = "#submit", label: String = "Sign in", tag: String = "button", value: String = "",
              redacted: Bool = false, url: String = "https://example.com/", at: Double = 1_700_000_000_000) -> BrowserRecordedStep {
        .init(kind: kind, selector: selector, label: label, tag: tag, value: value, redacted: redacted, url: url, at: at)
    }
}
