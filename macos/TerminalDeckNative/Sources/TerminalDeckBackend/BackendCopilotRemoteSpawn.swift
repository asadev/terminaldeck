import Foundation
import TerminalDeckNativeCore

public struct BackendCopilotRemoteFenceMeasurement: Sendable {
    /// nil means the measured fence is unsupported, as in buildRecordsFence.
    /// The run still starts; its records are described by the canonical paths.
    public let fenceID: String?
    public let records: BackendCopilotLayerRecords
    public init(fenceID: String?, records: BackendCopilotLayerRecords) { self.fenceID = fenceID; self.records = records }
}

/// Narrow launch services owned by the core account/session/confinement graph.
/// No guessed profiles, paths, fence proof or substitute shell is supplied here.
public protocol BackendCopilotRemoteSpawnServices: Sendable {
    func resolveProfile(cwd: String) async throws -> BackendAccountProfile
    /// The actual launch overrides, including an explicit removal of inherited
    /// CLAUDE_CONFIG_DIR for a system profile (return no override in that case).
    func sessionEnvironment(profile: BackendAccountProfile) async throws -> [String: String]
    func measureRecordsFence(cwd: String, profile: BackendAccountProfile) async throws -> BackendCopilotRemoteFenceMeasurement
    func tools() async throws -> [BackendCopilotLayerTool]
    func startSession(_ input: BackendCreateSessionInput, context: BackendLaunchContext) async throws -> BackendSessionMeta
    func announce(_ session: BackendSessionMeta) async throws
    func stopSession(_ sessionID: String) async throws
}

/// remote/copilot-wiring.ts startCopilotRun: same account, fresh conversation,
/// actual trust file, regenerated Hoot layer and freshly measured records fence.
public struct BackendCopilotRemoteSpawner: Sendable {
    private let userData: String
    private let home: String
    private let inheritedEnvironment: [String: String]
    private let services: any BackendCopilotRemoteSpawnServices
    private let diagnostic: @Sendable (String) -> Void
    private let hidden: BackendRemoteServeSessionHidden
    /// `hidden` is the same register `BackendCopilotRemoteRuns` uses: the run's
    /// PTY is hidden at spawn, before any list/attach/announce can see it.
    public init(userData: String, accountHome: String, inheritedEnvironment: [String: String],
                services: any BackendCopilotRemoteSpawnServices,
                diagnostic: @escaping @Sendable (String) -> Void = { NSLog("%@", $0) },
                hidden: BackendRemoteServeSessionHidden = .shared) {
        self.userData = userData; home = accountHome; self.inheritedEnvironment = inheritedEnvironment
        self.services = services; self.diagnostic = diagnostic; self.hidden = hidden
    }
    public func spawn(_ request: BackendCopilotRemoteSpawnRequest) async throws -> String {
        let profile = try await services.resolveProfile(cwd: request.cwd)
        let measured = try await services.measureRecordsFence(cwd: request.cwd, profile: profile)
        let environment = try await services.sessionEnvironment(profile: profile)
        // System launch clears an inherited config override, so the trust-file
        // calculation must clear it too. Named profile env wins over inheritance.
        var inherited = inheritedEnvironment
        if profile.system && environment["CLAUDE_CONFIG_DIR"] == nil { inherited["CLAUDE_CONFIG_DIR"] = nil }
        let trustFile = BackendCopilotTrust.trustFile(overrides: environment, environment: inherited, home: home)
        let trust = BackendCopilotTrust.trustFolder(file: trustFile, folder: request.cwd)
        if trust == .refused { diagnostic("[copilot] \(request.cwd) is recorded as not trusted, so this run will stop at the CLI’s prompt") }
        let paths = BackendCopilotPaths(userData: userData, home: request.cwd)
        let layer = BackendCopilotLayer.write(paths.layer, input: .init(root: paths.root, actionsLog: paths.actions,
            chosenFolder: !paths.ownFolder, userData: userData, tools: try await services.tools(), toolsAttached: true, records: measured.records))
        guard let composed = layer.composed else {
            throw NativeRPCError(code: "unavailable", message: "the instructions for this run of Hoot could not be prepared: \(layer.error ?? "instructions are unavailable")")
        }
        var input = BackendCreateSessionInput(cwd: request.cwd, cols: 120, rows: 30, provider: "claude")
        input.resume = false; input.profileId = profile.id; input.origin = .copilot
        let context = BackendLaunchContext(deviceBoundary: nil, appFenceID: measured.fenceID,
            extraArguments: ["--mcp-config", request.mcpConfig, "--strict-mcp-config"] + BackendCopilotLayer.args(composed: composed),
            rememberTab: false, isAppComposed: true, beforeExposure: { [hidden] id in hidden.hide(id) })
        let session = try await services.startSession(input, context: context)
        hidden.hide(session.id) // idempotent; covers a launcher that did not call the hook
        guard session.provider == "claude" else {
            try await services.stopSession(session.id); hidden.release(session.id)
            throw NativeRPCError(code: "unavailable", message: "this run of Hoot started as a plain shell rather than an agent")
        }
        do { try await services.announce(session) }
        catch {
            // Keep a possibly-live PTY hidden if stopping failed.
            if (try? await services.stopSession(session.id)) != nil { hidden.release(session.id) }
            throw error
        }
        return session.id
    }
}
