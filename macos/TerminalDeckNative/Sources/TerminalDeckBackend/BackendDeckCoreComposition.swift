import Foundation
import TerminalDeckNativeCore

public protocol BackendDeckCoreConsentRelay: Sendable {
    func ask(_ request: BackendDeckCoreSecurityConsentRequest) async throws -> Bool
    func settled(id: String, outcome: BackendDeckCoreSecurityConsentOutcome) async throws
}

/// The window identity is supplied by native assembly, never by tool arguments.
/// Navigation/reload/close must call gone(), so the old screen cannot approve.
public actor BackendDeckCoreWindowConsent {
    public typealias Trust = @Sendable (NativeRPCContext) -> Bool
    public let isApprover: Trust
    private let send: @Sendable (String, String, NativeRPCValue) async throws -> Bool
    private let broadcast: @Sendable (String, NativeRPCValue) async throws -> Void
    private let relay: (any BackendDeckCoreConsentRelay)?
    private var ownerID: String?
    public init(isApprover: @escaping Trust,
                send: @escaping @Sendable (String, String, NativeRPCValue) async throws -> Bool,
                broadcast: @escaping @Sendable (String, NativeRPCValue) async throws -> Void,
                relay: (any BackendDeckCoreConsentRelay)? = nil) {
        self.isApprover = isApprover; self.send = send; self.broadcast = broadcast; self.relay = relay
    }
    public func attach(context: NativeRPCContext, broker: BackendDeckCoreSecurityConsentBroker) async throws -> NativeRPCValue {
        guard isApprover(context) else { throw NativeRPCError(code: "access-denied", message: "deck-control: this window may not answer confirmations") }
        let previous = ownerID
        ownerID = context.ownerID
        if let previous, previous != context.ownerID { await broker.approverGone() }
        return .array(await broker.list().map(\.wireValue))
    }
    public func respond(context: NativeRPCContext, broker: BackendDeckCoreSecurityConsentBroker, id: NativeRPCValue, approved: NativeRPCValue) async throws -> NativeRPCValue {
        guard isApprover(context), ownerID == context.ownerID else { throw NativeRPCError(code: "access-denied", message: "deck-control: this window may not answer confirmations") }
        guard let id = id.string, !id.isEmpty else { throw NativeRPCError.invalidArguments("deck-control: a request id is required") }
        let accepted = await broker.respond(id: id, approved: approved == .bool(true), by: "window")
        return .object([.init("accepted", .bool(accepted))])
    }
    public func accepts(_ context: NativeRPCContext) -> Bool { isApprover(context) && context.ownerID == ownerID }
    @discardableResult public func gone(ownerID: String, broker: BackendDeckCoreSecurityConsentBroker) async -> Bool {
        guard self.ownerID == ownerID else { return false }; self.ownerID = nil; await broker.approverGone(); return true
    }
    public func ask(_ request: BackendDeckCoreSecurityConsentRequest) async -> Bool {
        // A failed relay never prevents the window from seeing the question.
        let delivered = (try? await relay?.ask(request)) == true
        guard let target = ownerID else { return delivered }
        return (try? await send(target, "deck-control:consent-request", request.wireValue)) == true || delivered
    }
    public func settled(id: String, outcome: BackendDeckCoreSecurityConsentOutcome) async {
        try? await broadcast("deck-control:consent-settled", .object([.init("id", .string(id)), .init("outcome", outcome.wireValue)]))
        try? await relay?.settled(id: id, outcome: outcome)
    }
}

/// Source index.ts's task/goal/plugin graph is supplied by its owning lanes.
/// These operations must reach the same objects the task channels use.
public protocol BackendDeckCoreFeatureLifecycle: Sendable {
    func recover(control: BackendDeckCoreSecurityControl) async throws
    func noteStatus(sessionID: String, status: String) async
    func noteExit(sessionID: String, exitCode: Int) async
    func tasksWake() async
    func stopTasks() async
    func stopPlugins() async
}
public protocol BackendDeckCoreTours: Sendable {
    func driving() async -> Bool
    func list(count: Int) async throws -> [NativeRPCValue]
    func acknowledge(id: String) async throws -> Bool
    func progress(id: String, record: NativeRPCValue) async throws -> Bool
    func end(id: String, record: NativeRPCValue) async throws -> Bool
    func windowGone() async
    func stop() async
}
public protocol BackendDeckCoreRelayInstallation: Sendable {
    func install(_ server: BackendDeckCoreSecurityServer?) async throws
    func facts() async -> BackendDeckCoreEventsRelayFacts?
}

/// A contributed area cannot lose its source policy while entering the door.
/// deck-tools supplies these metadata/policies beside its stable small ToolArea.
public enum BackendDeckCoreAreaIntegration {
    public static func bundle(area: BackendDeckCoreToolArea, metadata: [BackendDeckCoreCatalogueMetadata], policies: [BackendDeckCoreSecurityToolPolicy]) throws -> BackendDeckCoreCatalogueBundle {
        let ids = Set(area.tools.map(\.id))
        guard ids == Set(metadata.map { $0.tool.id }), ids == Set(policies.map { $0.tool.id }),
              metadata.count == area.tools.count, policies.count == area.tools.count,
              area.tools.allSatisfy({ tool in
                  metadata.contains { $0.tool.id == tool.id && $0.tool.wireName == tool.wireName && $0.tool.tier == tool.tier && $0.tool.inputSchema == tool.inputSchema }
              }) else { throw NativeRPCError.invalidArguments("Every tool area must supply its original metadata, consent policy and real handler.") }
        // Security: asset tools keep their URL redaction in the central action log.
        return try .init(metadata: metadata, policies: policies.map(BackendDeckToolsAssets.withURLRedaction))
    }
    public static func eventsBundle(policies: [BackendDeckCoreSecurityToolPolicy]) throws -> BackendDeckCoreCatalogueBundle {
        let rows = try BackendDeckCoreEventsToolDefinitions.all()
        let metadata = try policies.map { policy -> BackendDeckCoreCatalogueMetadata in
            guard let row = rows.first(where: { $0["id"].string == policy.tool.id }), let title = row["title"].string else {
                throw BackendSessionFailure.missingCapability("the source metadata for \(policy.tool.id)")
            }
            return .init(tool: policy.tool, title: title, aliases: row["aliases"].elements?.compactMap(\.string) ?? [],
                index: row["index"].string, audience: row["audience"].string, keyIndex: row["keyIndex"].string, keyGrant: row["keyGrant"].string)
        }
        return try .init(metadata: metadata, policies: policies)
    }
}

public enum BackendDeckCoreConfiguration {
    public static let attendedFile = "deck-control.json", unattendedFile = "deck-control-unattended.json"
    public static func mcpConfigFor(_ endpoint: BackendDeckCoreSecurityEndpoint, unattended: Bool = false) throws -> Data {
        let value = NativeRPCValue.object([.init("mcpServers", .object([.init("deck-control", .object([
            .init("type", .string("http")), .init("url", .string(endpoint.url.absoluteString)),
            .init("headers", .object([.init("Authorization", .string("Bearer " + (unattended ? endpoint.unattendedToken : endpoint.token)))]))
        ]))]))])
        return try value.encodedJSON(pretty: true) + Data([10])
    }
    public static func write(endpoint: BackendDeckCoreSecurityEndpoint, copilotRoot: URL, ownership: NativeStateStore.Ownership) throws -> (attended: URL, unattended: URL) {
        guard ownership == .exclusive else { throw NativeRPCError(code: "read-only", message: "Writing an MCP config requires exclusive native record ownership.") }
        let files = try BackendTaskPersistence(directory: copilotRoot, ownership: ownership)
        try files.writeBytes(attendedFile, data: mcpConfigFor(endpoint))
        do { try files.writeBytes(unattendedFile, data: mcpConfigFor(endpoint, unattended: true)) }
        catch { try? files.remove(attendedFile); throw error }
        return (try files.file(attendedFile), try files.file(unattendedFile))
    }
}

public enum BackendDeckCoreStatus {
    public static func value(endpoint: BackendDeckCoreSecurityEndpoint, control: BackendDeckCoreSecurityControl,
                             metadata: [BackendDeckCoreCatalogueMetadata], consent: BackendDeckCoreSecurityConsentBroker,
                             log: BackendDeckCoreSecurityActionLog) async throws -> NativeRPCValue {
        let policies = await control.tools(), ids = Set(policies.map { $0.tool.id })
        let registry = try BackendDeckCoreCatalogueRegistry(metadata: metadata.filter { ids.contains($0.tool.id) })
        let cost = BackendDeckCoreCatalogueCost.measure(try registry.listing())
        let titles = Dictionary(uniqueKeysWithValues: metadata.map { ($0.tool.id, $0.title) })
        let tools = try policies.map { policy -> NativeRPCValue in
            guard let title = titles[policy.tool.id] else { throw BackendSessionFailure.missingCapability("the source title for \(policy.tool.id)") }
            return .object([.init("id", .string(policy.tool.id)), .init("tier", .string(policy.tool.tier.rawValue)), .init("title", .string(title))])
        }
        return .object([.init("running", .bool(true)), .init("port", .number(Double(endpoint.port))), .init("server", .string("deck-control")),
            .init("tools", .array(tools)), .init("catalogue", cost.wireValue), .init("pendingConfirmations", .number(Double(await consent.list().count))),
            .init("copilotSessions", .array(await control.copilotSessions().map(NativeRPCValue.string))),
            .init("logFile", .string(log.file.path)), .init("logging", .bool(!(await log.broken())))])
    }
}

extension BackendDeckCoreLiveSurface: BackendDeckCoreEventsDetectionSurface {
    public func notificationSessions() async throws -> [NativeRPCValue] { listSessions() }
    public func notificationScreen(sessionId: String) async throws -> String? { try await sessionScreen(sessionId) }
    public func notificationAnswer(session: NativeRPCValue) async throws -> NativeRPCValue? {
        let match = try await transcriptFor(session: session)
        guard let path = match["path"].string else { return nil }
        let size = try await transcriptBytes(path: path)
        for message in try await readTranscriptFrom(path: path, fromByte: max(0, size - 256 * 1024)).reversed() {
            guard message["role"].string == "agent", let text = message["text"].string else { continue }
            let trimmed = BackendDeckCoreCatalogueRules.trim(text)
            if !trimmed.isEmpty { return .object([.init("at", message["at"]), .init("text", .string(trimmed)), .init("truncated", .bool(false))]) }
        }
        return nil
    }
}
