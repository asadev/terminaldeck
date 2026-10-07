import Foundation
import Testing
@testable import TerminalDeckBackend

@Suite("Server summary names every allowed bridge field")
struct BackendServersSummaryTests {
    @Test func portCredentialKindAndPublicIdentityCrossClocksDoNot() {
        let key = BackendServersHostKeyRecord(algorithm: "ssh-ed25519", fingerprint: "SHA256:public", firstSeenAt: 42)
        let stored = BackendServersStoredServer(id: "s1", name: "office", address: "192.0.2.11", port: 2222, username: "admin", credential: .key, hostKey: key, addedAt: 100, lastConnectedAt: 101, startIn: "/home/admin", drivesWindows: false)
        let summary = BackendServersSummary(stored).wireValue
        #expect(summary["port"].number == 2222); #expect(summary["credential"].string == "key")
        #expect(summary["hostKey"]["fingerprint"].string == "SHA256:public"); #expect(summary["drivesWindows"].bool == false)
        #expect(!summary.has("addedAt")); #expect(!summary.has("lastConnectedAt")); #expect(!summary.has("startIn"))
        #expect(!summary.has("password")); #expect(!summary.has("privateKey"))
    }
    @Test func defaultPortAndMissingIdentityStayHonest() {
        let summary = BackendServersSummary(.init(id: "s", name: "box", address: "example.com", username: "ada")).wireValue
        #expect(summary["port"].number == 22); #expect(!summary.has("hostKey"))
        #expect(summary.fields?.map(\.key).sorted() == ["address", "credential", "drivesWindows", "id", "name", "port", "username"])
    }
    @Test func realStoreRoundTripCarriesCustomPortAndNoExtraFields() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("td-server-summary-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let policy = BackendServersStoragePolicy(mayRead: true, mayWrite: true)
        let store = BackendServersStore(dataRoot: dir, policy: policy)
        _ = try store.add(.init(name: "office", address: "192.0.2.11", port: 2222, username: "admin"))
        let reloaded = BackendServersStore(dataRoot: dir, policy: policy)
        let summary = BackendServersSummary(try #require(reloaded.list().first)).wireValue
        #expect(summary["port"].number == 2222)
        #expect(summary.fields?.map(\.key).sorted() == ["address", "credential", "drivesWindows", "id", "name", "port", "username"])
    }
}
