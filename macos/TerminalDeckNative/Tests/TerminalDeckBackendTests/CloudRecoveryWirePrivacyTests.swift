import XCTest
@testable import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor
final class CloudRecoveryWirePrivacyTests: XCTestCase {
    func testEveryCapturedControlBodyExcludesClientSecrets() async throws {
        let server = CloudSecretsFixtureServer()
        let a = try await CloudSecretsFixtureClient(server: server)
        let b = try await CloudSecretsFixtureClient(server: server)
        let c = try await CloudSecretsFixtureClient(server: server)
        var forbidden: [Data] = [a.keys.signing.rawRepresentation, a.keys.wrapping.rawRepresentation,
            b.keys.signing.rawRepresentation, b.keys.wrapping.rawRepresentation,
            c.keys.signing.rawRepresentation, c.keys.wrapping.rawRepresentation]
        try await a.coordinator.setup()
        let firstKey = await a.local.value
        let firstWords = await a.ui.phrase
        let firstEntropy = try await BackendCloudRecoveryMnemonic().entropy(words: firstWords)
        let firstRecovery = try CloudRecoveryKeys(entropy: firstEntropy, sub: CloudSecretsFixtureServer.sub)
        forbidden += [try XCTUnwrap(firstKey).root, firstEntropy, firstRecovery.signing.rawRepresentation,
                      Data(firstWords.joined(separator: " ").utf8)]
        let pending = try await b.coordinator.requestApproval()
        try await a.coordinator.approve(id: pending.approvalId)
        try await b.coordinator.receiveApproval()
        await c.ui.setWords(firstWords)
        try await c.coordinator.recover()
        try await c.coordinator.reset()
        let newKey = await c.local.value
        let newWords = await c.ui.phrase
        let newEntropy = try await BackendCloudRecoveryMnemonic().entropy(words: newWords)
        let newRecovery = try CloudRecoveryKeys(entropy: newEntropy, sub: CloudSecretsFixtureServer.sub)
        forbidden += [try XCTUnwrap(newKey).root, newEntropy, newRecovery.signing.rawRepresentation,
                      Data(newWords.joined(separator: " ").utf8)]
        let bodies = await server.bodies
        var assertions = 0
        XCTAssertGreaterThan(bodies.count, 20); assertions += 1
        for body in bodies {
            let leaked = forbidden.contains { bytes in
                body.range(of: bytes) != nil || body.range(of: Data(CloudSecretsCrypto.encode(bytes).utf8)) != nil
            }
            XCTAssertFalse(leaked, "A client secret reached a control request")
            assertions += 1
        }
        let checked = await server.checkedBodies
        XCTAssertEqual(checked, bodies.count); assertions += 1
        print("CloudRecoveryWirePrivacyTests assertions=\(assertions)")
    }
}
