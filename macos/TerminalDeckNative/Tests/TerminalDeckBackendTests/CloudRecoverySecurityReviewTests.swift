import XCTest
@testable import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor CloudRecoverySecurityBaseline: CloudSecretsLogicalStore {
    nonisolated let sourceId = "security-baseline"
    nonisolated let inventoryRow = "I13"
    nonisolated let domain = CloudSecretsDomain.app
    var captures = 0
    func capture() -> [CloudSecretRecord] { captures += 1; return [] }
    func validate(_ record: CloudSecretRecord) {}
    func merge(_ record: CloudSecretRecord) -> CloudApplyStatus { .applied }
    func verify(_ record: CloudSecretRecord, outcome: CloudApplyStatus) -> Bool { true }
}
private actor CloudRecoverySecurityCalls {
    var restores = 0, prepares = 0
    func restore() { restores += 1 }
    func prepare() { prepares += 1 }
}
private actor CloudRecoverySecurityValues: CloudSecretsLogicalStore {
    nonisolated let sourceId = "security-values"
    nonisolated let inventoryRow = "I13"
    nonisolated let domain = CloudSecretsDomain.app
    var merges = 0
    func capture() throws -> [CloudSecretRecord] {
        [try BackendCloudSecretsRecords.record(sourceId, "one", domain, ["value": "fixture-queued-value"])]
    }
    func validate(_ record: CloudSecretRecord) {}
    func merge(_ record: CloudSecretRecord) -> CloudApplyStatus { merges += 1; return .applied }
    func verify(_ record: CloudSecretRecord, outcome: CloudApplyStatus) -> Bool { true }
}
@MainActor
final class CloudRecoverySecurityReviewTests: XCTestCase {
    var assertions = 0
    override func tearDown() async throws { print("CloudRecoverySecurityReviewTests assertions=\(assertions)") }
    func check(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) {
        assertions += 1; XCTAssertTrue(value, "Security review assertion", file: file, line: line)
    }
    func testInitialCodeBindsFixedTargetKeysAndCannotBeVariedByServerFields() throws {
        let target = "22222222-2222-4222-8222-222222222222"
        let original = CloudApproval(approvalId: "33333333-3333-4333-8333-333333333333", targetDeviceId: target,
            targetKeyHash: String(repeating: "1", count: 64), challenge: "server-choice-one", expiresAt: 100)
        let changedServerFields = CloudApproval(approvalId: "44444444-4444-4444-8444-444444444444", targetDeviceId: target,
            targetKeyHash: original.targetKeyHash, challenge: "server-choice-two", expiresAt: 200)
        let substituted = CloudApproval(approvalId: original.approvalId, targetDeviceId: target,
            targetKeyHash: String(repeating: "2", count: 64), challenge: original.challenge, expiresAt: original.expiresAt)
        let otherTarget = CloudApproval(approvalId: original.approvalId, targetDeviceId: "55555555-5555-4555-8555-555555555555",
            targetKeyHash: original.targetKeyHash, challenge: original.challenge, expiresAt: original.expiresAt)
        let code = CloudSecretsCrypto.matchingCode(original)
        check(code.replacingOccurrences(of: " ", with: "").count == 32)
        check(code == CloudSecretsCrypto.matchingCode(changedServerFields))
        check(code != CloudSecretsCrypto.matchingCode(substituted))
        check(code != CloudSecretsCrypto.matchingCode(otherTarget))
    }
    func testSubstitutedAuthorWithServerKnownRootCannotSaveOrExportEvenIfPossessionAccepted() async throws {
        let server = CloudSecretsFixtureServer()
        let author = try await CloudSecretsFixtureClient(server: server), target = try await CloudSecretsFixtureClient(server: server)
        try await author.coordinator.setup()
        let baseline = CloudRecoverySecurityBaseline(), outbox = CloudSecretsFixtureOutbox()
        let adapter = CloudSecretsLogicalAdapter(store: baseline, content: target.content, policy: target.policy,
            deviceId: target.device.deviceId, keepConflicts: { try await outbox.enqueue($0, files: []) }, retainIncomingConflict: { await outbox.retain($0) })
        let service = try CloudSecretsService(recovery: target.coordinator, policy: target.policy, content: target.content,
            outbox: outbox, adapters: [adapter], prepareSynchronization: {}, restoreLocalStores: {})
        let pending = try await service.requestApproval()
        try await author.coordinator.approve(id: pending.approvalId)
        let authorDisplays = await author.ui.displays
        let honestDisplay = try XCTUnwrap(authorDisplays.last)
        await target.ui.matchTransferCode(honestDisplay.matchingCode)
        let attacker = CloudSecretsFixtureKeys()
        let forgedAuthor = try attacker.registration(author.device.deviceId)
        let (forged, canaryHash) = try await CloudSecretsCrypto.wrapDevice(root: Data(repeating: 81, count: 32),
            sub: CloudSecretsFixtureServer.sub, target: target.device, epoch: 1, recoveryVersion: CloudSequence(1),
            author: author.device.deviceId, sign: { try await attacker.signDevicePayload($0) })
        await server.installForgedEnvelope(forged, canaryHash: canaryHash, author: forgedAuthor)
        // The refusal must come from the second-code step itself: the joining
        // person was shown a code, it differs from the honest one, and the
        // flow ended there as a cancellation (not an earlier failure).
        do { try await service.receiveApproval(); check(false) }
        catch is CancellationError { check(true) }
        catch { check(false) }
        let prompts = await target.ui.transferPrompts
        check(prompts.count == 1)
        check(prompts.first != nil && prompts.first != honestDisplay.matchingCode)
        check(await target.local.saves == 0)
        check(await target.local.value == nil)
        check(await baseline.captures == 0)
        check(await outbox.queued.isEmpty)
        let pulls = await outbox.pulls, flushes = await outbox.flushes
        check(pulls == 0 && flushes == 0)
        // A mismatch ends the request: the server cannot re-prompt.
        do { try await service.receiveApproval(); check(false) } catch { check(true) }
        check(await target.ui.transferPrompts.count == 1)
        // The forged envelope is valid and the server accepts its canary. The
        // independent human comparison, not server possession, blocks the leak.
        let receipt = try await target.control.envelope()
        let body = try await CloudSecretsCrypto.unwrapDevice(forged, sub: CloudSecretsFixtureServer.sub,
            targetDeviceId: target.device.deviceId, epoch: 1, version: CloudSequence(1), author: forgedAuthor.deviceId,
            authorKey: forgedAuthor.signPublicJwk, keys: target.keys)
        let signature = try await target.keys.signDevicePayload(CloudSecretsProof.possession(sub: CloudSecretsFixtureServer.sub,
            deviceId: target.device.deviceId, version: receipt.version, canary: body.canary))
        let accepted = try await target.control.possession(.init(requestId: UUID().uuidString.lowercased(), expectedVersion: receipt.version,
            canary: body.canary, signature: CloudSecretsCrypto.encode(signature)))
        check(accepted.secretsApproved)
        check(await target.local.saves == 0)
        check(await baseline.captures == 0)
    }
    func testHonestSecondCodeRequiresJoiningDeviceConfirmation() async throws {
        let server = CloudSecretsFixtureServer()
        let author = try await CloudSecretsFixtureClient(server: server), target = try await CloudSecretsFixtureClient(server: server)
        try await author.coordinator.setup()
        let request = try await target.coordinator.requestApproval()
        try await author.coordinator.approve(id: request.approvalId)
        await target.ui.denyTransferConfirmation()
        do { try await target.coordinator.receiveApproval(); check(false) }
        catch is CancellationError { check(true) }
        catch { check(false) }
        check(await target.local.saves == 0)
        check(await author.ui.displays.last?.matchingCode == target.ui.transferPrompts.last)
        check(await server.approved.count == 1)
        // "They don't match" ends the request and closes the sheet; another
        // secrets-change event cannot ask again without a new request.
        let dismissals = await target.ui.dismissals
        check(dismissals >= 1)
        await target.ui.allowTransferConfirmation()
        do { try await target.coordinator.receiveApproval(); check(false) } catch { check(true) }
        check(await target.ui.transferPrompts.count == 1)
        check(await target.local.saves == 0)
    }
    func testCancelledSetupClearsWordsAndSignoutDismissesPendingApproval() async throws {
        let server = CloudSecretsFixtureServer(), client = try await CloudSecretsFixtureClient(server: server)
        let baseline = CloudRecoverySecurityBaseline(), outbox = CloudSecretsFixtureOutbox()
        let adapter = CloudSecretsLogicalAdapter(store: baseline, content: client.content, policy: client.policy,
            deviceId: client.device.deviceId, keepConflicts: { try await outbox.enqueue($0, files: []) }, retainIncomingConflict: { await outbox.retain($0) })
        let service = try CloudSecretsService(recovery: client.coordinator, policy: client.policy, content: client.content,
            outbox: outbox, adapters: [adapter], prepareSynchronization: {}, restoreLocalStores: {})
        await server.fault("cancelAfterWords")
        do { try await service.beginSetup(); check(false) } catch is CancellationError { check(true) }
        check(await client.ui.confirmationCount == 1)
        check(await client.ui.phrase.isEmpty)
        check(await client.ui.dismissals == 1)
        check(await client.local.saves == 0)
        check(await baseline.captures == 0)
        check(await outbox.queued.isEmpty)
        await server.fault(nil)
        try await service.beginSetup()
        _ = try await service.requestApproval()
        check(!(await client.ui.displays.isEmpty))
        await service.seal()
        check(await client.ui.displays.isEmpty)
        check(await client.ui.phrase.isEmpty)
        check(await client.ui.dismissals == 2)
    }
    func testResetUsesExactServerReplyWithoutEnvelopeThenReadsBackAndSaves() async throws {
        let server = CloudSecretsFixtureServer(), client = try await CloudSecretsFixtureClient(server: server)
        try await client.coordinator.setup()
        let old = await client.local.value, previousWords = await client.ui.phrase
        try await client.coordinator.reset()
        check(await client.local.saves == 2)
        check(await client.local.value?.epoch == 2)
        check(await client.local.value?.root != old?.root)
        check(await server.archives == 1)
        check(await server.approved.contains(client.device.deviceId))
        check(try await client.coordinator.status().recoveryReady)
        // The reset above already went through the server's exact reply bytes
        // (fixture handle). Also pin the literal shape asserted by
        // td-cloud-server test/secrets.test.ts (state, epoch, version "3",
        // secretsApproved false, preservedArchiveId) in secrets.ts order.
        let lastReply = await server.lastResetReply
        let reply = try XCTUnwrap(lastReply)
        check(try NativeRPCValue.parseJSON(reply)["deviceEnvelope"] == .missing)
        check(String(decoding: reply, as: UTF8.self).hasPrefix(#"{"epoch":2,"version":""#))
        let literal = Data(#"{"epoch":2,"version":"3","state":"ready","preservedArchiveId":"6f1c3a52-6a0e-4b8e-9d55-0d7c2e1b9a41","secretsApproved":false}"#.utf8)
        let decoded = try CloudWire.decode(CloudSecretsResetReceipt.self, from: literal, maximumBytes: 4096)
        check(decoded.epoch == 2 && decoded.version == CloudSequence(3) && decoded.state == .ready && !decoded.secretsApproved)
        check(decoded.preservedArchiveId == "6f1c3a52-6a0e-4b8e-9d55-0d7c2e1b9a41")
        // The type the first review rejected cannot read the server's reply.
        check((try? CloudWire.decode(CloudSecretsEnvelopeReceipt.self, from: literal, maximumBytes: 4096)) == nil)
        let current = await client.local.value
        let baseline = CloudRecoverySecurityBaseline(), outbox = CloudSecretsFixtureOutbox()
        let adapter = CloudSecretsLogicalAdapter(store: baseline, content: client.content, policy: client.policy,
            deviceId: client.device.deviceId, keepConflicts: { try await outbox.enqueue($0, files: []) }, retainIncomingConflict: { await outbox.retain($0) })
        let service = try CloudSecretsService(recovery: client.coordinator, policy: client.policy, content: client.content,
            outbox: outbox, adapters: [adapter], prepareSynchronization: {}, restoreLocalStores: {})
        await client.ui.setWords(previousWords)
        try await server.replayArchivedVault()
        do { try await service.beginRecovery(); check(false) } catch { check(true) }
        check(await client.local.saves == 2)
        check(await client.local.value?.epoch == current?.epoch)
        check(await client.local.value?.root == current?.root)
        check(await baseline.captures == 0)
        check(await outbox.queued.isEmpty)
    }
    func testSecondCodeIgnoresRenameAndAppVersionButNotKeysOrDeviceId() throws {
        let keys = CloudSecretsFixtureKeys(), other = CloudSecretsFixtureKeys()
        let id = "22222222-2222-4222-8222-222222222222"
        let local = try keys.registration(id)
        let stale = CloudDeviceRegistration(deviceId: id, label: "Name at first sign-in", platform: .macos, appVersion: "0.0.1",
            signPublicJwk: local.signPublicJwk, wrapPublicJwk: local.wrapPublicJwk)
        let otherKeys = try other.registration(id)
        let otherId = CloudDeviceRegistration(deviceId: "55555555-5555-4555-8555-555555555555", label: local.label, platform: local.platform,
            appVersion: local.appVersion, signPublicJwk: local.signPublicJwk, wrapPublicJwk: local.wrapPublicJwk)
        let subject = CloudSubject(issuer: CloudWire.issuer, sub: CloudSecretsFixtureServer.sub)
        let approval = CloudApproval(approvalId: "33333333-3333-4333-8333-333333333333", targetDeviceId: id,
            targetKeyHash: try CloudSecretsCrypto.keyHash(local), challenge: "fixture-challenge", expiresAt: 100)
        let author = try CloudSecretsFixtureKeys().registration("44444444-4444-4444-8444-444444444444")
        let envelope = CloudDeviceKeyEnvelope(v: 1, epoch: 1, targetDeviceId: id, ephemeralPublicJwk: author.wrapPublicJwk,
            salt: "c2FsdA", nonce: "bm9uY2U", ciphertext: "Y2lwaGVy", tag: "dGFn", authorDeviceId: author.deviceId, signature: "c2ln")
        func code(_ target: CloudDeviceRegistration) throws -> String {
            try CloudSecretsCrypto.transferCode(subject: subject, approval: approval, target: target, authorKey: author.signPublicJwk, envelope: envelope)
        }
        check(try code(local) == code(stale))
        check(try code(local) != code(otherKeys))
        check(try code(local) != code(otherId))
    }
    func testHonestApprovalSucceedsAfterRenameAndAppUpdate() async throws {
        let server = CloudSecretsFixtureServer()
        let author = try await CloudSecretsFixtureClient(server: server), target = try await CloudSecretsFixtureClient(server: server)
        try await author.coordinator.setup()
        let request = try await target.coordinator.requestApproval()
        // The approver reads the server's stale copy; the joining Mac uses its current one.
        try await server.relabel(target.device.deviceId, label: "Name at first sign-in", appVersion: "0.0.1")
        try await author.coordinator.approve(id: request.approvalId)
        let authorShown = await author.ui.displays.last?.matchingCode
        let shown = try XCTUnwrap(authorShown)
        await target.ui.matchTransferCode(shown)
        try await target.coordinator.receiveApproval()
        check(await target.ui.transferPrompts == [shown])
        check(await target.local.saves == 2) // saved, then marked acknowledged
        check(await target.local.value?.acknowledged == true)
        check(await target.local.value?.root == author.local.value?.root)
    }
    func testReplayedOldGenuineEnvelopeAgainstNewRequestIsRefusedAtSecondCode() async throws {
        let server = CloudSecretsFixtureServer()
        let author = try await CloudSecretsFixtureClient(server: server), target = try await CloudSecretsFixtureClient(server: server)
        try await author.coordinator.setup()
        let first = try await target.coordinator.requestApproval()
        try await author.coordinator.approve(id: first.approvalId)
        let authorShown = await author.ui.displays.last?.matchingCode
        let honest = try XCTUnwrap(authorShown)
        let installed = await server.envelopes[target.device.deviceId]
        let genuine = try XCTUnwrap(installed)
        await target.ui.denyTransferConfirmation()
        do { try await target.coordinator.receiveApproval(); check(false) } catch { check(true) }
        // New request; the server never asks the approver and replays the old,
        // genuinely signed envelope after the request (so it is not a leftover
        // this Mac saw beforehand). The person compares against the only code
        // the approving device ever showed.
        let taken = await server.removeEnvelope(target.device.deviceId)
        _ = try await target.coordinator.requestApproval()
        let replayed = try XCTUnwrap(taken)
        await server.restoreEnvelope(replayed, for: target.device.deviceId)
        check(await server.envelopes[target.device.deviceId] == genuine)
        await target.ui.allowTransferConfirmation()
        await target.ui.matchTransferCode(honest)
        do { try await target.coordinator.receiveApproval(); check(false) }
        catch is CancellationError { check(true) }
        catch { check(false) }
        let prompts = await target.ui.transferPrompts
        check(prompts.count == 2 && prompts[1] != honest)
        check(await target.local.saves == 0)
        check(await target.local.value == nil)
    }
    func testUnreadableLocalKeyNeverLetsAReplayedOlderEpochOverwrite() async throws {
        let server = CloudSecretsFixtureServer(), client = try await CloudSecretsFixtureClient(server: server)
        try await client.coordinator.setup()
        let previousWords = await client.ui.phrase
        try await client.coordinator.reset()
        let current = await client.local.value
        check(current?.epoch == 2)
        try await server.replayArchivedVault()
        await client.ui.setWords(previousWords)
        await client.local.rejectReads() // "could not read" is not "nothing there"
        do { try await client.coordinator.recover(); check(false) } catch { check(true) }
        check(await client.local.saves == 2)
        check(await client.local.value?.epoch == 2)
        check(await client.local.value?.root == current?.root)
    }
    func testLeftoverEnvelopeFromAnEarlierAttemptNeverPromptsOrSpendsRecoveryLookups() async throws {
        let server = CloudSecretsFixtureServer()
        let author = try await CloudSecretsFixtureClient(server: server), target = try await CloudSecretsFixtureClient(server: server)
        try await author.coordinator.setup()
        let first = try await target.coordinator.requestApproval()
        try await author.coordinator.approve(id: first.approvalId)
        await target.ui.denyTransferConfirmation()
        do { try await target.coordinator.receiveApproval(); check(false) } catch { check(true) }
        check(await target.ui.transferPrompts.count == 1)
        // The earlier envelope is still on the server when the person asks again.
        let second = try await target.coordinator.requestApproval()
        let lookups = await server.challenges.count
        try await target.coordinator.receiveApproval() // quiet: not this request's answer
        check(await target.ui.transferPrompts.count == 1)
        check(await server.challenges.count == lookups)
        check(await target.local.saves == 0)
        // The real answer to the new request still completes normally.
        await target.ui.allowTransferConfirmation()
        try await author.coordinator.approve(id: second.approvalId)
        let authorShown = await author.ui.displays.last?.matchingCode
        let honestCode = try XCTUnwrap(authorShown)
        await target.ui.matchTransferCode(honestCode)
        try await target.coordinator.receiveApproval()
        check(await target.ui.transferPrompts.count == 2)
        check(await target.local.saves == 2)
        check(await server.approved.contains(target.device.deviceId))
    }
    func testFailedSaveSendsNoAcknowledgmentAndTheSameRequestCompletesLater() async throws {
        let server = CloudSecretsFixtureServer()
        let author = try await CloudSecretsFixtureClient(server: server), target = try await CloudSecretsFixtureClient(server: server)
        try await author.coordinator.setup()
        let request = try await target.coordinator.requestApproval()
        try await author.coordinator.approve(id: request.approvalId)
        let authorShown = await author.ui.displays.last?.matchingCode
        let honestCode = try XCTUnwrap(authorShown)
        await target.ui.matchTransferCode(honestCode)
        await target.local.rejectWrites()
        do { try await target.coordinator.receiveApproval(); check(false) } catch { check(true) }
        check(await target.local.saves == 0)
        check(!(await server.approved.contains(target.device.deviceId))) // nothing acknowledged
        await target.local.acceptWrites()
        try await target.coordinator.receiveApproval()
        check(await target.local.saves == 2)
        check(await target.local.value?.acknowledged == true)
        check(await server.approved.contains(target.device.deviceId))
        check(await target.local.value?.root == author.local.value?.root)
    }
    func testLostAcknowledgmentAnswerIsRetriedWithoutAnotherPrompt() async throws {
        let server = CloudSecretsFixtureServer()
        let author = try await CloudSecretsFixtureClient(server: server), target = try await CloudSecretsFixtureClient(server: server)
        try await author.coordinator.setup()
        let request = try await target.coordinator.requestApproval()
        try await author.coordinator.approve(id: request.approvalId)
        let authorShown = await author.ui.displays.last?.matchingCode
        let honestCode = try XCTUnwrap(authorShown)
        await target.ui.matchTransferCode(honestCode)
        // Saved, then the acknowledgment's answer is lost (the server applied it).
        await server.fault("afterPossession")
        do { try await target.coordinator.receiveApproval(); check(false) } catch { check(true) }
        check(await target.local.saves == 1)
        check(await target.local.value?.acknowledged == false)
        check(await target.coordinator.protection() == .waitingForCloud)
        // A waiting key seals nothing: no secret is queued for a refused upload.
        check(await target.content.state(storageClass: .secrets).available == false)
        // The way out is on screen: ask again (recovery words are no longer offered on the normal path, 14 Nov).
        let waitingService = try CloudSecretsService(recovery: target.coordinator, policy: target.policy, content: target.content,
            outbox: CloudSecretsFixtureOutbox(), adapters: [], prepareSynchronization: {}, restoreLocalStores: {})
        let tools = BackendCloudSecretsTools(secrets: waitingService, policy: target.policy, browser: { _, _ in
            .init(cookies: 0, passwords: 0, needsSignIn: 0, expired: 0, conflicts: 0) })
        let shown = try await tools.invoke("cloud.secrets", arguments: .init(.object([.init("action", .string("status"))])))
        check(shown.raw["waitingForCloud"].bool == true && shown.raw["protected"].bool == false)
        check(shown.raw["message"].string == CloudSecretsProtection.waitingAdvice)
        check(shown.raw["nextSteps"].elements?.compactMap(\.string) == ["request_device"])
        check(!(try await target.coordinator.status().recoveryReady)) // never "protected" before the cloud confirms
        check(await server.approved.contains(target.device.deviceId))
        await server.fault(nil)
        // Retry: the server refuses a second acknowledgment; that means done.
        try await target.coordinator.receiveApproval()
        check(await target.ui.transferPrompts.count == 1)
        check(await target.local.saves == 2)
        check(await target.coordinator.protection() == .protected)
        check(try await target.coordinator.status().recoveryReady)
        check(await target.content.state(storageClass: .secrets).available)
        do { try await target.coordinator.receiveApproval(); check(false) } catch { check(true) } // request ended
    }
    func testKeyFromAnEarlierDeviceIdNeverBlocksTheNewDevicesSlot() async throws {
        final class Slots: @unchecked Sendable {
            let lock = NSLock(); var values: [String: Data] = [:]
            func get(_ name: String) -> Data? { lock.withLock { values[name] } }
            func set(_ name: String, _ data: Data) { lock.withLock { values[name] = data } }
        }
        let subject = CloudSubject(issuer: CloudWire.issuer, sub: CloudSecretsFixtureServer.sub)
        let earlier = "22222222-2222-4222-8222-222222222222", current = "33333333-3333-4333-8333-333333333333"
        let earlierSlot = BackendCloudSecretsProtectedStore.slot(subject: subject, deviceId: earlier)
        let currentSlot = BackendCloudSecretsProtectedStore.slot(subject: subject, deviceId: current)
        check(earlierSlot != currentSlot)
        check(BackendCloudSecretsProtectedStore.slot(subject: .init(issuer: CloudWire.issuer, sub: "44444444-4444-4444-8444-444444444444"), deviceId: current) != currentSlot)
        let key = CloudSecretsLocalKey(subject: subject, deviceId: earlier, epoch: 1, version: CloudSequence(1), root: Data(repeating: 5, count: 32),
            recoveryPublicKey: try CloudRecoveryKeys(entropy: Data(repeating: 6, count: 32), sub: CloudSecretsFixtureServer.sub).publicKey)
        let slots = Slots()
        slots.set(earlierSlot, try JSONEncoder().encode(key))
        // One slot per app (the trap): the earlier device's key is refused, never overwritten.
        let shared = BackendCloudSecretsProtectedStore(subject: subject, deviceId: current,
            read: { slots.get(earlierSlot) }, write: { slots.set(earlierSlot, $0) })
        do { _ = try await shared.read(); check(false) } catch { check(true) }
        // One slot per account and device: the new device id starts empty.
        let scoped = BackendCloudSecretsProtectedStore(subject: subject, deviceId: current,
            read: { slots.get(currentSlot) }, write: { slots.set(currentSlot, $0) })
        check(try await scoped.read() == nil)
    }
    func testLeftoverEnvelopeThroughTheServiceUnlocksNothing() async throws {
        let server = CloudSecretsFixtureServer()
        let author = try await CloudSecretsFixtureClient(server: server), target = try await CloudSecretsFixtureClient(server: server)
        try await author.coordinator.setup()
        let first = try await target.coordinator.requestApproval()
        try await author.coordinator.approve(id: first.approvalId)
        await target.ui.denyTransferConfirmation()
        do { try await target.coordinator.receiveApproval(); check(false) } catch { check(true) }
        let calls = CloudRecoverySecurityCalls(), baseline = CloudRecoverySecurityBaseline(), outbox = CloudSecretsFixtureOutbox()
        let adapter = CloudSecretsLogicalAdapter(store: baseline, content: target.content, policy: target.policy,
            deviceId: target.device.deviceId, keepConflicts: { try await outbox.enqueue($0, files: []) }, retainIncomingConflict: { await outbox.retain($0) })
        let service = try CloudSecretsService(recovery: target.coordinator, policy: target.policy, content: target.content,
            outbox: outbox, adapters: [adapter], prepareSynchronization: { await calls.prepare() }, restoreLocalStores: { await calls.restore() })
        _ = try await service.requestApproval()
        // A secrets-change event while only the earlier envelope is waiting.
        try await service.receiveApproval()
        check(await calls.restores == 0) // no local-store switch before a key is confirmed
        check(await calls.prepares == 0)
        check(await baseline.captures == 0)
        let pulls = await outbox.pulls, flushes = await outbox.flushes
        check(pulls == 0 && flushes == 0)
        check(await target.local.saves == 0)
    }
    func testSignOutAndInUploadsWhatTheEarlierDeviceIdOnlyQueued() async throws {
        let server = CloudSecretsFixtureServer(), client = try await CloudSecretsFixtureClient(server: server)
        try await client.coordinator.setup()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-known-" + UUID().uuidString.lowercased())
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let known = BackendCloudSecretsKnown(dataRoot: root, requireWriter: {})
        let journal = CloudSecretsFixtureJournal(), store = CloudRecoverySecurityValues()
        let cut = CloudSnapshotCut(snapshotId: UUID().uuidString.lowercased(), at: 1, watermarks: [:])
        let earlier = CloudSecretsLogicalAdapter(store: store, content: client.content, policy: client.policy, deviceId: client.device.deviceId,
            keepConflicts: { try await journal.enqueue($0) }, retainIncomingConflict: { await journal.retain($0) }, known: known)
        await earlier.useOutbox(queue: "fixture-queue")
        let queued = try await earlier.changedSnapshot(cut: cut)
        let receipt = try await journal.enqueue(queued.operations)
        try await earlier.markPublished(queued, receipt: receipt) // queued, never sent
        // Same account, root and epoch; a new device id after signing in again.
        let saved = await client.local.value
        let key = try XCTUnwrap(saved)
        let newDevice = UUID().uuidString.lowercased(), local = CloudSecretsFixtureLocal()
        try await local.saveVerified(CloudSecretsLocalKey(subject: key.subject, deviceId: newDevice, epoch: key.epoch, version: key.version,
                                                          root: key.root, recoveryPublicKey: key.recoveryPublicKey))
        let content = CloudSecretsContent(subject: key.subject, deviceId: newDevice, local: local, policy: client.policy)
        let later = CloudSecretsLogicalAdapter(store: store, content: content, policy: client.policy, deviceId: newDevice,
            keepConflicts: { try await journal.enqueue($0) }, retainIncomingConflict: { await journal.retain($0) }, known: known)
        await later.useOutbox(queue: "fixture-queue")
        check(try await later.changedSnapshot(cut: cut).operations.count == queued.operations.count)
        // The same device id after a restart: still waiting for the cloud's
        // receipt, so it is not queued again (and not marked); confirmed, skipped.
        func restartedAdapter() async -> CloudSecretsLogicalAdapter {
            let made = CloudSecretsLogicalAdapter(store: store, content: client.content, policy: client.policy, deviceId: client.device.deviceId,
                keepConflicts: { try await journal.enqueue($0) }, retainIncomingConflict: { await journal.retain($0) }, known: known)
            await made.useOutbox(queue: "fixture-queue")
            return made
        }
        check(try await restartedAdapter().changedSnapshot(cut: cut).operations.isEmpty)
        await earlier.confirmed(operationIds: Set(queued.operations.map(\.opId)))
        check(try await restartedAdapter().changedSnapshot(cut: cut).operations.isEmpty)
    }
    func testWordsStayVisibleWhenTheSetupTaskIsReallyCancelledAfterTheServerAccepted() async throws {
        let server = CloudSecretsFixtureServer(), client = try await CloudSecretsFixtureClient(server: server)
        await server.holdNextPossession()
        let task = Task { try await client.coordinator.setup() }
        while !(await server.holding) { await Task.yield() } // the server already accepted the vault
        task.cancel() // a real cancellation of the running task
        await server.releasePossession()
        do { try await task.value; check(false) } catch is CancellationError { check(true) } catch { check(false) }
        check(await server.epoch == 1)
        check(await client.local.saves == 0)
        check(await client.ui.dismissals == 0) // the words were not wiped
        check(await client.ui.finished == false)
        check(!(await client.ui.phrase.isEmpty))
    }
    func testSavedButUnconfirmedMacFinishesFromTheWaitingEnvelopeWithoutANewRequest() async throws {
        let server = CloudSecretsFixtureServer()
        let author = try await CloudSecretsFixtureClient(server: server), target = try await CloudSecretsFixtureClient(server: server)
        try await author.coordinator.setup()
        let request = try await target.coordinator.requestApproval()
        try await author.coordinator.approve(id: request.approvalId)
        let authorShown = await author.ui.displays.last?.matchingCode
        let honestCode = try XCTUnwrap(authorShown)
        await target.ui.matchTransferCode(honestCode)
        await server.fault("possession") // saved here, acknowledgement never reached Cloud
        do { try await target.coordinator.receiveApproval(); check(false) } catch { check(true) }
        check(await target.coordinator.protection() == .waitingForCloud)
        check(!(await server.approved.contains(target.device.deviceId)))
        await server.fault(nil)
        await target.coordinator.dismissPresentation() // the app quit: the request is gone
        check(try await target.coordinator.confirmPendingAcknowledgement())
        check(await server.approved.contains(target.device.deviceId))
        check(await target.coordinator.protection() == .protected)
        check(await target.ui.transferPrompts.count == 1) // no new request, no new prompt
    }
    /// Two approved Macs holding the same key.
    func twoHolders() async throws -> (CloudSecretsFixtureServer, CloudSecretsFixtureClient, CloudSecretsFixtureClient) {
        let server = CloudSecretsFixtureServer()
        let author = try await CloudSecretsFixtureClient(server: server), target = try await CloudSecretsFixtureClient(server: server)
        try await author.coordinator.setup()
        let request = try await target.coordinator.requestApproval()
        try await author.coordinator.approve(id: request.approvalId)
        let authorShown = await author.ui.displays.last?.matchingCode
        let honestCode = try XCTUnwrap(authorShown)
        await target.ui.matchTransferCode(honestCode)
        try await target.coordinator.receiveApproval()
        return (server, author, target)
    }
    func testSignOutNeverDeletesThisMacsKeySlot() async throws {
        // Two approved Macs, and a lone holder: signing out (sealing) keeps
        // every slot, whatever the device list says.
        let (_, author, target) = try await twoHolders()
        let server = CloudSecretsFixtureServer(), only = try await CloudSecretsFixtureClient(server: server)
        try await only.coordinator.setup()
        for client in [author, target, only] {
            let before = await client.local.value
            let outbox = CloudSecretsFixtureOutbox()
            let service = try CloudSecretsService(recovery: client.coordinator, policy: client.policy, content: client.content,
                outbox: outbox, adapters: [], prepareSynchronization: {}, restoreLocalStores: {})
            await service.seal()
            let after = await client.local.value
            check(after != nil && after?.root == before?.root && after?.epoch == before?.epoch)
        }
    }
    func testRecordsFromBeforeStartNewSavedPasswordsAreSkippedNotFatal() async throws {
        let server = CloudSecretsFixtureServer(), client = try await CloudSecretsFixtureClient(server: server)
        try await client.coordinator.setup()
        let store = CloudRecoverySecurityValues(), journal = CloudSecretsFixtureJournal()
        let adapter = CloudSecretsLogicalAdapter(store: store, content: client.content, policy: client.policy, deviceId: client.device.deviceId,
            keepConflicts: { try await journal.enqueue($0) }, retainIncomingConflict: { await journal.retain($0) })
        let rows = try await store.capture()
        let old = try await adapter.snapshot(records: rows, cut: .init(snapshotId: UUID().uuidString.lowercased(), at: 1, watermarks: [:]))
        check(old.operations.count == 1)
        try await client.coordinator.reset() // a new epoch; the old item can never be opened in it
        let preparation = try await adapter.validateIncoming(old.operations, files: [])
        let receipt = try await adapter.applyPrepared(preparation, origin: .init(deviceId: client.device.deviceId, sequence: CloudSequence(1)))
        // One FINAL row with its reason per item (round 8): the sync engine
        // neither stalls nor parks it, and later versions keep flowing.
        check(receipt.counts.blocked == 0 && receipt.counts.records == 0)
        check(receipt.results == [CloudItemResult(entityId: old.operations[0].entityId, status: .alreadyPresent, reason: CloudSecretsLogicalAdapter.olderEpochWords)])
        check(await adapter.notices() == [CloudSecretsLogicalAdapter.olderEpochWords: 1])
        let verification = try await adapter.verify(receipt)
        check(verification.verified && verification.reasons == [CloudSecretsLogicalAdapter.olderEpochWords])
        check(await store.merges == 0)
    }
    func testNothingIsSealedWhileTheCloudsEpochIsNewerThanThisMacsKey() async throws {
        let server = CloudSecretsFixtureServer(), client = try await CloudSecretsFixtureClient(server: server)
        try await client.coordinator.setup()
        let store = CloudRecoverySecurityValues(), outbox = CloudSecretsFixtureOutbox()
        let adapter = CloudSecretsLogicalAdapter(store: store, content: client.content, policy: client.policy, deviceId: client.device.deviceId,
            keepConflicts: { try await outbox.enqueue($0, files: []) }, retainIncomingConflict: { await outbox.retain($0) })
        let service = try CloudSecretsService(recovery: client.coordinator, policy: client.policy, content: client.content,
            outbox: outbox, adapters: [adapter], prepareSynchronization: {}, restoreLocalStores: {})
        await service.noteCloudEpoch(2) // "Start new saved passwords" on another device
        let state = await client.content.state(storageClass: .secrets)
        check(!state.available && (state.reason ?? "").contains("started anew"))
        do { _ = try await service.captureChanged(sourceId: store.sourceId); check(false) } catch { check(true) }
        check(await outbox.queued.isEmpty)
        check(state.epoch == 2) // the cloud's current epoch, for the sync core to retire older items
        // After a restart (a new content port, nobody has asked the cloud yet)
        // the newer epoch is still remembered from the sealed key slot.
        let restarted = CloudSecretsContent(subject: CloudSubject(issuer: CloudWire.issuer, sub: CloudSecretsFixtureServer.sub),
            deviceId: client.device.deviceId, local: client.local, policy: client.policy)
        let afterStart = await restarted.state(storageClass: .secrets)
        check(!afterStart.available && afterStart.epoch == 2)
        check(await client.local.seenEpoch == 2) // its own item, not the key item
    }
    func testAJoiningMacKeepsItsOlderEpochKeyAsAnArchiveKey() async throws {
        let (server, author, target) = try await twoHolders()
        let oldRoot = await target.local.value?.root
        try await author.coordinator.reset() // "Start new saved passwords" on the other Mac
        let newWords = await author.ui.phrase
        await target.ui.setWords(newWords)
        try await target.coordinator.recover() // joins the new epoch with the new words
        let current = await target.local.value, archived = await target.local.archives[1]
        check(current?.epoch == 2 && current?.root != oldRoot)
        check(archived?.epoch == 1 && archived?.root == oldRoot) // never discarded
        check(await target.content.state(storageClass: .secrets).epoch == 2) // seals only with the current key
        check(await server.epoch == 2)
    }
    func testSignOutAfterTheServerAcceptedTheVaultKeepsTheWords() async throws {
        let server = CloudSecretsFixtureServer(), client = try await CloudSecretsFixtureClient(server: server)
        let service = try CloudSecretsService(recovery: client.coordinator, policy: client.policy, content: client.content,
            outbox: CloudSecretsFixtureOutbox(), adapters: [], prepareSynchronization: {}, restoreLocalStores: {})
        await server.holdNextPossession()
        let task = Task { try await client.coordinator.setup() }
        while !(await server.holding) { await Task.yield() } // the vault exists, nothing saved here yet
        await service.seal() // sign-out or gate-off now
        check(await client.ui.dismissals == 0) // the words were not wiped
        check(!(await client.ui.phrase.isEmpty))
        check(await client.ui.finished == false)
        await server.releasePossession()
        _ = try? await task.value
    }
    func testRecordingTheCloudsEpochNeverRewritesTheKeyItem() async throws {
        let server = CloudSecretsFixtureServer(), client = try await CloudSecretsFixtureClient(server: server)
        try await client.coordinator.setup()
        let savesBefore = await client.local.saves
        // A status refresh reports a newer epoch while this Mac is joining it:
        // the note and the person-checked save of the new key overlap.
        await client.content.noteCloudEpoch(2)
        let held = await client.local.value
        let current = try XCTUnwrap(held)
        let joined = CloudSecretsLocalKey(subject: current.subject, deviceId: current.deviceId, epoch: 2, version: CloudSequence(2),
                                          root: Data(repeating: 77, count: 32), recoveryPublicKey: current.recoveryPublicKey)
        try await client.local.saveVerified(joined) // the approval/words path
        await client.content.noteCloudEpoch(2) // a later refresh
        let after = await client.local.value
        check(after?.epoch == 2 && after?.root == joined.root) // the new key stays
        check(await client.local.saves == savesBefore + 1) // only the person-checked save wrote the key item
        check(await client.local.seenEpoch == 2)
        check(await client.content.state(storageClass: .secrets).available)
    }
    func testAFalseNewerEpochReportClearsWhenTheCloudReportsThisKeysEpochAgain() async throws {
        let server = CloudSecretsFixtureServer(), client = try await CloudSecretsFixtureClient(server: server)
        try await client.coordinator.setup()
        await client.content.noteCloudEpoch(5) // one false report
        check(!(await client.content.state(storageClass: .secrets).available))
        await client.content.noteCloudEpoch(1) // the cloud reports this key's own epoch again
        check(await client.content.state(storageClass: .secrets).available)
        check(await client.local.seenEpoch == 1) // and a restart remembers the corrected value
    }
}
