import AppKit
import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

final class NativePassiveChatPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    func prepareForPassiveCapture() {
        isReleasedWhenClosed = false; hidesOnDeactivate = false; ignoresMouseEvents = true
        level = .floating
        collectionBehavior = [.canJoinAllApplications, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }
}

private struct PassiveChatSurface: View {
    let initial: String
    let slot: String
    var body: some View {
        let rail = NativeSessionRailContinuity.shared
        let id = AppModel.shared.visibleSidebar?.allItems.first(where: { rail.identity($0.id) == slot })?.id ?? initial
        NativeTerminalScreen(sessionId: id)
    }
}

@MainActor private enum PassiveChatWindows {
    struct Entry { let window: NativePassiveChatPanel; let initial: String; let slot: String }
    static var entries: [Int: Entry] = [:]
    static func open(_ id: String) -> NativeRPCValue {
        let slot = NativeSessionRailContinuity.shared.identity(id)
        if let held = entries.values.first(where: { $0.slot == slot && $0.window.isVisible }) { return state(held) }
        let panel = NativePassiveChatPanel(contentRect: NSRect(x: -30_000, y: -30_000, width: 960, height: 680),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // Auxiliary windows retain their full surface instead of Stage Manager thumbnails.
        panel.prepareForPassiveCapture()
        panel.identifier = NSUserInterfaceItemIdentifier("check-passive:" + slot)
        panel.title = "check passive Chat"
        panel.contentViewController = NSHostingController(rootView: PassiveChatSurface(initial: id, slot: slot))
        panel.orderBack(nil)
        let entry = Entry(window: panel, initial: id, slot: slot)
        entries[panel.windowNumber] = entry
        return state(entry)
    }
    static func close(_ id: Int) throws -> NativeRPCValue {
        guard let entry = entries.removeValue(forKey: id) else { throw NativeRPCError.invalidArguments("Choose one of the owned check windows.") }
        entry.window.close()
        return .object([.init("closed", .bool(true)), .init("windowId", .number(Double(id)))])
    }
    static func state(_ entry: Entry) -> NativeRPCValue {
        .object([.init("windowId", .number(Double(entry.window.windowNumber))), .init("sessionId", .string(entry.initial)),
            .init("visible", .bool(entry.window.isVisible)), .init("canBecomeKey", .bool(entry.window.canBecomeKey)),
            .init("canBecomeMain", .bool(entry.window.canBecomeMain))])
    }
    static var states: NativeRPCValue { .array(entries.values.map(state)) }
}

extension NativeCompositionProduction {
    func passiveChatWindowTool(gate: BackendCompositionDeckToolsGate) throws -> BackendDeckToolsDefinition {
        guard let chats = sessionChats else { throw BackendHOSTFailure.unavailable }
        let schema = try NativeRPCValue.parseJSON(Data(#"{"type":"object","properties":{"action":{"type":"string","enum":["read","open","close"]},"sessionId":{"type":"string"},"windowId":{"type":"integer","minimum":1,"maximum":2147483647}},"required":["action"],"additionalProperties":false}"#.utf8))
        let spec = try BackendMCPTool(id: "windows.check", wireName: "windows_check",
            description: "Owner-local checks only: open a fresh off-screen, never-key window showing the real Chat view of a session titled check followed by a space. Read or close only these check windows. No activation, user input, session start, or session stop. It follows provider handovers. Capture by its returned windowId.", inputSchema: schema, tier: .read)
        return BackendDeckToolsDefinition(spec: spec, title: "Passive Chat check window") { caller, args in
            await BackendDeckToolsSupport.reply {
                let resolved = try await gate.authority.resolve(caller)
                guard resolved.caller.kind == .local, resolved.caller.actsAsOwner else { throw BackendHOSTFailure.authentication }
                let action = args["action"].string ?? "read"
                try await gate.authorize(caller, action == "read" ? .read : .act, "Use an owned passive Chat check window", action != "read")
                if action == "read" { return .value(await MainActor.run { PassiveChatWindows.states }) }
                if action == "close" {
                    guard let id = args["windowId"].number, id.isFinite, id >= 1, id <= Double(Int32.max), id.rounded() == id else { throw NativeRPCError.invalidArguments("Supply the owned windowId.") }
                    return .value(try await MainActor.run { try PassiveChatWindows.close(Int(id)) })
                }
                let id = try args["sessionId"].requireString("sessionId", nonempty: true)
                let meta = try await gate.authority.requireSession(id, native: caller)
                guard meta.title.lowercased().hasPrefix("check ") else { throw NativeRPCError.invalidArguments("Only your named check sessions can use this window.") }
                let state = try await chats.read(id, cursor: nil, limit: 1)
                guard state["readOnly"].bool != true else { throw NativeRPCError.invalidArguments("Choose a live check Chat.") }
                return .value(await MainActor.run { PassiveChatWindows.open(id) })
            }
        }
    }
}
