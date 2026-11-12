import SwiftUI
import TerminalDeckNativeCore

enum NativeChatRoutines {
    static let availability = "Local routines need Terminal Deck's engine running and this Mac awake. Missed times while closed are recorded; ordinary Chat does not keep running in the background. Provider cloud scheduling is not connected here."
    static func prepare(draft: HootComposerDraft, explicitPrompt: String?, folder: String, projectID: String) throws -> ROUTINESDraft {
        if explicitPrompt == nil, !draft.attachments.isEmpty || !draft.activeMentions.isEmpty {
            throw NativeRPCError.invalidArguments("Write an explicit plain-text routine prompt. Files and mention chips cannot be copied into a recurring prompt.")
        }
        let prompt = explicitPrompt ?? draft.text
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.utf8.count <= 8192 else { throw NativeRPCError.invalidArguments("Write a routine prompt between 1 byte and 8 KiB.") }
        var result = ROUTINESDraft(id: "routine-" + String(UUID().uuidString.prefix(8)).lowercased())
        result.name = "Chat follow-up"; result.prompt = prompt; result.folder = folder; result.projectID = projectID; result.enabled = false
        return result
    }
    static func wire(_ draft: ROUTINESDraft?) -> NativeRPCValue {
        .object([.init("availability", .string(availability)), .init("persistentRoutineCreated", .bool(false)),
            .init("managementTools", .string("routines_list, routines_save, routines_pause, routines_resume, routines_run, routines_reports")),
            .init("editorDraft", draft.map { .object([.init("id", .string($0.id)), .init("prompt", .string($0.prompt)), .init("folder", .string($0.folder)), .init("agentID", .string($0.agentID)), .init("enabled", .bool($0.enabled))]) } ?? .null)])
    }
}
extension NativeHootChatModel {
    func routineTool(_ action: String, request: String?, text: String?) async throws -> NativeRPCValue {
        if action == "open" {
            if request == "manage" { AppModel.shared.select("agents-routines"); chatRoutinesVisible = false }
            else { chatRoutinesVisible = true }
        }
        if action == "close" { chatRoutinesVisible = false; chatRoutineDraft = nil }
        if action == "prepare" {
            guard !readOnly, !loading, !changingConversation, !chatRoutinePreparing else { throw NativeRPCError.invalidArguments("Wait for this chat to finish loading before preparing a routine.") }
            guard chatRoutineDraft == nil else { throw NativeRPCError.invalidArguments("Finish or cancel the open routine editor first.") }
            chatRoutinePreparing = true; defer { chatRoutinePreparing = false }
            let folder = try await projectReferenceRoot()
            let projectID = PROJProjects.resolve(projectID: nil, folder: folder, projects: NativePROJLabels.shared.projects)
            let next = try NativeChatRoutines.prepare(draft: composerDraft, explicitPrompt: text, folder: folder, projectID: projectID)
            AGTAgentsStore.shared.start(); NativePROJLabels.shared.start()
            chatRoutineDraft = next; chatRoutinesVisible = false
        }
        return NativeChatRoutines.wire(chatRoutineDraft)
    }
}
struct NativeChatRoutinesPopover: View {
    @Bindable var model: NativeHootChatModel
    @State private var prompt = ""
    @State private var problem: String?
    @State private var editor = ROUTINESPageModel()
    var body: some View {
        Color.clear
            .onChange(of: model.chatRoutinesVisible) { _, open in if open { prompt = model.composerDraft.activeMentions.isEmpty ? model.composerDraft.text : "" } }
            .popover(isPresented: $model.chatRoutinesVisible) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Schedule a prompt").font(.headline)
                    Text(NativeChatRoutines.availability).font(.caption).foregroundStyle(.secondary)
                    Text("The routine runs with the agent chosen in its editor; it does not resume this conversation. Files and mention chips stay in Chat. Write all recurring instructions below.").font(.caption).foregroundStyle(.secondary)
                    NativeSessionTextEditor(text: $prompt).font(.body).frame(height: 150).accessibilityLabel("Plain prompt for routine")
                    NativeSessionButton(model.chatRoutinePreparing ? "Preparing editor…" : "Review as a new routine…") { run("prepare", text: prompt) }
                        .disabled(model.chatRoutinePreparing || model.readOnly || model.loading || model.changingConversation || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text("The editor starts with the routine off. Nothing is saved until you choose Save routine.").font(.caption).foregroundStyle(.secondary)
                    NativeSessionButton("Manage routines and recent runs") { run("open", request: "manage") }
                    if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
                }.padding(16).frame(width: 520)
            }
            .sheet(item: $model.chatRoutineDraft) { draft in ROUTINESRoutineSheet(model: editor, initial: draft, introduction: NativeChatRoutines.availability) }
    }
    private func run(_ action: String, request: String? = nil, text: String? = nil) { Task { do { _ = try await model.routineTool(action, request: request, text: text); problem = nil } catch { problem = error.localizedDescription } } }
}
