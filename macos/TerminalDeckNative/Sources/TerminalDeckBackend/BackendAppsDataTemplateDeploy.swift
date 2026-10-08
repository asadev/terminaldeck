import Foundation
import TerminalDeckNativeCore

/// Creates protected server state, then reuses APE's health-gated deployment.
/// The APD channel authorizes the change before calling this service.
public struct BackendAppsDataTemplateDeploy: Sendable {
    private let runtime: BackendAppsRuntime
    private let store: BackendAppsStore
    private let caddy: BackendAppsCaddy

    public init(runtime: BackendAppsRuntime, store: BackendAppsStore) {
        self.runtime = runtime
        self.store = store
        self.caddy = BackendAppsCaddy(runtime: runtime)
    }

    public func deploy(serverID: String, appID: String, name: String, templateID: String,
                       environment: [String: String] = [:]) async throws -> NativeRPCValue {
        _ = try BackendAppsValidation.id(appID)
        try BackendAppsDataTemplatePlanner.validateRuntime(runtime, appID: appID)
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !serverID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, serverID.utf8.count <= 256,
              !serverID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !cleanName.isEmpty, cleanName.utf8.count <= 120,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw NativeRPCError.invalidArguments("Choose a short app name on one line and a connected server.")
        }
        let source = try BackendAppsDataTemplates.source(templateID: templateID)
        if templateID != "uptime-kuma", !runtime.features.contains(BackendAppsDataTemplates.expandedFeature) {
            throw BackendAppsRuntime.unavailable("This template is unavailable until its safe deploy support is connected.")
        }
        let env = try BackendAppsValidation.environment(.object(environment.map { .init($0.key, .string($0.value)) }))
        guard !env.values.contains(where: { ["••••••••", "••••••", "[redacted]"].contains($0) }) else {
            throw NativeRPCError.invalidArguments("Hidden settings cannot be used as real values.")
        }
        // Initial protected creation and the subsequent deploy share ONE
        // previously approved scope. The first lock must not close the lease
        // before APE's second lock and routing transaction begin.
        return try await runtime.withRecoveryTransaction(serverID: serverID, appID: appID) {
            try await self.deployPrepared(serverID: serverID, appID: appID, name: cleanName, source: source, environment: env)
        }
    }

    private func deployPrepared(serverID: String, appID: String, name: String, source: NativeRPCValue,
                                environment env: [String: String]) async throws -> NativeRPCValue {
        let store = self.store, caddy = self.caddy, now = runtime.now()
        try await store.withLock(serverID, appID) {
            if try await store.readFile(serverID, path: store.directory(appID) + "/state.json") != nil {
                throw NativeRPCError(code: "conflict", message: "An app with that address name already exists on this server.")
            }
            let domain = try await caddy.defaultDomain(serverID: serverID, appID: appID)
            let record = BackendAppsValidation.object([
                ("id", .string(appID)), ("name", .string(name)), ("kind", .string("app")),
                ("status", .string("stopped")), ("address", .string("https://" + domain)),
                ("domains", .array([.string(domain)])), ("source", source),
                ("createdAt", .number(now)), ("updatedAt", .number(now)),
                ("envKeys", .array(env.keys.sorted().map(NativeRPCValue.string))),
                ("activeDeploymentId", .null), ("autoDeploy", .bool(false)),
                ("backupPolicy", BackendAppsValidation.object([("enabled", .bool(false))]))
            ])
            try await store.applyEnvironment(serverID, appID, env)
            try await store.write(serverID, appID, record)
        }
        // APE acquires its own deploy lock. Do not nest the server lock.
        // Failures retain saved state/history for recovery and never report success.
        _ = try await BackendAppsDeploy(runtime: runtime, store: store, caddy: caddy).deploy(serverID: serverID, appID: appID)
        let record = try await store.read(serverID, appID)
        guard record["status"].string == "running", record["activeDeploymentId"].string != nil else {
            throw NativeRPCError(code: "state-failed", message: "The app's successful deploy could not be verified in its saved state.")
        }
        return BackendAppsStore.publicRecord(record)
    }
}
