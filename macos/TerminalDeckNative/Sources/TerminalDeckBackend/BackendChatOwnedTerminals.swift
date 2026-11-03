import Foundation
import CryptoKit
import TerminalDeckNativeCore

/// An app-approved standalone terminal attached to a Chat. Its private app-server connection
/// owns only this terminal, and never starts/resumes a provider conversation or borrows an OS PID.
public actor BackendChatOwnedTerminals {
    public struct Scope: Sendable {
        public let sessionID: String, conversation: String, generation: UUID, cwd: String
        public let launch: BackendHootChatLaunch
        public let effectivePolicy: NativeRPCValue, executionEvidence: NativeRPCValue
        public var scopeID: String {
            (try? BackendChatOwnedTerminals.canonicalDigest(BackendChatOwnedTerminals.object([
                ("sessionID", .string(sessionID)), ("conversation", .string(conversation)), ("generation", .string(generation.uuidString)),
                ("cwd", .string(cwd)), ("policy", effectivePolicy), ("evidence", executionEvidence)]))) ?? ""
        }
        public init(sessionID: String, conversation: String, generation: UUID, cwd: String, launch: BackendHootChatLaunch,
                    effectivePolicy: NativeRPCValue, executionEvidence: NativeRPCValue) {
            self.sessionID = sessionID; self.conversation = conversation; self.generation = generation; self.cwd = cwd
            self.launch = launch; self.effectivePolicy = effectivePolicy; self.executionEvidence = executionEvidence
        }
    }
    /// Mint only after a native-user action or successful authenticated app act/owner consent.
    /// This value is transported only through the authenticated app/helper terminal door, never
    /// accepted from a model's terminal arguments or a caller-supplied Boolean.
    public struct AppApproval: Sendable {
        public enum Origin: String, Sendable { case nativeUser, toolConsent }
        public let nonce: String, sessionID: String, scopeID: String, operation: String, digest: String, origin: Origin
        public let issuedAt: Double, expiresAt: Double
        public static func mint(sessionID: String, scopeID: String, operation: String, arguments: NativeRPCValue, origin: Origin,
                                now: Double = Date().timeIntervalSince1970 * 1000) throws -> Self {
            guard !sessionID.isEmpty, scopeID.count == 64, BackendChatOwnedTerminals.mutations.contains(operation), now.isFinite else { throw BackendChatOwnedTerminals.invalid("An authenticated terminal action is required.") }
            return .init(nonce: UUID().uuidString, sessionID: sessionID, scopeID: scopeID, operation: operation,
                         digest: try BackendChatOwnedTerminals.canonicalDigest(arguments), origin: origin, issuedAt: now, expiresAt: now + 30_000)
        }
        private init(nonce: String, sessionID: String, scopeID: String, operation: String, digest: String, origin: Origin, issuedAt: Double, expiresAt: Double) {
            self.nonce = nonce; self.sessionID = sessionID; self.scopeID = scopeID; self.operation = operation; self.digest = digest
            self.origin = origin; self.issuedAt = issuedAt; self.expiresAt = expiresAt
        }
        public init(trustedWire value: NativeRPCValue) throws {
            guard value["version"].number == 1, let nonce = value["nonce"].string, UUID(uuidString: nonce) != nil,
                  let session = value["sessionID"].string, !session.isEmpty, session.utf8.count <= 512,
                  let scopeID = value["scopeID"].string, scopeID.count == 64, scopeID.allSatisfy({ $0.isHexDigit }),
                  let operation = value["operation"].string, BackendChatOwnedTerminals.mutations.contains(operation),
                  let digest = value["digest"].string, digest.count == 64, digest.allSatisfy({ $0.isHexDigit }),
                  let origin = Origin(rawValue: value["origin"].string ?? ""),
                  let issued = value["issuedAt"].number, let expiry = value["expiresAt"].number,
                  expiry > issued, expiry - issued <= 30_000 else { throw BackendChatOwnedTerminals.invalid("Invalid authenticated app terminal approval.") }
            self.init(nonce: nonce, sessionID: session, scopeID: scopeID, operation: operation, digest: digest, origin: origin, issuedAt: issued, expiresAt: expiry)
        }
        public var wireValue: NativeRPCValue { BackendChatOwnedTerminals.object([("version", .number(1)), ("nonce", .string(nonce)),
            ("sessionID", .string(sessionID)), ("scopeID", .string(scopeID)), ("operation", .string(operation)), ("digest", .string(digest)),
            ("origin", .string(origin.rawValue)), ("issuedAt", .number(issuedAt)), ("expiresAt", .number(expiresAt))]) }
    }
    public static let operations = ["capabilities", "list", "create", "read", "write", "resize", "stop", "close"]
    private static let mutations = ["create", "write", "resize", "stop", "close"]
    private final class Terminal: @unchecked Sendable {
        let handle = UUID().uuidString, processID = UUID().uuidString, token = UUID(), child = BackendHootChatProcess()
        var consumer: Task<Void, Never>?, timeout: Task<Void, Never>?
        var waiters: [String: CheckedContinuation<NativeRPCValue, Error>] = [:]
        var timeouts: [String: Task<Void, Never>] = [:]
        var execID = "", title = "Terminal", state = "starting", exitCode: Double?, error: String?
        var output = Data(), totalBytes = 0, sequence = 0, truncated = false
        var closing: Task<Void, Never>?
        var reaped = false
        var order = 0
        init(title: String) { self.title = title }
        deinit { consumer?.cancel(); timeout?.cancel(); child.stop() }
    }
    private let scope: Scope, sandbox: NativeRPCValue
    private let onChange: @Sendable () async -> Void
    private let now: @Sendable () -> Double
    private var terminals: [String: Terminal] = [:], approvals: [String: Double] = [:]
    private var closed = false, nextOrder = 0
    /// Finished terminals stay listed (their last output can still be read), but only this many; the oldest go first.
    static let finishedKept = 8
    public init(scope: Scope, onChange: @escaping @Sendable () async -> Void = {},
                now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1000 }) throws {
        self.scope = scope; sandbox = try Self.executionSandbox(scope)
        self.onChange = onChange; self.now = now
    }
    /// Backend-only provenance. Keep this complete object out of public journals/snapshots.
    public static func executionEvidence(_ response: NativeRPCValue, conversation: String, source: String) -> NativeRPCValue? {
        guard ["thread/start", "thread/resume"].contains(source), response["thread"]["id"].string == conversation,
              response["error"].isNullish, let size = try? response["sandbox"].encodedJSON().count, size <= 65_536 else { return nil }
        return object([("providerConversationId", .string(conversation)), ("source", .string(source)),
            ("cwd", response["cwd"]), ("sandbox", response["sandbox"]), ("activePermissionProfileReported", .bool(response.has("activePermissionProfile"))),
            ("activePermissionProfile", response["activePermissionProfile"])])
    }
    public var activeTerminalCount: Int {
        terminals.values.filter { !$0.reaped && (["starting", "running"].contains($0.state) || $0.closing != nil) }.count
    }
    public func invoke(operation: String, arguments: NativeRPCValue, approval: AppApproval? = nil) async throws -> NativeRPCValue {
        guard Self.operations.contains(operation), arguments.fields != nil, try arguments.encodedJSON().count <= 131_072 else { throw Self.invalid("Choose a bounded app-owned terminal action.") }
        guard !closed else { throw Self.unavailable("This Chat's terminal owner has closed. Start from its current generation.") }
        if Self.mutations.contains(operation) { try consume(approval, operation: operation, arguments: arguments) }
        switch operation {
        case "capabilities":
            return Self.object([("available", .bool(true)), ("operations", .array(Self.operations.map(NativeRPCValue.string))),
                ("approvalSource", .string("explicit-app-user-or-tool-consent")), ("providerNativeApproval", .bool(false)),
                ("cwd", .string(scope.cwd)), ("requestedSandbox", sandbox), ("provenance", .string("app-approved-standalone-attached-to-chat")),
                ("executionLocation", .string("same-provider-host-as-parent")), ("maximumTerminals", .number(2)), ("parentConversationId", .string(scope.conversation)), ("scopeID", .string(scope.scopeID))])
        case "list":
            try Self.keys(arguments, [])
            return Self.object([("terminals", .array(terminals.values.sorted { $0.handle < $1.handle }.map(metadata))),
                ("parentConversationId", .string(scope.conversation)), ("scopeID", .string(scope.scopeID)), ("approvalSource", .string("explicit-app-user-or-tool-consent"))])
        case "create": return try await create(arguments)
        case "read":
            try Self.keys(arguments, ["handle", "after"])
            let item = try selected(arguments)
            let after = arguments["after"].number
            if arguments.has("after") {
                guard let after, after.rounded() == after, after >= 0, after <= Double(Int.max / 2) else { throw Self.invalid("Choose a nonnegative terminal snapshot cursor.") }
            }
            return snapshot(item).setting("snapshot", .bool(true)).setting("outputScope", .string("full-bounded-snapshot"))
                .setting("changed", .bool(after == nil || after != Double(item.sequence)))
        case "write":
            try Self.keys(arguments, ["handle", "text", "dataBase64", "closeStdin"])
            let item = try writable(arguments)
            guard !(arguments.has("text") && arguments.has("dataBase64")) else { throw Self.invalid("Send text or base64 bytes, not both.") }
            let bytes: Data
            if let text = arguments["text"].string { bytes = Data(text.utf8) }
            else if let encoded = arguments["dataBase64"].string, let decoded = Data(base64Encoded: encoded) { bytes = decoded }
            else if arguments["closeStdin"].bool == true { bytes = Data() }
            else { throw Self.invalid("Enter terminal input or explicitly close stdin.") }
            guard bytes.count <= 65_536 else { throw Self.invalid("Terminal input is limited to 64 KiB per approved write.") }
            _ = try await request(item, method: "command/exec/write", params: Self.object([("processId", .string(item.processID)),
                ("deltaBase64", .string(bytes.base64EncodedString())), ("closeStdin", .bool(arguments["closeStdin"].bool == true))]))
            if item.state == "starting" { item.state = "running" }; item.sequence += 1; await onChange()
            return snapshot(item).setting("inputAcknowledged", .bool(true)).setting("inputProcessed", .bool(false))
        case "resize":
            try Self.keys(arguments, ["handle", "cols", "rows"])
            let item = try writable(arguments)
            _ = try await request(item, method: "command/exec/resize", params: Self.object([("processId", .string(item.processID)),
                ("size", try Self.size(arguments))]))
            if item.state == "starting" { item.state = "running" }; item.sequence += 1; await onChange()
            return snapshot(item)
        case "stop", "close":
            try Self.keys(arguments, ["handle"])
            let item = try selected(arguments)
            await close(item, reason: "Stopped by an approved app action")
            return snapshot(item)
        default: throw Self.invalid("Unknown app-owned terminal action.")
        }
    }
    public func closeAll(reason: String) async -> NativeRPCValue {
        closed = true
        for item in terminals.values { await close(item, reason: reason) }
        return Self.object([("closed", .bool(true)), ("terminals", .array(terminals.values.map(metadata)))])
    }
    /// A closed, exited or failed terminal that is fully reaped must not count toward the Chat's terminal limit
    /// forever: forget all but the newest few, so opening and closing shells never uses the Chat up.
    private func pruneFinished() {
        let finished = terminals.values.filter { $0.reaped && ["closed", "exited", "failed"].contains($0.state) }.sorted { $0.order > $1.order }
        for old in finished.dropFirst(Self.finishedKept) { terminals.removeValue(forKey: old.handle) }
    }
    private func create(_ arguments: NativeRPCValue) async throws -> NativeRPCValue {
        try Self.keys(arguments, ["argv", "title", "timeoutMs", "cols", "rows"])
        pruneFinished()
        guard terminals.values.filter({ !["closed", "exited", "failed"].contains($0.state) }).count < 2, terminals.count < 16 else { throw Self.unavailable("This Chat has reached its bounded terminal limit. Close its current terminals first.") }
        let argv: [String]
        if arguments.has("argv") {
            guard let values = arguments["argv"].elements, !values.isEmpty, values.count <= 64 else { throw Self.invalid("Provide a nonempty command argument vector.") }
            argv = try values.map { guard let text = $0.string, !text.contains("\0"), text.utf8.count <= 4096 else { throw Self.invalid("Terminal command arguments are invalid.") }; return text }
            guard !argv[0].isEmpty else { throw Self.invalid("Choose a command executable.") }
        } else { argv = ["/bin/zsh", "-f", "-i"] }
        let duration = arguments["timeoutMs"].number ?? 600_000
        guard duration.rounded() == duration, (1...3_600_000).contains(duration) else { throw Self.invalid("Choose a terminal timeout from 1 ms to one hour.") }
        let size = try Self.size(arguments)
        let item = Terminal(title: String((arguments["title"].string ?? "Chat terminal").prefix(128)))
        nextOrder += 1; item.order = nextOrder
        terminals[item.handle] = item
        item.sequence += 1; await onChange()
        do {
            guard !closed, item.closing == nil else { throw Self.unavailable("The Chat closed before terminal initialization.") }
            try item.child.start(scope.launch)
            item.consumer = Task { [weak self, child = item.child, handle = item.handle, token = item.token] in
                var lines = HootChatJSONLines()
                for await output in child.output {
                    do {
                        switch output {
                        case .stdout(let bytes): for row in try lines.append(bytes) { await self?.receive(handle: handle, token: token, row: row) }
                        case .stderr: break
                        case .exit(let code):
                            for row in try lines.append(Data(), end: true) { await self?.receive(handle: handle, token: token, row: row) }
                            await self?.exited(handle: handle, token: token, code: code); return
                        }
                    } catch { await self?.fail(handle: handle, token: token, error: error); return }
                }
            }
            _ = try await request(item, method: "initialize", params: Self.object([("clientInfo", Self.object([("name", .string("terminaldeck-owned-terminal")), ("version", .string("1"))])),
                ("capabilities", Self.object([("experimentalApi", .bool(true))]))]))
            guard !closed, item.closing == nil else { throw Self.unavailable("The Chat closed during terminal initialization.") }
            try await item.child.send(BackendHootChatRPC.request("initialized"))
            item.execID = UUID().uuidString
            let params = Self.object([("processId", .string(item.processID)), ("command", .array(argv.map(NativeRPCValue.string))),
                ("cwd", .string(scope.cwd)), ("sandboxPolicy", sandbox), ("tty", .bool(true)), ("streamStdin", .bool(true)),
                ("streamStdoutStderr", .bool(true)), ("outputBytesCap", .number(262_144)), ("timeoutMs", .number(duration)), ("size", size)])
            // command/exec replies only on exit. This is a queued request, not a startup ack.
            item.timeout = Task { [weak self, handle = item.handle, token = item.token] in
                do { try await Task.sleep(for: .milliseconds(Int64(duration) + 5_000)) } catch { return }
                await self?.fail(handle: handle, token: token, error: Self.unavailable("The bounded terminal lifetime ended without a final provider acknowledgement."))
            }
            try await item.child.send(BackendHootChatRPC.request("command/exec", id: .string(item.execID), params: params))
            item.sequence += 1; await onChange()
            return snapshot(item)
        } catch {
            await close(item, reason: "Terminal startup failed")
            throw error
        }
    }
    private func request(_ item: Terminal, method: String, params: NativeRPCValue, allowClosing: Bool = false) async throws -> NativeRPCValue {
        let id = UUID().uuidString
        return try await withCheckedThrowingContinuation(isolation: self) { continuation in
            guard item.child.alive, item.closing == nil || allowClosing, item.waiters.count < 4 else { continuation.resume(throwing: Self.unavailable("The private terminal connection is closed.")); return }
            item.waiters[id] = continuation
            Task {
                do { try await item.child.send(BackendHootChatRPC.request(method, id: .string(id), params: params)) }
                catch { reject(item, id: id, error: error) }
            }
            item.timeouts[id] = Task {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                reject(item, id: id, error: Self.unavailable("The private terminal provider did not confirm this request. Read its state before retrying input."))
            }
        }
    }
    private func receive(handle: String, token: UUID, row: NativeRPCValue) async {
        guard let item = terminals[handle], item.token == token else { return }
        if let id = row["id"].string, let waiter = item.waiters.removeValue(forKey: id) {
            item.timeouts.removeValue(forKey: id)?.cancel()
            if row["error"].isNullish, row.has("result") { waiter.resume(returning: row["result"]) }
            else { waiter.resume(throwing: Self.unavailable("The private terminal provider refused the operation.")) }
            return
        }
        if row["id"].string == item.execID, !item.execID.isEmpty {
            item.timeout?.cancel(); item.timeout = nil
            if row["error"].isNullish, let code = row["result"]["exitCode"].number { item.state = "exited"; item.exitCode = code }
            else { item.state = "failed"; item.error = "The provider did not confirm a terminal exit result." }
            item.sequence += 1; await onChange()
            // A final command result is not proof that its private server exits on EOF.
            // Use the same bounded reaping barrier while retaining the actual exit result.
            Task { await close(item, reason: "Terminal command exited", requestTermination: false) }
            return
        }
        if row["method"].string != nil, !row["id"].isNullish {
            try? await item.child.send(.object([.init("jsonrpc", .string("2.0")), .init("id", row["id"]),
                .init("error", .object([.init("code", .number(-32601)), .init("message", .string("This app-approved terminal does not grant provider approval requests."))]))]))
            Task { await close(item, reason: "The private terminal requested unsupported provider approval", requestTermination: false) }
            return
        }
        guard row["method"].string == "command/exec/outputDelta", row["params"]["processId"].string == item.processID,
              let encoded = row["params"]["deltaBase64"].string, encoded.utf8.count <= 524_288,
              let bytes = Data(base64Encoded: encoded) else { return }
        item.output.append(bytes); item.totalBytes += bytes.count
        if item.output.count > 262_144 { item.output.removeFirst(item.output.count - 262_144); item.truncated = true }
        if row["params"]["capReached"].bool == true { item.truncated = true }
        if item.state == "starting" { item.state = "running" }
        item.sequence += 1; await onChange()
    }
    private func exited(handle: String, token: UUID, code: Int32) async {
        guard let item = terminals[handle], item.token == token else { return }
        item.reaped = true
        if item.closing == nil, !["closed", "exited", "failed"].contains(item.state) { item.state = "failed"; item.error = "The private terminal connection ended before reporting the command's exit." }
        failWaiters(item, Self.unavailable("The private terminal connection ended.")); item.sequence += 1; await onChange()
    }
    private func fail(handle: String, token: UUID, error: Error) async {
        guard let item = terminals[handle], item.token == token else { return }
        item.error = String(error.localizedDescription.prefix(1024)); await close(item, reason: "Terminal transport failed", requestTermination: false)
    }
    private func close(_ item: Terminal, reason: String, requestTermination: Bool = true) async {
        if let closing = item.closing { await closing.value; return }
        let cleanup = Task {
            if requestTermination, !item.execID.isEmpty, ["starting", "running"].contains(item.state), item.child.alive {
                _ = try? await request(item, method: "command/exec/terminate", params: Self.object([("processId", .string(item.processID))]), allowClosing: true)
            }
            // EOF closes the sole private connection, including an exec accepted after a lost reply.
            await item.child.closeInput()
            await withTaskGroup(of: Bool.self) { group in
                group.addTask { await item.child.waitForExit(); return true }
                group.addTask { try? await Task.sleep(for: .seconds(1)); return false }
                if await group.next() == false { await item.child.stopAndWait() }
                group.cancelAll()
            }
            item.reaped = true
            item.consumer?.cancel(); item.consumer = nil
            if item.state != "exited" { item.state = "closed" }
        }
        item.closing = cleanup
        failWaiters(item, Self.unavailable(reason)); item.timeout?.cancel(); item.timeout = nil
        await cleanup.value
        item.sequence += 1; await onChange()
    }
    private func reject(_ item: Terminal, id: String, error: Error) { item.timeouts.removeValue(forKey: id)?.cancel(); item.waiters.removeValue(forKey: id)?.resume(throwing: error) }
    private func failWaiters(_ item: Terminal, _ error: Error) {
        let pending = item.waiters; item.waiters = [:]
        for timeout in item.timeouts.values { timeout.cancel() }; item.timeouts = [:]
        for waiter in pending.values { waiter.resume(throwing: error) }
    }
    private func selected(_ arguments: NativeRPCValue) throws -> Terminal {
        guard let handle = arguments["handle"].string, let item = terminals[handle] else { throw Self.denied("Choose a terminal handle minted by this Chat generation.") }
        return item
    }
    private func writable(_ arguments: NativeRPCValue) throws -> Terminal {
        let item = try selected(arguments)
        guard ["starting", "running"].contains(item.state), item.closing == nil else { throw Self.unavailable("The terminal is no longer accepting input.") }
        return item
    }
    private func consume(_ approval: AppApproval?, operation: String, arguments: NativeRPCValue) throws {
        let at = now(); approvals = approvals.filter { $0.value >= at }
        guard let approval, approval.sessionID == scope.sessionID, approval.scopeID == scope.scopeID, approval.operation == operation,
              approval.digest == (try Self.canonicalDigest(arguments)), approval.issuedAt <= at + 1_000,
              approval.expiresAt >= at, approval.expiresAt - approval.issuedAt <= 30_000,
              approvals[approval.nonce] == nil, approvals.count < 1024 else { throw Self.denied("This terminal mutation needs a fresh app approval for these exact arguments and Chat.") }
        approvals[approval.nonce] = approval.expiresAt
    }
    private func snapshot(_ item: Terminal) -> NativeRPCValue {
        metadata(item).setting("output", .string(String(decoding: item.output, as: UTF8.self)))
    }
    private func metadata(_ item: Terminal) -> NativeRPCValue {
        Self.object([("handle", .string(item.handle)), ("title", .string(item.title)), ("state", .string(item.state)),
            ("sessionID", .string(scope.sessionID)), ("parentConversationId", .string(scope.conversation)),
            ("generation", .string(scope.generation.uuidString)), ("scopeID", .string(scope.scopeID)), ("cwd", .string(scope.cwd)),
            ("cursor", .number(Double(item.sequence))), ("outputBytes", .number(Double(item.totalBytes))),
            ("truncated", .bool(item.truncated)), ("droppedBefore", .number(Double(max(0, item.totalBytes - item.output.count)))),
            ("exitCode", item.exitCode.map(NativeRPCValue.number) ?? .null), ("error", item.error.map(NativeRPCValue.string) ?? .null),
            ("provenance", .string("app-approved-standalone-attached-to-chat")), ("providerNativeApproval", .bool(false)),
            ("executionLocation", .string("same-provider-host-as-parent")), ("requestedSandbox", sandbox),
            ("sandboxSource", .string("validated-parent-effective-policy")), ("terminalEffectivePolicyEcho", .bool(false)), ("connectionAlive", .bool(item.child.alive)), ("commandExitConfirmed", .bool(item.exitCode != nil))])
    }
    private static func executionSandbox(_ scope: Scope) throws -> NativeRPCValue {
        guard !scope.sessionID.isEmpty, !scope.conversation.isEmpty, scope.cwd.hasPrefix("/"), !scope.cwd.contains("\0"), scope.launch.cwd == scope.cwd,
              scope.effectivePolicy["provider"].string == "codex", scope.effectivePolicy["authority"].string == "provider-response",
              scope.effectivePolicy["providerConversationId"].string == scope.conversation, scope.effectivePolicy["cwd"].string == scope.cwd,
              scope.executionEvidence["cwd"].string == scope.cwd,
              scope.executionEvidence["providerConversationId"].string == scope.conversation,
              ["thread/start", "thread/resume"].contains(scope.executionEvidence["source"].string ?? ""),
              scope.executionEvidence["activePermissionProfileReported"].bool == true else { throw unavailable("The parent has no complete, current provider execution-policy provenance for a terminal.") }
        let raw = scope.executionEvidence["sandbox"], profile = scope.executionEvidence["activePermissionProfile"]
        let type = raw["type"].string ?? ""
        let builtin = [":read-only": "readOnly", ":workspace": "workspaceWrite"]
        guard let profileID = profile["id"].string, builtin[profileID] == type, profile["extends"].isNullish,
              Set(profile.fields?.map(\.key) ?? []).isSubset(of: ["id", "extends"]) else {
            throw unavailable("Unknown, custom or extended provider permission profiles cannot be faithfully reconstructed for a standalone terminal.")
        }
        let keys: Set<String> = type == "readOnly" ? ["type", "networkAccess"] : ["type", "networkAccess", "writableRoots", "excludeSlashTmp", "excludeTmpdirEnvVar"]
        guard let fields = raw.fields, Set(fields.map(\.key)).isSubset(of: keys), raw["networkAccess"].bool != nil else { throw unavailable("The provider sandbox includes missing or unrecognized restrictions; no terminal was launched.") }
        if type == "readOnly" { return object([("type", .string(type)), ("networkAccess", .bool(false))]) }
        guard let roots = raw["writableRoots"].elements, roots.count <= 100, roots.allSatisfy({ $0.string?.hasPrefix("/") == true && ($0.string?.utf8.count ?? .max) <= 4096 && $0.string?.contains("\0") == false }) else { throw unavailable("The provider did not report complete writable roots for this terminal.") }
        return object([("type", .string("workspaceWrite")), ("writableRoots", .array(roots)), ("networkAccess", .bool(false)),
            ("excludeSlashTmp", .bool(true)), ("excludeTmpdirEnvVar", .bool(true))])
    }
    private static func size(_ arguments: NativeRPCValue) throws -> NativeRPCValue {
        let cols = arguments["cols"].number ?? 100, rows = arguments["rows"].number ?? 30
        guard cols.rounded() == cols, rows.rounded() == rows, (1...500).contains(cols), (1...200).contains(rows) else { throw invalid("Choose terminal dimensions within 500 columns and 200 rows.") }
        return object([("cols", .number(cols)), ("rows", .number(rows))])
    }
    private static func canonicalDigest(_ value: NativeRPCValue) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value.foundation ?? NSNull(), options: [.sortedKeys, .fragmentsAllowed])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func keys(_ arguments: NativeRPCValue, _ allowed: Set<String>) throws {
        guard Set(arguments.fields?.map(\.key) ?? []).isSubset(of: allowed) else { throw invalid("Unsupported terminal arguments. Private provider IDs, policies, paths and approval flags are not accepted.") }
    }
    private static func object(_ fields: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(fields.map { .init($0.0, $0.1) }) }
    private static func invalid(_ message: String) -> NativeRPCError { .invalidArguments(message) }
    private static func unavailable(_ message: String) -> NativeRPCError { .init(code: "unavailable", message: message) }
    private static func denied(_ message: String) -> NativeRPCError { .init(code: "access-denied", message: message) }
}
