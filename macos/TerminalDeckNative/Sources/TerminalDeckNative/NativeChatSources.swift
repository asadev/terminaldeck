import AppKit
import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

enum NativeChatInstructionSources {
    static func files(cwd: String, agentFile: String?, exists: (String) -> Bool) -> [String] {
        let root = URL(fileURLWithPath: cwd)
        let candidates = (cwd.hasPrefix("/") ? ["AGENTS.md", "CLAUDE.md", "GEMINI.md"].map { root.appendingPathComponent($0).path } : []) + [agentFile].compactMap { $0 }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted && exists($0) }
    }
    static func state(files: [String], owner: String?) -> NativeRPCValue {
        .object([.init("filesPresent", .array(files.map(NativeRPCValue.string))), .init("memoryOwner", owner.map(NativeRPCValue.string) ?? .null),
            .init("effectiveAppliedSources", .null), .init("notice", .string("These files are present and this is the app's memory owner. The provider's complete applied instruction/memory manifest has not been reported."))])
    }
}
extension NativeHootChatModel {
    func instructionSources() async throws -> NativeRPCValue {
        let cwd: String
        if let id = source.sessionID {
            let sessions = try await EngineBridge.shared.invoke("session:list") as? [[String: Any]] ?? []
            cwd = sessions.first { $0["id"] as? String == id }?["cwd"] as? String ?? ""
        } else { cwd = DeckProject.current ?? "" }
        let agentFile = AGTAgentsStore.shared.profile(replyAgent)?.sourceFile
        let files = NativeChatInstructionSources.files(cwd: cwd, agentFile: agentFile, exists: { FileManager.default.fileExists(atPath: $0) })
        let owner = source.isHoot ? DeckMemoryOwner.hoot : source.sessionID.flatMap { id in DeckMemorySessionCenter.shared.flatMap { BackendAGTMemoryOwners.memoryOwner($0.owner(sessionID: id)) } }
        return NativeChatInstructionSources.state(files: files, owner: owner?.key).setting("cwd", .string(cwd))
    }
    func sourceTool(_ action: String, request: String?) async throws -> NativeRPCValue {
        let state = try await instructionSources()
        if action == "open" {
            if let request {
                if request == "memory" {
                    guard state["memoryOwner"].string != nil else { throw NativeRPCError(code: "unavailable", message: "This chat has no assigned memory seat.") }
                    chatMemoryVisible = true
                } else {
                    guard state["filesPresent"].elements?.contains(.string(request)) == true else { throw NativeRPCError.invalidArguments("Choose a present instruction source from read.") }
                    guard NSWorkspace.shared.open(URL(fileURLWithPath: request)) else { throw NativeRPCError(code: "open-failed", message: "The default editor could not open that source.") }
                }
            } else { chatSourcesVisible = true }
        }
        if action == "close" { chatSourcesVisible = false; chatMemoryVisible = false }
        return state
    }
}
/// Instruction files and the links/files the chat emitted are one job: the "Instructions & sources" list of
/// ⓘ Session › Context, a tab each.
struct NativeChatSourcesPanel: View {
    @Bindable var model: NativeHootChatModel
    @State private var state: NativeRPCValue?
    @State private var problem: String?
    var body: some View {
        NativeChatTabbedPanel([("instructions", "Instructions"), ("sources", "Links & files")], first: model.chatArtifactsVisible && !model.chatSourcesVisible ? "sources" : "instructions") { tab in
            if tab == "sources" { NativeChatArtifactsView(model: model) } else { instructions }
        }
    }
    private var instructions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Instructions and memory").font(.headline)
            if let state {
                Text(state["notice"].string ?? "").font(.caption).foregroundStyle(.secondary)
                ForEach(state["filesPresent"].elements?.compactMap(\.string) ?? [], id: \.self) { path in
                    HStack { Text(path).font(.caption.monospaced()).lineLimit(2).textSelection(.enabled); Spacer(); Button("Open in editor") { run(path) } }
                }
                if let owner = state["memoryOwner"].string {
                    Text("Memory seat: \(owner)").font(.caption)
                    Button("Open this seat's memory") { run("memory") }
                } else { Text("No assigned memory seat. Shared diary and project files may still apply.").font(.caption).foregroundStyle(.secondary) }
            } else { ProgressView("Reading source metadata…") }
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
        }.padding(16).frame(width: 520)
            .task { do { state = try await model.instructionSources() } catch { problem = error.localizedDescription } }
    }
    private func run(_ request: String) { Task { do { state = try await model.sourceTool("open", request: request) } catch { problem = error.localizedDescription } } }
}
/// The seat's memory, opened from the sources list or by the sources tool; it hangs off the chat's strip.
struct NativeChatMemorySheet: View {
    @Bindable var model: NativeHootChatModel
    @State private var state: NativeRPCValue?
    var body: some View {
        Color.clear
            .sheet(isPresented: $model.chatMemoryVisible) {
                VStack {
                    if let key = state?["memoryOwner"].string, let owner = DeckMemoryOwner(key: key) { NativeMemoryArea(owner: owner) }
                    else { Text("Memory seat is not available.") }
                    Button("Done") { model.chatMemoryVisible = false }.padding(8)
                }.frame(width: 780, height: 560)
                    .task { if state == nil { state = try? await model.instructionSources() } }
            }
    }
}
