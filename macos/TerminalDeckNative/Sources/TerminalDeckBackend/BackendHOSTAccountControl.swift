// Stage B resumed for managed agent survival; opt in with TD_HOST_ACCOUNT_BRIDGE.
#if TD_HOST_ACCOUNT_BRIDGE
import Foundation
import TerminalDeckNativeCore

/// Helper facade over the ORIGINAL account RPC/sign-in bodies. It has no
/// permissive authorizer and owns no additional profile/vault/state writer.
public actor BackendHOSTAccountControl {
    public typealias Authorize = @Sendable (BackendHOSTAccountControlRequest) async throws -> BackendHOSTAccountControlApproval
    public typealias ProviderResolver = @Sendable (BackendHOSTAccountControlProviderRequest) async throws -> BackendHOSTAccountControlProviderAnswer
    private let service: BackendHOSTAccountService
    private let hostInstance: UUID
    private let currentAttachment: @Sendable () -> UUID?
    private let authorize: Authorize?
    private let rpc: BackendAccountRPC
    private let signIn: BackendAppAccountSignInService
    private let usageProvider: BackendHOSTAccountSignInDependencies
    private var hookRPC: BackendSessionHookRPC?
    private struct Call: Sendable {
        let request: BackendHOSTAccountControlRequest, receipt: BackendHOSTAccountReceipt, operation: Task<Data, Error>
        var finished = false
    }
    private var calls: [UUID: Call] = [:]
    private var stopped = false
    public init(service: BackendHOSTAccountService, hostInstance: UUID,
                currentAttachment: @escaping @Sendable () -> UUID?, authorize: Authorize? = nil,
                providerResolver: ProviderResolver? = nil, sessionTitle: @escaping @Sendable (String) async -> String? = { _ in nil },
                executor: any BackendAppSessionCommandExecuting = BackendAppSessionCommandExecutor(),
                clock: any BackendAppSessionClock = BackendAppSessionSystemClock()) {
        self.service = service; self.hostInstance = hostInstance; self.currentAttachment = currentAttachment; self.authorize = authorize
        rpc = BackendAccountRPC(accounts: service.accounts, configuration: service.configuration,
            authorizeMutation: { context in try BackendHOSTAccountScope.require(context, mutation: true) }, sessionTitle: sessionTitle)
        let dependencies = BackendHOSTAccountSignInDependencies(accounts: service.accounts, configuration: service.configuration,
            currentAttachment: currentAttachment, providerResolver: providerResolver)
        usageProvider = dependencies
        signIn = BackendAppAccountSignInService(dependencies: dependencies, executor: executor, clock: clock,
            authorizeMetadata: { context in try BackendHOSTAccountScope.require(context, mutation: false) },
            authorizeMutation: { context in try BackendHOSTAccountScope.require(context, mutation: true) })
        // The keeper's own launches refuse a signed-out Claude login the same way (BackendAccountLaunchAdapter).
        let reader = signIn, launches = service.accounts
        Task {
            await launches.setSignInCheck(identity: { profile in await reader.read(profile, refresh: false).account }) {
                profile, fresh in await reader.read(profile, refresh: fresh).state
            }
        }
    }
    public func installHookRPC(_ rpc: BackendSessionHookRPC) throws {
        guard !stopped else { throw BackendHOSTFailure.unavailable }
        if let hookRPC { guard hookRPC === rpc else { throw BackendHOSTFailure.authentication }; return }
        hookRPC = rpc
    }
    public nonisolated static func authorizeHookMutation(_ context: NativeRPCContext) throws {
        try BackendHOSTAccountScope.require(context, mutation: true)
    }
    public func cancel(nonce: UUID) { calls[nonce]?.receipt.cancel(); calls[nonce]?.operation.cancel() }
    public func invoke(payload: Data) async throws -> Data {
        guard !stopped else { throw BackendHOSTFailure.remote("The session host's account service has stopped.") }
        guard let authorize else { throw BackendHOSTFailure.remote("The session host has no app connection to approve account requests.") }
        let request = try JSONDecoder().decode(BackendHOSTAccountControlRequest.self, from: payload)
        // L8 (11 Oct): a newer app asking an older running host for something it does not know is not a failed
        // authentication. Say what it is, so the app (and the person) can tell and fall back.
        guard BackendHOSTAccountControlRequest.channels.contains(request.channel) else {
            throw BackendHOSTUnknownChannel("This session host is from an older build and does not know \"\(request.channel)\". Choose a login in New session, or use Add account in Settings › Coding AIs.")
        }
        guard request.hostInstance == hostInstance,
              request.attachment == currentAttachment(), Date().timeIntervalSince(request.issuedAt) >= -5,
              Date().timeIntervalSince(request.issuedAt) < 60 else { throw BackendHOSTFailure.authentication }
        _ = try request.arguments(); try Task.checkCancellation()
        let approval = try await authorize(request)
        guard !stopped, approval.validates(request), request.attachment == currentAttachment() else { throw BackendHOSTFailure.authentication }
        try Task.checkCancellation()
        if let existing = calls[request.nonce] {
            guard existing.request == request else { throw BackendHOSTFailure.authentication }
            return try await result(existing)
        }
        // Bound both completed receipt memory and active work. Do not evict an
        // active operation and allow its nonce to perform a second mutation.
        // L8 (10 Oct): prune EVERY finished receipt past its 60 s replay window, not only a run at the head of
        // an arrival list (one slow call there pinned all later ones), and cap ACTIVE work rather than remembered
        // receipts. Busy apps make hundreds of profile reads a minute; at 512 remembered receipts every
        // later read was refused as "the session host is unavailable" (Asad's sessions_wait, task launches).
        let now = Date()
        for (nonce, value) in calls where value.finished && now.timeIntervalSince(value.request.issuedAt) >= 60 { calls[nonce] = nil }
        let active = calls.values.reduce(0) { $0 + ($1.finished ? 0 : 1) }
        guard active < 512, calls.count < 16_384 else {
            throw BackendHOSTFailure.remote("The session host is busy with \(active) account requests at once. Try again in a moment.")
        }
        let receipt = BackendHOSTAccountReceipt(request: request, currentAttachment: currentAttachment)
        let operation = Task<Data, Error> {
            try await BackendHOSTAccountScope.$receipt.withValue(receipt) {
                try receipt.claimOnce()
                return try await self.perform(request)
            }
        }
        let call = Call(request: request, receipt: receipt, operation: operation)
        calls[request.nonce] = call
        do { let value = try await result(call); calls[request.nonce]?.finished = true; return value }
        catch { calls[request.nonce]?.finished = true; throw error }
    }
    private func result(_ call: Call) async throws -> Data {
        let value = try await withTaskCancellationHandler {
            try await call.operation.value
        } onCancel: { call.receipt.cancel(); call.operation.cancel() }
        guard !stopped else { throw BackendHOSTFailure.unavailable }
        try call.receipt.requireCurrent(); try call.receipt.throwProviderFailure(); try Task.checkCancellation()
        return value
    }
    private func perform(_ request: BackendHOSTAccountControlRequest) async throws -> Data {
        guard !stopped, let receipt = BackendHOSTAccountScope.receipt, receipt.request == request else { throw BackendHOSTFailure.authentication }
        try receipt.requireCurrent()
        // Transport only after the ORIGINAL app context was reauthorized. The
        // facade callbacks still require this exact one-use TaskLocal receipt;
        // copied nativeApp fields alone cannot grant even one operation.
        let context = try request.context.transported(), arguments = try request.arguments()
        let value: NativeRPCValue
        if BackendAccountRPC.channels.contains(request.channel) {
            try BackendHOSTAccountScope.require(context, mutation: request.mutation)
            value = try await rpc.invoke(request.channel, args: arguments, context: context)
        } else if BackendAppAccountSignInService.channels.contains(request.channel) {
            value = try await signIn.invoke(request.channel, args: arguments, context: context)
        } else if BackendSessionHookRPC.channels.contains(request.channel) {
            try BackendHOSTAccountScope.require(context, mutation: request.mutation)
            guard let hookRPC else { throw BackendHOSTFailure.unavailable }
            value = try await hookRPC.invoke(request.channel, args: arguments, context: context)
        } else if request.channel == "host.usage.probe" {
            try BackendHOSTAccountScope.require(context, mutation: false)
            guard let input = arguments.first, input["provider"].string == "claude", let id = input["id"].string,
                  let profile = try await service.accounts.profiles.find(id), profile.provider == "claude",
                  let requested = input["configDir"].string,
                  NativeTranscriptPaths.canonical(requested) == NativeTranscriptPaths.canonical(profile.configDir) else {
                throw BackendHOSTFailure.authentication
            }
            let account = BackendUsageAccount(provider: profile.provider, id: profile.id, name: profile.name, configDirectory: profile.configDir)
            let probe = BackendUsageProbe(accounts: service.accounts, providers: usageProvider)
            let result = await probe.run(account: account, cancellation: receipt.cancellation)
            value = .object([.init("kind", .string(result.kind)), .init("detail", .string(result.detail)),
                .init("readings", .array(result.readings.map(\.wireValue))), .init("spawned", .bool(result.spawned)),
                .init("elapsedMilliseconds", .number(result.elapsedMilliseconds))])
        } else {
            try BackendHOSTAccountScope.require(context, mutation: false)
            let profiles = await service.accounts.profiles
            func arg(_ index: Int) -> NativeRPCValue { arguments.indices.contains(index) ? arguments[index] : .missing }
            switch request.channel {
            case "host.profiles.find": value = try await profiles.find(arg(0).requireString("account id", nonempty: true)).map(encoded) ?? .null
            case "host.profiles.list": value = .array(try await profiles.list(provider: arg(0).string).map(encoded))
            case "host.profiles.snapshot": value = try encoded(BackendHOSTAccountControlProfiles(await profiles.snapshot()))
            case "host.profiles.resolve":
                let overrides = Dictionary(uniqueKeysWithValues: (arg(0)["environmentOverrides"].fields ?? []).compactMap { field in
                    field.value.string.map { (field.key, $0) }
                })
                value = try await BackendDefaultClaudeLogin.$environmentOverrides.withValue(overrides) {
                    try encoded(await profiles.resolve(sessionProfileID: arg(0)["sessionProfileId"].string,
                        projectPath: arg(0)["projectPath"].string, provider: arg(0)["provider"].string))
                }
            case "host.profiles.managed":
                guard let profile = try await profiles.find(arg(0).requireString("account id", nonempty: true)) else { throw BackendAccountFailure("That account no longer exists.") }
                value = .bool(await profiles.managed(profile))
            default: throw BackendHOSTFailure.invalid("Unknown private account read view.")
            }
        }
        try receipt.requireCurrent(); try receipt.throwProviderFailure(); try Task.checkCancellation()
        return try value.encodedJSON()
    }
    private func encoded<T: Encodable>(_ value: T) throws -> NativeRPCValue { try NativeRPCValue.parseJSON(JSONEncoder().encode(value)) }
    public func stop() async {
        stopped = true
        let active = Array(calls.values); calls.removeAll()
        for call in active { call.receipt.cancel(); call.operation.cancel() }
        for call in active { _ = try? await call.operation.value }
        await signIn.resetCache()
        // Account/broker shutdown belongs to Resources AFTER process drain.
    }
}

private enum BackendHOSTAccountScope {
    @TaskLocal static var receipt: BackendHOSTAccountReceipt?
    static func require(_ context: NativeRPCContext, mutation: Bool) throws {
        guard let receipt, receipt.request.context == BackendHOSTAccountControlContext(context),
              !mutation || receipt.request.mutation else { throw BackendHOSTFailure.authentication }
        try receipt.requireCurrent()
    }
}
private final class BackendHOSTAccountReceipt: @unchecked Sendable {
    let request: BackendHOSTAccountControlRequest
    let cancellation = BackendMCPCancellation()
    private let currentAttachment: @Sendable () -> UUID?
    private let lock = NSLock()
    private var consumed = false, cancelled = false
    private var providerFailure: NativeRPCError?
    init(request: BackendHOSTAccountControlRequest, currentAttachment: @escaping @Sendable () -> UUID?) {
        self.request = request; self.currentAttachment = currentAttachment
    }
    func claimOnce() throws {
        try lock.withLock { guard !consumed, !cancelled else { throw BackendHOSTFailure.authentication }; consumed = true }
        try requireCurrent()
    }
    func requireCurrent() throws {
        guard !Task.isCancelled, currentAttachment() == request.attachment,
              lock.withLock({ consumed && !cancelled }) else { throw BackendHOSTFailure.authentication }
    }
    func cancel() { lock.withLock { cancelled = true }; cancellation.cancel() }
    func noteProviderFailure(_ error: Error) { lock.withLock { providerFailure = NativeRPCError.wrapping(error) } }
    func throwProviderFailure() throws { if let error = lock.withLock({ providerFailure }) { throw error } }
}

/// The same actual account actors as NativeDependencies, with only provider
/// discovery routed to the original app actor. No helper aux-store defaults.
private struct BackendHOSTAccountSignInDependencies: BackendAppAccountSignInDependencies {
    let accounts: BackendAccountLaunchAdapter
    let configuration: BackendAccountConfiguration
    let currentAttachment: @Sendable () -> UUID?
    let providerResolver: BackendHOSTAccountControl.ProviderResolver?
    private func current() throws -> BackendHOSTAccountReceipt {
        guard let receipt = BackendHOSTAccountScope.receipt else { throw BackendHOSTFailure.authentication }
        try receipt.requireCurrent(); return receipt
    }
    func find(_ id: String) async throws -> BackendAccountProfile? {
        let receipt = try current(), value = try await accounts.profiles.find(id); try receipt.requireCurrent(); return value
    }
    func managed(_ profile: BackendAccountProfile) async -> Bool { await accounts.profiles.managed(profile) }
    func summaries() async throws -> [BackendAccountVaultSummary] {
        let receipt = try current(), value = try await accounts.vault.summaries(); try receipt.requireCurrent(); return value
    }
    func vaultUsable() async -> Bool { await accounts.vault.openState() == .ready }
    func loginPath() async throws -> String {
        do {
            let receipt = try current(); guard let providerResolver else { throw BackendHOSTFailure.unavailable }
            let answer = try await providerResolver(.init(operation: receipt.request, kind: .path))
            try receipt.requireCurrent()
            guard let path = answer.path, !path.contains("\0") else { throw BackendHOSTFailure.authentication }
            return path
        } catch { BackendHOSTAccountScope.receipt?.noteProviderFailure(error); throw error }
    }
    func binary(_ provider: String, path: String, refresh: Bool) async -> BackendNativeProviders.Binary {
        do {
            let receipt = try current(); guard let providerResolver else { throw BackendHOSTFailure.unavailable }
            let answer = try await providerResolver(.init(operation: receipt.request, kind: .binary, provider: provider, path: path, refresh: refresh))
            try receipt.requireCurrent()
            guard let binary = answer.binary, binary.id == provider,
                  binary.runnable.map({ $0.hasPrefix("/") && !$0.contains("\0") }) ?? true else { throw BackendHOSTFailure.authentication }
            return binary.original()
        } catch {
            BackendHOSTAccountScope.receipt?.noteProviderFailure(error)
            // The original dependency API cannot throw here. The outer helper
            // invocation throws this recorded failure; no fallback is served.
            return .init(id: provider, onPath: nil, runnable: nil, version: nil, broken: true,
                said: "The original provider resolver is unavailable.", usedAlternate: false, checkedAt: Date())
        }
    }
    func recheck(_ profile: BackendAccountProfile) async throws {
        let receipt = try current(); await accounts.codex.capture(profile); try receipt.requireCurrent()
    }
    func readJSON(_ file: URL) -> NativeRPCValue {
        guard (try? current()) != nil, let data = try? Data(contentsOf: file), let value = try? NativeRPCValue.parseJSON(data) else { return .null }; return value
    }
    func nonEmptyFile(_ file: URL) -> Bool {
        guard (try? current()) != nil else { return false }
        return (((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.int64Value ?? 0) > 0
    }
    func probeEnvironment(_ profile: BackendAccountProfile, provider: String, path: String) async throws -> [String: String] {
        let receipt = try current()
        var overrides: [String: String] = [:], shim: String?
        if !profile.system, provider == profile.provider, provider == "claude", await accounts.profiles.managed(profile) {
            let broker = await accounts.broker
            overrides = try await broker.allocateAccount(profile).environment; shim = broker.shimDirectory
        } else if !profile.system, provider == profile.provider, provider == "codex", await accounts.profiles.managed(profile) {
            try await accounts.codex.settle(profile)
        }
        try receipt.requireCurrent()
        return BackendAppAccountSignInParsing.accountEnvironment(profile, provider: provider, inherited: configuration.inheritedEnvironment,
            path: path, vaultVariables: configuration.vaultVariables, overrides: overrides, shimDirectory: shim)
    }
}
extension BackendHOSTAccountSignInDependencies: BackendHOSTUsageProvider {
    func resolveBinary(_ id: String, path: String, refresh: Bool) async -> BackendNativeProviders.Binary {
        await binary(id, path: path, refresh: refresh)
    }
}

#endif
