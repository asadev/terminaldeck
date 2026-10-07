import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor
final class BackendRemoteServeMachinesTestsStore: XCTestCase {
    private typealias F = BackendRemoteServeMachinesTestsFixture
    private func store(_ directory: URL, clock: BackendRemoteServeMachinesTestsClock = .init()) async throws -> BackendMachineStore {
        let store = BackendMachineStore(directory: directory, clock: { clock.now() })
        try await store.open(); return store
    }
    func testPublicRecordOmitsCredentialAndPrivateKey() async throws {
        let directory = try F.scratch(); defer { F.remove(directory) }
        let store = try await store(directory), input = F.secrets()
        let record = try await store.remember(name: "Studio PC", secrets: input, platform: "win32")
        XCTAssertEqual(record.name, "Studio PC"); XCTAssertEqual(record.hostID, input.hostID); XCTAssertEqual(record.platform, "win32")
        XCTAssertNotNil(record.fingerprint.range(of: #"^[A-Z2-9]{4}(-[A-Z2-9]{4}){5}$"#, options: .regularExpression))
        XCTAssertFalse(record.value.compact.contains(input.credential))
        XCTAssertFalse(record.value.compact.contains(input.guestIdentity.privateKey.base64EncodedString()))
        await store.close()
    }
    func testDialSecretsRemainAvailableOnlyThroughSecretRead() async throws {
        let directory = try F.scratch(); defer { F.remove(directory) }
        let store = try await store(directory), input = F.secrets()
        let record = try await store.remember(name: "Studio PC", secrets: input, platform: "darwin")
        let secret = try await store.secrets(record.id)
        XCTAssertEqual(secret.credential, input.credential); XCTAssertEqual(secret.guestIdentity.privateKey, input.guestIdentity.privateKey)
        XCTAssertEqual(secret.hostPublicKey, input.hostPublicKey); XCTAssertEqual(secret.relayURL, "wss://relay.example.invalid")
        await store.close()
    }
    func testRepairingSameMachineReplacesNameAndCredential() async throws {
        let directory = try F.scratch(); defer { F.remove(directory) }
        let store = try await store(directory)
        let first = F.secrets(byte: 3, credential: "aaaa.1111"), second = F.secrets(byte: 3, credential: "bbbb.2222")
        _ = try await store.remember(name: "Old name", secrets: first, platform: "darwin")
        _ = try await store.remember(name: "New name", secrets: second, platform: "darwin")
        let rows = try await store.list(), secrets = try await store.secrets(first.hostID)
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?.name, "New name"); XCTAssertEqual(secrets.credential, "bbbb.2222")
        await store.close()
    }
    func testInvalidHostIDRefused() async throws {
        let directory = try F.scratch(); defer { F.remove(directory) }
        let store = try await store(directory), good = F.secrets()
        let bad = BackendMachineSecrets(hostID: "not-a-host-id", hostPublicKey: good.hostPublicKey, relayURL: good.relayURL, credential: good.credential, guestIdentity: good.guestIdentity)
        do { _ = try await store.remember(name: "PC", secrets: bad, platform: "darwin"); XCTFail("An invalid host id was remembered") }
        catch { XCTAssertTrue(error.localizedDescription.lowercased().contains("host id"), "Source expectation: an actionable host-id refusal") }
        await store.close()
    }
    func testRemoteMachineNameStripsControls() async throws {
        let directory = try F.scratch(); defer { F.remove(directory) }
        let store = try await store(directory)
        let record = try await store.remember(name: "  \u{1b}[31mAsad's PC\u{7}  ", secrets: F.secrets(), platform: "darwin")
        XCTAssertEqual(record.name, "[31mAsad's PC"); await store.close()
    }
    func testSecretFileIs0600WithVersionOne() async throws {
        let directory = try F.scratch(); defer { F.remove(directory) }
        let store = try await store(directory)
        _ = try await store.remember(name: "PC", secrets: F.secrets(), platform: "darwin")
        let file = directory.appendingPathComponent("machines.json")
        let permissions = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("\"version\": 1")); await store.close()
    }
    func testMachineFileWrittenToSuppliedDirectory() async throws {
        let directory = try F.scratch(); defer { F.remove(directory) }
        let store = try await store(directory)
        _ = try await store.remember(name: "PC", secrets: F.secrets(), platform: "darwin")
        XCTAssertEqual(try F.readMachines(directory)["version"].number, 1); await store.close()
    }
    func testSecretReadSurvivesRestart() async throws {
        let directory = try F.scratch(); defer { F.remove(directory) }
        let first = try await store(directory), input = F.secrets()
        _ = try await first.remember(name: "PC", secrets: input, platform: "darwin"); await first.close()
        let reopened = try await store(directory)
        let rows = try await reopened.list(), secret = try await reopened.secrets(input.hostID)
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(secret.credential, input.credential); await reopened.close()
    }
    func testRowsMissingDialRequirementsDropped() async throws {
        let directory = try F.scratch(); defer { F.remove(directory) }
        let first = try await store(directory), input = F.secrets()
        _ = try await first.remember(name: "PC", secrets: input, platform: "darwin"); await first.close()
        let saved = try F.readMachines(directory), row = try XCTUnwrap(saved["machines"].elements?.first)
        let requirements = ["hostPublicKey", "relayUrl", "credential", "guestPrivateKey"]
        let broken = requirements.enumerated().map { index, field in
            row.removing(field).setting("id", .string("broken\(index)")).setting("hostId", .string(BackendRelayPacketCodec.hostID(for: Data(repeating: UInt8(index + 20), count: 32))))
        }
        try F.writeMachines(saved.setting("machines", .array([row] + broken)), directory)
        let reopened = try await store(directory); let rows = try await reopened.list()
        XCTAssertEqual(rows.map(\.id), [input.hostID]); await reopened.close()
    }
    func testDamagedMachineFileQuarantined() async throws {
        let directory = try F.scratch(); defer { F.remove(directory) }
        try Data("not json at all".utf8).write(to: directory.appendingPathComponent("machines.json"))
        let store = try await store(directory), rows = try await store.list()
        XCTAssertTrue(rows.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.contains(".corrupt-") })
        await store.close()
    }
    func testDuplicateMachineRowsKeepFirst() async throws {
        let directory = try F.scratch(); defer { F.remove(directory) }
        let first = try await store(directory)
        _ = try await first.remember(name: "First", secrets: F.secrets(), platform: "darwin"); await first.close()
        let saved = try F.readMachines(directory), row = try XCTUnwrap(saved["machines"].elements?.first)
        try F.writeMachines(saved.setting("machines", .array([row, row.setting("name", .string("Second"))])), directory)
        let reopened = try await store(directory), rows = try await reopened.list()
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?.name, "First"); await reopened.close()
    }
    func testForgetReportsPresenceAndRemovesSecret() async throws {
        let directory = try F.scratch(); defer { F.remove(directory) }
        let store = try await store(directory)
        let record = try await store.remember(name: "PC", secrets: F.secrets(), platform: "darwin")
        let removed = try await store.forget(record.id), again = try await store.forget(record.id), rows = try await store.list()
        XCTAssertTrue(removed); XCTAssertFalse(again); XCTAssertTrue(rows.isEmpty)
        do { _ = try await store.secrets(record.id); XCTFail("Forgotten secret was still readable") } catch { XCTAssertEqual((error as? NativeRPCError)?.code, "unknown-machine") }
        await store.close()
    }
    func testRenameRefusesEmptyNameAndKeepsPreviousName() async throws {
        let directory = try F.scratch(); defer { F.remove(directory) }
        let store = try await store(directory), record = try await store.remember(name: "PC", secrets: F.secrets(), platform: "darwin")
        let renamed = try await store.rename(record.id, name: "The loud one"), empty = try await store.rename(record.id, name: "   ")
        let rows = try await store.list()
        XCTAssertTrue(renamed); XCTAssertFalse(empty); XCTAssertEqual(rows.first?.name, "The loud one"); await store.close()
        // Non-string values cannot enter the typed store API; dynamic bridge validation is tested separately.
    }
    func testWelcomeUsesInjectedClockAndKeepsPreviousPlatformWhenAbsent() async throws {
        let directory = try F.scratch(); defer { F.remove(directory) }
        let clock = BackendRemoteServeMachinesTestsClock(1000), store = try await store(directory, clock: clock)
        let record = try await store.remember(name: "PC", secrets: F.secrets(), platform: "")
        let before = try await store.list(); XCTAssertNil(before.first?.lastConnectedAt)
        clock.set(5000); try await store.sawWelcome(record.id, platform: "darwin")
        let after = try await store.list(); XCTAssertEqual(after.first?.lastConnectedAt, 5000); XCTAssertEqual(after.first?.platform, "darwin")
        try await store.sawWelcome(record.id, platform: ""); let silent = try await store.list()
        XCTAssertEqual(silent.first?.platform, "darwin"); await store.close()
    }
    func testBrowserGrantDefaultsOpenAndDurableOffSwitchSurvivesRestart() async throws {
        let directory = try F.scratch(); defer { F.remove(directory) }
        let first = try await store(directory), record = try await first.remember(name: "PC", secrets: F.secrets(), platform: "darwin")
        let allowed = try await first.drivesWindows(record.id), unknown = try await first.drivesWindows("someone-else")
        XCTAssertTrue(allowed); XCTAssertFalse(unknown)
        let denied = try await first.setDrivesWindows(record.id, allowed: false); XCTAssertFalse(denied); await first.close()
        let second = try await store(directory); let stillDenied = try await second.drivesWindows(record.id)
        XCTAssertFalse(stillDenied); let restored = try await second.setDrivesWindows(record.id, allowed: true)
        XCTAssertTrue(restored); await second.close()
        let third = try await store(directory), granted = try await third.drivesWindows(record.id), absent = try await third.setDrivesWindows("someone-else", allowed: true)
        XCTAssertTrue(granted); XCTAssertFalse(absent); await third.close()
    }
    func testLegacyMissingBrowserGrantMeansAllowed() async throws {
        let directory = try F.scratch(); defer { F.remove(directory) }
        let first = try await store(directory), record = try await first.remember(name: "PC", secrets: F.secrets(), platform: "darwin"); await first.close()
        let saved = try F.readMachines(directory), row = try XCTUnwrap(saved["machines"].elements?.first)
        try F.writeMachines(saved.setting("machines", .array([row.removing("drivesWindows")])), directory)
        let reopened = try await store(directory), allowed = try await reopened.drivesWindows(record.id)
        XCTAssertTrue(allowed); await reopened.close()
    }
    func testOnlyLiteralFalseClosesBrowserGrant() async throws {
        let directory = try F.scratch(); defer { F.remove(directory) }
        let first = try await store(directory), record = try await first.remember(name: "PC", secrets: F.secrets(), platform: "darwin"); await first.close()
        let saved = try F.readMachines(directory), row = try XCTUnwrap(saved["machines"].elements?.first)
        for value in [NativeRPCValue.bool(false), .string("false"), .number(0), .null] {
            try F.writeMachines(saved.setting("machines", .array([row.setting("drivesWindows", value)])), directory)
            let reopened = try await store(directory), allowed = try await reopened.drivesWindows(record.id)
            XCTAssertEqual(allowed, value != .bool(false)); await reopened.close()
        }
    }
    func testFreshGuestIdentityPerMachine() {
        let first = BackendSealedIdentity.generate(), second = BackendSealedIdentity.generate()
        XCTAssertNotEqual(first.privateKey, second.privateKey)
    }
}
