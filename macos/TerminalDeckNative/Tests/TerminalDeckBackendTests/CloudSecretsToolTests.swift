import XCTest
@testable import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor CloudSecretsFixtureToolPort: CloudSecretsPort {
    var mutations = 0
    func status() -> CloudSecretsStatus { .init(state: .ready, epoch: 1, version: CloudSequence(2), recoveryReady: true, approvedDeviceCount: 2,
        pendingApprovals: [.init(approvalId: UUID().uuidString.lowercased(), targetDeviceId: UUID().uuidString.lowercased(), targetKeyHash: "fixture-fingerprint", challenge: "fixture-challenge", expiresAt: 1)]) }
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
@MainActor
final class CloudSecretsToolTests: XCTestCase {
    func testToolsReturnOnlySafeCountsAndRefuseWordsApprovalAndRemoval() async throws {
        let gate = CloudSecretsFixtureGate(clock: CloudSecretsFixtureServer.now), port = CloudSecretsFixtureToolPort()
        let policy = CloudSecretsPolicy(capabilities: { await gate.value() }, now: { CloudSecretsFixtureServer.now })
        let tools = BackendCloudSecretsTools(secrets: port, policy: policy, browser: { _, _ in .init(cookies: 2, passwords: 1, needsSignIn: 3, expired: 0, conflicts: 1) })
        let status = try await tools.invoke("cloud.secrets", arguments: .init(.object([.init("action", .string("status"))])))
        XCTAssertTrue(status.raw["protected"].bool == true)
        let encoded = try CloudSecretsCanonical.encode(status)
        XCTAssertTrue(encoded.range(of: Data("fixture-challenge".utf8)) == nil)
        XCTAssertTrue(encoded.range(of: Data("fixture-fingerprint".utf8)) == nil)
        for field in ["words", "rootKey", "privateKey", "allow", "signature"] {
            do {
                _ = try await tools.invoke("cloud.secrets", arguments: .init(.object([.init("action", .string("setup")), .init(field, .string("fixture"))])))
                XCTFail("Sensitive tool input was accepted")
            } catch { XCTAssertTrue(true) }
        }
        for action in ["rotate", "remove", "approve"] {
            do { _ = try await tools.invoke("cloud.secrets", arguments: .init(.object([.init("action", .string(action))]))); XCTFail("Unavailable action was exposed") }
            catch { XCTAssertTrue(true) }
        }
        let browser = try await tools.invoke("cloud.browser", arguments: .init(.object([.init("action", .string("status"))])))
        XCTAssertTrue(browser.raw["needsSignIn"].number == 3)
        XCTAssertEqual(browser.raw["note"].string, "A site that renews its sign-in can sign one of your devices out.")
        let mutations = await port.mutations
        XCTAssertTrue(mutations == 0)
        XCTAssertFalse(BackendCloudSecretsTools.contribution.actions.contains { $0.contains("remove") || $0.contains("rotate") })
        await gate.disableCloud()
        do { _ = try await tools.invoke("cloud.secrets", arguments: .init(.object([.init("action", .string("status"))]))); XCTFail("Closed gate was accepted") }
        catch { XCTAssertTrue(true) }
        print("CloudSecretsToolTests safe-output assertions=15")
    }
}
