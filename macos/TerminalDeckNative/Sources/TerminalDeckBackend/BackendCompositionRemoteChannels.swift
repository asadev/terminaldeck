import Foundation
import TerminalDeckNativeCore

/// The Remote settings page's own channels, natively (server.ts
/// registerRemoteIpc L9396-9600 with index.ts deps), over the real owners: the
/// host service (start/stop/status/pairing code), its endpoint (connection
/// rows) and the trust store (devices, kinds, approval). The channels
/// BackendRemoteServeRegistration owns — remote:folders(:set),
/// remote:accounts(:set), remote:sessions(:running|:set), remote:windows(:set),
/// remote:tunnel:stop — and the `remote:connections` push are not touched.
///
/// Policy: the app window (requireLocalUI) for everything; a credential-resolved
/// core call's page ticket may read (`authorizeMetadata`) and may change only
/// after its accepted act/alter receipt (`authorizeMutation`), which is how the
/// remote.* tools reach these. A paired device never passes either.
public enum BackendCompositionRemoteChannels {
    public static let reads: [String] = ["remote:status", "remote:devices", "remote:kinds", "confine:state"]
    public static let writes: [String] = ["remote:start", "remote:stop", "remote:pair", "remote:pair:cancel",
                                          "remote:device:approve", "remote:connection:disconnect"]
    public static var channels: [String] { reads + writes }
    /// index.ts REMOTE_ENABLED_KEY, written by onEnabledChange (L3370-3372).
    public static let enabledKey = "remote.enabled"

    /// `dropConnection` is the endpoint's own per-connection close (server.ts
    /// dropConnection L7813-7821: close 1001 "disconnected from the desktop", the
    /// device stays paired); false when that connection had already gone.
    /// `directPort` is the port the host service was built with (TS DEFAULT_PORT).
    public static func register(registry: NativeChannelRegistry, ownerID: String,
                                authority: BackendCompositionAuthority,
                                service: BackendRemoteHostService,
                                settings: any BackendCompositionSettingsWriting,
                                dropConnection: @escaping @Sendable (UUID) async -> Bool,
                                directPort: Int = 8443) async throws -> [String] {
        for channel in Self.channels {
            if await registry.has(channel) { throw NativeRPCError(code: "duplicate-handler", message: "Remote channel is already registered: " + channel) }
        }
        let memory = BackendCompositionRemoteChannelsMemory()
        let endpoint = service.endpoint, trust = endpoint.trust
        let status: @Sendable () async -> NativeRPCValue = {
            Self.wire(await service.status(), memory: await memory.snapshot(), port: directPort, connections: await endpoint.remoteServeConnectionRows())
        }
        let devices: @Sendable () async -> NativeRPCValue = { .array(await trust.listDevices().map(\.value)) }
        var handlers: [(String, NativeChannelRegistry.Handler)] = []
        handlers.append(("remote:status", { _, _ in await status() }))
        handlers.append(("remote:devices", { _, _ in await devices() }))
        handlers.append(("remote:kinds", { _, _ in .array(await trust.compositionKindRecords()) }))
        handlers.append(("confine:state", { _, _ in BackendAppConfinementChannels().state }))
        handlers.append(("remote:start", { _, _ in
            // server.start answers a status that says why rather than throwing.
            let started: Bool
            do { _ = try await service.start(); await memory.started(failure: nil); started = true }
            catch is CancellationError { throw CancellationError() }
            catch { await memory.started(failure: NativeRPCError.wrapping(error).message); started = false }
            let answer = await status()
            // Only a start that took is remembered (L9399-9402).
            if started, answer["running"].bool == true {
                _ = try await settings.writeSettingsAsync(.object([.init(Self.enabledKey, .bool(true))]))
            }
            return answer
        }))
        handlers.append(("remote:stop", { _, _ in
            await service.stop(); await memory.stopped()
            _ = try await settings.writeSettingsAsync(.object([.init(Self.enabledKey, .bool(false))]))
            return await status()
        }))
        handlers.append(("remote:pair", { _, _ in
            // The code and whether a phone can find it (L9470-9473).
            let shown = try await service.showPairingCode()
            return .object([.init("token", .string(shown.code.token)), .init("expiresAt", .number(shown.code.expiresAt)), .init("findable", .bool(shown.findable))])
        }))
        handlers.append(("remote:pair:cancel", { _, _ in
            await service.cancelPairing()
            return .object([.init("cancelled", .bool(true))])
        }))
        handlers.append(("remote:device:approve", { context, args in
            // L9527-9590: kind first, then the guest's folders and logins, and
            // the approval last; a malformed request approves nothing.
            let id = context.argument(0, in: args).string ?? ""
            guard !id.isEmpty, let kind = context.argument(1, in: args).string.flatMap(BackendRemoteDeviceKind.init(rawValue:)) else { return await devices() }
            _ = try await trust.compositionApprove(id, kind: kind, folders: context.argument(2, in: args).elements ?? [],
                accountMode: context.argument(3, in: args), accounts: context.argument(4, in: args).elements ?? [])
            return await devices()
        }))
        handlers.append(("remote:connection:disconnect", { context, args in
            if let raw = context.argument(0, in: args).string, let id = UUID(uuidString: raw) { _ = await dropConnection(id) }
            return .array(await endpoint.remoteServeConnectionRows())
        }))
        var registered: [String] = []
        do {
            for (channel, handler) in handlers {
                let write = Self.writes.contains(channel)
                try await registry.register(channel, ownerID: ownerID, policy: { context in
                    if write { try authority.authorizeMutation(context) } else { try authority.authorizeMetadata(context) }
                }, handler: handler)
                registered.append(channel)
            }
        } catch {
            for channel in registered { await registry.removeHandler(channel, ownerID: ownerID) }
            throw error
        }
        return registered
    }

    /// server.ts RemoteStatus (L1548-1571) from the native host status.
    /// `address` (the tailnet IP) is not something the native status carries,
    /// so it is null rather than guessed.
    static func wire(_ status: BackendRemoteHostStatus, memory: (failure: String?, cleared: Bool), port: Int,
                     connections: [NativeRPCValue]) -> NativeRPCValue {
        let direct = status.directURL != nil
        let relay: NativeRPCValue = status.relay.map { link in
            .object([.init("url", .string(link.url)), .init("hostId", .string(link.hostID)), .init("publicKey", .string(link.publicKey)),
                     .init("fingerprint", .string(link.fingerprint)), .init("connected", .bool(link.connected)),
                     .init("channels", .number(Double(link.channels))), .init("reason", link.reason.map(NativeRPCValue.string) ?? .null),
                     .init("retryAt", link.retryAt.map(NativeRPCValue.number) ?? .null)])
        } ?? .null
        // snapshot() L8307-8322: no reason while the direct path listens; else
        // what the relay says now; else the last failure.
        let reason: String? = direct ? nil : status.relay.map { $0.reason } ?? memory.failure
        let directReason: String? = memory.cleared ? nil : status.directReason ?? (status.running ? nil : memory.failure)
        return .object([.init("running", .bool(status.running)), .init("url", status.directURL.map(NativeRPCValue.string) ?? .null),
                        .init("address", .null), .init("port", .number(Double(port))),
                        .init("reason", reason.map(NativeRPCValue.string) ?? .null),
                        .init("directReason", directReason.map(NativeRPCValue.string) ?? .null),
                        .init("relay", relay), .init("connections", .array(connections))])
    }
}

/// The two facts server.ts keeps between calls: the last start failure (kept
/// across stop, as `reason` is) and that stop cleared the direct reason.
actor BackendCompositionRemoteChannelsMemory {
    private var failure: String?
    private var cleared = false
    func started(failure: String?) { self.failure = failure; cleared = false }
    func stopped() { cleared = true }
    func snapshot() -> (failure: String?, cleared: Bool) { (failure, cleared) }
}

extension BackendRemoteTrustStore {
    /// device-kind.ts list() (L172-178): every decided kind with when it was decided.
    func compositionKindRecords() -> [NativeRPCValue] {
        kinds.sorted { $0.value.decidedAt == $1.value.decidedAt ? $0.key < $1.key : $0.value.decidedAt < $1.value.decidedAt }.map {
            .object([.init("deviceId", .string($0.key)), .init("kind", .string($0.value.kind.rawValue)), .init("decidedAt", .number($0.value.decidedAt))])
        }
    }
    /// server.ts remote:device:approve, in one actor turn so no connection can
    /// be verified between the writes: an existing, unrevoked device; a kind
    /// that is refused (not overwritten) when a different one was decided; a
    /// guest's folders (an empty list is written) and logins ("all" or
    /// selected); a device of your own keeps neither; approval last.
    @discardableResult
    func compositionApprove(_ id: String, kind: BackendRemoteDeviceKind, folders: [NativeRPCValue],
                            accountMode: NativeRPCValue, accounts: [NativeRPCValue]) throws -> Bool {
        try requireOpen()
        guard devices.contains(where: { $0.id == id && !$0.revoked }) else { return false }
        if let decided = kinds[id], decided.kind != kind { return false }
        try claimKind(id, kind: kind)
        if kind == .guest {
            _ = try remoteServeSetFolderGrants(id, folders: folders)
            _ = try remoteServeSetAccountGrants(id, mode: .string(accountMode.string == "all" ? "all" : "selected"), accounts: accounts)
        } else {
            _ = try remoteServeForgetFolderGrants(id)
            _ = try remoteServeForgetAccountGrants(id)
        }
        return try approve(id, kind: kind)
    }
}
