import Foundation
import TerminalDeckNativeCore

/// Exact existing settings IPC names. These use the same trust actor as phone
/// requests; authorization is supplied by the native app's trusted caller gate.
public struct BackendRemoteServeAccountChannels: Sendable {
    public static let channels: Set<String> = ["remote:folders", "remote:folders:set", "remote:accounts", "remote:accounts:set", "remote:sessions", "remote:sessions:running", "remote:sessions:set"]
    private let trust: BackendRemoteTrustStore
    private let lifecycle: BackendSessionLifecycleCoordinator
    private let hidden: BackendRemoteServeSessionHidden
    private let foldersChanged: @Sendable (String) async -> Void
    private let sessionsChanged: @Sendable () async -> Void
    public init(trust: BackendRemoteTrustStore, lifecycle: BackendSessionLifecycleCoordinator, hidden: BackendRemoteServeSessionHidden = .shared,
                foldersChanged: @escaping @Sendable (String) async -> Void, sessionsChanged: @escaping @Sendable () async -> Void) {
        self.trust = trust; self.lifecycle = lifecycle; self.hidden = hidden; self.foldersChanged = foldersChanged; self.sessionsChanged = sessionsChanged
    }
    public func register(in registry: NativeChannelRegistry, ownerID: String, policy: @escaping NativeChannelRegistry.Policy) async throws {
        for channel in Self.channels.sorted() { try await registry.register(channel, ownerID: ownerID, policy: policy) { _, args in try await invoke(channel, arguments: args) } }
    }
    public func invoke(_ channel: String, arguments: [NativeRPCValue]) async throws -> NativeRPCValue {
        func arg(_ at: Int) -> NativeRPCValue { arguments.indices.contains(at) ? arguments[at] : .missing }
        switch channel {
        case "remote:folders": return await trust.remoteServeFolderGrants()
        case "remote:folders:set":
            if let id = arg(0).string, let folders = arg(1).elements {
                try await trust.remoteServeSetFolderGrants(id, folders: folders); await foldersChanged(id)
            }
            return await trust.remoteServeFolderGrants()
        case "remote:accounts": return .array(await trust.remoteServeAccountGrants().map(\.wireValue))
        case "remote:accounts:set":
            if let id = arg(0).string, !id.isEmpty { try await trust.remoteServeSetAccountGrants(id, mode: arg(1), accounts: arg(2).elements ?? []) }
            // As in source, current rules take effect immediately but account
            // capability changes wait for reconnect. No socket is torn down.
            return .array(await trust.remoteServeAccountGrants().map(\.wireValue))
        case "remote:sessions": return .array(await trust.remoteServeSessionGrants().map(\.wireValue))
        case "remote:sessions:running":
            return .array(await lifecycle.metadata().filter { !hidden.contains($0.session.id) }.map { meta in
                .object([.init("id", .string(meta.session.id)), .init("title", .string(meta.session.title)), .init("cwd", .string(meta.session.cwd)),
                    .init("provider", .string(meta.session.provider)), .init("status", .string(meta.status.rawValue)),
                    .init("exitCode", meta.session.exitCode.map { .number(Double($0)) } ?? .null)])
            })
        case "remote:sessions:set":
            if let id = arg(0).string, !id.isEmpty { try await trust.remoteServeSetSessionGrants(id, mode: arg(1), sessions: arg(2).elements ?? []); await sessionsChanged() }
            return .array(await trust.remoteServeSessionGrants().map(\.wireValue))
        default: throw NativeRPCError.invalidArguments("Unknown remote grant settings channel")
        }
    }
}
