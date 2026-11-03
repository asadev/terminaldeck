// Stage B resumed for managed agent survival; opt in with TD_HOST_ACCOUNT_BRIDGE.
#if TD_HOST_ACCOUNT_BRIDGE
import Foundation
import Darwin
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class HOSTAccountControlTests: XCTestCase, @unchecked Sendable {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TD_WIP"]?.contains("HOST") == true, "WIP HOST")
    }
    private struct Fixture: Sendable {
        let root: URL, composition: BackendCompositionRoot, authority: BackendCompositionAuthority
        let service: BackendHOSTAccountService, app: BackendHOSTAccountControlAuthority, control: BackendHOSTAccountControl
        let binding: HOSTAccountBinding, instance: UUID, executor: HOSTAccountProbeExecutor
    }
    private func fixture(gate: BackendCompositionCoreGate? = nil) async throws -> Fixture {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath().appendingPathComponent("tdh-acct-" + UUID().uuidString)
        let data = root.appendingPathComponent("data", isDirectory: true), home = root.appendingPathComponent("home", isDirectory: true)
        for folder in [data, home] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try NativeStateStore(file: data.appendingPathComponent("state.json"), ownership: .exclusive)
        let environment = ["HOME": home.path, "PATH": "/usr/bin:/bin", "USER": "owned-account-fixture"]
        let composition = try BackendCompositionRoot(dataRoot: data, state: store, environment: environment, home: home.path)
        let state = await BackendCompositionState.make(store: store, settings: composition.settings, dataRoot: data,
            registry: composition.registry, copilotRoot: { _ in root.appendingPathComponent("copilot").path })
        let configuration = try BackendAccountConfiguration(dataDirectory: data, homeDirectory: home, appName: "HOST Scratch Account Control", appID: "terminaldeck",
            helperExecutable: URL(fileURLWithPath: "/usr/bin/true"), inheritedEnvironment: composition.preparedSessions.environment)
        let contexts = BackendDeckCoreToolContextAuthority()
        let authority = try BackendCompositionAuthority(prepared: composition.preparedSessions, state: state, configuration: configuration,
            coreContexts: contexts, gate: gate ?? .init(authorize: { _, _, _, _, _, _ in throw BackendHOSTFailure.unavailable },
                record: { _, _, _, _ in throw BackendHOSTFailure.unavailable }), hidden: .init())
        addTeardownBlock { authority.close(); await state.stop(); try await composition.shutdown(); await store.close() }
        let service = try await BackendHOSTAccountService.start(configuration: configuration, nativeAccountOwnerDisabled: true,
            vaultCipher: HOSTAccountControlCipher(), brokerFactory: { config, profiles, vault in
                try await BackendAccountBroker.offline(configuration: config, profiles: profiles, vault: vault,
                    runner: { _, _ in .init(code: 46, stdout: "", stderr: "") })
            })
        addTeardownBlock { try await service.stop(afterProcessDrain: true) }
        let binding = HOSTAccountBinding(), instance = UUID(), executor = HOSTAccountProbeExecutor()
        let app = BackendHOSTAccountControlAuthority(hostInstance: instance, currentAttachment: { binding.current },
            authorizeRPC: { context, channel, args in try await authority.authorizeSessionRPC(context, channel: channel, arguments: args) },
            authorizeMetadata: { try authority.authorizeMetadata($0) }, authorizeMutation: { try authority.authorizeMutation($0) }, providers: composition.providers)
        let control = BackendHOSTAccountControl(service: service, hostInstance: instance, currentAttachment: { binding.current },
            authorize: { request in try await app.authorize(request: request, cancellation: .init()) },
            providerResolver: { request in try await app.resolveProvider(request: request, cancellation: .init()) }, executor: executor)
        addTeardownBlock { await control.stop(); app.close() }
        return .init(root: root, composition: composition, authority: authority, service: service, app: app, control: control,
            binding: binding, instance: instance, executor: executor)
    }
    private func invoke(_ fixture: Fixture, channel: String, args: [NativeRPCValue], context: NativeRPCContext? = nil) async throws -> NativeRPCValue {
        let request = try fixture.app.begin(channel: channel, arguments: args, context: context ?? fixture.authority.localContext())
        defer { fixture.app.complete(request.nonce) }
        return try NativeRPCValue.parseJSON(await fixture.control.invoke(payload: JSONEncoder().encode(request)))
    }
    private func refused(_ body: () async throws -> Void) async {
        do { try await body(); XCTFail("Absent or changed original authority must refuse the request.") } catch {}
    }
    func testActualOriginalUIContextControlsOriginalAccountRPCAndSafeReadViews() async throws {
        let fixture = try await fixture()
        let created = try await invoke(fixture, channel: "profiles:create", args: [.string("Owned scratch account")])
        let id = try XCTUnwrap(created["id"].string)
        let found = try await invoke(fixture, channel: "host.profiles.find", args: [.string(id)])
        XCTAssertEqual(found["id"].string, id); XCTAssertEqual(found["name"].string, "Owned scratch account")
        let snapshot = try await invoke(fixture, channel: "profiles:list", args: [])
        XCTAssertTrue(snapshot["profiles"].elements?.contains(where: { $0["id"].string == id }) == true)
        XCTAssertFalse(String(decoding: try snapshot.encodedJSON(), as: UTF8.self).contains("environment"))
        fixture.authority.revokeLocalUI()
        await refused { _ = try await self.invoke(fixture, channel: "profiles:rename", args: [.string(id), .string("Must not rename")]) }
        let profile = try await fixture.service.accounts.profiles.find(id); XCTAssertEqual(profile?.name, "Owned scratch account")
    }
    func testDefaultLoginReadCanResolveProviderOnlyWithItsOriginalApprovedCall() async throws {
        let fixture = try await fixture()
        for channel in ["host.profiles.resolve", "profiles:resolve", "profiles:effective"] {
            let request = try fixture.app.begin(channel: channel, arguments: [.object([.init("provider", .string("claude"))])], context: fixture.authority.localContext())
            let lookup = BackendHOSTAccountControlProviderRequest(operation: request, kind: .path)
            await refused { _ = try await fixture.app.resolveProvider(request: lookup, cancellation: .init()) }
            _ = try await fixture.app.authorize(request: request, cancellation: .init())
            let path = try await fixture.app.resolveProvider(request: lookup, cancellation: .init())
            XCTAssertNotNil(path.path)
            let wrongProvider = BackendHOSTAccountControlProviderRequest(operation: request, kind: .binary, provider: "codex", path: path.path, refresh: false)
            await refused { _ = try await fixture.app.resolveProvider(request: wrongProvider, cancellation: .init()) }
            fixture.app.complete(request.nonce)
            await refused { _ = try await fixture.app.resolveProvider(request: lookup, cancellation: .init()) }
        }
        let unrelated = try fixture.app.begin(channel: "profiles:list", arguments: [], context: fixture.authority.localContext())
        _ = try await fixture.app.authorize(request: unrelated, cancellation: .init())
        await refused { _ = try await fixture.app.resolveProvider(request: .init(operation: unrelated, kind: .path), cancellation: .init()) }
        fixture.app.complete(unrelated.nonce)
    }

    func testSameNonceConcurrentMutationExecutesOnlyOneOriginalCreate() async throws {
        let fixture = try await fixture()
        let request = try fixture.app.begin(channel: "profiles:create", arguments: [.string("Once only")], context: fixture.authority.localContext())
        defer { fixture.app.complete(request.nonce) }
        let payload = try JSONEncoder().encode(request)
        let results = try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<8 { group.addTask { try await fixture.control.invoke(payload: payload) } }
            var answers: [Data] = []; for try await value in group { answers.append(value) }; return answers
        }
        XCTAssertEqual(Set(results).count, 1)
        let profiles = try await fixture.service.accounts.profiles.list(); XCTAssertEqual(profiles.filter { $0.name == "Once only" }.count, 1)
    }
    func testWireCallerAndRequestArgumentsCannotReplaceOriginalRetainedContext() async throws {
        let fixture = try await fixture(), original = NativeRPCContext(caller: .page, ownerID: "unregistered-page", capabilities: ["files.write"])
        let request = try fixture.app.begin(channel: "profiles:create", arguments: [.string("Never create")], context: original)
        defer { fixture.app.complete(request.nonce) }
        await refused { _ = try await fixture.control.invoke(payload: JSONEncoder().encode(request)) }
        var wire = try NativeRPCValue.parseJSON(JSONEncoder().encode(request))
        wire = wire.setting("context", wire["context"].setting("caller", .string("nativeApp")).setting("ownerID", .string(BackendCompositionRoot.appOwnerID)))
        await refused { _ = try await fixture.control.invoke(payload: wire.encodedJSON()) }
        let profiles = try await fixture.service.accounts.profiles.list(); XCTAssertFalse(profiles.contains { $0.name == "Never create" })
    }
    func testAppDetachNewAttachmentAndCompletedNonceRefuse() async throws {
        let fixture = try await fixture()
        let request = try fixture.app.begin(channel: "profiles:list", arguments: [], context: fixture.authority.localContext())
        fixture.binding.set(nil)
        await refused { _ = try await fixture.control.invoke(payload: JSONEncoder().encode(request)) }
        fixture.binding.set(UUID())
        await refused { _ = try await fixture.control.invoke(payload: JSONEncoder().encode(request)) }
        fixture.app.complete(request.nonce)
        await refused { _ = try await fixture.app.authorize(request: request, cancellation: .init()) }
    }
    func testUnconfiguredHostFacadeCannotCreateOrProbe() async throws {
        let fixture = try await fixture(), control = BackendHOSTAccountControl(service: fixture.service, hostInstance: fixture.instance,
            currentAttachment: { fixture.binding.current }, executor: fixture.executor)
        addTeardownBlock { await control.stop() }
        let request = try fixture.app.begin(channel: "profiles:create", arguments: [.string("Unconfigured")], context: fixture.authority.localContext())
        defer { fixture.app.complete(request.nonce) }
        await refused { _ = try await control.invoke(payload: JSONEncoder().encode(request)) }
        XCTAssertEqual(fixture.executor.count, 0)
        let profiles = try await fixture.service.accounts.profiles.list(); XCTAssertFalse(profiles.contains { $0.name == "Unconfigured" })
    }
    func testMissingProviderResolverDoesNotProbeDefaultBinary() async throws {
        let fixture = try await fixture(), control = BackendHOSTAccountControl(service: fixture.service, hostInstance: fixture.instance,
            currentAttachment: { fixture.binding.current }, authorize: { try await fixture.app.authorize(request: $0, cancellation: .init()) }, executor: fixture.executor)
        addTeardownBlock { await control.stop() }
        let request = try fixture.app.begin(channel: "profiles:signin", arguments: [.string(BackendAccountProfile.systemID("claude"))], context: fixture.authority.localContext())
        defer { fixture.app.complete(request.nonce) }
        await refused { _ = try await control.invoke(payload: JSONEncoder().encode(request)) }
        XCTAssertEqual(fixture.executor.count, 0)
    }
    func testOriginalAppProviderActorSuppliesExactOwnedBinaryPATHToHelperProbe() async throws {
        let fixture = try await fixture(), bin = fixture.root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("claude")
        try Data("#!/bin/sh\nprintf 'scratch-claude-version\\n'\n".utf8).write(to: executable); XCTAssertEqual(chmod(executable.path, 0o700), 0)
        let providers = try BackendNativeProviders(store: fixture.composition.state, dataRoot: fixture.service.configuration.dataDirectory,
            inheritedEnvironment: fixture.service.configuration.inheritedEnvironment, home: fixture.service.configuration.homeDirectory.path,
            runner: BackendCommandRunner(), loginPath: { bin.path })
        let app = BackendHOSTAccountControlAuthority(hostInstance: fixture.instance, currentAttachment: { fixture.binding.current },
            authorizeRPC: { try await fixture.authority.authorizeSessionRPC($0, channel: $1, arguments: $2) },
            authorizeMetadata: { try fixture.authority.authorizeMetadata($0) }, authorizeMutation: { try fixture.authority.authorizeMutation($0) }, providers: providers)
        let control = BackendHOSTAccountControl(service: fixture.service, hostInstance: fixture.instance, currentAttachment: { fixture.binding.current },
            authorize: { try await app.authorize(request: $0, cancellation: .init()) }, providerResolver: { try await app.resolveProvider(request: $0, cancellation: .init()) }, executor: fixture.executor)
        addTeardownBlock { await control.stop(); app.close() }
        let request = try app.begin(channel: "profiles:signin", arguments: [.string(BackendAccountProfile.systemID("claude")), .object([.init("refresh", .bool(true))])], context: fixture.authority.localContext())
        defer { app.complete(request.nonce) }
        let value = try NativeRPCValue.parseJSON(await control.invoke(payload: JSONEncoder().encode(request)))
        XCTAssertEqual(value["state"].string, "signed-in")
        XCTAssertEqual(fixture.executor.command, executable.path); XCTAssertEqual(fixture.executor.environment?["PATH"], bin.path)
        XCTAssertEqual(fixture.executor.count, 1)
    }
    func testCancellationDuringAuthorizationPreventsMutation() async throws {
        let fixture = try await fixture(), gate = HOSTAccountControlGate(), entered = expectation(description: "authorize entered")
        let control = BackendHOSTAccountControl(service: fixture.service, hostInstance: fixture.instance, currentAttachment: { fixture.binding.current },
            authorize: { request in entered.fulfill(); await gate.wait(); return try await fixture.app.authorize(request: request, cancellation: .init()) }, executor: fixture.executor)
        addTeardownBlock { await control.stop() }
        let request = try fixture.app.begin(channel: "profiles:create", arguments: [.string("Cancelled")], context: fixture.authority.localContext())
        defer { fixture.app.complete(request.nonce) }
        let operation = Task { try await control.invoke(payload: JSONEncoder().encode(request)) }
        await fulfillment(of: [entered], timeout: 5); operation.cancel(); await gate.release()
        await refused { _ = try await operation.value }
        let profiles = try await fixture.service.accounts.profiles.list(); XCTAssertFalse(profiles.contains { $0.name == "Cancelled" })
    }
    func testOriginalCredentialResolvedCoreTicketNeedsAcceptedMutationReceiptAndExpiresWithCall() async throws {
        let gate = BackendCompositionCoreGate(authorize: { context, tool, args, tier, _, _ in
            guard context.caller.kind == .key, context.caller.keyID == "owned-scratch-key", tool == "accounts.create", tier == .alter,
                  args["name"].string == "From original ticket" else { throw BackendHOSTFailure.authentication }
        }, record: { _, _, _, _ in throw BackendHOSTFailure.unavailable })
        let fixture = try await fixture(gate: gate), saved = HOSTAccountRequestBox()
        let native = BackendMCPCallContext(sessionID: "owned-scratch-session", machineID: "scratch-machine", projectRoot: nil, attended: true,
            allowedTools: ["accounts.create"], allowedTiers: [.read, .alter], cancellation: .init())
        let core = BackendDeckCoreSecurityCallContext(native: native,
            caller: .init(kind: .key, tiers: [.read, .alter], keyID: "owned-scratch-key"), callID: UUID().uuidString,
            attended: true, granted: ["accounts.create"], sessionLimits: .object([]), now: { Date().timeIntervalSince1970 * 1000 },
            startedByCopilot: { _ in false }, noteStarted: { _ in })
        let reply = try await fixture.authority.coreContexts.invoke(handler: { native, _ in
            let context = try await fixture.authority.rpc(native)
            XCTAssertEqual(context.caller, .page)
            let request = try fixture.app.begin(channel: "profiles:create", arguments: [.string("From original ticket")], context: context)
            saved.put(request)
            await self.refused { _ = try await fixture.control.invoke(payload: JSONEncoder().encode(request)) }
            try await fixture.authority.authorize(native, tool: "accounts.create", arguments: .object([.init("name", .string("From original ticket"))]),
                tier: .alter, sentence: "Create only the owned scratch account")
            let bytes = try await fixture.control.invoke(payload: JSONEncoder().encode(request))
            return .value(try NativeRPCValue.parseJSON(bytes))
        }, arguments: .object([]), context: core)
        XCTAssertEqual(reply.structuredContent?["name"].string, "From original ticket")
        let request = try XCTUnwrap(saved.get())
        // The actual core invocation cancelled its scoped native capability.
        // Faithful wire fields and the helper's prior result confer no authority.
        await refused { _ = try await fixture.control.invoke(payload: JSONEncoder().encode(request)) }
        fixture.app.complete(request.nonce)
    }
    /// ACCOUNTS-SPEC (11 Oct, FORK-L1): the whole app, a project and a seat are set and read through
    /// the helper's own control path, which is how the dev copy and the released app run. A change
    /// must be accepted there as a change, and no answer may carry a login.
    func testAccountLevelsAreSetAndReadThroughTheHelperAndNoAnswerCarriesALogin() async throws {
        let fixture = try await fixture()
        func create(_ name: String) async throws -> String {
            let made = try await invoke(fixture, channel: "profiles:create", args: [.string(name)])
            return try XCTUnwrap(made["id"].string)
        }
        let work = try await create("Work"), side = try await create("Side")
        let folder = fixture.root.appendingPathComponent("home/project").path
        let appLevel = NativeRPCValue.object([.init("kind", .string("app"))])
        let projectLevel = NativeRPCValue.object([.init("kind", .string("project")), .init("path", .string(folder))])
        let seatLevel = NativeRPCValue.object([.init("kind", .string("seat")), .init("key", .string("lead:demo"))])
        func set(_ level: NativeRPCValue, _ account: String?) async throws {
            _ = try await invoke(fixture, channel: "profiles:set-level", args: [level, .string("claude"), account.map(NativeRPCValue.string) ?? .null])
        }
        func effective(_ fields: [NativeRPCValue.Field] = []) async throws -> NativeRPCValue {
            var input: [NativeRPCValue.Field] = [.init("provider", .string("claude"))]
            input += fields
            return try await invoke(fixture, channel: "profiles:effective", args: [.object(input)])
        }
        try await set(appLevel, work); try await set(projectLevel, side); try await set(seatLevel, work)
        let levels = try await invoke(fixture, channel: "profiles:levels", args: [])
        XCTAssertEqual(levels["app"]["claude"].string, work)
        XCTAssertEqual(levels["seats"]["lead:demo"]["claude"].string, work)
        let app = try await effective()
        XCTAssertEqual(app["accountId"].string, work); XCTAssertEqual(app["source"].string, "app")
        let project = try await effective([.init("projectPath", .string(folder + "/src"))])
        XCTAssertEqual(project["accountId"].string, side); XCTAssertEqual(project["source"].string, "project")
        let seat = try await effective([.init("projectPath", .string(folder)), .init("seat", .string("lead:demo"))])
        XCTAssertEqual(seat["accountId"].string, work); XCTAssertEqual(seat["source"].string, "seat")
        let session = try await effective([.init("projectPath", .string(folder)), .init("seat", .string("lead:demo")), .init("sessionProfileId", .string(side))])
        XCTAssertEqual(session["accountId"].string, side); XCTAssertEqual(session["source"].string, "session")
        // "Same as above" on the project and the seat: both follow the whole-app choice again.
        try await set(projectLevel, nil); try await set(seatLevel, nil)
        let cleared = try await effective([.init("projectPath", .string(folder)), .init("seat", .string("lead:demo"))])
        XCTAssertEqual(cleared["accountId"].string, work); XCTAssertEqual(cleared["source"].string, "app")
        // A step of a sign-in the app runs is a change too; with none running it only answers.
        let cancelled = try await invoke(fixture, channel: "profiles:signin-cancel", args: [.string("none")])
        XCTAssertEqual(cancelled["state"].string, "cancelled")
        // The model list: once the app keeps a login, one that has run out is a plain failure (never
        // this Mac's own login, and no request is sent), and the stored login is in no answer.
        let marker = "scratch-not-a-login-" + UUID().uuidString
        _ = try await fixture.service.accounts.vault.put(accountID: work, provider: "claude", slot: BackendAccountSwitchInPlace.loginSlot,
            value: #"{"claudeAiOauth":{"accessToken":""# + marker + #"","expiresAt":1}}"#, source: "sign-in")
        let models = try await invoke(fixture, channel: "profiles:claude-models", args: [.object([.init("seat", .string("orchestrator"))])])
        XCTAssertEqual(models["source"].string, "app"); XCTAssertNotNil(models["failure"].string); XCTAssertNil(models["body"].string)
        let listed = try await invoke(fixture, channel: "profiles:list", args: [])
        for answer in [levels, app, project, seat, session, cleared, models, listed] {
            XCTAssertFalse(String(decoding: try answer.encodedJSON(), as: UTF8.self).contains(marker))
        }
        // The app never runs an AI's sign-in on this Mac's own login (11 Oct): refused in plain words, before any command.
        let commandsBefore = fixture.executor.count
        do {
            _ = try await invoke(fixture, channel: "profiles:signin-start", args: [.string(BackendAccountProfile.systemID("claude"))])
            XCTFail("A sign-in on this Mac's own login must be refused.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Mac’s own"), error.localizedDescription) }
        XCTAssertEqual(fixture.executor.count, commandsBefore, "no command was run for it")
        // Without the owner's local authority nothing can be set.
        fixture.authority.revokeLocalUI()
        await refused { try await set(appLevel, side) }
        let kept = try await fixture.service.accounts.profiles.snapshot().levels.app["claude"]; XCTAssertEqual(kept, work)
    }
}
private final class HOSTAccountBinding: @unchecked Sendable {
    private let lock = NSLock(); private var value: UUID? = UUID()
    var current: UUID? { lock.withLock { value } }
    func set(_ value: UUID?) { lock.withLock { self.value = value } }
}
private final class HOSTAccountRequestBox: @unchecked Sendable {
    private let lock = NSLock(); private var value: BackendHOSTAccountControlRequest?
    func put(_ value: BackendHOSTAccountControlRequest) { lock.withLock { self.value = value } }
    func get() -> BackendHOSTAccountControlRequest? { lock.withLock { value } }
}
private final class HOSTAccountProbeExecutor: BackendAppSessionCommandExecuting, @unchecked Sendable {
    private let lock = NSLock(); private var calls: [(String, [String: String])] = []
    var count: Int { lock.withLock { calls.count } }
    var command: String? { lock.withLock { calls.last?.0 } }
    var environment: [String: String]? { lock.withLock { calls.last?.1 } }
    func run(_ command: String, arguments: [String], environment: [String: String], cwd: String, timeoutMilliseconds: Int, maximumBytes: Int) async -> BackendAppSessionCommandResult {
        lock.withLock { calls.append((command, environment)) }
        return .init(stdout: "{\"loggedIn\":true,\"email\":\"scratch@example.invalid\"}", exitCode: 0)
    }
    func detach(_ command: String, arguments: [String], environment: [String: String], cwd: String) async throws { throw BackendHOSTFailure.unavailable }
}
private actor HOSTAccountControlGate {
    private var open = false, waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if open { return }; await withCheckedContinuation { waiters.append($0) } }
    func release() { open = true; let pending = waiters; waiters.removeAll(); for waiter in pending { waiter.resume() } }
}
private struct HOSTAccountControlCipher: BackendAccountVaultCipher {
    private static let prefix = Data("HOST-account-control-fixture:".utf8)
    func available() -> Bool { true }
    func prepareForWrites(existingVault: Bool) throws {}
    func encrypt(_ text: String, existingVault: Bool) throws -> Data { Self.prefix + Data(Data(text.utf8).reversed()) }
    func decrypt(_ data: Data) throws -> String {
        guard data.starts(with: Self.prefix) else { throw BackendAccountFailure("Invalid scratch ciphertext.") }
        return String(decoding: Data(data.dropFirst(Self.prefix.count).reversed()), as: UTF8.self)
    }
}

#endif
