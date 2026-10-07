import Foundation
import TerminalDeckNativeCore

/// store-install-ipc.ts factory only. BackendCommunityChannels already owns the
/// three exact channel handlers and choice/projection rules; no second registry.
public enum BackendOSStoreChannels {
    public static func make(userData: URL, environment: [String: String], home: String, packaged: Bool,
                            writable: Bool, configuredBase: @escaping @Sendable () async -> String?,
                            providers: BackendNativeProviders, commandRunner: BackendCommandRunner,
                            claudeMCP: BackendMcpClientWriter) throws -> BackendOSStoreInstaller {
        let keys = BackendSharedStoreKeys.keys(environment: environment, packaged: packaged)
        let cache = BackendAppStoreIndexCache(userData: userData, writable: writable, keys: keys)
        let runner = BackendOSStoreAgentRunner(providers: providers, runner: commandRunner, environment: environment, home: home)
        return try BackendOSStoreInstaller(userData: userData, environment: environment, home: home, writable: writable,
            loadIndex: {
                let configured = await configuredBase(), base = BackendSharedStoreApi.base(environment: environment, configured: configured)
                return await cache.load(base: base, now: Date().timeIntervalSince1970 * 1000)
            }, runAgent: { await runner.run(agent: $0, arguments: $1) }, claudeMCP: claudeMCP,
            environmentNames: { try await BackendOSPlatform.environmentNames(runner: commandRunner, environment: environment, home: home) })
    }
    @discardableResult public static func register(registry: NativeChannelRegistry, ownerID: String,
                                                  installer: BackendOSStoreInstaller, userData: URL,
                                                  providers: BackendNativeProviders, environment: [String: String], home: String) async throws -> [String] {
        try await BackendCommunityChannels.register(registry: registry, ownerID: ownerID, store: installer,
            userData: userData.path, probe: BackendCommunityNativeProbe(providers: providers),
            emptyHomes: BackendOSStoreInstaller.agentHomes(environment: environment, home: home))
    }
}
