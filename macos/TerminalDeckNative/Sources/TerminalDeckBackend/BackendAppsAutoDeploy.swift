import CryptoKit
import Foundation
import TerminalDeckNativeCore

public struct BackendAppsPushHeader: Sendable, Equatable {
    public let name: String
    public let value: String
    public init(_ name: String, _ value: String) { self.name = name; self.value = value }
}

/// An explicit branch is required; guessing the repository's default branch
/// would let an approval cover a different ref after repository settings change.
public struct BackendAppsPushTarget: Sendable, Equatable {
    public let repository: String
    public let branch: String
    public var ref: String { "refs/heads/" + branch }
    public init(repository: String, branch: String) throws {
        let source = try BackendAppsDeploySource(BackendAppsValidation.object([
            ("kind", .string("github")), ("repository", .string(repository)), ("branch", .string(branch))
        ]))
        guard !branch.hasPrefix("refs/"), !branch.hasPrefix("/"), !branch.hasSuffix("/"), !branch.hasSuffix("."), !branch.hasSuffix(".lock"), !branch.contains("//") else {
            throw NativeRPCError.invalidArguments("Choose an explicit repository branch for automatic deploys.")
        }
        self.repository = source.repository; self.branch = branch
    }
    init(record: NativeRPCValue) throws {
        guard record["kind"].string == "app", record["source"]["kind"].string == "github",
              let repository = record["source"]["repository"].string, let branch = record["source"]["branch"].string else {
            throw BackendAppsRuntime.unavailable("Automatic deploys need a GitHub app with an explicit branch.")
        }
        try self.init(repository: repository, branch: branch)
    }
}

/// No public initializer: only the verifier creates a delivery for dispatch.
/// Raw payloads, webhook signatures and secrets never appear in this value.
public struct BackendAppsVerifiedPush: Sendable, Equatable {
    public let deliveryID: String
    public let repository: String
    public let repositoryID: UInt64
    public let ref: String
    public let revision: String
    public let senderID: UInt64
    public let senderLogin: String
    public let bodyDigest: String
    public var preview: NativeRPCValue {
        BackendAppsValidation.object([
            ("deliveryId", .string(deliveryID)), ("repository", .string(repository)),
            ("ref", .string(ref)), ("revision", .string(revision)), ("sender", .string(senderLogin))
        ])
    }
}

public enum BackendAppsPushVerifier {
    public static let maximumBodyBytes = 1_048_576

    /// Uses CryptoKit's authentication-code verifier, not string equality.
    /// GitHub signs the original request bytes, so do not re-encode JSON first.
    public static func validSignature(body: Data, secret: Data, signature: String) -> Bool {
        guard !body.isEmpty, body.count <= maximumBodyBytes, (16...4096).contains(secret.count),
              signature.hasPrefix("sha256="), let code = decodeHex(String(signature.dropFirst(7))), code.count == 32 else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(code, authenticating: body, using: SymmetricKey(data: secret))
    }

    public static func verify(headers: [BackendAppsPushHeader], body: Data, secret: Data, target: BackendAppsPushTarget) throws -> BackendAppsVerifiedPush {
        let values = try checkedHeaders(headers, body: body)
        guard validSignature(body: body, secret: secret, signature: values.signature) else { throw invalidDelivery() }
        // Bound nesting before using the existing ordered parser or JSONDecoder.
        // The display-oriented ordered parser is deliberately permissive.
        // Foundation must reject malformed JSON/UTF-16 escapes before it runs.
        guard safeJSON(body) else { throw invalidDelivery() }
        let payload: PushPayload
        do { payload = try JSONDecoder().decode(PushPayload.self, from: body) }
        catch { throw invalidDelivery() }
        guard payload.repository.id > 0, payload.sender.id > 0,
              payload.repository.fullName == target.repository, payload.ref == target.ref,
              !payload.deleted, validRevision(payload.after), payload.after.contains(where: { $0 != "0" }),
              payload.sender.login.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]{0,99}(?:\[bot\])?$"#, options: .regularExpression) != nil else { throw invalidDelivery() }
        return BackendAppsVerifiedPush(deliveryID: values.delivery, repository: payload.repository.fullName,
            repositoryID: payload.repository.id, ref: payload.ref, revision: payload.after.lowercased(),
            senderID: payload.sender.id, senderLogin: payload.sender.login,
            bodyDigest: SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined())
    }

    /// Cheap preflight before asking the trusted ingress for its secret/target.
    public static func preflight(headers: [BackendAppsPushHeader], body: Data) throws { _ = try checkedHeaders(headers, body: body) }

    static func safeJSON(_ body: Data) -> Bool {
        guard !body.isEmpty, body.count <= maximumBodyBytes, shallowJSON(body), validUnicodeEscapes(body),
              (try? JSONSerialization.jsonObject(with: body)) != nil, let ordered = OrderedJSON.parse(body) else { return false }
        return uniqueKeys(ordered, depth: 0)
    }

    private struct PushPayload: Decodable {
        let ref: String
        let after: String
        let deleted: Bool
        let repository: Repository
        let sender: Sender
        struct Repository: Decodable {
            let id: UInt64
            let fullName: String
            enum CodingKeys: String, CodingKey { case id; case fullName = "full_name" }
        }
        struct Sender: Decodable { let id: UInt64; let login: String }
    }
    private struct Headers { let delivery: String; let signature: String }
    private static func checkedHeaders(_ headers: [BackendAppsPushHeader], body: Data) throws -> Headers {
        guard !body.isEmpty, body.count <= maximumBodyBytes, headers.count <= 64,
              headers.reduce(0, { $0 + $1.name.utf8.count + $1.value.utf8.count }) <= 16_384 else { throw invalidDelivery() }
        var values: [String: String] = [:]
        for header in headers {
            guard !header.name.isEmpty, header.name.utf8.count <= 128,
                  header.name.range(of: #"^[A-Za-z0-9!#$%&'*+.^_`|~-]+$"#, options: .regularExpression) != nil,
                  header.value.utf8.count <= 8192, !header.value.unicodeScalars.contains(where: { $0.value < 32 && $0.value != 9 || $0.value == 127 }) else { throw invalidDelivery() }
            let name = header.name.lowercased()
            guard values[name] == nil else { throw invalidDelivery() }
            values[name] = header.value
        }
        guard values["x-github-event"] == "push", let delivery = values["x-github-delivery"], delivery.utf8.count == 36,
              let uuid = UUID(uuidString: delivery), uuid.uuidString.lowercased() == delivery.lowercased(),
              uuid != UUID(uuidString: "00000000-0000-0000-0000-000000000000"),
              let signature = values["x-hub-signature-256"], signature.utf8.count == 71,
              let contentType = values["content-type"], contentType.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else { throw invalidDelivery() }
        return Headers(delivery: delivery.lowercased(), signature: signature)
    }
    private static func decodeHex(_ text: String) -> Data? {
        let chars = Array(text.utf8)
        guard chars.count == 64 else { return nil }
        var result = Data(); result.reserveCapacity(32)
        for index in stride(from: 0, to: chars.count, by: 2) {
            guard let high = hexNibble(chars[index]), let low = hexNibble(chars[index + 1]) else { return nil }
            result.append((high << 4) | low)
        }
        return result
    }
    private static func hexNibble(_ value: UInt8) -> UInt8? {
        switch value {
        case 48...57: value - 48
        case 65...70: value - 55
        case 97...102: value - 87
        default: nil
        }
    }
    private static func validUnicodeEscapes(_ body: Data) -> Bool {
        let bytes = Array(body)
        var index = 0, quoted = false
        func unit(_ start: Int) -> Int? {
            guard start >= 0, start + 4 <= bytes.count else { return nil }
            var result = 0
            for offset in 0..<4 {
                guard let value = hexNibble(bytes[start + offset]) else { return nil }
                result = (result << 4) | Int(value)
            }
            return result
        }
        while index < bytes.count {
            let byte = bytes[index]
            if !quoted {
                if byte == 34 { quoted = true }
                index += 1; continue
            }
            if byte == 34 { quoted = false; index += 1; continue }
            guard byte >= 32 else { return false }
            if byte != 92 { index += 1; continue }
            guard index + 1 < bytes.count else { return false }
            let escape = bytes[index + 1]
            if escape != 117 {
                guard [34, 92, 47, 98, 102, 110, 114, 116].contains(escape) else { return false }
                index += 2; continue
            }
            guard let scalar = unit(index + 2) else { return false }
            if (0xD800...0xDBFF).contains(scalar) {
                guard index + 12 <= bytes.count, bytes[index + 6] == 92, bytes[index + 7] == 117,
                      let low = unit(index + 8), (0xDC00...0xDFFF).contains(low) else { return false }
                index += 12
            } else {
                guard !(0xDC00...0xDFFF).contains(scalar) else { return false }
                index += 6
            }
        }
        return !quoted
    }
    private static func shallowJSON(_ body: Data) -> Bool {
        var depth = 0, quoted = false, escaped = false
        for byte in body {
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { quoted = false }
            } else if byte == 34 { quoted = true }
            else if byte == 123 || byte == 91 { depth += 1; if depth > 64 { return false } }
            else if byte == 125 || byte == 93 { depth -= 1; if depth < 0 { return false } }
        }
        return depth == 0 && !quoted
    }
    private static func uniqueKeys(_ value: OrderedJSON, depth: Int) -> Bool {
        guard depth <= 64 else { return false }
        switch value {
        case .object(let fields):
            return Set(fields.map(\.key)).count == fields.count && fields.allSatisfy { uniqueKeys($0.value, depth: depth + 1) }
        case .array(let values): return values.allSatisfy { uniqueKeys($0, depth: depth + 1) }
        default: return true
        }
    }
    private static func validRevision(_ text: String) -> Bool { text.range(of: #"^[A-Fa-f0-9]{40}$|^[A-Fa-f0-9]{64}$"#, options: .regularExpression) != nil }
    private static func invalidDelivery() -> NativeRPCError { .init(code: "access-denied", message: "This GitHub delivery could not be verified for the selected app and branch.") }
}

/// Supplied only by DKA's existing trusted server/helper connection. Merely
/// setting a runtime feature flag or an RPC payload cannot create this seam.
/// readConnection is read only; it returns the protected webhook secret and
/// exact configured target. The ingress owns durable receipt of events while
/// the Mac is off. This module starts no listener, port, task or timer.
public struct BackendAppsAutoDeployIngress: Sendable {
    public let readConnection: @Sendable (String, String, NativeRPCContext) async throws -> BackendAppsAutoDeployConnection
    public let configure: @Sendable (String, String, Bool, BackendAppsPushTarget?, NativeRPCContext) async throws -> Void
    public let authorizeDelivery: @Sendable (String, String, BackendAppsVerifiedPush, NativeRPCContext) async throws -> Void
    /// Dispatch must deploy `push.revision` exactly under the approved context,
    /// never the latest branch head. It must also recheck the app is enabled.
    public let dispatch: @Sendable (String, String, BackendAppsVerifiedPush, NativeRPCContext) async throws -> NativeRPCValue
    public init(readConnection: @escaping @Sendable (String, String, NativeRPCContext) async throws -> BackendAppsAutoDeployConnection,
                configure: @escaping @Sendable (String, String, Bool, BackendAppsPushTarget?, NativeRPCContext) async throws -> Void,
                authorizeDelivery: @escaping @Sendable (String, String, BackendAppsVerifiedPush, NativeRPCContext) async throws -> Void,
                dispatch: @escaping @Sendable (String, String, BackendAppsVerifiedPush, NativeRPCContext) async throws -> NativeRPCValue) {
        self.readConnection = readConnection; self.configure = configure
        self.authorizeDelivery = authorizeDelivery; self.dispatch = dispatch
    }
}

public struct BackendAppsAutoDeployConnection: Sendable {
    public let target: BackendAppsPushTarget
    public let secret: Data
    public let enabled: Bool
    public init(target: BackendAppsPushTarget, secret: Data, enabled: Bool = false) throws {
        guard (16...4096).contains(secret.count) else { throw BackendAppsRuntime.unavailable("The trusted GitHub connection needs a protected webhook secret.") }
        self.target = target; self.secret = secret; self.enabled = enabled
    }
}

public struct BackendAppsAutoDeploy: Sendable {
    public static let maximumDeliveries = 256
    public static let replayTTLMS: Double = 7 * 86_400_000
    private let runtime: BackendAppsRuntime
    private let store: BackendAppsStore
    private let ingress: BackendAppsAutoDeployIngress?
    public init(runtime: BackendAppsRuntime, store: BackendAppsStore? = nil, trustedIngress: BackendAppsAutoDeployIngress? = nil) {
        self.runtime = runtime; self.store = store ?? BackendAppsStore(runtime: runtime); self.ingress = trustedIngress
    }

    /// Called only after the channel's existing write approval. Enabling
    /// remains unavailable by default, even if a feature flag claims otherwise.
    public func apply(serverID: String, appID: String, enabled: Bool, context: NativeRPCContext) async throws -> NativeRPCValue {
        let app = try BackendAppsValidation.id(appID)
        if enabled && ingress == nil { throw Self.unavailable() }
        let store = store, ingress = ingress
        return try await store.withLock(serverID, app) {
            let record = try await store.read(serverID, app)
            guard record["pendingAutoDeploy"].isNullish else { throw NativeRPCError(code: "conflict", message: "An automatic deploy settings change is pending. Inspect it before changing these settings again.") }
            guard let ingress else {
                guard record["autoDeploy"].bool != true else { throw BackendAppsRuntime.unavailable("The trusted GitHub connection is unavailable, so its current automatic deploy settings cannot be disabled safely.") }
                try await store.write(serverID, app, record.setting("autoDeploy", .bool(false)))
                return BackendAppsValidation.object([("enabled", .bool(false))])
            }
            let target: BackendAppsPushTarget?
            if enabled { target = try BackendAppsPushTarget(record: record) } else { target = nil }
            let previous = try await Self.connection(ingress, serverID, app, context)
            if let target { guard previous.target == target else { throw Self.unavailable() } }
            // A durable intent closes the crash window between helper config
            // and state.json. receive refuses pushes while this journal exists.
            let journal = BackendAppsValidation.object([
                ("id", .string(UUID().uuidString.lowercased())), ("requestedEnabled", .bool(enabled)),
                ("previousEnabled", .bool(previous.enabled)), ("repository", .string(previous.target.repository)),
                ("branch", .string(previous.target.branch)), ("phase", .string("configuring"))
            ])
            try await store.write(serverID, app, record.setting("pendingAutoDeploy", journal))
            do {
                try await ingress.configure(serverID, app, enabled, target, context)
                let verified = try await Self.connection(ingress, serverID, app, context)
                guard verified.enabled == enabled, !enabled || verified.target == target else { throw Self.unavailable() }
                try await store.write(serverID, app, record.setting("autoDeploy", .bool(enabled)).removing("pendingAutoDeploy"))
            } catch {
                // Restore the original binding AND record. Keep the journal
                // if either restoration cannot be verified. Task retains RPC
                // tasklocals and does not inherit cancellation of this action.
                let reverted = await Task { () -> Bool in
                    do {
                        try await ingress.configure(serverID, app, previous.enabled, previous.enabled ? previous.target : nil, context)
                        let verified = try await Self.connection(ingress, serverID, app, context)
                        guard verified.enabled == previous.enabled, !previous.enabled || verified.target == previous.target else { return false }
                        try await store.write(serverID, app, record)
                        return true
                    } catch { return false }
                }.value
                if !reverted { throw NativeRPCError(code: "state-failed", message: "Automatic deploy settings could not be confirmed. Inspect the server's pending change before retrying.", details: BackendAppsValidation.object([("autoDeployUncertain", .bool(true))])) }
                if error is CancellationError { throw CancellationError() }
                throw NativeRPCError(code: "state-failed", message: "Automatic deploy settings could not be changed. The previous settings were restored.")
            }
            return BackendAppsValidation.object([("enabled", .bool(enabled))])
        }
    }

    /// Driven by one delivery from the trusted ingress. HMAC verification
    /// precedes approval; approval precedes all server state I/O and dispatch.
    /// Opting into auto deploy never substitutes for approval of this push.
    public func receive(serverID: String, appID: String, headers: [BackendAppsPushHeader], body: Data, context: NativeRPCContext) async throws -> NativeRPCValue {
        let app = try BackendAppsValidation.id(appID)
        guard let ingress else { throw Self.unavailable() }
        try BackendAppsPushVerifier.preflight(headers: headers, body: body)
        let connection = try await Self.connection(ingress, serverID, app, context)
        guard connection.enabled else { throw NativeRPCError(code: "conflict", message: "Automatic deploys are disabled in this app's GitHub connection.") }
        let push = try BackendAppsPushVerifier.verify(headers: headers, body: body, secret: connection.secret, target: connection.target)
        // A thrown/denied approval reaches no store, lock, timestamp or deploy.
        try await ingress.authorizeDelivery(serverID, app, push, context)
        try Task.checkCancellation()
        let store = store, service = self
        let claimed = try await store.withLock(serverID, app) {
            let record = try await store.read(serverID, app)
            guard record["pendingAutoDeploy"].isNullish else { throw NativeRPCError(code: "conflict", message: "An automatic deploy settings change is pending. Inspect it before accepting pushes.") }
            guard record["autoDeploy"].bool == true else { throw NativeRPCError(code: "conflict", message: "Automatic deploys are disabled for this app.") }
            guard try BackendAppsPushTarget(record: record) == connection.target else { throw NativeRPCError(code: "conflict", message: "The app's repository or branch changed. Check its GitHub connection.") }
            let now = try await service.serverTimestamp(serverID)
            var ledger = try await service.readLedger(serverID, app)
            // Only completed entries expire. An interrupted/uncertain dispatch
            // remains claimed until explicitly inspected, never auto retried.
            ledger.deliveries.removeAll { $0.status == "completed" && now >= $0.receivedAt && now - $0.receivedAt >= Self.replayTTLMS }
            if ledger.deliveries.contains(where: { $0.push.deliveryID == push.deliveryID || $0.push.bodyDigest == push.bodyDigest }) { return false }
            guard ledger.deliveries.count < Self.maximumDeliveries else { throw NativeRPCError(code: "busy", message: "The server's GitHub delivery record is full. Inspect pending deploys before accepting more pushes.") }
            ledger.deliveries.append(.init(push: push, receivedAt: now, status: "dispatching"))
            try await service.writeLedger(serverID, app, ledger)
            return true
        }
        guard claimed else { return BackendAppsValidation.object([("accepted", .bool(false)), ("duplicate", .bool(true)), ("deliveryId", .string(push.deliveryID))]) }
        let result: NativeRPCValue
        do {
            try Task.checkCancellation()
            result = try await ingress.dispatch(serverID, app, push, context)
            guard let deploymentID = result["id"].string, (try? BackendAppsValidation.identifier(deploymentID)) != nil,
                  result["commit"].string == push.revision, result["status"].string == "running" else {
                throw BackendAppsRuntime.unavailable("The deployment did not confirm the approved GitHub revision.")
            }
        } catch {
            // A transport can fail after deployment. Keep an uncertain claim
            // so redelivery cannot start the same push twice.
            _ = await Task { try? await service.finish(serverID, app, push: push, status: "uncertain") }.value
            if error is CancellationError { throw CancellationError() }
            throw NativeRPCError(code: (error as? NativeRPCError)?.code == "unavailable" ? "unavailable" : "build-failed", message: "The approved GitHub push could not be confirmed as deployed. Its delivery remains recorded; inspect the app before retrying.")
        }
        try await finish(serverID, app, push: push, status: "completed")
        return BackendAppsValidation.object([
            ("accepted", .bool(true)), ("deliveryId", .string(push.deliveryID)),
            ("revision", .string(push.revision)), ("deploymentId", result["id"].string.map(NativeRPCValue.string) ?? .null)
        ])
    }

    private static func connection(_ ingress: BackendAppsAutoDeployIngress, _ server: String, _ app: String, _ context: NativeRPCContext) async throws -> BackendAppsAutoDeployConnection {
        do { return try await ingress.readConnection(server, app, context) }
        catch is CancellationError { throw CancellationError() }
        catch { throw unavailable() }
    }
    private func serverTimestamp(_ server: String) async throws -> Double {
        let result = try await runtime.run(server, "date +%s", timeoutMS: 10_000, maximumBytes: 128)
        guard result.code == 0, !result.truncated, let seconds = Double(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)), seconds.isFinite, seconds > 0, seconds < 253_402_300_800 else {
            throw NativeRPCError(code: "state-failed", message: "The server's clock could not be checked for GitHub deliveries.")
        }
        return seconds * 1000
    }
    private func ledgerPath(_ app: String) throws -> String { try store.directory(app) + "/push-deliveries.json" }
    private func readLedger(_ server: String, _ app: String) async throws -> Ledger {
        guard let data = try await store.readFile(server, path: ledgerPath(app)) else { return .init(version: 1, deliveries: []) }
        do {
            guard BackendAppsPushVerifier.safeJSON(data) else { throw Self.damagedLedger() }
            let ledger = try JSONDecoder().decode(Ledger.self, from: data)
            guard ledger.version == 1, ledger.deliveries.count <= Self.maximumDeliveries,
                  ledger.deliveries.allSatisfy({ ["dispatching", "completed", "uncertain"].contains($0.status) && $0.receivedAt.isFinite && $0.receivedAt > 0 && $0.push.valid }),
                  Set(ledger.deliveries.map { $0.push.deliveryID }).count == ledger.deliveries.count else { throw Self.damagedLedger() }
            return ledger
        } catch { throw Self.damagedLedger() }
    }
    private func writeLedger(_ server: String, _ app: String, _ ledger: Ledger) async throws {
        try await store.writeFile(server, path: ledgerPath(app), contents: JSONEncoder().encode(ledger))
    }
    private func finish(_ server: String, _ app: String, push: BackendAppsVerifiedPush, status: String) async throws {
        let store = store, service = self
        try await store.withLock(server, app) {
            var ledger = try await service.readLedger(server, app)
            guard let index = ledger.deliveries.firstIndex(where: { $0.push.deliveryID == push.deliveryID && $0.push.bodyDigest == push.bodyDigest }) else { throw Self.damagedLedger() }
            ledger.deliveries[index].status = status
            try await service.writeLedger(server, app, ledger)
        }
    }
    private struct Ledger: Codable, Sendable { let version: Int; var deliveries: [Receipt] }
    private struct Receipt: Codable, Sendable {
        let push: SavedPush
        let receivedAt: Double
        var status: String
        init(push: BackendAppsVerifiedPush, receivedAt: Double, status: String) { self.push = SavedPush(push); self.receivedAt = receivedAt; self.status = status }
    }
    private struct SavedPush: Codable, Sendable {
        let deliveryID: String, repository: String, ref: String, revision: String, senderLogin: String, bodyDigest: String
        let repositoryID: UInt64, senderID: UInt64
        init(_ push: BackendAppsVerifiedPush) {
            deliveryID = push.deliveryID; repository = push.repository; ref = push.ref; revision = push.revision
            senderLogin = push.senderLogin; bodyDigest = push.bodyDigest; repositoryID = push.repositoryID; senderID = push.senderID
        }
        var valid: Bool {
            guard let uuid = UUID(uuidString: deliveryID), uuid.uuidString.lowercased() == deliveryID,
                  repositoryID > 0, senderID > 0, ref.hasPrefix("refs/heads/"),
                  (try? BackendAppsPushTarget(repository: repository, branch: String(ref.dropFirst(11)))) != nil,
                  senderLogin.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]{0,99}(?:\[bot\])?$"#, options: .regularExpression) != nil,
                  revision.range(of: #"^[a-f0-9]{40}$|^[a-f0-9]{64}$"#, options: .regularExpression) != nil,
                  revision.contains(where: { $0 != "0" }), bodyDigest.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else { return false }
            return true
        }
    }
    private static func damagedLedger() -> NativeRPCError { .init(code: "state-failed", message: "The server's GitHub delivery record could not be read safely. Inspect it before retrying.") }
    private static func unavailable() -> NativeRPCError { BackendAppsRuntime.unavailable("Automatic deploys need a trusted signed GitHub connection with approval for each push. It has not been connected yet.") }
}
