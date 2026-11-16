import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Presentation metadata only. Archiving never closes, stops or removes a provider conversation.
@MainActor @Observable final class NativeChatArchives {
    static let shared = NativeChatArchives(defaults: .standard)
    static let key = "chat.archivedSessions.v1"
    private(set) var ids: [String]
    @ObservationIgnored private let defaults: UserDefaults
    init(defaults: UserDefaults) { self.defaults = defaults; ids = defaults.stringArray(forKey: Self.key) ?? [] }
    func contains(_ id: String) -> Bool { ids.contains(id) }
    func set(_ id: String, archived: Bool) {
        if archived { if !ids.contains(id) { ids.append(id) } } else { ids.removeAll { $0 == id } }
        defaults.set(ids, forKey: Self.key)
    }
    func replaced(_ old: String, with next: String) {
        guard ids.contains(old) else { return }; ids = Array(Set(ids.map { $0 == old ? next : $0 })).sorted(); defaults.set(ids, forKey: Self.key)
    }
}
/// A submenu of the chat's ⋯ menu; Hoot is not a sidebar session, so it has none.
struct NativeChatOrganizationMenu: View {
    let model: NativeHootChatModel
    var body: some View {
        if let id = model.source.sessionID {
            Menu {
                Button(SIDEBARPins.shared.isPinned(id) ? "Unpin from sidebar" : "Pin in sidebar") { SIDEBARPins.shared.toggle(id) }
                Button(NativeChatArchives.shared.contains(id) ? "Restore to sidebar" : "Archive in sidebar") {
                    NativeChatArchives.shared.set(id, archived: !NativeChatArchives.shared.contains(id))
                }.disabled(model.busy || model.sending)
                Text("Archive keeps the chat and its history. Rename and Delete are in the sidebar's session menu.")
            } label: { Label(NativeChatMenuEntry.organize.title, systemImage: NativeChatMenuEntry.organize.symbol) }
        }
    }
}
struct NativeChatArchivedRows: View {
    let state: SidebarState
    let open: (String?) -> Void
    /// A page waiting for the person in one of these chats (MAC-NEXT-13 B1): the hand sits on the group's header, so it
    /// shows while the group is folded; its own click opens that page.
    var waiting: String? = nil
    var body: some View {
        if !NativeChatArchives.shared.ids.isEmpty {
            DisclosureGroup {
                ForEach(NativeChatArchives.shared.ids, id: \.self) { id in
                    HStack {
                        if let row = state.item(id: id) {
                            // A session row: the chat icon and its name (Asad, 15 Nov; DESIGN-SESSION-ROWS).
                            Button { open(id) } label: {
                                HStack(spacing: 8) {
                                    SIDEBARSessionTypeIcon(chat: true)
                                    Text(row.title).lineLimit(1).truncationMode(.tail)
                                }
                            }.buttonStyle(.plain)
                        }
                        else {
                            HStack(spacing: 8) {
                                SIDEBARSessionTypeIcon(chat: true)
                                Text("Chat not currently open").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 4)
                        Button("Restore") { NativeChatArchives.shared.set(id, archived: false) }.buttonStyle(.link).font(.caption)
                    }.padding(.vertical, 4)
                }
            } label: {
                HStack(spacing: 6) {
                    Text("Archived chats (\(NativeChatArchives.shared.ids.count))")
                    Spacer(minLength: 0)
                    if let waiting { SIDEBARWaitingHand(page: waiting) }
                }
            }.font(.callout)
        }
    }
}
extension NativeCompositionProduction {
    func chatOrganizationToolDefinitions(gate: BackendCompositionDeckToolsGate) throws -> [BackendDeckToolsDefinition] {
        let spec = try BackendMCPTool(id: "sessions.chat_organize", wireName: "sessions_chat_organize",
            description: "Read or change a Chat's existing sidebar pin or presentation archive. Archive keeps its session and history and refuses a working answer; restore only restores sidebar visibility. Rename uses sessions_rename; Delete uses window_buttons close-session with its existing confirmation. Mac owner only.",
            inputSchema: try NativeRPCValue.parseJSON(Data(#"{"type":"object","properties":{"sessionId":{"type":"string"},"do":{"type":"string","enum":["read","pin","unpin","archive","restore"]}},"required":["sessionId","do"],"additionalProperties":false}"#.utf8)), tier: .read)
        let chats = sessionChats
        return [BackendDeckToolsDefinition(spec: spec, title: "Organize Chat") { caller, args in
            await BackendDeckToolsSupport.reply {
                let resolved = try await gate.authority.resolve(caller)
                guard resolved.caller.kind == .local else { throw NativeRPCError(code: "not-granted", message: "Sidebar organization belongs to the Mac owner.") }
                let id = try args["sessionId"].requireString("chat session", nonempty: true)
                let meta = try await gate.authority.requireSession(id, native: caller)
                guard meta.chat == true else { throw NativeRPCError.invalidArguments("Choose a Chat session.") }
                let action = try args["do"].requireString("action")
                guard ["read", "pin", "unpin", "archive", "restore"].contains(action) else { throw NativeRPCError.invalidArguments("Choose a supported organization action.") }
                try await gate.authorize(caller, action == "read" ? .read : .act, "Organize this Chat in the sidebar", action != "read")
                if action == "archive" {
                    guard let chats else { throw NativeRPCError(code: "unavailable", message: "Chat is not ready.") }
                    let snapshot = try await chats.read(id, cursor: nil, limit: 1)
                    guard snapshot["busy"].bool != true else { throw NativeRPCError.invalidArguments("Wait for this answer before archiving its chat.") }
                }
                let result = await MainActor.run {
                    let pins = SIDEBARPins.shared, archives = NativeChatArchives.shared
                    if action == "pin" && !pins.isPinned(id) || action == "unpin" && pins.isPinned(id) { pins.toggle(id) }
                    if ["archive", "restore"].contains(action) { archives.set(id, archived: action == "archive") }
                    return NativeRPCValue.object([.init("sessionId", .string(id)), .init("pinned", .bool(pins.isPinned(id))), .init("archived", .bool(archives.contains(id)))])
                }
                await gate.noteResult(caller, result); return .value(result)
            }
        }]
    }
}
