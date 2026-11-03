import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

@Suite("Durable local recovery receipt, distinct from server summary")
struct BackendServersJournalTests {
    @Test func journalRoundTripAndServerScopedForget() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let journal = BackendServersFileJournal(storageDirectory: root, policy: .init(mayRead: true, mayWrite: true))
        #expect(!FileManager.default.fileExists(atPath: root.path))
        let record = BackendServersWayBack.repoCommit(at: 12, dir: "/srv/actual app", commit: String(repeating: "a", count: 40), managedBy: .systemd(unit: "actual-app.service"), backupPath: nil)
        try await journal.put(serverId: "one", cardId: "app", record: record)
        try await journal.put(serverId: "two", cardId: "app", record: record)
        let journalFile = await journal.file
        let raw = try NativeRPCValue.parseJSON(Data(contentsOf: journalFile))
        #expect(raw["version"].number == 1 && raw["rows"]["one app"]["kind"].string == "repo-commit")
        #expect(raw["rows"]["one app"]["backupPath"] == .null)
        let reopened = BackendServersFileJournal(storageDirectory: root, policy: .init(mayRead: true, mayWrite: true))
        #expect(try await reopened.get(serverId: "one", cardId: "app") == record)
        try await reopened.forgetServer("one")
        #expect(try await reopened.get(serverId: "one", cardId: "app") == nil)
        #expect(try await reopened.get(serverId: "two", cardId: "app") == record)
        #expect((try FileManager.default.attributesOfItem(atPath: journalFile.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
    @Test func unreadableOrFutureJournalOffersNoGuessedWayBack() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"version":2,"rows":{"one app":{"kind":"future"}}}"#.utf8).write(to: root.appendingPathComponent("server-waybacks.json"))
        let journal = BackendServersFileJournal(storageDirectory: root, policy: .init(mayRead: true, mayWrite: false))
        #expect(try await journal.get(serverId: "one", cardId: "app") == nil)
        do { try await journal.clear(serverId: "one", cardId: "app"); Issue.record("Wrote without storage permission") } catch let error as NativeRPCError { #expect(error.code == "unavailable") }
    }
    @Test func symbolicRecoveryPathIsRefusedAndTargetPreserved() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("another-owner"), bytes = Data("keep".utf8)
        try bytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("server-waybacks.json"), withDestinationURL: target)
        let journal = BackendServersFileJournal(storageDirectory: root, policy: .init(mayRead: true, mayWrite: true))
        do { _ = try await journal.get(serverId: "one", cardId: "app"); Issue.record("Followed symbolic recovery path") } catch let error as NativeRPCError { #expect(error.code == "unsafe-path") }
        #expect(try Data(contentsOf: target) == bytes)
    }
    private func temporaryRoot() -> URL { BackendServersS4RealTemp.directory().appendingPathComponent("servers-journal-" + UUID().uuidString) }
}
