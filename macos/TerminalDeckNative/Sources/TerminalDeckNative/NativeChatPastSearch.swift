import SwiftUI
import TerminalDeckNativeCore

enum NativeChatPastSearch {
    static func request(cwd: String, query: String, scope: String, role: String) throws -> NativeRPCValue {
        guard !cwd.isEmpty, query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2,
              ["project", "all"].contains(scope), ["all", "user", "assistant", "tool"].contains(role) else {
            throw NativeRPCError.invalidArguments("Choose a project, scope, speaker and at least two search characters.")
        }
        return .object([.init("cwd", .string(cwd)), .init("query", .string(query)), .init("scope", .string(scope)),
            .init("roles", .array((role == "all" ? ["user", "assistant", "tool"] : [role]).map(NativeRPCValue.string))), .init("maxHits", .number(100))])
    }
}

struct NativeChatPastSearchView: View {
    let initialProject: String
    @State private var query = ""
    @State private var scope = "project"
    @State private var role = "all"
    @State private var hits: [NativeRPCValue] = []
    @State private var loading = false
    @State private var problem: String?
    @State private var excerpt = ""
    @State private var generation = 0
    @State private var limited = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Search past chats").font(.headline)
            Text(initialProject).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack { TextField("Search conversation text", text: $query).onSubmit(search); Button("Search", action: search).disabled(query.count < 2 || loading) }
            HStack {
                Picker("Scope", selection: $scope) { Text("This project").tag("project"); Text("All projects").tag("all") }
                Picker("Speaker", selection: $role) { Text("Everyone").tag("all"); Text("You").tag("user"); Text("Assistant").tag("assistant"); Text("Tools").tag("tool") }
            }
            if limited { Text("Search limits reached. Narrow the query for more complete results.").font(.caption).foregroundStyle(.secondary) }
            if loading { ProgressView("Searching recorded chats…") }
            if let problem { Text(problem).foregroundStyle(.red).textSelection(.enabled) }
            Text("\(hits.count) matches · Recorded project transcripts").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(hits.enumerated()), id: \.offset) { _, hit in
                        Button {
                            Task {
                                do {
                                    let raw = try await EngineBridge.shared.invoke("chat:load", [["transcriptPath": hit["transcriptPath"].string ?? ""]])
                                    excerpt = "Matched text\n" + (hit["snippet"]["text"].string ?? "") + "\n\nRead-only recent excerpt\n\n" + (ChatUpdate.decode(raw)?.messages.map { $0.text }.joined(separator: "\n\n") ?? "Transcript unavailable")
                                } catch { problem = error.localizedDescription }
                            }
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                let identity = NativeSessionRowIdentity(id: hit["sessionId"].string ?? "", folder: hit["cwd"].string, provider: hit["provider"].string ?? "claude", chat: true)
                                identity.picture()
                                VStack(alignment: .leading, spacing: 4) {
                                    if let subtitle = identity.subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
                                    Text("\(hit["projectName"].string ?? "Project") · \(hit["role"].string ?? "") · \(hit["sessionId"].string ?? "")").font(.caption).foregroundStyle(.secondary)
                                    Text(hit["snippet"]["text"].string ?? "").font(.callout).lineLimit(4).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }.padding(8).background(DeckTokens.card, in: .rect(cornerRadius: 8))
                        }.buttonStyle(.plain)
                    }
                }
            }.frame(minHeight: 100, maxHeight: 300)
            if !excerpt.isEmpty { ScrollView { Text(excerpt).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 160) }
        }.padding(16).frame(width: 580)
            .onChange(of: scope) { _, _ in invalidate() }
            .onChange(of: role) { _, _ in invalidate() }
            .onChange(of: query) { _, _ in invalidate() }
    }
    private func invalidate() { generation += 1; hits = []; loading = false; limited = false }
    private func search() {
        generation += 1; let asked = generation
        loading = true; problem = nil; hits = []; limited = false
        Task {
            do {
                let request = try NativeChatPastSearch.request(cwd: initialProject, query: query, scope: scope, role: role)
                let result = try NativeRPCValue.fromFoundation(await EngineBridge.shared.invoke("session-search:run", [request.foundation]))
                guard asked == generation else { return }
                loading = false
                if result["ok"].bool == true { hits = result["hits"].elements ?? []; limited = result["truncated"].bool == true }
                else { problem = result["message"].string ?? result["error"].string ?? "Search did not complete." }
            } catch { if asked == generation { loading = false; problem = error.localizedDescription } }
        }
    }
}
