import SwiftUI
import TerminalDeckNativeCore

/// Uses the existing project transcript catalogue. It never guesses a provider from a filename.
enum NativeChatLibrary {
    static func matches(_ row: NativeRPCValue, query: String) -> Bool {
        query.isEmpty || [row["sessionId"].string, row["path"].string].compactMap { $0 }.joined(separator: " ").localizedStandardContains(query)
    }
    static func resumeInput(_ row: NativeRPCValue, cwd: String) throws -> NativeRPCValue {
        let id = try row["sessionId"].requireString("conversation id", nonempty: true)
        guard !cwd.isEmpty, id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil else {
            throw NativeRPCError.invalidArguments("Choose a recorded conversation and project.")
        }
        // insights:list is the Claude transcript catalogue, not a cross-provider guess.
        return .object([.init("cwd", .string(cwd)), .init("provider", .string("claude")), .init("chat", .bool(true)),
            .init("resume", .bool(true)), .init("resumeConversationId", .string(id)), .init("cols", .number(100)), .init("rows", .number(30))])
    }
}

struct NativeChatLibraryView: View {
    var sessionID: String? = nil
    /// The chat whose own prompts the search field at the top finds.
    var prompts: NativeHootChatModel? = nil
    @State private var cwd = ""
    @State private var query = ""
    @State private var rows: [NativeRPCValue] = []
    @State private var loading = false
    /// The folder the last load asked for; only a different folder (the person editing the field) clears the list.
    @State private var loadedFolder = ""
    @State private var problem: String?
    @State private var preview = ""
    @State private var working = false
    @State private var searching = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let prompts { NativeChatPromptSearchView(model: prompts); Divider() }
            HStack { Text("Past conversations").font(.headline); Spacer(); Button("Search text…") { searching = true }.disabled(cwd.isEmpty) }
            TextField("Project folder", text: $cwd).onSubmit { load() }.disabled(working)
            HStack { TextField("Conversation ID or path", text: $query); Button("Load") { load() }.disabled(cwd.isEmpty || loading) }
            Text("Claude project transcripts")
                .font(.caption).foregroundStyle(.secondary)
            if loading { ProgressView("Loading conversations…") }
            if let problem { Text(problem).foregroundStyle(.red).textSelection(.enabled) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(rows.filter { NativeChatLibrary.matches($0, query: query) }.enumerated()), id: \.offset) { _, row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row["sessionId"].string ?? "Conversation").font(.callout.monospaced()).textSelection(.enabled)
                            HStack {
                                Button("Preview") { perform { let raw = try await EngineBridge.shared.invoke("chat:load", [["transcriptPath": row["path"].string ?? ""]]); let update = ChatUpdate.decode(raw); preview = (update?.startedMidFile == true ? "Recent excerpt (earlier messages omitted)\n\n" : "Read-only transcript\n\n") + (update?.messages.map { "\($0.role == .you ? "You" : "Assistant")\n\($0.text)" }.joined(separator: "\n\n") ?? "Transcript unavailable") } }
                                Button("Resume Claude chat") { perform {
                                    let input = try NativeChatLibrary.resumeInput(row, cwd: cwd)
                                    guard let result = try await EngineBridge.shared.invoke("session:create", [input.foundation]) as? [String: Any], result["resumed"] as? Bool == true else {
                                        throw NativeRPCError(code: "resume-unconfirmed", message: "The provider did not confirm a resumed conversation. Check the newly opened session before sending.")
                                    }
                                    AppModel.shared.buttonActions.created(result)
                                    if let id = result["id"] as? String { AppModel.shared.select(id) }
                                } }
                            }.disabled(working)
                        }
                    }
                    if !loading && rows.isEmpty { Text("No loaded conversations").foregroundStyle(.secondary) }
                }
            }.frame(minHeight: 120, maxHeight: 260)
            if !preview.isEmpty { ScrollView { Text(preview).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 160) }
        }.padding(16).frame(width: 560)
            .onChange(of: cwd) { _, folder in guard folder != loadedFolder else { return }; rows = []; preview = ""; loading = false }
            .sheet(isPresented: $searching) { VStack { NativeChatPastSearchView(initialProject: cwd); Button("Done") { searching = false }.padding(.bottom) } }
            .task {
                if let sessionID, let sessions = try? await EngineBridge.shared.invoke("session:list") as? [[String: Any]], let row = sessions.first(where: { $0["id"] as? String == sessionID }) { cwd = row["cwd"] as? String ?? "" }
                else { cwd = DeckProject.current ?? "" }
                if !cwd.isEmpty { load() }
            }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        working = true; problem = nil
        Task { defer { working = false }; do { try await action() } catch { problem = error.localizedDescription } }
    }
    private func load() {
        loading = true; problem = nil
        let asked = cwd
        loadedFolder = asked
        Task {
            defer { if asked == cwd { loading = false } }
            do {
                let loaded = try NativeRPCValue.fromFoundation(await EngineBridge.shared.invoke("insights:list", [asked])).elements ?? []
                guard asked == cwd else { return }
                rows = loaded
            } catch { if asked == cwd { rows = []; problem = error.localizedDescription } }
        }
    }
}
