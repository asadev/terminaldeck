import Foundation
import Observation
import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

extension NativeCompositionProduction {
    func chatOwnedTerminalFeature(_ id: String, operation: String, arguments: NativeRPCValue,
                                  origin: BackendChatOwnedTerminals.AppApproval.Origin, expectedScopeID: String? = nil) async throws -> NativeRPCValue {
        guard BackendChatOwnedTerminals.operations.contains(operation) else { throw NativeRPCError.invalidArguments("Choose a supported Chat terminal action.") }
        guard let chats = sessionChats else { throw BackendSessionFailure.missingSession }
        let target = try await providerSessionID(id)
        let changes = !["capabilities", "list", "read"].contains(operation)
        let permit: BackendChatOwnedTerminals.AppApproval?
        if changes {
            let scopeID: String
            if let expectedScopeID { scopeID = expectedScopeID }
            else {
                let capability = try await chats.ownedTerminalFeature(target, operation: "capabilities", arguments: .object([]), approval: nil)
                scopeID = try capability["scopeID"].requireString("current terminal owner", nonempty: true)
            }
            permit = try BackendChatOwnedTerminals.AppApproval.mint(sessionID: target, scopeID: scopeID, operation: operation, arguments: arguments, origin: origin)
        } else { permit = nil }
        return try await chats.ownedTerminalFeature(target, operation: operation, arguments: arguments, approval: permit)
    }

    func chatOwnedTerminalToolDefinitions(gate: BackendCompositionDeckToolsGate) throws -> [BackendDeckToolsDefinition] {
        let spec = try BackendMCPTool(id: "sessions.chat_terminal", wireName: "sessions_chat_terminal",
            description: "Use an app-approved standalone terminal attached to an exact Chat. This is separate from provider-native command approvals. capabilities reports availability and policy evidence; create uses an explicit sandbox no broader than the confirmed parent boundary and a private connection; list/read return opaque handles and bounded output. write, resize, stop and close accept only handles owned by this Chat. Every mutation uses the app's current consent gate. Parent close/rebind ends these terminals; closing the Provider panel does not. Missing or custom/unreconstructable provider policy refuses creation. create arguments are optional argv (a string array), title, timeoutMs, cols and rows; default is an interactive shell without dotfiles. write uses handle plus text or dataBase64, or closeStdin=true. resize uses handle, cols and rows. read/stop/close use handle. No OS PID or provider process ID is accepted.",
            inputSchema: try NativeRPCValue.parseJSON(Data(#"{"type":"object","properties":{"sessionId":{"type":"string"},"do":{"type":"string","enum":["capabilities","list","create","read","write","resize","stop","close"]},"arguments":{"type":"object","properties":{"handle":{"type":"string"},"argv":{"type":"array","minItems":1,"maxItems":64,"items":{"type":"string","maxLength":4096}},"title":{"type":"string","maxLength":128},"timeoutMs":{"type":"integer","minimum":1,"maximum":3600000},"cols":{"type":"integer","minimum":1,"maximum":500},"rows":{"type":"integer","minimum":1,"maximum":200},"text":{"type":"string","maxLength":65536},"dataBase64":{"type":"string","maxLength":90000},"closeStdin":{"type":"boolean"}},"additionalProperties":false}},"required":["sessionId","do"],"additionalProperties":false}"#.utf8)), tier: .read)
        return [BackendDeckToolsDefinition(spec: spec, title: "Chat-owned app-approved terminal") { caller, args in
            await BackendDeckToolsSupport.reply {
                let id = try args["sessionId"].requireString("session", nonempty: true)
                let operation = try args["do"].requireString("terminal action", nonempty: true)
                let arguments = args["arguments"].isNullish ? NativeRPCValue.object([]) : args["arguments"]
                let resolved = try await gate.authority.resolve(caller)
                if id == "hoot" {
                    guard resolved.caller.kind == .local, caller.sessionID.isEmpty else {
                        throw NativeRPCError(code: "not-granted", message: "Hoot's attached terminals belong to the Mac owner.")
                    }
                } else {
                    let meta = try await gate.authority.requireSession(id, native: caller)
                    guard meta.chat == true else { throw NativeRPCError.invalidArguments("Choose a Chat session.") }
                }
                let changes = !["capabilities", "list", "read"].contains(operation)
                let target = try await self.providerSessionID(id)
                let expectedScopeID: String?
                var consentSummary = "Read Chat terminal: " + operation
                if changes {
                    let capability = try await self.chatOwnedTerminalFeature(target, operation: "capabilities", arguments: .object([]), origin: .toolConsent)
                    expectedScopeID = try capability["scopeID"].requireString("current terminal owner", nonempty: true)
                    let cwd = capability["cwd"].string ?? "this Chat's confirmed folder"
                    let policy = capability["requestedSandbox"]["type"].string ?? "confirmed provider boundary"
                    let command = (arguments["argv"].elements ?? [.string("/bin/zsh"), .string("-f"), .string("-i")]).compactMap(\.string).joined(separator: " ")
                    let action = operation == "create" ? "Open " + String(command.prefix(256)) : "Terminal " + operation
                    consentSummary = action + " in " + cwd + " (" + policy + "; app approval)"
                } else { expectedScopeID = nil }
                try await gate.authorize(caller, changes ? .act : .read, consentSummary, changes)
                if id != "hoot" { _ = try await gate.authority.requireSession(id, native: caller) }
                // The permit is minted here, after consent. It is never supplied by tool arguments.
                let result = try await self.chatOwnedTerminalFeature(target, operation: operation, arguments: arguments, origin: .toolConsent, expectedScopeID: expectedScopeID)
                if changes { await gate.noteResult(caller, result) }
                return .value(result)
            }
        }]
    }
}

struct NativeChatOwnedTerminalsView: View {
    let sessionID: String
    @State private var model = NativeChatOwnedTerminalModel()
    @State private var input = ""
    @State private var columns = 80
    @State private var rows = 24
    var body: some View {
        GroupBox("Attached terminal · app approval") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Runs on the same host as this Chat, through a separate helper-owned connection. It uses the confirmed provider boundary with app approval. Parent close, reconnect or policy changes end it; closing this panel keeps it available. The default shell lifetime is 10 minutes.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    NativeSessionButton("Check availability") { model.perform("capabilities") }
                    NativeSessionButton("Open shell") { model.perform("create") }
                    NativeSessionButton("Refresh terminals") { model.perform("list") }
                }
                ForEach(Array(model.terminals.enumerated()), id: \.offset) { _, row in
                    if let handle = row["handle"].string {
                        NativeSessionButton((row["title"].string ?? "Shell") + " · " + (row["state"].string ?? "unknown")) { model.select(handle) }
                    }
                }
                if let handle = model.selected {
                    HStack {
                        NativeSessionButton("Read output") { model.perform("read", fields: [.init("handle", .string(handle))]) }
                        NativeSessionButton("Stop terminal") { model.perform("stop", fields: [.init("handle", .string(handle))]) }
                        NativeSessionButton("Close terminal") { model.perform("close", fields: [.init("handle", .string(handle))]) }
                    }
                    ScrollView([.vertical, .horizontal]) {
                        Text(model.output.isEmpty ? "No output received yet." : model.output).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(minHeight: 80, maxHeight: 220)
                    if model.truncated { Text("Earlier output was clipped by the terminal's bounded output buffer.").font(.caption).foregroundStyle(.secondary) }
                    NativeSessionTextField("Text to send", text: $input)
                    HStack {
                        NativeSessionButton("Send line") {
                            let original = input
                            model.perform("write", fields: [.init("handle", .string(handle)), .init("text", .string(original + "\n"))]) { accepted in
                                if accepted && input == original { input = "" }
                            }
                        }
                        NativeSessionButton("Close input") { model.perform("write", fields: [.init("handle", .string(handle)), .init("closeStdin", .bool(true))]) }
                    }
                    HStack {
                        Stepper("Columns: \(columns)", value: $columns, in: 20...300)
                        Stepper("Rows: \(rows)", value: $rows, in: 5...100)
                        NativeSessionButton("Resize") { model.perform("resize", fields: [.init("handle", .string(handle)), .init("cols", .number(Double(columns))), .init("rows", .number(Double(rows)))]) }
                    }
                }
                if let available = model.receipt["available"].bool {
                    Text(available ? "Available with app approval." : model.receipt["reason"].string ?? "Unavailable for this provider boundary.").font(.caption).foregroundStyle(.secondary)
                }
                if model.busy { ProgressView("Waiting for helper…").controlSize(.small) }
                if let problem = model.problem { Text(problem).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                if !model.receipt.isNullish { DisclosureGroup("Terminal details") { NativeChatProviderResult(value: model.receipt) } }
            }.disabled(model.busy).padding(4).frame(maxWidth: .infinity, alignment: .leading)
        }.onAppear { model.connect(sessionID) }.onDisappear { model.disconnect() }
            .onChange(of: sessionID) { _, id in model.connect(id) }
    }
}

@MainActor @Observable final class NativeChatOwnedTerminalModel {
    private(set) var terminals: [NativeRPCValue] = []
    private(set) var selected: String?
    private(set) var output = ""
    private(set) var truncated = false
    private(set) var busy = false
    private(set) var problem: String?
    private(set) var receipt: NativeRPCValue = .null
    @ObservationIgnored private var id = ""
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var subscription: EngineSubscription?
    @ObservationIgnored private var refresh: Task<Void, Never>?
    @ObservationIgnored private var cursor = -1
    func connect(_ id: String) {
        disconnect(); self.id = id; generation += 1
        terminals = []; selected = nil; output = ""; receipt = .null; problem = nil; cursor = -1
        let token = generation
        subscription = EngineBridge.shared.on("session:chat:changed") { [weak self] args in
            guard let self, token == self.generation, args.count >= 2, args[0] as? String == self.id,
                  let value = try? NativeRPCValue.fromFoundation(args[1]), let cursor = value["ownedTerminalCursor"].number,
                  Int(cursor) > self.cursor else { return }
            self.cursor = Int(cursor); self.scheduleRefresh()
        }
        perform("list")
    }
    func disconnect() { generation += 1; busy = false; subscription?.cancel(); subscription = nil; refresh?.cancel(); refresh = nil }
    func select(_ handle: String) { selected = handle; perform("read", fields: [.init("handle", .string(handle))]) }
    func perform(_ operation: String, fields: [NativeRPCValue.Field] = [], completion: ((Bool) -> Void)? = nil) {
        guard !busy else { return }
        busy = true; problem = nil
        let token = generation
        Task {
            defer { if token == generation { busy = false } }
            do {
                guard token == generation else { return }
                let result = try await call(operation, .object(fields))
                guard token == generation else { return }
                receipt = operation == "read" ? result.setting("output", .null) : result
                completion?(true)
                if let handle = result["handle"].string { selected = handle }
                if operation == "read" { acceptOutput(result) }
                if operation != "capabilities" { try await reload(token) }
            } catch { if token == generation { problem = error.localizedDescription; completion?(false) } }
        }
    }
    private func call(_ operation: String, _ arguments: NativeRPCValue) async throws -> NativeRPCValue {
        try NativeRPCValue.fromFoundation(await EngineBridge.shared.invoke("session:chat:terminal", [id, operation, arguments.foundation]))
    }
    private func acceptOutput(_ result: NativeRPCValue) {
        guard result["handle"].string == selected else { return }
        output = result["output"].string ?? ""; truncated = result["truncated"].bool == true
    }
    private func reload(_ token: Int) async throws {
        let result = try await call("list", .object([]))
        guard token == generation else { return }
        terminals = result["items"].elements ?? result["terminals"].elements ?? []
        if let selected, terminals.contains(where: { $0["handle"].string == selected }) {
            let result = try await call("read", .object([.init("handle", .string(selected))]))
            guard token == generation else { return }; acceptOutput(result)
        } else if selected != nil {
            selected = nil; output = ""; truncated = false
        }
    }
    private func scheduleRefresh() {
        guard refresh == nil else { return }
        let token = generation
        refresh = Task {
            defer { if token == generation { refresh = nil } }
            guard token == generation else { return }
            do {
                var handled: Int
                repeat {
                    handled = cursor
                    try await reload(token)
                    guard token == generation else { return }
                } while cursor > handled
            } catch { if token == generation { problem = error.localizedDescription } }
        }
    }
}
