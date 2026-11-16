import XCTest
@testable import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor
final class CloudRecoveryTests: XCTestCase {
    var assertions = 0
    override func tearDown() async throws { print("CloudRecoveryTests assertions=\(assertions)") }
    func check(_ condition: Bool, file: StaticString = #filePath, line: UInt = #line) {
        assertions += 1; XCTAssertTrue(condition, "Recovery assertion", file: file, line: line)
    }
    func unwrap<T>(_ value: T?) throws -> T { try XCTUnwrap(value) }
    func testAuditedMnemonicKnownAnswerAndChecksum() async throws {
        let codec = BackendCloudRecoveryMnemonic()
        let entropy = Data(repeating: 0, count: 32)
        let words = try await codec.words(entropy: entropy)
        // BIP-39's published 256-bit zero-entropy vector; never emitted to output.
        check(words.count == 24)
        check(words.dropLast().allSatisfy { $0 == "abandon" } && words.last == "art")
        check(try await codec.entropy(words: words) == entropy)
        var invalid = words; invalid[23] = "abandon"
        do { _ = try await codec.entropy(words: invalid); check(false) } catch { check(true) }
        do { _ = try await codec.entropy(words: Array(words.prefix(12))); check(false) } catch { check(true) }
    }
    func testSetupRequiresConfirmedWordsAndIndependentReadback() async throws {
        let server = CloudSecretsFixtureServer(), client = try await CloudSecretsFixtureClient(server: server)
        await client.ui.setConfirmation(false)
        do { try await client.coordinator.setup(); check(false) } catch { check(true) }
        check(await server.epoch == 0)
        check(await client.local.saves == 0)
        check(await client.content.state(storageClass: .secrets).available == false)
        await client.ui.setConfirmation(true)
        try await client.coordinator.setup()
        check(try await client.coordinator.status().recoveryReady)
        check(await client.local.saves == 1)
        check(await server.approved.count == 1)
        check(await client.ui.finished == true)
        let local = try unwrap(await client.local.value)
        let phrase = await client.ui.phrase
        let entropy = try await BackendCloudRecoveryMnemonic().entropy(words: phrase)
        let recovery = try CloudRecoveryKeys(entropy: entropy, sub: CloudSecretsFixtureServer.sub)
        let forbidden = [local.root, entropy, Data(phrase.joined(separator: " ").utf8), client.keys.signing.rawRepresentation,
                         client.keys.wrapping.rawRepresentation, recovery.signing.rawRepresentation]
        for body in await server.bodies {
            check(!forbidden.contains { bytes in body.range(of: bytes) != nil || body.range(of: Data(CloudSecretsCrypto.encode(bytes).utf8)) != nil })
        }
        check(await server.checkedBodies == server.bodies.count)
        check(await server.roster.count == 3)
    }
    func testUnsetServerCannotReplaceASurvivingLocalRoot() async throws {
        let server = CloudSecretsFixtureServer(), client = try await CloudSecretsFixtureClient(server: server)
        let saved = CloudSecretsLocalKey(subject: .init(issuer: CloudWire.issuer, sub: CloudSecretsFixtureServer.sub), deviceId: client.device.deviceId,
            epoch: 1, version: CloudSequence(1), root: Data(repeating: 5, count: 32),
            recoveryPublicKey: try CloudRecoveryKeys(entropy: Data(repeating: 6, count: 32), sub: CloudSecretsFixtureServer.sub).publicKey)
        try await client.local.saveVerified(saved)
        do { try await client.coordinator.setup(); check(false) } catch { check(true) }
        check(await client.local.value?.root == saved.root)
        check(await server.epoch == 0)
    }
    func testInterruptedSetupNeverUploadsRecordsOrChangesLocalStores() async throws {
        for point in ["status", "initialize", "afterInitialize", "recoveryReadback", "envelope", "possession", "localSave"] {
            let server = CloudSecretsFixtureServer(), client = try await CloudSecretsFixtureClient(server: server)
            if point == "localSave" { await client.local.rejectWrites() } else { await server.fault(point) }
            do { try await client.coordinator.setup(); check(false) } catch { check(true) }
            check(await client.local.saves == 0)
            check(await client.content.state(storageClass: .secrets).available == false)
            check(await server.roster.count == 3)
            check(await server.checkedBodies == server.bodies.count)
        }
    }
    func testApprovalBothSidesAndReplayRefusal() async throws {
        let server = CloudSecretsFixtureServer()
        let a = try await CloudSecretsFixtureClient(server: server), b = try await CloudSecretsFixtureClient(server: server)
        try await a.coordinator.setup()
        let pending = try await b.coordinator.requestApproval()
        try await a.coordinator.approve(id: pending.approvalId)
        try await b.coordinator.receiveApproval()
        check(try await b.coordinator.status().recoveryReady)
        check(await a.local.value?.root == b.local.value?.root)
        check(await server.approved.count == 2)
        check(await a.ui.displays.last?.matchingCode == b.ui.displays.last?.matchingCode)
        let answer = try unwrap(await server.capturedAnswer)
        check(try await a.control.answerApproval(answer).state == "approved")
        let replay = CloudApprovalAnswer(requestId: UUID().uuidString.lowercased(), approvalId: answer.approvalId, allow: answer.allow,
            expectedVersion: answer.expectedVersion, deviceEnvelope: answer.deviceEnvelope, canaryHash: answer.canaryHash, proof: answer.proof)
        do { _ = try await a.control.answerApproval(replay); check(false) } catch { check(true) }
        do { try await b.coordinator.receiveApproval(); check(false) } catch { check(true) }
    }
    func testSubstitutedKeySelfApprovalAndDenialAreRefused() async throws {
        let server = CloudSecretsFixtureServer()
        let a = try await CloudSecretsFixtureClient(server: server), b = try await CloudSecretsFixtureClient(server: server)
        try await a.coordinator.setup()
        let request = try await b.coordinator.requestApproval()
        let substituted = try CloudSecretsFixtureKeys().registration(b.device.deviceId)
        await a.ui.onConfirmation { await server.substitute(substituted) }
        do { try await a.coordinator.approve(id: request.approvalId); check(false) } catch { check(true) }
        check(await server.envelopes[b.device.deviceId] == nil)
        await server.substitute(nil)
        let selfRequest = try await a.coordinator.requestApproval()
        do { try await a.coordinator.approve(id: selfRequest.approvalId); check(false) } catch { check(true) }
        await a.ui.onConfirmation { }
        await a.ui.setAllow(false)
        try await a.coordinator.approve(id: request.approvalId)
        do { try await b.coordinator.receiveApproval(); check(false) } catch { check(true) }
        check(await b.local.value == nil)
    }
    func testWordsRestoreAfterKeyLossWithoutChangingRosterOrOldStores() async throws {
        let server = CloudSecretsFixtureServer(), a = try await CloudSecretsFixtureClient(server: server)
        try await a.coordinator.setup()
        let old = try unwrap(await a.local.value), phrase = await a.ui.phrase
        let content = try await a.content.seal(Data("fixture saved password".utf8), blobId: UUID().uuidString.lowercased(),
            storageClass: .secrets, purpose: .secret, epoch: old.epoch, codec: .identity)
        await a.local.loseKey()
        check(await a.content.state(storageClass: .secrets).available == false)
        check(await server.roster.count == 3)
        let replacement = try await CloudSecretsFixtureClient(server: server)
        check(replacement.device.deviceId != a.device.deviceId)
        await replacement.ui.setWords(phrase)
        try await replacement.coordinator.recover()
        check(await replacement.local.value?.root == old.root)
        check(try await replacement.content.open(content) == Data("fixture saved password".utf8))
        check(await server.roster.count == 3)
        check(await server.completedRecoveries == 1)
        let original = try unwrap(await server.capturedRecovery)
        check(try await replacement.control.recover(original).secretsApproved == true)
        let replay = CloudRecoveryCompleteRequest(requestId: UUID().uuidString.lowercased(), challengeId: original.challengeId,
            targetKeyHash: original.targetKeyHash, expectedVersion: original.expectedVersion,
            deviceEnvelope: original.deviceEnvelope, signature: original.signature)
        do { _ = try await replacement.control.recover(replay); check(false) } catch { check(true) }
    }
    func testWrongWordsFailLocallyAndExplicitResetPreservesArchive() async throws {
        let server = CloudSecretsFixtureServer(), a = try await CloudSecretsFixtureClient(server: server)
        try await a.coordinator.setup()
        let old = try unwrap(await a.local.value)
        let b = try await CloudSecretsFixtureClient(server: server)
        await b.ui.setWords(Array(repeating: "invalid-fixture-word", count: 24))
        let before = await server.checkedBodies
        do { try await b.coordinator.recover(); check(false) } catch { check(true) }
        check(await server.checkedBodies == before)
        let validWrong = try await BackendCloudRecoveryMnemonic().words(entropy: Data(repeating: 9, count: 32))
        await b.ui.setWords(validWrong)
        do { try await b.coordinator.recover(); check(false) } catch { check(true) }
        check(await server.completedRecoveries == 0)
        check(await b.local.value == nil)
        let oldRecovery = await server.recovery, oldEnvelope = await server.envelopes[a.device.deviceId]
        try await b.coordinator.reset()
        check(await server.archives == 1)
        check(await server.archivedRecovery.first == oldRecovery)
        check(await server.archivedEnvelopes.first?[a.device.deviceId] == oldEnvelope)
        check(await server.roster.count == 3)
        check(await b.local.value?.epoch == old.epoch + 1)
        check(await b.local.value?.root != old.root)
        check(await server.approved == [b.device.deviceId])
    }
}
