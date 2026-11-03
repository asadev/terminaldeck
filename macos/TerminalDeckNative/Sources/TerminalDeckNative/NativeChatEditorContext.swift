import Foundation
import CryptoKit
import SwiftUI
import TerminalDeckNativeCore

struct NativeChatEditorSnapshot: Identifiable, Equatable {
    let id: String, path: String, text: String
    let selection: NSRange
    let truncatedFile: Bool
    let revision: Int
    var metadata: NativeRPCValue { .object([.init("id", .string(id)), .init("path", .string(path)), .init("revision", .number(Double(revision))), .init("hasSelection", .bool(selection.length > 0)), .init("displayedFileIsTruncated", .bool(truncatedFile)), .init("origin", .string("Terminal Deck Files viewer"))]) }
    func context(_ mode: String) throws -> (payload: String, receipt: NativeRPCValue) {
        guard ["selection", "file"].contains(mode) else { throw NativeRPCError.invalidArguments("Choose selection or file.") }
        let source = text as NSString
        let range = mode == "file" ? NSRange(location: 0, length: source.length) : selection
        guard range.location >= 0, range.location <= source.length, range.length > 0, range.length <= source.length - range.location else { throw NativeRPCError.invalidArguments("Select text in the Files viewer first.") }
        let safe = source.rangeOfComposedCharacterSequences(for: range), body = source.substring(with: safe)
        let first = source.substring(to: safe.location).components(separatedBy: "\n").count
        let last = source.substring(to: max(safe.location, NSMaxRange(safe) - 1)).components(separatedBy: "\n").count
        var run = 0, longest = 0
        for character in body { run = character == "`" ? run + 1 : 0; longest = max(longest, run) }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        let file = String(decoding: try NativeRPCValue.string(path).encodedJSON(), as: UTF8.self)
        let scope = mode == "selection" ? "Selected text" : truncatedFile ? "Displayed file excerpt" : "Open file text"
        let payload = "\(scope) from Terminal Deck Files\nFile: \(file)\nLines: \(first)–\(last)\n\(fence)\n\(body)\n\(fence)"
        let receipt = metadata.setting("mode", .string(mode)).setting("scope", .string(scope)).setting("lineStart", .number(Double(first))).setting("lineEnd", .number(Double(last)))
            .setting("utf8Bytes", .number(Double(body.utf8.count))).setting("contentSHA256", .string(Self.digest(body))).setting("stage", .string("prepared draft")).setting("deliveryConfirmed", .bool(false))
        return (payload, receipt)
    }
    static func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
}
@MainActor @Observable final class NativeChatEditorContexts {
    static let shared = NativeChatEditorContexts()
    private(set) var snapshots: [NativeChatEditorSnapshot] = []
    @ObservationIgnored private var revision = 0
    func update(id: String, path: String, text: String, selection: NSRange, truncated: Bool) {
        let length = (text as NSString).length
        let valid = selection.location >= 0 && selection.location <= length && selection.length >= 0 && selection.length <= length - selection.location
        let range = valid ? selection : NSRange(location: 0, length: 0)
        if let old = snapshots.first(where: { $0.id == id }), old.path == path, old.text == text, old.selection == range, old.truncatedFile == truncated { return }
        revision += 1; snapshots.removeAll { $0.id == id }
        snapshots.insert(.init(id: id, path: path, text: text, selection: range, truncatedFile: truncated, revision: revision), at: 0)
    }
    func remove(_ id: String) { snapshots.removeAll { $0.id == id } }
    func checked(_ id: String, revision: Int?) throws -> NativeChatEditorSnapshot {
        guard let snapshot = snapshots.first(where: { $0.id == id }), revision == snapshot.revision else { throw NativeRPCError(code: "stale-context", message: "This file or selection changed. Read its current revision before inserting it.") }
        return snapshot
    }
}
extension NativeHootChatModel {
    func editorContextTool(_ action: String, request: String?, mode: String?, revision: Int?, store: NativeChatEditorContexts = .shared) throws -> NativeRPCValue {
        if action == "open" { chatEditorContextVisible = true }
        if action == "close" { chatEditorContextVisible = false }
        if action == "insert" {
            guard !loading, !changingConversation else { throw NativeRPCError(code: "unavailable", message: "Wait for this chat to finish loading before inserting context.") }
            let snapshot = try store.checked(request ?? "", revision: revision)
            let prepared = try snapshot.context(mode ?? "selection")
            try setDraftText(composerDraft.text.isEmpty ? prepared.payload : composerDraft.text + "\n\n" + prepared.payload)
            chatEditorContextReceipt = prepared.receipt.setting("preparedDraftSHA256", .string(NativeChatEditorSnapshot.digest(composerDraft.text)))
        }
        let receipt = chatEditorContextReceipt.isNullish ? .null : chatEditorContextReceipt.setting("draftTextChangedSincePreparation", .bool(chatEditorContextReceipt["preparedDraftSHA256"].string != NativeChatEditorSnapshot.digest(composerDraft.text)))
        return .object([.init("files", .array(store.snapshots.map(\.metadata))), .init("receipt", receipt), .init("scope", .string("Open Terminal Deck Files views only; selections and displayed file text are inserted visibly into the editable draft"))])
    }
}
struct NativeChatEditorContextPanel: View {
    @Bindable var model: NativeHootChatModel
    @State private var outcome: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open-file and selection context").font(.headline)
            Text("Choose text from Terminal Deck's Files viewer. The exact excerpt enters your draft, where you can edit it before sending.").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(NativeChatEditorContexts.shared.snapshots) { snapshot in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(snapshot.path).font(.caption.monospaced()).lineLimit(3).textSelection(.enabled)
                            if snapshot.truncatedFile { Text("Displayed file is an excerpt.").font(.caption).foregroundStyle(.secondary) }
                            HStack {
                                Button("Insert selection") { insert(snapshot, "selection") }.disabled(snapshot.selection.length == 0 || model.readOnly || model.loading || model.changingConversation)
                                Button(snapshot.truncatedFile ? "Insert displayed excerpt" : "Insert open file text") { insert(snapshot, "file") }.disabled(snapshot.text.isEmpty || model.readOnly || model.loading || model.changingConversation)
                            }
                            if snapshot.selection.length > 0, let preview = try? snapshot.context("selection") { Text(preview.payload).font(.caption.monospaced()).lineLimit(8).textSelection(.enabled) }
                        }
                    }
                    if NativeChatEditorContexts.shared.snapshots.isEmpty { Text("Open a text file in Files, then select the text you want to include.").foregroundStyle(.secondary) }
                }
            }.frame(maxHeight: 340)
            if let scope = model.chatEditorContextReceipt["scope"].string {
                Text("Prepared: \(scope) · \(Int(model.chatEditorContextReceipt["utf8Bytes"].number ?? 0)) bytes · SHA256 \(String((model.chatEditorContextReceipt["contentSHA256"].string ?? "").prefix(12)))").font(.caption).textSelection(.enabled)
                if model.chatEditorContextReceipt["preparedDraftSHA256"].string != NativeChatEditorSnapshot.digest(model.composerDraft.text) { Text("Draft text changed since this receipt was prepared.").font(.caption).foregroundStyle(.secondary) }
                Text("This is a draft receipt; sending and later edits are separate.").font(.caption).foregroundStyle(.secondary)
            }
            if let outcome { Text(outcome).font(.caption) }
        }.padding(16).frame(width: 590)
    }
    private func insert(_ snapshot: NativeChatEditorSnapshot, _ mode: String) { do { _ = try model.editorContextTool("insert", request: snapshot.id, mode: mode, revision: snapshot.revision); outcome = "Context inserted; existing text, mentions and files preserved." } catch { outcome = error.localizedDescription } }
}
