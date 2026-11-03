import CryptoKit
import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

@Suite("Apps GitHub push verification and approval-gated server receipts")
struct BackendAppsAutoDeployTests {
    private let context = NativeRPCContext(caller: .nativeApp, ownerID: "push-owner")

    @Test func verifiesOfficialGitHubHMACVectorWithCryptoKit() {
        let signature = "sha256=757107ea0eb2509fc211221cce984b8a37570b6d7586c22c46f4379c8b043e17"
        #expect(BackendAppsPushVerifier.validSignature(body: Data("Hello, World!".utf8), secret: Data("It's a Secret to Everybody".utf8), signature: signature))
        #expect(!BackendAppsPushVerifier.validSignature(body: Data("Hello, World?".utf8), secret: Data("It's a Secret to Everybody".utf8), signature: signature))
    }

    @Test func rawBytesAreVerifiedBeforeTypedPayloadAndOnlyConfiguredBranchPasses() throws {
        let body = BackendAppsPushFake.body()
        let target = try BackendAppsPushTarget(repository: "owner/site", branch: "main")
        let push = try BackendAppsPushVerifier.verify(headers: BackendAppsPushFake.headers(body), body: body, secret: BackendAppsPushFake.secret, target: target)
        #expect(push.repository == "owner/site")
        #expect(push.repositoryID == 12)
        #expect(push.ref == "refs/heads/main")
        #expect(push.revision == String(repeating: "a", count: 40))
        #expect(push.senderID == 34 && push.senderLogin == "github-actions[bot]")
        #expect(push.preview["secret"].isNullish)
        let formatted = Data((String(data: body, encoding: .utf8)! + "\n").utf8)
        #expect(throws: NativeRPCError.self) { _ = try BackendAppsPushVerifier.verify(headers: BackendAppsPushFake.headers(body), body: formatted, secret: BackendAppsPushFake.secret, target: target) }
    }

    @Test func signedWrongRepositoryTagsOtherBranchesDeletesAndZeroRevisionsAreRejected() throws {
        let target = try BackendAppsPushTarget(repository: "owner/site", branch: "main")
        let bodies = [
            BackendAppsPushFake.body(repository: "other/site"), BackendAppsPushFake.body(ref: "refs/heads/other"),
            BackendAppsPushFake.body(ref: "refs/tags/main"), BackendAppsPushFake.body(deleted: true),
            BackendAppsPushFake.body(revision: String(repeating: "0", count: 40)), BackendAppsPushFake.body(revision: "main")
        ]
        for body in bodies {
            #expect(throws: NativeRPCError.self) { _ = try BackendAppsPushVerifier.verify(headers: BackendAppsPushFake.headers(body), body: body, secret: BackendAppsPushFake.secret, target: target) }
        }
    }

    @Test func typedSenderAndRepositoryRejectWrongTypesMissingFieldsAndNonpositiveIDs() throws {
        let target = try BackendAppsPushTarget(repository: "owner/site", branch: "main")
        let base = try NativeRPCValue.parseJSON(BackendAppsPushFake.body())
        let payloads = [
            base.setting("sender", .string("trusted")), base.removing("sender"),
            base.setting("sender", BackendAppsValidation.object([("id", .number(0)), ("login", .string("owner"))])),
            base.setting("sender", BackendAppsValidation.object([("id", .number(34)), ("login", .string("bad\nname"))])),
            base.setting("repository", BackendAppsValidation.object([("id", .number(-1)), ("full_name", .string("owner/site"))]))
        ]
        for value in payloads {
            let body = try value.encodedJSON()
            #expect(throws: NativeRPCError.self) { _ = try BackendAppsPushVerifier.verify(headers: BackendAppsPushFake.headers(body), body: body, secret: BackendAppsPushFake.secret, target: target) }
        }
    }

    @Test func requiredHeadersAreUniqueCaseInsensitiveAndBounded() throws {
        let body = BackendAppsPushFake.body(), valid = BackendAppsPushFake.headers(body)
        let target = try BackendAppsPushTarget(repository: "owner/site", branch: "main")
        let uppercase = valid.map { BackendAppsPushHeader($0.name.uppercased(), $0.value) }
        #expect(try BackendAppsPushVerifier.verify(headers: uppercase, body: body, secret: BackendAppsPushFake.secret, target: target).ref == "refs/heads/main")
        for bad in [
            valid + [.init("X-GITHUB-EVENT", "push")],
            valid.map { $0.name == "X-GitHub-Event" ? .init($0.name, "pull_request") : $0 },
            valid.map { $0.name == "X-GitHub-Delivery" ? .init($0.name, "not-a-uuid") : $0 },
            valid.map { $0.name == "X-GitHub-Delivery" ? .init($0.name, "00000000-0000-0000-0000-000000000000") : $0 },
            valid.map { $0.name == "X-Hub-Signature-256" ? .init($0.name, "sha1=" + String(repeating: "a", count: 40)) : $0 },
            valid + [.init("extra", "value\r\nX-GitHub-Event: push")],
            valid.filter { $0.name != "Content-Type" }
        ] {
            #expect(throws: NativeRPCError.self) { _ = try BackendAppsPushVerifier.verify(headers: bad, body: body, secret: BackendAppsPushFake.secret, target: target) }
        }
    }

    @Test func CRLFBindingHeaderIsRejectedBeforeIngressOrServerIO() async throws {
        let fake = BackendAppsPushFake()
        let service = BackendAppsAutoDeploy(runtime: await fake.runtime(), trustedIngress: await fake.ingress())
        let body = BackendAppsPushFake.body()
        // CRLF is one Swift Character, but two forbidden Unicode scalars.
        // Keep every required header and HMAC valid so rejection must come
        // from the injected header's control bytes, rather than another check.
        let headers = BackendAppsPushFake.headers(body) + [BackendAppsPushHeader("X-TerminalDeck-Binding", "site\r\nX-GitHub-Event: push")]
        let expected = NativeRPCError(code: "access-denied", message: "This GitHub delivery could not be verified for the selected app and branch.")
        await #expect(throws: expected) {
            _ = try await service.receive(serverID: "one", appID: "site", headers: headers, body: body, context: context)
        }
        let state = await fake.snapshot()
        #expect(state.events.isEmpty)
        #expect(state.commands.isEmpty && state.dispatched.isEmpty && state.ledger == nil)
    }

    @Test func oversizedDeepAndDuplicateKeyBodiesAreRejected() throws {
        let target = try BackendAppsPushTarget(repository: "owner/site", branch: "main")
        let oversized = Data(repeating: 32, count: BackendAppsPushVerifier.maximumBodyBytes + 1)
        #expect(throws: NativeRPCError.self) { try BackendAppsPushVerifier.preflight(headers: BackendAppsPushFake.headers(BackendAppsPushFake.body()), body: oversized) }
        let duplicate = Data(#"{"ref":"refs/heads/main","ref":"refs/heads/main","after":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","deleted":false,"repository":{"id":12,"full_name":"owner/site"},"sender":{"id":34,"login":"owner"}}"#.utf8)
        let deep = Data((String(repeating: "[", count: 65) + "0" + String(repeating: "]", count: 65)).utf8)
        let malformedSurrogate = Data(#"{"ref":"refs/heads/main","after":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","deleted":false,"repository":{"id":12,"full_name":"owner/site"},"sender":{"id":34,"login":"owner"},"unused":"\uD800\u0000"}"#.utf8)
        for body in [duplicate, deep, malformedSurrogate] {
            #expect(throws: NativeRPCError.self) { _ = try BackendAppsPushVerifier.verify(headers: BackendAppsPushFake.headers(body), body: body, secret: BackendAppsPushFake.secret, target: target) }
        }
    }

    @Test func signedMalformedUTF16NeverReachesOrderedParserAndValidPairPasses() throws {
        let target = try BackendAppsPushTarget(repository: "owner/site", branch: "main")
        let base = String(data: BackendAppsPushFake.body(), encoding: .utf8)!
        for escape in [#"\uD800\u0000"#, #"\uD800"#, #"\uDC00"#, #"\u123"#, #"\uD800\uDFFFx\uDC00"#] {
            let body = Data((String(base.dropLast()) + ",\"unused\":\"" + escape + "\"}").utf8)
            #expect(throws: NativeRPCError.self) { _ = try BackendAppsPushVerifier.verify(headers: BackendAppsPushFake.headers(body), body: body, secret: BackendAppsPushFake.secret, target: target) }
        }
        let valid = Data((String(base.dropLast()) + #","unused":"\uD83D\uDE80"}"#).utf8)
        #expect(try BackendAppsPushVerifier.verify(headers: BackendAppsPushFake.headers(valid), body: valid, secret: BackendAppsPushFake.secret, target: target).revision == String(repeating: "a", count: 40))
    }

    @Test func noIngressCannotBeEnabledAndDoesNoServerIO() async throws {
        let fake = BackendAppsPushFake()
        let service = BackendAppsAutoDeploy(runtime: await fake.runtime())
        await #expect(throws: NativeRPCError.self) { _ = try await service.apply(serverID: "one", appID: "site", enabled: true, context: context) }
        let body = BackendAppsPushFake.body()
        await #expect(throws: NativeRPCError.self) { _ = try await service.receive(serverID: "one", appID: "site", headers: BackendAppsPushFake.headers(body), body: body, context: context) }
        #expect((await fake.snapshot()).commands.isEmpty)
    }

    @Test func deniedDeliveryApprovalDoesNoStateIOOrDispatch() async throws {
        let fake = BackendAppsPushFake(approvalAllowed: false)
        let service = BackendAppsAutoDeploy(runtime: await fake.runtime(), trustedIngress: await fake.ingress())
        let body = BackendAppsPushFake.body()
        await #expect(throws: NativeRPCError.self) { _ = try await service.receive(serverID: "one", appID: "site", headers: BackendAppsPushFake.headers(body), body: body, context: context) }
        let state = await fake.snapshot()
        #expect(state.events == ["connection", "approval"])
        #expect(state.commands.isEmpty && state.dispatched.isEmpty && state.ledger == nil)
    }

    @Test func invalidSignatureNeverReachesApprovalOrServerState() async throws {
        let fake = BackendAppsPushFake()
        let service = BackendAppsAutoDeploy(runtime: await fake.runtime(), trustedIngress: await fake.ingress())
        let body = BackendAppsPushFake.body(), wrong = BackendAppsPushFake.body(repository: "other/site")
        await #expect(throws: NativeRPCError.self) { _ = try await service.receive(serverID: "one", appID: "site", headers: BackendAppsPushFake.headers(body), body: wrong, context: context) }
        let state = await fake.snapshot()
        #expect(state.events == ["connection"] && state.commands.isEmpty && state.dispatched.isEmpty)
    }

    @Test func approvedDeliveryClaimsServerReceiptBeforeDispatchingExactSHA() async throws {
        let fake = BackendAppsPushFake()
        let service = BackendAppsAutoDeploy(runtime: await fake.runtime(), trustedIngress: await fake.ingress())
        let body = BackendAppsPushFake.body()
        let result = try await service.receive(serverID: "one", appID: "site", headers: BackendAppsPushFake.headers(body), body: body, context: context)
        let state = await fake.snapshot()
        #expect(result["accepted"].bool == true)
        #expect(result["deploymentId"].string == "deployment-one")
        #expect(state.dispatched == [String(repeating: "a", count: 40)])
        #expect(state.claimExistedAtDispatch)
        #expect(state.ledger?["deliveries"].elements?.first?["status"].string == "completed")
        #expect(!state.ledger!.compact.contains(String(data: BackendAppsPushFake.secret, encoding: .utf8)!))
        #expect(!state.locked)
    }

    @Test func replayIsDeduplicatedAcrossMacInstancesAndChangedUnsignedDeliveryUUID() async throws {
        let fake = BackendAppsPushFake(), body = BackendAppsPushFake.body()
        let first = BackendAppsAutoDeploy(runtime: await fake.runtime(), trustedIngress: await fake.ingress())
        _ = try await first.receive(serverID: "one", appID: "site", headers: BackendAppsPushFake.headers(body), body: body, context: context)
        let anotherMac = BackendAppsAutoDeploy(runtime: await fake.runtime(), trustedIngress: await fake.ingress())
        let duplicate = try await anotherMac.receive(serverID: "one", appID: "site", headers: BackendAppsPushFake.headers(body, delivery: "11111111-2222-4333-8444-555555555555"), body: body, context: context)
        #expect(duplicate["duplicate"].bool == true && duplicate["accepted"].bool == false)
        #expect((await fake.snapshot()).dispatched.count == 1)
    }

    @Test func changedSourceOrDisabledAppCannotDispatchEvenAfterApproval() async throws {
        for fake in [BackendAppsPushFake(enabled: false), BackendAppsPushFake(recordBranch: "other")] {
            let service = BackendAppsAutoDeploy(runtime: await fake.runtime(), trustedIngress: await fake.ingress())
            let body = BackendAppsPushFake.body()
            await #expect(throws: NativeRPCError.self) { _ = try await service.receive(serverID: "one", appID: "site", headers: BackendAppsPushFake.headers(body), body: body, context: context) }
            #expect((await fake.snapshot()).dispatched.isEmpty)
        }
    }

    @Test func failedDurableClaimNeverDispatches() async throws {
        let fake = BackendAppsPushFake(failLedgerWrite: true)
        let service = BackendAppsAutoDeploy(runtime: await fake.runtime(), trustedIngress: await fake.ingress())
        let body = BackendAppsPushFake.body()
        await #expect(throws: NativeRPCError.self) { _ = try await service.receive(serverID: "one", appID: "site", headers: BackendAppsPushFake.headers(body), body: body, context: context) }
        let state = await fake.snapshot()
        #expect(state.dispatched.isEmpty && state.ledger == nil && !state.locked)
    }

    @Test func duplicateLedgerKeysFailClosedBeforeDispatch() async throws {
        let fake = BackendAppsPushFake()
        await fake.setLedger(Data(#"{"version":1,"deliveries":[],"deliveries":[]}"#.utf8))
        let service = BackendAppsAutoDeploy(runtime: await fake.runtime(), trustedIngress: await fake.ingress())
        let body = BackendAppsPushFake.body()
        await #expect(throws: NativeRPCError.self) { _ = try await service.receive(serverID: "one", appID: "site", headers: BackendAppsPushFake.headers(body), body: body, context: context) }
        #expect((await fake.snapshot()).dispatched.isEmpty)
    }

    @Test func missingOrMismatchedDispatchProofLeavesUncertainReceipt() async throws {
        let invalidResults: [NativeRPCValue] = [
            .null,
            BackendAppsValidation.object([("id", .string("deployment-one"))]),
            BackendAppsValidation.object([("id", .string("deployment-one")), ("commit", .string(String(repeating: "b", count: 40))), ("status", .string("running"))]),
            BackendAppsValidation.object([("id", .string("deployment-one")), ("commit", .string(String(repeating: "a", count: 40))), ("status", .string("failed"))])
        ]
        for result in invalidResults {
            let fake = BackendAppsPushFake(dispatchResult: result)
            let service = BackendAppsAutoDeploy(runtime: await fake.runtime(), trustedIngress: await fake.ingress())
            let body = BackendAppsPushFake.body()
            await #expect(throws: NativeRPCError.self) { _ = try await service.receive(serverID: "one", appID: "site", headers: BackendAppsPushFake.headers(body), body: body, context: context) }
            #expect((await fake.snapshot()).ledger?["deliveries"].elements?.first?["status"].string == "uncertain")
        }
    }

    @Test func uncertainDispatchRemainsClaimedAndErrorsContainNoSecret() async throws {
        let fake = BackendAppsPushFake(failDispatch: true)
        let service = BackendAppsAutoDeploy(runtime: await fake.runtime(), trustedIngress: await fake.ingress())
        let body = BackendAppsPushFake.body()
        do {
            _ = try await service.receive(serverID: "one", appID: "site", headers: BackendAppsPushFake.headers(body), body: body, context: context)
            Issue.record("An unconfirmed deployment was accepted.")
        } catch let error as NativeRPCError { #expect(!error.message.contains("raw-secret")) }
        let duplicate = try await service.receive(serverID: "one", appID: "site", headers: BackendAppsPushFake.headers(body), body: body, context: context)
        #expect(duplicate["duplicate"].bool == true)
        let state = await fake.snapshot()
        #expect(state.ledger?["deliveries"].elements?.first?["status"].string == "uncertain")
        #expect(state.dispatched.count == 1)
    }

    @Test func completedTTLExpiresOnNewEventButUncertainReceiptNeverAutoExpires() async throws {
        let fake = BackendAppsPushFake()
        await fake.seedLedger(count: 2, old: true, includeUncertain: true)
        let service = BackendAppsAutoDeploy(runtime: await fake.runtime(), trustedIngress: await fake.ingress())
        let body = BackendAppsPushFake.body()
        _ = try await service.receive(serverID: "one", appID: "site", headers: BackendAppsPushFake.headers(body), body: body, context: context)
        let rows = try #require((await fake.snapshot()).ledger?["deliveries"].elements)
        #expect(rows.count == 2)
        #expect(rows.contains { $0["status"].string == "uncertain" })
        #expect(rows.contains { $0["status"].string == "completed" })
    }

    @Test func fullUnexpiredLedgerFailsClosedInsteadOfEvictingReplayProtection() async throws {
        let fake = BackendAppsPushFake()
        await fake.seedLedger(count: BackendAppsAutoDeploy.maximumDeliveries)
        let service = BackendAppsAutoDeploy(runtime: await fake.runtime(), trustedIngress: await fake.ingress())
        let body = BackendAppsPushFake.body()
        do {
            _ = try await service.receive(serverID: "one", appID: "site", headers: BackendAppsPushFake.headers(body), body: body, context: context)
            Issue.record("A full delivery ledger was silently evicted.")
        } catch let error as NativeRPCError { #expect(error.code == "busy") }
        #expect((await fake.snapshot()).dispatched.isEmpty)
    }

    @Test func disablingWorksWithoutIngressAndEnablingRequiresMatchingTrustedTarget() async throws {
        let fake = BackendAppsPushFake(enabled: false)
        let noIngress = BackendAppsAutoDeploy(runtime: await fake.runtime())
        #expect(try await noIngress.apply(serverID: "one", appID: "site", enabled: false, context: context)["enabled"].bool == false)
        let service = BackendAppsAutoDeploy(runtime: await fake.runtime(), trustedIngress: await fake.ingress())
        #expect(try await service.apply(serverID: "one", appID: "site", enabled: true, context: context)["enabled"].bool == true)
        let state = await fake.snapshot()
        #expect(state.record["autoDeploy"].bool == true)
        #expect(state.events.contains("configure:true"))
    }

    @Test func activeBindingCannotBePretendedDisabledWhenIngressIsMissing() async throws {
        let fake = BackendAppsPushFake(enabled: true)
        let service = BackendAppsAutoDeploy(runtime: await fake.runtime())
        await #expect(throws: NativeRPCError.self) { _ = try await service.apply(serverID: "one", appID: "site", enabled: false, context: context) }
        let state = await fake.snapshot()
        #expect(state.record["autoDeploy"].bool == true)
        #expect(state.events.isEmpty)
    }

    @Test func existingInjectedApprovalCanAuthorizePageWithoutInventedAppsCapability() async throws {
        let fake = BackendAppsPushFake()
        let service = BackendAppsAutoDeploy(runtime: await fake.runtime(), trustedIngress: await fake.ingress())
        let pageContext = NativeRPCContext(caller: .page, ownerID: "push-owner", capabilities: ["projects.read", "files.read", "git.read"])
        let body = BackendAppsPushFake.body()
        #expect(try await service.receive(serverID: "one", appID: "site", headers: BackendAppsPushFake.headers(body), body: body, context: pageContext)["accepted"].bool == true)
        #expect((await fake.snapshot()).events.contains("approval"))
    }

    @Test func failedEnablePersistenceDisablesHelperWithInheritedRPCIdentity() async throws {
        let fake = BackendAppsPushFake(enabled: false, failStateWrite: true, requireRPCIdentity: true)
        let service = BackendAppsAutoDeploy(runtime: await fake.runtime(), trustedIngress: await fake.ingress())
        try await BackendAppsPushTestContext.$identity.withValue("push-owner") {
            await #expect(throws: NativeRPCError.self) { _ = try await service.apply(serverID: "one", appID: "site", enabled: true, context: context) }
        }
        let state = await fake.snapshot()
        #expect(state.events.contains("configure:true") && state.events.contains("configure:false"))
        #expect(!state.helperEnabled && !state.locked)
        #expect(state.record["autoDeploy"].bool == false)
    }

    @Test func failedDisableRestoresOriginalEnabledBindingAndRecord() async throws {
        let fake = BackendAppsPushFake(enabled: true, failStateWrite: true)
        let service = BackendAppsAutoDeploy(runtime: await fake.runtime(), trustedIngress: await fake.ingress())
        await #expect(throws: NativeRPCError.self) { _ = try await service.apply(serverID: "one", appID: "site", enabled: false, context: context) }
        let state = await fake.snapshot()
        #expect(state.events.contains("configure:false") && state.events.contains("configure:true"))
        #expect(state.record["autoDeploy"].bool == true && state.helperEnabled)
        #expect(state.record["pendingAutoDeploy"].isNullish)
    }

    @Test func pendingConfigurationBlocksAllPushDispatch() async throws {
        let fake = BackendAppsPushFake()
        await fake.markPendingConfiguration()
        let service = BackendAppsAutoDeploy(runtime: await fake.runtime(), trustedIngress: await fake.ingress())
        let body = BackendAppsPushFake.body()
        await #expect(throws: NativeRPCError.self) { _ = try await service.receive(serverID: "one", appID: "site", headers: BackendAppsPushFake.headers(body), body: body, context: context) }
        #expect((await fake.snapshot()).dispatched.isEmpty)
    }

    @Test func failedBindingCompensationLeavesDurableJournalAndRefusesPushes() async throws {
        let fake = BackendAppsPushFake(enabled: false, failStateWrite: true, failRollbackConfigure: true)
        let service = BackendAppsAutoDeploy(runtime: await fake.runtime(), trustedIngress: await fake.ingress())
        do {
            _ = try await service.apply(serverID: "one", appID: "site", enabled: true, context: context)
            Issue.record("Unverified helper settings were accepted.")
        } catch let error as NativeRPCError { #expect(error.details["autoDeployUncertain"].bool == true) }
        #expect(!(await fake.snapshot()).record["pendingAutoDeploy"].isNullish)
        let body = BackendAppsPushFake.body()
        await #expect(throws: NativeRPCError.self) { _ = try await service.receive(serverID: "one", appID: "site", headers: BackendAppsPushFake.headers(body), body: body, context: context) }
        #expect((await fake.snapshot()).dispatched.isEmpty)
    }
}

private enum BackendAppsPushTestContext { @TaskLocal static var identity: String? }

/// All fake state is held in this Swift actor, modeling one server shared by
/// multiple Mac service instances. No shell, process, socket or timer runs.
private actor BackendAppsPushFake {
    static let secret = Data("test-shared-webhook-key-at-least-32-bytes".utf8)
    static let nowMS: Double = 1_800_000_000_000
    struct Snapshot: Sendable {
        let commands: [String], events: [String], dispatched: [String]
        let record: NativeRPCValue, ledger: NativeRPCValue?
        let claimExistedAtDispatch: Bool, locked: Bool, helperEnabled: Bool
    }
    private var commands: [String] = [], events: [String] = [], dispatched: [String] = []
    private var record: NativeRPCValue
    private var ledger: Data?
    private var locked = false, helperEnabled = false, claimExistedAtDispatch = false
    private var stateWriteCount = 0
    private var configureCount = 0
    private let failRollbackConfigure: Bool
    private let dispatchResult: NativeRPCValue?
    private let approvalAllowed: Bool, failLedgerWrite: Bool, failDispatch: Bool, failStateWrite: Bool, requireRPCIdentity: Bool
    init(enabled: Bool = true, recordBranch: String = "main", approvalAllowed: Bool = true, failLedgerWrite: Bool = false, failDispatch: Bool = false, failStateWrite: Bool = false, requireRPCIdentity: Bool = false, failRollbackConfigure: Bool = false, dispatchResult: NativeRPCValue? = nil) {
        record = BackendAppsValidation.object([
            ("id", .string("site")), ("name", .string("Site")), ("kind", .string("app")), ("autoDeploy", .bool(enabled)),
            ("source", BackendAppsValidation.object([("kind", .string("github")), ("repository", .string("owner/site")), ("branch", .string(recordBranch))]))
        ])
        self.approvalAllowed = approvalAllowed; self.failLedgerWrite = failLedgerWrite; self.failDispatch = failDispatch
        self.failStateWrite = failStateWrite; self.requireRPCIdentity = requireRPCIdentity
        self.helperEnabled = enabled
        self.failRollbackConfigure = failRollbackConfigure
        self.dispatchResult = dispatchResult
    }
    func runtime() -> BackendAppsRuntime { .init(execute: { _, command, stdin, _, _ in try await self.execute(command, stdin: stdin) }) }
    func ingress() -> BackendAppsAutoDeployIngress {
        .init(readConnection: { _, _, _ in try await self.connection() },
              configure: { _, _, enabled, _, _ in try await self.configure(enabled) },
              authorizeDelivery: { _, _, _, _ in try await self.approve() },
              dispatch: { _, _, push, _ in try await self.dispatch(push) })
    }
    func snapshot() -> Snapshot {
        .init(commands: commands, events: events, dispatched: dispatched, record: record,
              ledger: ledger.flatMap { try? NativeRPCValue.parseJSON($0) }, claimExistedAtDispatch: claimExistedAtDispatch, locked: locked, helperEnabled: helperEnabled)
    }
    private func connection() throws -> BackendAppsAutoDeployConnection {
        try requireIdentity(); events.append("connection")
        return try .init(target: BackendAppsPushTarget(repository: "owner/site", branch: "main"), secret: Self.secret, enabled: helperEnabled)
    }
    private func configure(_ enabled: Bool) throws {
        try requireIdentity(); events.append("configure:" + String(enabled)); configureCount += 1
        if failRollbackConfigure && configureCount > 1 { throw NativeRPCError(code: "unavailable", message: "The helper response was lost.") }
        helperEnabled = enabled
    }
    private func approve() throws {
        events.append("approval")
        if !approvalAllowed { throw NativeRPCError(code: "approval-required", message: "This push needs approval.") }
    }
    private func dispatch(_ push: BackendAppsVerifiedPush) throws -> NativeRPCValue {
        events.append("dispatch"); dispatched.append(push.revision)
        if let ledger, let saved = try? NativeRPCValue.parseJSON(ledger) {
            claimExistedAtDispatch = saved["deliveries"].elements?.contains { $0["push"]["revision"].string == push.revision && $0["status"].string == "dispatching" } == true
        }
        if failDispatch { throw NativeRPCError(code: "unknown", message: "raw-secret-from-server") }
        return dispatchResult ?? BackendAppsValidation.object([("id", .string("deployment-one")), ("commit", .string(push.revision)), ("status", .string("running"))])
    }
    private func requireIdentity() throws {
        if requireRPCIdentity && BackendAppsPushTestContext.identity != "push-owner" { throw NativeRPCError(code: "access-denied", message: "Missing RPC identity.") }
    }
    private func execute(_ command: String, stdin: Data?) throws -> BackendServersRunResult {
        try requireIdentity(); commands.append(command)
        if command.contains("date +%s") { return .init(code: 0, stdout: String(Int(Self.nowMS / 1000))) }
        if command.contains("rmdir --") && command.contains("/owner") { locked = false; return .init(code: 0, stdout: "") }
        if command.contains("mkdir --") && command.contains("/owner") {
            if locked { return .init(code: 73, stdout: "") }
            locked = true; return .init(code: 0, stdout: "")
        }
        if command.contains("mv -f --"), let stdin {
            if command.contains("push-deliveries.json") {
                if failLedgerWrite { return .init(code: 1, stdout: "") }
                ledger = stdin
            } else if command.contains("state.json") {
                stateWriteCount += 1
                if failStateWrite && stateWriteCount == 2 { return .init(code: 1, stdout: "") }
                record = try NativeRPCValue.parseJSON(stdin)
            }
            return .init(code: 0, stdout: "")
        }
        if command.contains("cat --") {
            if command.contains("push-deliveries.json") {
                guard let ledger else { return .init(code: 44, stdout: "") }
                return .init(code: 0, stdout: String(data: ledger, encoding: .utf8)!)
            }
            if command.contains("state.json") { return .init(code: 0, stdout: record.compact) }
        }
        return .init(code: 1, stdout: "")
    }
    func seedLedger(count: Int, old: Bool = false, includeUncertain: Bool = false) {
        let receipts = (0..<count).map { index in
            BackendAppsValidation.object([
                ("receivedAt", .number(old ? Self.nowMS - BackendAppsAutoDeploy.replayTTLMS - 1000 : Self.nowMS)),
                ("status", .string(includeUncertain && index == 0 ? "uncertain" : "completed")),
                ("push", BackendAppsValidation.object([
                    ("deliveryID", .string(String(format: "%08x-2222-4333-8444-555555555555", index + 1))),
                    ("repository", .string("owner/site")), ("ref", .string("refs/heads/main")),
                    ("revision", .string(String(repeating: "b", count: 40))), ("senderLogin", .string("owner")),
                    ("bodyDigest", .string(String(format: "%064x", index + 1))),
                    ("repositoryID", .number(12)), ("senderID", .number(34))
                ]))
            ])
        }
        ledger = try? BackendAppsValidation.object([("version", .number(1)), ("deliveries", .array(receipts))]).encodedJSON()
    }
    func markPendingConfiguration() { record = record.setting("pendingAutoDeploy", BackendAppsValidation.object([("phase", .string("configuring"))])) }
    func setLedger(_ data: Data) { ledger = data }
    static func body(repository: String = "owner/site", ref: String = "refs/heads/main", revision: String = String(repeating: "a", count: 40), deleted: Bool = false) -> Data {
        try! BackendAppsValidation.object([
            ("ref", .string(ref)), ("after", .string(revision)), ("deleted", .bool(deleted)),
            ("repository", BackendAppsValidation.object([("id", .number(12)), ("full_name", .string(repository))])),
            ("sender", BackendAppsValidation.object([("id", .number(34)), ("login", .string("github-actions[bot]"))]))
        ]).encodedJSON()
    }
    static func headers(_ body: Data, delivery: String = "12345678-2222-4333-8444-555555555555") -> [BackendAppsPushHeader] {
        let code = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: secret)).map { String(format: "%02x", $0) }.joined()
        return [.init("X-GitHub-Event", "push"), .init("X-GitHub-Delivery", delivery), .init("X-Hub-Signature-256", "sha256=" + code), .init("Content-Type", "application/json")]
    }
}
