import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Only the native desktop callbacks are fake. The desktop wrapper, controller,
/// protocol parser/message factory and per-rig binding store are real.
@MainActor
final class BackendAppDesktopTestPortRig {
    struct Typed: Equatable { let session: String; let data: String }
    struct Pick: Equatable { let id: String; let viewID: String; let name: String; let x: Double; let y: Double; let up: Int }
    let bindings = BackendBrowserBindings()
    var panes: [BackendAppDesktopBrowserPane] = []
    var pages: [String: BackendAppDesktopBrowserPage] = [:]
    var hostSessions: [BackendRemoteServeBrowserSession] = []
    var did: [String] = []
    var typed: [Typed] = []
    var flows: [String: BackendAppDesktopBrowserRecorder.State] = [:]
    var stuck: Set<String> = []
    var opens: String? = "browser:9:9"
    var unclaimed: Set<String> = []
    var picks: [Pick] = []
    var waited: [Int] = []
    var authorizations: [(String, String?)] = []
    let hasRecorder: Bool
    let hasPick: Bool
    let shot = BackendRemoteServeBrowserCapture(path: "/Pictures/Terminal Deck/example.com-20260824-120000.png", width: 2560, height: 1440, preview: Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))
    lazy var operations = BackendAppMachineBrowserDesktop(access: access(), bindings: bindings, isMine: { $0 == "mydevice" })
    lazy var controller = operations.controller()
    init(recorder: Bool = true, pick: Bool = false) { hasRecorder = recorder; hasPick = pick }
    @discardableResult func add(_ n: Int, url: String, title: String = "") -> BackendAppDesktopBrowserPane {
        let pane = BackendAppDesktopBrowserPane(id: "browser:1:\(n)", viewID: "view:\(n)", url: url, title: title)
        panes.append(pane); pages["view:\(n)"] = .init(url: url, profile: "Default"); return pane
    }
    private func access() -> BackendAppDesktopBrowserAccess {
        let recorder: BackendAppDesktopBrowserRecorder? = hasRecorder ? .init(state: { [self] view, _ in
            if unclaimed.contains(view) { throw NativeRPCError(code: "unavailable", message: "browser-view: that tab is not open here") }
            return flows[view] ?? .init(recording: false, steps: [])
        }, set: { [self] view, on, _ in
            let flow = flows[view] ?? .init(recording: false, steps: []); flows[view] = .init(recording: on, steps: flow.steps)
        }) : nil
        let pick: BackendAppDesktopBrowserAccess.Pick? = hasPick ? { @MainActor @Sendable [self] target, x, y, up, _ in
            picks.append(.init(id: target.id, viewID: target.viewID, name: target.name, x: x, y: y, up: up))
            return .init(found: true, tag: "button", selector: "#save", label: "Save changes", labelSource: "text", x: 24, y: 1180, width: 128, height: 40, depth: Double(up), maxUp: Double(6 - up))
        } : nil
        return .init(panes: { [self] _ in panes }, page: { [self] view, _ in pages[view] }, openPane: { [self] url, _ in
            did.append("open \(url)")
            guard let id = opens else { return nil }
            panes.append(.init(id: id, viewID: "view:" + id, url: url)); pages["view:" + id] = .init(url: url, profile: "Default"); return id
        }, closePane: { [self] target, _ in
            did.append("close \(target.id) \(target.viewID) \(target.name)")
            if stuck.contains(target.id) { return false }; panes.removeAll { $0.id == target.id }; return true
        }, go: { [self] view, url, _ in did.append("go \(view) \(url)") }, history: { [self] view, move, _ in did.append("\(move) \(view)") }, capture: { [self] view, _ in did.append("capture \(view)"); return shot }, sessions: { [self] _ in hostSessions }, write: { [self] session, data, _ in typed.append(.init(session: session, data: data)) }, authorize: { [self] context, action, target in
            guard context.caller == .pairedDevice, context.ownerID == "mydevice" else { throw NativeRPCError(code: "access-denied", message: "Fixture expects the paired owner device.") }
            authorizations.append((action, target))
        }, pick: pick, recorder: recorder, now: { 1_700_000_000_000 }, wait: { [self] milliseconds in waited.append(milliseconds) })
    }
    func answer(_ tag: String, _ fields: [NativeRPCValue.Field] = []) async throws -> NativeRPCValue {
        let request: BackendRemoteClientMessage
        switch BackendRemoteProtocol.parseClientMessage(.object([.init("t", .string(tag))] + fields)) {
        case .message(let parsed): request = parsed
        case .refused(let failure): throw failure
        }
        let response = await controller.answer(request, deviceID: "mydevice", kind: .mine, context: .init(caller: .pairedDevice, ownerID: "mydevice"))
        // The controller constructs BackendRemoteServerMessage through its real
        // schema factories. Preserve the resulting frame exactly for assertions.
        return response.value
    }
    func rows(_ value: NativeRPCValue) throws -> [NativeRPCValue] {
        XCTAssertEqual(value["t"].string, "browser.window.rows")
        return try XCTUnwrap(value["windows"].elements)
    }
    func notice(_ value: NativeRPCValue) -> String { value["notice"].string ?? "" }
    func held(_ session: String) -> [BrowserBoundWindow] { bindings.bindings(for: .init(ownerID: "fixture", managesWindows: true)).of(.init(sessionId: session)) }
    func heldView(_ session: String) -> [NativeRPCValue] {
        let view = bindings.view(for: .init(ownerID: "fixture", managesWindows: true))
        return view["sessions"].elements?.first { $0["sessionId"].string == session }?["windows"].elements ?? []
    }
}
