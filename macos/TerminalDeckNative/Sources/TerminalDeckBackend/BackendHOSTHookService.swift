import Foundation
import TerminalDeckNativeCore

public struct BackendHOSTHookProjection: Codable, Sendable {
    public var sessionID: String
    public var provider: String
    public var conversationID: String?
    public var status: BackendSessionStatus?
    public var receivedAt: Double
}

/// Uses the existing authenticated hook HTTP server and its parser. Only the
/// session bookkeeping callback changes owner; no provider settings are guessed.
public actor BackendHOSTHookService {
    public typealias Receiver = @Sendable (BackendSessionHookEvent) async -> Bool
    public typealias CoordinatorFactory = @Sendable (@escaping Receiver) -> BackendSessionHookCoordinator
    public nonisolated let attribution: BackendAccountAttribution
    private let manager: BackendPTYManager
    private let peerBelongs: @Sendable (Int32, Int32) -> Bool
    private let changed: @Sendable (BackendHOSTHookProjection) -> Void
    private let externalSession: @Sendable (String) async throws -> (BackendSessionMeta, Int32)?
    private var hookServer: BackendSessionHookServer?
    private var coordinator: BackendSessionHookCoordinator?
    private var observations: [String: BackendHOSTHookProjection] = [:]
    private var stopped = false
    private var observers: [UUID: @Sendable (BackendHOSTHookProjection) -> Void] = [:]
    #if TD_HOST_ACCOUNT_BRIDGE
    private var acceptedEvents: [BackendHOSTAcceptedHookEvent] = []
    private var acceptedSequence: UInt64 = 0
    private var acceptedObserver: (@Sendable (BackendSessionHookEvent) -> Void)?
    private var installedRPC: BackendSessionHookRPC?
    private var installedSettings: [String: URL]?
    private var installedOffer: URL?
    public func observeAccepted(_ callback: (@Sendable (BackendSessionHookEvent) -> Void)?) { acceptedObserver = callback }
    public func makeRPC(configuration: BackendAccountConfiguration, settings: [String: URL], offer: URL,
                        authorizeMutation: @escaping @Sendable (NativeRPCContext) throws -> Void) throws -> BackendSessionHookRPC {
        guard !stopped, let hookServer else { throw BackendHOSTFailure.unavailable }
        if let installedRPC {
            guard settings == installedSettings, offer == installedOffer else { throw BackendHOSTFailure.authentication }
            return installedRPC
        }
        let installation = try BackendSessionHookInstallation(configuration: configuration, endpoint: hookServer.endpoint,
            providerSettingsFiles: settings, offerFile: offer, authorizeMutation: authorizeMutation)
        let rpc = BackendSessionHookRPC(installation: installation, server: hookServer)
        installedRPC = rpc; installedSettings = settings; installedOffer = offer; return rpc
    }
    public func accepted(after sequence: UInt64) -> [BackendHOSTAcceptedHookEvent] { acceptedEvents.filter { $0.sequence > sequence } }
    #endif

    private init(manager: BackendPTYManager, attribution: BackendAccountAttribution,
                 peerBelongs: @escaping @Sendable (Int32, Int32) -> Bool,
                 externalSession: @escaping @Sendable (String) async throws -> (BackendSessionMeta, Int32)?,
                 changed: @escaping @Sendable (BackendHOSTHookProjection) -> Void) {
        self.manager = manager; self.attribution = attribution; self.peerBelongs = peerBelongs; self.externalSession = externalSession; self.changed = changed
    }
    public static func start(configuration: BackendAccountConfiguration, manager: BackendPTYManager,
                             accounts: BackendHOSTAccountService,
                             makeCoordinator: @escaping CoordinatorFactory,
                             peerBelongs: @escaping @Sendable (Int32, Int32) -> Bool,
                             additionalContext: @escaping @Sendable (BackendSessionHookEvent) async throws -> String?,
                             openLink: (@Sendable (URL, String?) async throws -> BackendSessionHookOpenAnswer)? = nil,
                             changed: @escaping @Sendable (BackendHOSTHookProjection) -> Void = { _ in }) async throws -> BackendHOSTHookService {
        let profiles = await accounts.accounts.profiles
        let attribution = BackendAccountAttribution(configuration: configuration, profiles: profiles, sessions: .init(manager: manager))
        let owner = BackendHOSTHookService(manager: manager, attribution: attribution, peerBelongs: peerBelongs, externalSession: { id in
            #if TD_HOST_ACCOUNT_BRIDGE
            guard let meta = await accounts.externalMetadata(id), let pid = try await accounts.externalPID(id) else { return nil }
            return (meta, pid)
            #else
            return nil
            #endif
        }, changed: changed)
        let coordinator = makeCoordinator { [weak owner] event in await owner?.receive(event) ?? false }
        let server = try BackendSessionHookServer(configuration: configuration, sessionEnvironment: BackendSessionEnvironment.sessionVariable,
            coordinator: coordinator, additionalContext: additionalContext, openLink: openLink)
        await owner.install(server, coordinator: coordinator)
        return owner
    }
    private func install(_ server: BackendSessionHookServer, coordinator: BackendSessionHookCoordinator) {
        hookServer = server; self.coordinator = coordinator
    }
    public func endpoint() throws -> BackendSessionHookEndpoint {
        guard !stopped, let hookServer else { throw BackendHOSTFailure.unavailable }; return hookServer.endpoint
    }
    @discardableResult
    public func receive(_ event: BackendSessionHookEvent) async -> Bool {
        guard !stopped, let id = event.sessionID else { return false }
        let external = try? await externalSession(id)
        guard let session = manager.list().first(where: { $0.id == id }) ?? external?.0, session.exitCode == nil,
              session.provider == event.provider || session.provider == "shell",
              let pid = manager.pidOf(id) ?? external?.1, peerBelongs(event.peerPID, pid),
              event.payload["isSidechain"].bool != true, event.payload["is_sidechain"].bool != true,
              event.cliSessionID == nil || session.agentSessionId == nil || event.cliSessionID == session.agentSessionId else { return false }
        #if TD_HOST_ACCOUNT_BRIDGE
        do {
            let next = acceptedSequence + 1
            let actual = try BackendHOSTAcceptedHookEvent(sequence: next, actual: event)
            acceptedSequence = next; acceptedEvents.append(actual)
            if acceptedEvents.count > 128 { acceptedEvents.removeFirst(acceptedEvents.count - 128) }
        } catch { return false }
        #endif
        let named = event.cliSessionID
        if event.event == "SessionStart", session.provider != "shell", let named,
           named.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil {
            manager.setAgentSessionId(id, conversationId: named)
        }
        if let evidence = event.agentEnvironment { await attribution.recordHook(sessionID: id, evidence: evidence) }
        var status = BackendSessionHookCoordinator.statuses[event.provider]?[event.event]
        if session.provider == "shell", event.event == "SessionEnd" { status = .waiting }
        let value = BackendHOSTHookProjection(sessionID: id, provider: event.provider,
            conversationID: named ?? session.agentSessionId, status: status, receivedAt: event.receivedAt.timeIntervalSince1970 * 1_000)
        observations[id] = value; changed(value)
        for observer in observers.values { observer(value) }
        if event.event == "SessionEnd" { await attribution.drop(sessionID: id) }
        #if TD_HOST_ACCOUNT_BRIDGE
        acceptedObserver?(event)
        #endif
        return true
    }
    public func snapshot() -> [BackendHOSTHookProjection] {
        observations.values.filter { value in manager.list().contains { $0.id == value.sessionID && $0.exitCode == nil } }.sorted { $0.sessionID < $1.sessionID }
    }
    public func processExited(_ id: String) async { observations[id] = nil; await attribution.drop(sessionID: id) }
    public func detachApp() {} // Endpoint/token/statuses remain owned by this helper.
    public func observe(_ callback: @escaping @Sendable (BackendHOSTHookProjection) -> Void) -> UUID {
        let id = UUID(); observers[id] = callback; return id
    }
    public func removeObserver(_ id: UUID) { observers[id] = nil }
    public func stop(afterProcessDrain drained: Bool) async throws {
        guard drained else { throw BackendHOSTFailure.remote("Running sessions still own the hook endpoint.") }
        guard !stopped else { return }; stopped = true
        hookServer?.stop(); hookServer = nil; await coordinator?.stop(); coordinator = nil; observations.removeAll(); observers.removeAll()
        #if TD_HOST_ACCOUNT_BRIDGE
        acceptedEvents.removeAll()
        acceptedObserver = nil
        installedRPC = nil; installedSettings = nil; installedOffer = nil
        #endif
    }
}
