import AppKit
import Darwin
import SwiftUI
import TerminalDeckNativeCore

@MainActor @Observable final class NativeChatDraftEditor {
    static let limit = 262_144
    var text = ""
    private(set) var baseline: HootComposerDraft?
    private(set) var conversation = ""
    private(set) var file: URL?
    func begin(_ draft: HootComposerDraft, conversation: String) {
        guard baseline == nil else { return }
        baseline = draft; self.conversation = conversation; text = draft.text
    }
    func check(_ draft: HootComposerDraft, conversation: String) throws {
        guard baseline == draft, self.conversation == conversation else { throw NativeRPCError.invalidArguments("Chat changed while this editor was open. Keep its text, cancel this copy and reopen; the current draft was preserved.") }
    }
    func checkedText() throws -> String {
        guard text.utf8.count <= Self.limit, !text.contains("\0") else { throw NativeRPCError.invalidArguments("Keep the prompt within 256 KiB of UTF-8 text without NUL characters.") }
        return text
    }
    func export() throws -> URL {
        let content = try checkedText()
        guard baseline != nil else { throw NativeRPCError.invalidArguments("Open a draft snapshot first.") }
        if let file { return file }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-chat-draft-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let url = root.appendingPathComponent("prompt.md")
        do { try Data(content.utf8).write(to: url, options: .atomic); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path); file = url; return url }
        catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    func readExternal() throws -> String {
        guard let file else { throw NativeRPCError.invalidArguments("Export the editor copy first.") }
        let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw NativeRPCError.invalidArguments("The editor copy is missing or became a symbolic link. The draft was preserved.") }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= Self.limit else { throw NativeRPCError.invalidArguments("Import requires a regular text file no larger than 256 KiB.") }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: Self.limit + 1) ?? Data()
        guard data.count <= Self.limit, let text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw NativeRPCError.invalidArguments("The editor copy is not supported UTF-8 text within 256 KiB.") }
        return text
    }
    func clear() {
        if let file { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        file = nil; baseline = nil; text = ""; conversation = ""
    }
    var state: NativeRPCValue { .object([.init("text", .string(text)), .init("bytes", .number(Double(text.utf8.count))), .init("limitBytes", .number(Double(Self.limit))), .init("editorFile", file.map { .string($0.path) } ?? .null), .init("hasSnapshot", .bool(baseline != nil)), .init("automaticSend", .bool(false))]) }
}
extension NativeHootChatModel {
    func longDraftTool(_ action: String, text: String?) throws -> NativeRPCValue {
        featurePanel("long-draft", action)
        let editor = chatDraftEditor
        if ["open", "edit", "export", "open-editor"].contains(action) { editor.begin(composerDraft, conversation: conversationID) }
        if action == "edit" { guard let text, text.utf8.count <= NativeChatDraftEditor.limit else { throw NativeRPCError.invalidArguments("Provide prompt text within 256 KiB.") }; editor.text = text }
        if ["export", "open-editor"].contains(action) {
            try editor.check(composerDraft, conversation: conversationID)
            let file = try editor.export()
            if action == "open-editor", !fixtureMode, !NSWorkspace.shared.open(file) { throw NativeRPCError.invalidArguments("No editor accepted the private prompt copy. It remains available for import or cancellation.") }
        }
        if ["apply", "import"].contains(action) {
            try editor.check(composerDraft, conversation: conversationID)
            if action == "import" { editor.text = try editor.readExternal() }
            try setDraftText(editor.checkedText()); editor.clear(); chatFeaturePanels.remove("long-draft")
        }
        if action == "cancel" { editor.clear(); chatFeaturePanels.remove("long-draft") }
        return editor.state.setting("appliedToDraft", .bool(["apply", "import"].contains(action)))
    }
}
struct NativeChatLongDraftPopover: View {
    @Bindable var model: NativeHootChatModel
    @State private var problem: String?
    var body: some View {
        Color.clear
            .popover(isPresented: Binding(get: { model.chatFeaturePanels.contains("long-draft") }, set: { if !$0 { model.chatFeaturePanels.remove("long-draft") } })) {
                @Bindable var editor = model.chatDraftEditor
                VStack(alignment: .leading, spacing: 12) {
                    Text("Edit full prompt").font(.headline)
                    Text("\(editor.text.utf8.count) / 262144 UTF-8 bytes · files and mention chips stay in the original draft. Apply/import refuses to overwrite a changed draft or conversation.").font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $editor.text).font(.body.monospaced()).frame(height: 320).accessibilityLabel("Full prompt editor")
                    HStack { Button("Apply editor text to draft") { run("apply") }; Button("Open private copy in editor") { run("open-editor") } }
                    if editor.file != nil { Button("Import saved editor copy") { run("import") } }
                    Button("Discard editor copy") { run("cancel") }
                    if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
                }.padding(16).frame(width: 660)
            }
    }
    private func run(_ action: String) { do { _ = try model.longDraftTool(action, text: nil); problem = nil } catch { problem = error.localizedDescription } }
}
