import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Lane A's wiring of saved passwords (lean scope item 3). Fixtures only: no Keychain, no network, no live owner.
@Suite("Cloud saved passwords — lane A's wiring")
@MainActor
struct CloudSecretsWiringTests {
    private struct Wired {
        let graph: BackendCloudSecretsGraph
        let client: CloudSecretsFixtureClient
        let outbox: WiringOutbox
        let changes: WiringCounter
        let restores: WiringCounter
    }
    /// Lane V's own fixture client (in-memory key, fixture service, fixture person) under lane A's graph.
    /// `standing` is this Mac's own stores as lane V's lean local-store check reports them: the fixture answers the
    /// page's question and refuses the unlock's check the way `recoverAfterVerifiedCloudUnlock()` does.
    private func made(stores: [any CloudSecretsLogicalStore] = [WiringStore(sourceId: "api", domain: .apiKey)],
                      standing: WiringStanding = WiringStanding(), log: CloudSecretsLog = .none) async throws -> Wired {
        let server = CloudSecretsFixtureServer(), client = try await CloudSecretsFixtureClient(server: server)
        let outbox = WiringOutbox(), changes = WiringCounter(), restores = WiringCounter()
        let graph = try BackendCloudSecretsGraph(recovery: client.coordinator, content: client.content, policy: client.policy,
            local: client.local, deviceId: client.device.deviceId, outbox: outbox, stores: stores,
            retainConflict: { _ in }, known: nil, restoreLocalStores: {
                restores.add()
                switch standing.get() {
                case .ready: return
                case .blocked(let reason): throw BackendCloudRecoveryBlocked(reason: reason)
                case .keyLost(let owners): throw BackendCloudRecoveryKeyLost(owners: owners)
                case .cannotCheck(let owners): throw BackendCloudRecoveryCannotCheck(owners: owners)
                case .notConverted(let owners): throw BackendCloudRecoveryNotConverted(owners: owners)
                }
            }, localStanding: { standing.get() }, changed: { changes.add() }, log: log)
        return Wired(graph: graph, client: client, outbox: outbox, changes: changes, restores: restores)
    }
    /// An account whose ports seal the graph, as the app's assembly does.
    private func makeAccount(_ f: CloudAccountFixture, sealing graph: BackendCloudSecretsGraph) -> BackendCloudAccount {
        BackendCloudAccount(configuration: f.identity.configuration, identity: f.identity, http: f.server,
            ports: { BackendCloudAccountPorts(transport: f.transport, outbox: f.outbox, trust: f.trust, seal: { await graph.seal() }) },
            clock: { f.clock.now() }, monotonic: { f.clock.monotonic() })
    }
    private func signIn(_ account: BackendCloudAccount, _ f: CloudAccountFixture) async throws {
        let callback = CloudHandoffCallback(port: 49555, pathToken: String(repeating: "a", count: 32))
        let url = try await account.beginSignIn(callback: callback, provider: "google")
        try await f.server.authorize(url)
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!
        try await account.finishSignIn(code: "fixture-code", state: state, callback: callback)
    }
    private func notice(_ type: String, epoch: Int? = nil) -> CloudEvent {
        var fields: [NativeRPCValue.Field] = []
        if let epoch { fields = [.init("state", .string("ready")), .init("epoch", .number(Double(epoch))), .init("version", .string("3"))] }
        return CloudEvent(v: 1, type: type, id: UUID().uuidString.lowercased(), payload: CloudValue(.object(fields)))
    }

    @Test func theControlPortSendsMethodPathBodyAndRequestIdUnchanged() async throws {
        let sent = WiringSent()
        let status = CloudSecretsStatus(state: .ready, epoch: 1, version: CloudSequence(2), recoveryReady: true, approvedDeviceCount: 1, pendingApprovals: [])
        let receipt = CloudSecretsPossessionReceipt(secretsApproved: true, epoch: 1, version: CloudSequence(3))
        let statusBytes = try CloudSecretsCanonical.encode(status)
        let receiptBytes = try CloudSecretsCanonical.encode(receipt)
        let control = BackendCloudSecretsLean.control(send: { method, path, body, requestId in
            sent.add(.init(method: method, path: path, body: body, requestId: requestId))
            return method == "GET" ? statusBytes : receiptBytes
        }, devices: { CloudDeviceList(devices: []) })
        let read = try await control.status()
        #expect(read == status)
        let request = CloudPossessionRequest(requestId: UUID().uuidString.lowercased(), expectedVersion: CloudSequence(2),
                                             canary: "fixture-canary", signature: "fixture-signature")
        let answer = try await control.possession(request)
        #expect(answer.epoch == 1)
        let calls = sent.all()
        #expect(calls.count == 2)
        let first = try #require(calls.first)
        let second = try #require(calls.last)
        #expect(first.method == "GET")
        #expect(first.path == "/secrets/status")
        #expect(first.body.isEmpty)
        // The sync transport takes only a lower-case UUID as the request id.
        #expect(UUID(uuidString: first.requestId)?.uuidString.lowercased() == first.requestId)
        let expected = try CloudSecretsCanonical.encode(request)
        #expect(second.method == "POST")
        #expect(second.path == "/secrets/possession")
        #expect(second.body == expected)
        #expect(second.requestId == request.requestId)
    }

    @Test func aSavedPasswordsRefusalGoesBackToLaneVAndNeverSignsTheAccountOut() async throws {
        let f = try CloudAccountFixture.make()
        _ = try await f.signin()
        let refusal = CloudFailure.remote(.init(code: "not_approved", message: "This device is not approved.", retryable: false, requestId: "fixture"))
        let refused = BackendCloudSecretsLean.control(send: { _, _, _, _ in throw refusal }, devices: { try await f.transport.devices() })
        var first: CloudFailure?
        do { _ = try await refused.status() } catch { first = error as? CloudFailure }
        #expect(first == refusal)
        // The transport's own "locked" answer reaches lane V as the service's code, which V reads as "already
        // approved" after an acknowledgement whose answer was lost. Without this a waiting Mac could never finish.
        let locked = BackendCloudSecretsLean.control(send: { _, _, _, _ in throw CloudFailure.secretsLocked }, devices: { try await f.transport.devices() })
        var second: CloudFailure?
        do { _ = try await locked.envelope() } catch { second = error as? CloudFailure }
        var code = ""
        if let second, case .remote(let detail) = second { code = detail.code }
        #expect(code == "secrets_locked")
        // Neither is an answer about the session: the account stays signed in.
        if let first { #expect(!BackendCloudAccount.sessionRefused(first)) }
        if let second { #expect(!BackendCloudAccount.sessionRefused(second)) }
        #expect(await f.account.state().phase == .signedIn)
        #expect(try await f.identity.existing() != nil)
    }

    @Test func aDeviceIsProjectedOnlyFromTheAccountsOwnList() throws {
        let key = CloudPublicJWK(kty: "EC", crv: "P-256", x: "fixture-x", y: "fixture-y")
        let active = CloudDevice(deviceId: "a", label: "Mac a", platform: .macos, appVersion: "fixture", status: .active, secretsApproved: false,
                                 lastSeenAt: 0, signPublicJwk: key, wrapPublicJwk: key)
        let cutOff = CloudDevice(deviceId: "b", label: "Mac b", platform: .macos, appVersion: "fixture", status: .revoked, secretsApproved: false,
                                 lastSeenAt: 0, signPublicJwk: key, wrapPublicJwk: key)
        let list = [active, cutOff], twice = [active, cutOff, active]
        let found = try BackendCloudSecretsLean.registeredDevice("a", in: list)
        #expect(found.deviceId == "a")
        #expect(found.label == "Mac a")
        #expect(found.signPublicJwk == key)
        #expect(throws: CloudFailure.invalidRequest) { _ = try BackendCloudSecretsLean.registeredDevice("b", in: list) }
        #expect(throws: CloudFailure.invalidRequest) { _ = try BackendCloudSecretsLean.registeredDevice("c", in: list) }
        #expect(throws: CloudFailure.invalidRequest) { _ = try BackendCloudSecretsLean.registeredDevice("a", in: twice) }
    }

    @Test func onlyTheLeanSourcesEachUnderItsOwnDomainReachTheSyncCore() {
        let lean: [any CloudSecretsLogicalStore] = BackendCloudSecretsLean.sources.map { WiringStore(sourceId: $0.key, domain: $0.value) }
        let out: [any CloudSecretsLogicalStore] = [
            WiringStore(sourceId: "github", domain: .app), WiringStore(sourceId: "cookies", domain: .browserCookies),
            WiringStore(sourceId: "browser-passwords", domain: .browserPassword), WiringStore(sourceId: "subscriptions", domain: .aiSubscription),
            WiringStore(sourceId: "project/one", domain: .project), WiringStore(sourceId: "mcp-project", domain: .mcp),
            // A lean name under another source's domain is not that source.
            WiringStore(sourceId: "voice", domain: .apiKey)]
        #expect(BackendCloudSecretsLean.domains(out).isEmpty)
        let domains = BackendCloudSecretsLean.domains(out + lean + out + lean)
        #expect(domains == ["api-key", "server", "ssh", "mcp", "task-connection", "receiver", "app", "project", "whatsapp"])
        let kept = BackendCloudSecretsLean.admitted(out + lean + lean).map { $0.sourceId }.sorted()
        #expect(kept == ["api", "mcp-user", "project-files", "receiver", "servers", "ssh", "tasks", "voice", "whatsapp"])
        // Nothing handed in: the sync core is built with no saved-password domain and no saved-password content port.
        let parts = BackendCloudSecretsEngineParts()
        #expect(parts.domains.isEmpty)
        #expect(parts.content == nil)
    }

    @Test func cloudSecretsCanOnlyReadTheStateAndOpenThisMacsSheets() async throws {
        let spec = try BackendCloudSecretsLeanTool.definition()
        #expect(spec.id == "cloud.secrets")
        let properties = spec.inputSchema["properties"]
        let names = (properties.fields ?? []).map { $0.key }.sorted()
        #expect(names == ["action", "approvalId"])
        let offered = NativeRPCValue.array(["status", "setup", "request_device", "open_approval", "recover"].map(NativeRPCValue.string))
        #expect(properties["action"]["enum"] == offered)
        #expect(spec.inputSchema["additionalProperties"] == NativeRPCValue.bool(false))
        let port = WiringPort(), gate = CloudSecretsFixtureGate(clock: CloudSecretsFixtureServer.now)
        let policy = CloudSecretsPolicy(capabilities: { await gate.value() }, now: { CloudSecretsFixtureServer.now })
        let tools = BackendCloudSecretsTools(secrets: port, policy: policy, browser: { _, _ in throw CloudFailure.unavailable })
        let id = UUID().uuidString.lowercased()
        let refused: [[NativeRPCValue.Field]] = [
            [.init("action", .string("reset"))],
            [.init("action", .string("add_mcp"))], [.init("action", .string("dismiss_mcp"))], [.init("action", .string("answer_code"))],
            [.init("action", .string("setup")), .init("words", .string("fixture words"))],
            [.init("action", .string("recover")), .init("words", .string("fixture words"))],
            [.init("action", .string("open_approval")), .init("approvalId", .string(id)), .init("allow", .bool(true))],
            [.init("action", .string("open_approval")), .init("approvalId", .string(id)), .init("code", .string("1234"))],
            [.init("action", .string("status")), .init("mcpId", .string("fixture"))],
            [.init("approvalId", .string(id))]
        ]
        for fields in refused {
            var failure: CloudFailure?
            do { _ = try await BackendCloudSecretsLeanTool.invoke(tools, arguments: .object(fields)) }
            catch { failure = error as? CloudFailure }
            #expect(failure == .invalidRequest)
        }
        #expect(await port.mutations == 0)
        let status = try await BackendCloudSecretsLeanTool.invoke(tools, arguments: .object([.init("action", .string("status"))]))
        #expect(status["protected"].bool == true)
        #expect(await port.mutations == 0)
        // Not visible: nothing is registered. Visible: this one tool and no other.
        let hidden = try await BackendCloudSecretsLeanTool.registrations(tools: tools, visible: { false })
        #expect(hidden.isEmpty)
        let shown = try await BackendCloudSecretsLeanTool.registrations(tools: tools, visible: { true })
        let shownIds = shown.map { $0.0.id }
        #expect(shownIds == ["cloud.secrets"])
    }

    @Test func theStateLineSaysProtectedOnlyWithNoGapAndNoWait() {
        var page = BackendCloudSecretsPage()
        let others: [BackendCloudSecretsPage.Standing] = [.unknown, .notSetUp, .locked, .waitingForCloud,
            .startedAnew("Saved passwords were started anew on another device. Allow this Mac again or use the new recovery words."),
            .keyBlocked(BackendCloudSecretsKeyBlocked(status: -25308).errorDescription ?? ""),
            .loginStoreBlocked(BackendCloudRecoveryBlocked(reason: "The login store is locked.").errorDescription ?? "")]
        for standing in others {
            page.standing = standing
            let line = BackendCloudSecretsWords.state(page).lowercased()
            #expect(!line.isEmpty)
            #expect(!line.contains("protected"))
            #expect(!line.contains("up to date"))
        }
        page.standing = .waitingForCloud
        #expect(BackendCloudSecretsWords.state(page) == CloudSecretsProtection.waitingAdvice)
        page.standing = .protected
        #expect(BackendCloudSecretsWords.state(page) == BackendCloudSecretsWords.on)
        page.gaps = ["An API key is too large to save in Cloud. It stays on this Mac."]
        let withGap = BackendCloudSecretsWords.state(page).lowercased()
        #expect(!withGap.contains("protected"))
        #expect(!withGap.contains("up to date"))
        // Which state it is: a blocked key, a blocked login store, a newer Cloud and a wait all come before "protected".
        #expect(BackendCloudSecretsPage.standing(keyBlocked: nil, loginStoreBlocked: nil, protection: .protected, available: true, cloudAhead: nil, vault: .ready) == .protected)
        #expect(BackendCloudSecretsPage.standing(keyBlocked: nil, loginStoreBlocked: nil, protection: .waitingForCloud, available: true, cloudAhead: nil, vault: .ready) == .waitingForCloud)
        #expect(BackendCloudSecretsPage.standing(keyBlocked: nil, loginStoreBlocked: nil, protection: .protected, available: false, cloudAhead: "newer", vault: .ready) == .startedAnew("newer"))
        #expect(BackendCloudSecretsPage.standing(keyBlocked: nil, loginStoreBlocked: nil, protection: .protected, available: false, cloudAhead: nil, vault: nil) == .unknown)
        #expect(BackendCloudSecretsPage.standing(keyBlocked: "key", loginStoreBlocked: "store", protection: .protected, available: true, cloudAhead: nil, vault: .ready) == .keyBlocked("key"))
        #expect(BackendCloudSecretsPage.standing(keyBlocked: nil, loginStoreBlocked: "store", protection: .protected, available: true, cloudAhead: nil, vault: .ready) == .loginStoreBlocked("store"))
        #expect(BackendCloudSecretsPage.standing(keyBlocked: nil, loginStoreBlocked: nil, protection: .locked, available: false, cloudAhead: nil, vault: .unset) == .notSetUp)
        #expect(BackendCloudSecretsPage.standing(keyBlocked: nil, loginStoreBlocked: nil, protection: .locked, available: false, cloudAhead: nil, vault: .ready) == .locked)
    }

    @Test func signOutSealsSavedPasswordsAndTakesTheToolAway() async throws {
        let w = try await made(), f = try CloudAccountFixture.make()
        let graph = w.graph, account = makeAccount(f, sealing: graph)
        try await signIn(account, f)
        let visible: @Sendable () async -> Bool = {
            let open = await account.state().visible(at: 0)
            let sealed = await graph.isSealed()
            return open && !sealed
        }
        let before = try await BackendCloudSecretsLeanTool.registrations(tools: graph.tools, visible: visible)
        #expect(before.count == 1)
        try await account.signOut()
        #expect(await graph.isSealed())
        let after = try await BackendCloudSecretsLeanTool.registrations(tools: graph.tools, visible: visible)
        #expect(after.isEmpty)
        // Lane V's sheets were closed, and nothing reaches lane V any more.
        #expect(await w.client.ui.dismissals == 1)
        #expect(try await graph.recoveryWordsConfirmed() == false)
        let page = await graph.page()
        #expect(page == BackendCloudSecretsPage())
        await graph.event(notice("vault", epoch: 7))
        await graph.catchUp()
        await graph.sourceChanged("api")
        #expect(await w.client.local.seenEpoch == nil)
        #expect(await w.outbox.joined.isEmpty)
    }

    @Test func theRecoveryWordsAnswerComesFromSavedPasswordsOwnStatus() async throws {
        let w = try await made(), f = try CloudAccountFixture.make()
        let graph = w.graph, account = makeAccount(f, sealing: graph)
        await account.setLastSignOutWarning { true }
        await account.setRecoveryWordsConfirmed { try await graph.recoveryWordsConfirmed() }
        await account.setSavedPasswordsKeyHeld { await graph.keyHeld() }
        try await signIn(account, f)
        await f.server.setOwnApproved(true)
        // Saved passwords are not set up: this Mac holds no key, so the sign-out guard has nothing to protect yet
        // (security review M3: decided from what this Mac holds, not from the service's list).
        #expect(await graph.keyHeld() == false)
        #expect(try await graph.recoveryWordsConfirmed() == false)
        #expect(await graph.isSealed() == false)
        // The person protects saved passwords in lane V's sheet (the fixture person keeps and confirms the words).
        await graph.perform(.setup)
        #expect(await graph.keyHeld())
        #expect(try await graph.recoveryWordsConfirmed())
        // Only now, with the key on this Mac, did the source join the sync core; once, and the migration ran first.
        #expect(await w.outbox.joined == ["api"])
        #expect(w.restores.count() == 1)
        await graph.catchUp()
        #expect(await w.outbox.joined == ["api"])
        let page = await graph.page()
        #expect(page.standing == .protected)
        #expect(BackendCloudSecretsWords.state(page) == BackendCloudSecretsWords.on)
        try await account.signOut()
        #expect(await account.state().phase == .signedOut)
        #expect(await graph.isSealed())
    }

    @Test func aPressThatDoesNotFinishIsSaidOnThePageAndTheNextGoodPressClearsIt() async throws {
        let w = try await made()
        let quiet = await w.graph.page()
        #expect(quiet.problem == nil)
        // A press that cannot finish (here: "Review" with no request named) never fails silently.
        await w.graph.perform(.openApproval)
        let failed = await w.graph.page()
        #expect(failed.problem == BackendCloudSecretsWords.stepNotFinished)
        // A step nobody pressed (start, a notice from the service) neither sets nor clears it.
        await w.graph.catchUp()
        let still = await w.graph.page()
        #expect(still.problem == BackendCloudSecretsWords.stepNotFinished)
        // The next press that gets through clears it.
        await w.graph.perform(.setup)
        let done = await w.graph.page()
        #expect(done.problem == nil)
        #expect(await w.graph.keyHeld())
    }

    @Test func withThisMacsOwnStoreKeyLostNothingJoinsAndThePageNeverSaysProtected() async throws {
        // Lane V's lean rule: sources join the sync core and are captured only while this Mac holds the confirmed
        // key AND its own stores open. A lost local key is said as it is, with nothing switched.
        let standing = WiringStanding()
        standing.set(.keyLost(["server"]))
        let w = try await made(standing: standing)
        await w.graph.perform(.setup)
        // The Cloud key is on this Mac (the sign-out guard must know), but nothing joined.
        #expect(await w.graph.keyHeld())
        #expect(await w.outbox.joined.isEmpty)
        let lost = await w.graph.page()
        let words = try #require(BackendCloudRecoveryLocalStanding.keyLost(["server"]).words(cloudKeyHere: true))
        #expect(lost.standing == .keyLost(words))
        #expect(BackendCloudSecretsWords.state(lost) == words)
        #expect(BackendCloudSecretsWords.state(lost) != BackendCloudSecretsWords.on)
        #expect(lost.cloudKeyHere)
        // It has its own state line: it is not "that step did not finish".
        #expect(lost.problem == nil)
        // No later moment joins a source either: start, an owner's change, the sync core reconnecting, Sync now.
        await w.graph.catchUp()
        await w.graph.sourceChanged("api")
        await w.graph.event(notice("hello"))
        await w.graph.syncNow()
        #expect(await w.outbox.joined.isEmpty)
        // A blocked login store is the other refusal: said with lane V's own sentence (Allow login store).
        standing.set(.blocked("The login store is locked."))
        let blocked = await w.graph.page()
        let blockedWords = try #require(BackendCloudRecoveryLocalStanding.blocked("The login store is locked.").words(cloudKeyHere: true))
        #expect(blocked.standing == .loginStoreBlocked(blockedWords))
        await w.graph.syncNow()
        #expect(await w.outbox.joined.isEmpty)
        // Once this Mac's stores open again, the next of those moments joins the source, once.
        standing.set(.ready)
        await w.graph.event(notice("hello"))
        #expect(await w.outbox.joined == ["api"])
        await w.graph.syncNow()
        #expect(await w.outbox.joined == ["api"])
        let ready = await w.graph.page()
        #expect(ready.standing == .protected)
    }
    @Test func aSourceThatFailsToSaveIsNamedAndThePageNeverSaysProtected_B2() async throws {
        // Review B-M2: a per-source save failure used to be dropped (`try?`), leaving "Protected" and a settled row.
        let failing = WiringFlag()
        failing.set(true)
        let w = try await made(stores: [WiringFailingStore(sourceId: "api", domain: .apiKey, failing: failing)])
        await w.graph.perform(.setup)
        await w.graph.syncNow()
        let page = await w.graph.page()
        #expect(page.standing == .protected)
        let named = page.gaps.contains { $0.hasPrefix("Not saved to Cloud from this Mac: API keys.") }
        #expect(named)
        #expect(BackendCloudSecretsWords.state(page) != BackendCloudSecretsWords.on)
        let level = CloudAccountSnapshot(phase: .signedIn, gate: CloudGate(features: ["cloud"], storageEntitled: true), displayName: "Fixture",
                                         coverage: [], cloudHead: CloudSequence(4), fetched: CloudSequence(4))
        let overview = try #require(BackendCloudOverviewBuilder.build(BackendCloudOverviewInput(snapshot: level, passwords: page)))
        #expect(overview.standing == .needsYou)
        #expect(overview.rows.first?.settled == false)
        // The next save that gets through clears it.
        failing.set(false)
        await w.graph.syncNow()
        let cleared = await w.graph.page()
        let stillNamed = cleared.gaps.contains { $0.hasPrefix("Not saved to Cloud from this Mac:") }
        #expect(!stillNamed)
        #expect(BackendCloudSecretsWords.state(cleared) == BackendCloudSecretsWords.on)
    }
    @Test func oneUnreadableKindDoesNotBlameOrBlockTheOtherEightAndRetriesOnlyTheMissingRegistration() async throws {
        let failing = WiringFlag(), lines = WiringSeen()
        failing.set(true)
        let healthy = BackendCloudSecretsLean.sources.filter { $0.key != "api" }.sorted { $0.key < $1.key }
        let captures = Dictionary(uniqueKeysWithValues: healthy.map { ($0.key, WiringCounter()) })
        let stores: [any CloudSecretsLogicalStore] = [WiringFailingStore(sourceId: "api", domain: .apiKey, failing: failing)]
            + healthy.map {
                WiringCountingStore(sourceId: $0.key, domain: $0.value, captures: captures[$0.key]!) as any CloudSecretsLogicalStore
            }
        let w = try await made(stores: stores, log: CloudSecretsLog { lines.add($0) })
        await w.graph.perform(.setup)
        await w.graph.syncNow()
        await w.graph.syncNow()
        #expect(Set(await w.outbox.joined) == Set(BackendCloudSecretsLean.sources.keys).subtracting(["api"]))
        // Each healthy owner was read for registration, then captured on both syncs despite the unreadable API kind.
        #expect(captures.values.allSatisfy { $0.count() >= 3 })
        let failed = await w.graph.page()
        #expect(failed.gapKinds == ["API keys"])
        #expect(failed.gaps.filter { $0.hasPrefix("Not saved to Cloud from this Mac:") }.count == 1)
        let failures = lines.all().filter { $0.contains("saving API keys did not finish") }
        #expect(failures.count == 1)
        #expect(lines.all().allSatisfy(CloudSecretsLog.safe))
        failing.set(false)
        await w.graph.syncNow()
        let joined = await w.outbox.joined
        #expect(joined.count == 9)
        #expect(Set(joined).count == 9)
        let recovered = await w.graph.page()
        #expect(recovered.gapKinds.isEmpty)
        #expect(!recovered.gaps.contains { $0.hasPrefix("Not saved to Cloud from this Mac:") })
        #expect(lines.all().filter { $0.contains("saving API keys works again") }.count == 1)
    }

    @Test func whatIsNotSavedIsNamedAndTheSignOutGuardReadsSavedPasswordsOwnFacts() async throws {
        let w = try await made()
        // Every source of this version that did not join is named in one plain sentence, on the page and in the tool.
        let expected = BackendCloudSecretsLeanCoverage.notSaved(registered: ["api"])
        #expect(w.graph.notSaved == expected)
        #expect(expected.count == 8) // eight lean sources besides "api" (project secret files joined 14 Nov, WhatsApp keys 16 Nov)
        let page = await w.graph.page()
        #expect(page.notSaved == expected)
        #expect(page.skipped.isEmpty)
        #expect(!page.cloudKeyHere)
        // The sign-out guard's two facts are lane V's own: no key here before setup, key and recovery copy after.
        #expect(await w.graph.keyHeld() == false)
        #expect(try await w.graph.recoveryWordsConfirmed() == false)
        await w.graph.perform(.setup)
        #expect(await w.graph.keyHeld())
        #expect(try await w.graph.recoveryWordsConfirmed())
        // Sealed (signed out): nothing is held and nothing is asked.
        await w.graph.seal()
        #expect(await w.graph.keyHeld() == false)
    }

    @Test func theServicesNoticeReachesSavedPasswordsAndNothingJoinsWhileLocked() async throws {
        let w = try await made()
        let before = w.changes.count()
        // Other events are the sync core's business.
        await w.graph.event(notice("changed"))
        await w.graph.event(notice("hello"))
        #expect(await w.client.local.seenEpoch == nil)
        #expect(w.changes.count() == before)
        // The service's saved-passwords notice carries its epoch to lane V and refreshes the page.
        await w.graph.event(notice("vault", epoch: 3))
        #expect(await w.client.local.seenEpoch == 3)
        #expect(w.changes.count() == before + 1)
        await w.graph.event(notice("approval"))
        #expect(w.changes.count() == before + 2)
        // No key on this Mac: no source joins the sync core and the migration is not run.
        await w.graph.catchUp()
        await w.graph.sourceChanged("api")
        #expect(await w.outbox.joined.isEmpty)
        #expect(w.restores.count() == 0)
        let page = await w.graph.page()
        #expect(page.standing == .notSetUp)
    }

    @Test func theEventTapShowsEveryNoticeAndHoldsNothingBack() async throws {
        let wire = WiringWire(events: [notice("hello"), notice("vault", epoch: 2), notice("changed"), notice("approval")])
        let sink = BackendCloudSecretsEventSink(), seen = WiringSeen()
        sink.listen { seen.add($0.type) }
        let tap = BackendCloudSecretsEventTap(upstream: wire, sink: sink)
        var forwarded: [String] = []
        for try await event in await tap.events() { forwarded.append(event.type) }
        #expect(forwarded == ["hello", "vault", "changed", "approval"])
        #expect(seen.all() == ["hello", "vault", "changed", "approval"])
        // Every other call goes to the real transport unchanged.
        _ = try await tap.devices()
        #expect(await wire.deviceCalls == 1)
        #expect(try await tap.currentDeviceId() == "fixture-device")
        await tap.stop()
        #expect(await wire.stopped)
        // Nobody listening (signed out): events still reach the sync core.
        sink.listen(nil)
        var again: [String] = []
        for try await event in await tap.events() { again.append(event.type) }
        #expect(again.count == 4)
        #expect(seen.all().count == 4)
    }

    @Test func theGateAsksTheServiceOnceUntilItsAnswerRunsOutAndClosesForGood() async throws {
        let asked = WiringCounter(), clock = CloudAccountFixtureClock()
        let gate = BackendCloudSecretsGate(fetch: {
            asked.add()
            return CloudGate(features: ["cloud"], storageEntitled: true, expiresAt: clock.now() + 300_000)
        }, now: { clock.now() })
        let policy = gate.policy(now: { clock.now() })
        try await policy.require(.secret, stage: .capture)
        try await policy.require(.secret, stage: .upload)
        #expect(asked.count() == 1)
        clock.advance(280_000)
        try await policy.require(.secret, stage: .upload)
        #expect(asked.count() == 2)
        await gate.seal()
        await #expect(throws: CloudFailure.gateClosed) { try await policy.require(.secret, stage: .capture) }
        #expect(asked.count() == 2)
    }
}

private struct WiringStore: CloudSecretsLogicalStore {
    let sourceId: String
    let inventoryRow = "I13"
    let domain: CloudSecretsDomain
    func capture() async throws -> [CloudSecretRecord] { [] }
    func validate(_ record: CloudSecretRecord) async throws {}
    func merge(_ record: CloudSecretRecord) async throws -> CloudApplyStatus { .alreadyPresent }
    func verify(_ record: CloudSecretRecord, outcome: CloudApplyStatus) async throws -> Bool { true }
}

private struct WiringCountingStore: CloudSecretsLogicalStore {
    let sourceId: String
    let inventoryRow = "I13"
    let domain: CloudSecretsDomain
    let captures: WiringCounter
    func capture() async throws -> [CloudSecretRecord] { captures.add(); return [] }
    func validate(_ record: CloudSecretRecord) async throws {}
    func merge(_ record: CloudSecretRecord) async throws -> CloudApplyStatus { .alreadyPresent }
    func verify(_ record: CloudSecretRecord, outcome: CloudApplyStatus) async throws -> Bool { true }
}

/// A source whose capture fails while `failing` is set (review B-M2).
private struct WiringFailingStore: CloudSecretsLogicalStore {
    let sourceId: String
    let inventoryRow = "I13"
    let domain: CloudSecretsDomain
    let failing: WiringFlag
    func capture() async throws -> [CloudSecretRecord] {
        if failing.get() { throw CloudFailure.unavailable }
        return []
    }
    func validate(_ record: CloudSecretRecord) async throws {}
    func merge(_ record: CloudSecretRecord) async throws -> CloudApplyStatus { .alreadyPresent }
    func verify(_ record: CloudSecretRecord, outcome: CloudApplyStatus) async throws -> Bool { true }
}

private final class WiringFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ next: Bool) { lock.withLock { value = next } }
    func get() -> Bool { lock.withLock { value } }
}

/// This Mac's own stores as lane V's local-store check would report them.
private final class WiringStanding: @unchecked Sendable {
    private let lock = NSLock()
    private var value: BackendCloudRecoveryLocalStanding = .ready
    func set(_ next: BackendCloudRecoveryLocalStanding) { lock.withLock { value = next } }
    func get() -> BackendCloudRecoveryLocalStanding { lock.withLock { value } }
}

private final class WiringCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func add() { lock.withLock { value += 1 } }
    func count() -> Int { lock.withLock { value } }
}

private final class WiringSeen: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func add(_ value: String) { lock.withLock { values.append(value) } }
    func all() -> [String] { lock.withLock { values } }
}

private final class WiringSent: @unchecked Sendable {
    struct Call: Sendable { let method: String; let path: String; let body: Data; let requestId: String }
    private let lock = NSLock()
    private var calls: [Call] = []
    func add(_ call: Call) { lock.withLock { calls.append(call) } }
    func all() -> [Call] { lock.withLock { calls } }
}

/// The sync core's side of lane V's service: records which sources joined, sends nothing.
private actor WiringOutbox: CloudOutboxPort {
    var joined: [String] = []
    func enqueue(_ operations: [CloudOperation], files: [CloudLocalBlob]) async throws -> CloudLocalReceipt {
        .init(operationIds: operations.map { $0.opId }, queued: operations.count, bytes: 0, savedAt: CloudSecretsFixtureServer.now)
    }
    func coverage(sourceId: String) async throws -> CloudCoverage { throw CloudFailure.unavailable }
    func flush() async throws -> [CloudReceipt] { [] }
    func restoreProgress() async throws -> CloudRestoreProgress { throw CloudFailure.unavailable }
    func contextReady(projectId: String) async throws -> CloudContextReady { throw CloudFailure.unavailable }
    func register(adapter: any CloudDomainAdapter) async throws {
        guard let secret = adapter as? CloudSecretsLogicalAdapter else { throw CloudFailure.unsupportedFormat }
        // The real engine reads inventory before claiming a source's domain. This can fail for one store.
        _ = try await adapter.sourceInventory()
        // As the sync core does: a second adapter for the same source is refused.
        guard !joined.contains(secret.sourceId) else { throw CloudFailure.idReused }
        joined.append(secret.sourceId)
    }
    func bootstrap(_ snapshots: [CloudDomainSnapshot]) async throws -> CloudCheckpointReceipt { throw CloudFailure.unavailable }
    func bootstrap(sources: [any CloudDomainAdapter], cut: CloudSnapshotCut) async throws -> CloudCheckpointReceipt { throw CloudFailure.unavailable }
    func pull() async throws -> [CloudImportReceipt] { [] }
    func setPaused(_ paused: Bool) async throws {}
}

/// A tool-side port that counts every flow it is asked to open.
private actor WiringPort: CloudSecretsPort {
    var mutations = 0
    func status() -> CloudSecretsStatus {
        .init(state: .ready, epoch: 1, version: CloudSequence(2), recoveryReady: true, approvedDeviceCount: 1, pendingApprovals: [])
    }
    func beginSetup() { mutations += 1 }
    func requestApproval() throws -> CloudApproval { mutations += 1; throw CloudFailure.unavailable }
    func openApproval(id: String) { mutations += 1 }
    func beginRecovery() { mutations += 1 }
    func beginReset() { mutations += 1 }
    func exportLogical(source: String) throws -> [CloudSecretRecord] { throw CloudFailure.unavailable }
    func importLogical(_ records: [CloudSecretRecord], conflictPolicy: CloudConflictPolicy) throws -> CloudVerification { throw CloudFailure.unavailable }
    func classify(relativePath: String, sourceId: String) -> CloudSecretClassification { CloudSecretsPolicy.classify(relativePath: relativePath, sourceId: sourceId) }
    func protectProjectSettings(projectId: String, rootId: String, bytes: Data) throws -> CloudSecretRecord { throw CloudFailure.unavailable }
}

/// The real transport's place under the event tap: a fixed list of events, and counts of what was passed through.
private actor WiringWire: CloudTransportPort, CloudSyncWakePort, CloudSyncRegistrationPort {
  /// MAC-NEXT-7 (5): retry back-offs on the fixture clock (100 times faster), never the real one.
  func backoff(milliseconds: Int64) async throws { try await Task.sleep(for: .milliseconds(max(1, milliseconds / 100))) }
    private let stored: [CloudEvent]
    var deviceCalls = 0
    var stopped = false
    init(events: [CloudEvent]) { stored = events }
    func capabilities() async throws -> CloudGate { throw CloudFailure.unsupportedFormat }
    func registerDevice(_ request: CloudDeviceRegistration) async throws -> CloudDeviceRegistrationReceipt { throw CloudFailure.unsupportedFormat }
    func devices() async throws -> CloudDeviceList { deviceCalls += 1; return CloudDeviceList(devices: []) }
    func state() async throws -> CloudRemoteState { throw CloudFailure.unsupportedFormat }
    func commit(_ segment: CloudSegment) async throws -> CloudReceipt { throw CloudFailure.unsupportedFormat }
    func changes(after: CloudSequence, limit: Int) async throws -> CloudChangePage { throw CloudFailure.unsupportedFormat }
    func prepareBlobs(_ items: [CloudBlobUpload]) async throws -> [CloudBlobTicket] { throw CloudFailure.unsupportedFormat }
    func finalizeBlobs(_ items: [CloudBlobFinalize]) async throws -> [CloudBlobResult] { throw CloudFailure.unsupportedFormat }
    func readBlobs(ids: [String]) async throws -> [CloudBlobDownload] { throw CloudFailure.unsupportedFormat }
    func publishCheckpoint(_ request: CloudCheckpointRequest) async throws -> CloudCheckpointReceipt { throw CloudFailure.unsupportedFormat }
    func checkpoint() async throws -> CloudCheckpoint? { nil }
    func verifyCheckpoint(id: String, inventoryDigest: String, counts: CloudCounts) async throws -> [String] { throw CloudFailure.unsupportedFormat }
    func applied(brainSeq: CloudSequence, secretsSeq: CloudSequence, checkpointId: String?) async throws -> CloudAppliedReceipt { throw CloudFailure.unsupportedFormat }
    func takeLease(_ request: CloudLeaseRequest) async throws -> CloudLease { throw CloudFailure.unsupportedFormat }
    func releaseLease(resourceId: String, generation: CloudSequence) async throws { throw CloudFailure.unsupportedFormat }
    func events() async -> AsyncThrowingStream<CloudEvent, Error> {
        let list = stored
        return AsyncThrowingStream { continuation in
            for event in list { continuation.yield(event) }
            continuation.finish()
        }
    }
    func stop() async { stopped = true }
    func onWake(_ handler: @escaping @Sendable () async -> Void) async {}
    func currentDeviceId() async throws -> String { "fixture-device" }
}
