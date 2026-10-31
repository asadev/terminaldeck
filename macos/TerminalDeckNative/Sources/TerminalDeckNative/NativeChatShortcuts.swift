import SwiftUI
import TerminalDeckNativeCore

struct NativeChatShortcuts {
    struct Entry: Identifiable {
        let id: String, keys: String, title: String, condition: String
        var wire: NativeRPCValue { .object([.init("action", .string(id)), .init("keys", .string(keys)), .init("title", .string(title)), .init("condition", .string(condition))]) }
    }
    static let entries: [Entry] = [
        .init(id: "send", keys: "Return", title: "Send or queue", condition: "In the composer; while working, the message queues."),
        .init(id: "newline", keys: "Shift Return", title: "New line", condition: "In the composer."),
        .init(id: "history.previous", keys: "↑", title: "Recall previous prompt", condition: "Empty composer, or at the end of an unchanged recalled prompt."),
        .init(id: "history.next", keys: "↓", title: "Recall next prompt", condition: "At the end of an unchanged recalled prompt."),
        .init(id: "attachments", keys: "⌘O", title: "Add files", condition: "Editable chat composer."),
        .init(id: "find", keys: "⌘F", title: "Find in conversation", condition: "Visible chat in the key window; no modal sheet."),
        .init(id: "find.next", keys: "⌘G", title: "Next match", condition: "Visible chat in the key window."),
        .init(id: "find.previous", keys: "⌘Shift G", title: "Previous match", condition: "Visible chat in the key window."),
        .init(id: "stop", keys: "⌘.", title: "Stop answer", condition: "Only the visible chat's active answer; queued messages stay held."),
        .init(id: "shortcuts", keys: "⌃⌘/", title: "Chat shortcuts", condition: "Visible chat in the key window.")
    ]
    static var wire: NativeRPCValue { .array(entries.map(\.wire)) }
    @MainActor static func navigate(_ model: NativeHootChatModel, action: String) {
        if action == "shortcuts" { model.chatShortcutsVisible = true }
        else if action == "stop" { if !model.readOnly && (model.busy || model.sending) { model.stop() } }
        else { model.findChat(action) }
    }
}
struct NativeChatShortcutsPopover: View {
    @Bindable var model: NativeHootChatModel
    var body: some View {
        Color.clear
            .popover(isPresented: $model.chatShortcutsVisible) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Chat shortcuts").font(.headline)
                    ScrollView {
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                            ForEach(NativeChatShortcuts.entries) { entry in
                                GridRow {
                                    Text(entry.keys).font(.callout.monospaced()).fixedSize()
                                    VStack(alignment: .leading, spacing: 3) { Text(entry.title); Text(entry.condition).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }.frame(maxHeight: 360)
                    Text("Queued messages have a Send now control for steering where supported.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(16).frame(width: 460)
            }
    }
}
