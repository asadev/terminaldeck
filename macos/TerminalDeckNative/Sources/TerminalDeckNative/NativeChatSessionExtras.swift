import SwiftUI
import TerminalDeckNativeCore

/// File checkpoints (F29), background tasks (F35), fork, worktree and where the Chat runs (F38, F56, F57).
/// Every button is one named helper or app action that the MCP tools reach too; nothing here is local-only.
struct NativeChatSessionExtrasView: View {
    let sessionID: String
    @State private var checkpoints: [NativeRPCValue] = []
    @State private var checkpointNote = ""
    @State private var preview = NativeRPCValue.null
    @State private var previewTurn: String?
    @State private var confirmRestore = false
    @State private var confirmRemoveWorktree = false
    @State private var tasks: [NativeRPCValue] = []
    @State private var taskNote = ""
    @State private var taskOutput = ""
    @State private var outputTask: String?
    @State private var location = NativeRPCValue.null
    @State private var title = ""
    @State private var worktree = NativeRPCValue.null
    @State private var busy = false
    @State private var error: String?
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if busy { ProgressView().controlSize(.small) }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if let notice { Text(notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            GroupBox("File checkpoints") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Put back the files this chat changed since one of your messages. Your conversation is not rewound, and Git is not used.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Read checkpoints") { load { try await checkpointsRead() } }
                    if !checkpointNote.isEmpty { Text(checkpointNote).font(.caption).foregroundStyle(.secondary) }
                    ForEach(Array(checkpoints.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .top) {
                            Text(row["text"].string ?? "Message").lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                            Button("Preview") { load { try await previewCheckpoint(row["turnId"].string) } }
                        }.font(.caption)
                    }
                    if previewTurn != nil, !preview.isNullish {
                        VStack(alignment: .leading, spacing: 4) {
                            if preview["canRewind"].bool == true {
                                Text("\(Int(preview["fileCount"].number ?? 0)) file(s), +\(Int(preview["insertions"].number ?? 0)) / -\(Int(preview["deletions"].number ?? 0)) lines would be restored").font(.callout)
                                ForEach(preview["files"].elements?.compactMap(\.string) ?? [], id: \.self) { Text($0).font(.caption.monospaced()).textSelection(.enabled) }
                                Button("Restore these files…") { confirmRestore = true }
                            } else {
                                Text(preview["error"].string ?? "The provider has no checkpoint for that message.").font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.padding(4).frame(maxWidth: .infinity, alignment: .leading)
            }
            .alert("Restore files?", isPresented: $confirmRestore) {
                Button("Restore", role: .destructive) { load { try await restoreCheckpoint() } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("The files listed in the preview go back to how they were before that message. The conversation stays as it is.") }
            GroupBox("Background task history") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Button("Read tasks") { load { try await readTasks() } }; Button("Move foreground tasks to background") { load { try await taskAction("background/detach", [.init("all", .bool(true))]) } } }
                    if !taskNote.isEmpty { Text(taskNote).font(.caption).foregroundStyle(.secondary) }
                    Text("Running tasks and their Stop controls are above the message box.").font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(tasks.filter { $0["running"].bool != true }.enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading) {
                                Text(row["title"].string ?? row["id"].string ?? "Task").lineLimit(2)
                                Text((row["kind"].string ?? "task") + " · " + (row["status"].string ?? "unknown")).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Button("Output") { load { try await readOutput(row["id"].string) } }
                        }.font(.caption)
                    }
                    if let outputTask, !taskOutput.isEmpty {
                        Text("Last output of \(outputTask)").font(.caption).foregroundStyle(.secondary)
                        Text(taskOutput).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.padding(4).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Worktree and location") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("A worktree is a separate checkout of the project, so chats can work in separate folders.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Name for the new work (optional)", text: $title)
                    HStack {
                        Button("New Chat in a worktree") { load { try await forkAction("worktree-chat", [.init("title", .string(title))]) } }
                    }
                    HStack {
                        Button("Worktree status") { load { worktree = try await forkAction("worktree-status", [], open: false) } }
                        Button("Remove worktree…") { confirmRemoveWorktree = true }
                        Button("Where does this run?") { load { location = try await forkAction("location", [], open: false) } }
                    }
                    if !worktree.isNullish { NativeChatProviderResult(value: worktree) }
                    if !location.isNullish { NativeChatProviderResult(value: location) }
                }.padding(4).frame(maxWidth: .infinity, alignment: .leading)
            }
            // #548: removing the checkout asks first, like restoring files does.
            .alert("Remove this chat's worktree?", isPresented: $confirmRemoveWorktree) {
                Button("Remove", role: .destructive) { load { worktree = try await forkAction("worktree-remove", [], open: false) } }
                Button("Cancel", role: .cancel) {}
            } message: { Text("The separate checkout folder is deleted, including ignored files such as local settings. Its branch stays.") }
        }
    }

    private func load(_ work: @escaping () async throws -> Void) {
        busy = true; error = nil; notice = nil
        Task { defer { busy = false }; do { try await work() } catch { self.error = error.localizedDescription } }
    }
    private func call(_ operation: String, _ fields: [NativeRPCValue.Field] = []) async throws -> NativeRPCValue {
        try NativeRPCValue.fromFoundation(await EngineBridge.shared.invoke("session:chat:provider", [sessionID, operation, NativeRPCValue.object(fields).foundation]))
    }
    private func checkpointsRead() async throws {
        let value = try await call("checkpoints/list")
        checkpoints = value["items"].elements ?? []; checkpointNote = value["reason"].string ?? value["note"].string ?? ""
    }
    private func previewCheckpoint(_ turn: String?) async throws {
        guard let turn else { return }
        preview = try await call("checkpoints/preview", [.init("turnId", .string(turn))]); previewTurn = turn
    }
    private func restoreCheckpoint() async throws {
        guard let turn = previewTurn, let digest = preview["digest"].string else { return }
        let done = try await call("checkpoints/restore", [.init("turnId", .string(turn)), .init("approvedDigest", .string(digest))])
        notice = "Restored \((done["files"].elements ?? []).count) file(s). The conversation was not rewound."
        preview = .null; previewTurn = nil
    }
    private func readTasks() async throws {
        let value = try await call("background/list")
        tasks = value["items"].elements ?? []; taskNote = value["note"].string ?? ""
    }
    private func readOutput(_ id: String?) async throws {
        guard let id else { return }
        let value = try await call("background/output", [.init("taskId", .string(id))])
        outputTask = id; taskOutput = value["output"].string ?? ""
        if taskOutput.isEmpty { notice = "That task has written no output." }
    }
    private func taskAction(_ operation: String, _ fields: [NativeRPCValue.Field]) async throws {
        let value = try await call(operation, fields)
        notice = value["note"].string ?? "Requested."
        try await readTasks()
    }
    @discardableResult
    private func forkAction(_ action: String, _ fields: [NativeRPCValue.Field], open: Bool = true) async throws -> NativeRPCValue {
        let fields = fields.filter { $0.value.string != "" }
        let result = try NativeRPCValue.fromFoundation(await EngineBridge.shared.invoke("session:chat:fork", [sessionID, action, NativeRPCValue.object(fields).foundation]))
        if open, let created = result["session"].foundation as? [String: Any], let id = created["id"] as? String {
            AppModel.shared.buttonActions.created(created); AppModel.shared.select(id)
            if result["confirmed"].bool != true { error = result["warning"].string ?? "The provider did not confirm the new conversation." }
        }
        return result
    }
}
