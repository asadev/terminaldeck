import Foundation
import Observation
import SwiftUI
import TerminalDeckNativeCore

/// Settings screen model for remote workers. Every button goes through the same owner channel
/// the `agents.remote_*` tools use, and shows what the service really answered.
@MainActor @Observable final class NativeRemoteWorkersModel {
    typealias Invoke = @MainActor @Sendable (NativeRPCValue) async throws -> NativeRPCValue
    var state: NativeRPCValue = .null
    var pending = false
    var problem: String?
    var newName = ""
    var newURL = ""
    var tokens: [String: String] = [:]
    var prompts: [String: String] = [:]
    var messages: [String: String] = [:]
    private let invoke: Invoke
    init(invoke: Invoke? = nil) {
        self.invoke = invoke ?? { try await EngineBridge.shared.invokeNativeValue("remote-workers:perform", [$0]) }
    }
    var connections: [NativeRPCValue] { state["connections"].elements ?? [] }
    func runs(for connection: String) -> [NativeRPCValue] { (state["runs"].elements ?? []).filter { $0["connection"].string == connection } }
    func load() async {
        do { state = try await invoke(.object([.init("op", .string("list"))])) } catch { problem = error.localizedDescription }
    }
    /// Runs one action, then reloads the list. Secrets are cleared from the screen as soon as they are sent.
    func perform(_ op: String, _ fields: [NativeRPCValue.Field] = []) async {
        guard !pending else { return }; pending = true; problem = nil
        defer { pending = false }
        do { _ = try await invoke(.object([.init("op", .string(op))] + fields)) } catch { problem = error.localizedDescription }
        await load()
    }
    func addConnection() async {
        await perform("connection_set", [.init("label", .string(newName)), .init("url", .string(newURL))])
        if problem == nil { newName = ""; newURL = "" }
    }
    func saveToken(_ connection: String) async {
        let token = tokens[connection] ?? ""; tokens[connection] = ""
        await perform("credential_set", [.init("connection", .string(connection)), .init("token", .string(token))])
    }
    func start(_ connection: String) async {
        let prompt = prompts[connection] ?? ""
        await perform("start", [.init("connection", .string(connection)), .init("prompt", .string(prompt))])
        if problem == nil { prompts[connection] = "" }
    }
    func resume(_ run: String) async {
        let message = messages[run] ?? ""
        await perform("resume", [.init("run", .string(run)), .init("message", .string(message))])
        if problem == nil { messages[run] = "" }
    }
    static func tokenText(_ run: NativeRPCValue) -> String {
        guard run["tokens"]["reported"].bool == true else { return "Tokens: Not reported" }
        func part(_ label: String, _ key: String) -> String? { run["tokens"][key].number.map { label + " " + String(Int($0)) } }
        return "Tokens (reported by the worker): " + [part("in", "input"), part("out", "output"), part("total", "total")].compactMap { $0 }.joined(separator: " · ")
    }
    static func stateText(_ run: NativeRPCValue) -> String {
        switch run["state"].string ?? "" {
        case "prepared", "starting": "Starting"
        case "running": "Running"
        case "completed": "Finished"
        case "failed": "Failed"
        case "stop_requested": run["stopConfirmed"].bool == true ? "Stopping" : "Stop requested, not confirmed"
        case "stopped": "Stopped"
        default: "Not known whether it started"
        }
    }
}

struct NativeRemoteWorkersView: View {
    @State private var model: NativeRemoteWorkersModel
    @State private var feed: EngineSubscription?
    init(model: NativeRemoteWorkersModel = NativeRemoteWorkersModel()) { _model = State(initialValue: model) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Run one request on another computer that speaks Terminal Deck's remote worker protocol. Terminal sessions on this Mac are not used or changed. Tokens counted here are only what the worker reports.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(model.connections.indices, id: \.self) { connection(model.connections[$0]) }
            if model.connections.isEmpty { Text("No remote workers yet.").font(.callout).foregroundStyle(.secondary) }
            GroupBox("Add a worker") {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Name", text: $model.newName)
                    TextField("https://worker.example.com", text: $model.newURL)
                    Button("Add worker") { Task { await model.addConnection() } }.disabled(model.newName.isEmpty || model.newURL.isEmpty)
                }.padding(4)
            }
            if let problem = model.problem { Text(problem).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
        }
        .disabled(model.pending)
        .task {
            await model.load()
            feed = EngineBridge.shared.on("remote-workers:changed") { _ in Task { @MainActor in await model.load() } }
        }
        .onDisappear { feed?.cancel(); feed = nil }
    }

    @ViewBuilder private func connection(_ item: NativeRPCValue) -> some View {
        let id = item["id"].string ?? ""
        let check = item["check"]
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack { Text(item["label"].string ?? id).font(.headline); Spacer(); Text(item["credential"].string == "saved" ? "Token saved" : "No token").font(.caption).foregroundStyle(.secondary) }
                Text(item["url"].string ?? "").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if check["ok"].bool == true {
                    let caps = check["capabilities"]
                    Text("Connected to " + (caps["service"].string ?? "worker") + " · " + [caps["stop"].bool == true ? "stop" : nil, caps["resume"].bool == true ? "resume" : nil, caps["tokens"].bool == true ? "token counts" : nil].compactMap { $0 }.joined(separator: ", ")).font(.caption)
                } else if let error = check["error"].string { Text(error).font(.caption).foregroundStyle(.red) }
                else { Text("Not checked yet.").font(.caption).foregroundStyle(.secondary) }
                HStack {
                    Button("Check connection") { Task { await model.perform("check", [.init("connection", .string(id))]) } }
                    Button("Remove") { Task { await model.perform("connection_remove", [.init("connection", .string(id))]) } }
                }
                HStack {
                    SecureField("Access token (write-only)", text: Binding(get: { model.tokens[id] ?? "" }, set: { model.tokens[id] = $0 }))
                    Button("Save token") { Task { await model.saveToken(id) } }.disabled((model.tokens[id] ?? "").isEmpty)
                    if item["credential"].string == "saved" { Button("Remove token") { Task { await model.perform("credential_remove", [.init("connection", .string(id))]) } } }
                }
                HStack {
                    TextField("What should it do?", text: Binding(get: { model.prompts[id] ?? "" }, set: { model.prompts[id] = $0 }))
                    Button("Start") { Task { await model.start(id) } }.disabled((model.prompts[id] ?? "").isEmpty || check["ok"].bool != true)
                }
                ForEach(model.runs(for: id).prefix(5).indices, id: \.self) { run(model.runs(for: id)[$0]) }
            }.padding(4)
        }
    }

    @ViewBuilder private func run(_ item: NativeRPCValue) -> some View {
        let id = item["id"].string ?? ""
        VStack(alignment: .leading, spacing: 3) {
            Text((item["title"].string ?? "Remote run") + (item["attempt"].number.map { $0 > 1 ? " · attempt \(Int($0))" : "" } ?? "")).font(.callout.weight(.medium))
            Text("Remote run · " + NativeRemoteWorkersModel.stateText(item) + " · " + NativeRemoteWorkersModel.tokenText(item)).font(.caption).foregroundStyle(.secondary)
            if let note = item["note"].string { Text(note).font(.caption).foregroundStyle(.orange) }
            if let error = item["error"].string { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            if let result = item["result"].string { Text(String(result.prefix(1200))).font(.caption).textSelection(.enabled) }
            HStack {
                if item["canRefresh"].bool == true { Button("Refresh") { Task { await model.perform("refresh", [.init("run", .string(id))]) } } }
                if item["canStop"].bool == true { Button("Stop") { Task { await model.perform("stop", [.init("run", .string(id))]) } } }
                if item["canAbandon"].bool == true {
                    Button("Abandon") { Task { await model.perform("abandon", [.init("run", .string(id))]) } }
                        .help("End this run here only when it can no longer be stopped or refreshed. Nothing is sent; the worker may still run it.")
                }
            }
            if item["canResume"].bool == true {
                HStack {
                    TextField("Continue with…", text: Binding(get: { model.messages[id] ?? "" }, set: { model.messages[id] = $0 }))
                    Button("Resume") { Task { await model.resume(id) } }.disabled((model.messages[id] ?? "").isEmpty)
                }
            }
        }.padding(.vertical, 2)
    }
}
