import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// U1: a saved file that does not read is never written over (its exact bytes are kept as a .damaged copy first),
/// and one bad record costs only that record.
@Suite("Damaged saved files never wipe a list")
struct DamagedSavedFilesTests {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("td-damaged-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func copies(_ file: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
            .filter { $0.hasPrefix(file.lastPathComponent + DamagedFile.marker) }.map { file.deletingLastPathComponent().appendingPathComponent($0) }
    }

    /// #16: one password typed again after the sign-ins file failed to read keeps the old file's bytes.
    @Test func serverSignInsKeepTheUnreadableFileBeforeSaving() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let cipher = BackendBrowserPasswordsCipher(available: { true }, decrypt: { _ in throw NativeRPCError(code: "decrypt", message: "rotated") },
                                                   encrypt: { text, _ in Data(text.utf8) })
        let store = BackendServersCredentials(dataRoot: dir, cipher: cipher, policy: .init(mayRead: true, mayWrite: true),
                                              keyValidator: .init(validate: { _, _ in nil }))
        let old = Data("b2xkIHNpZ24taW5z".utf8)
        try old.write(to: store.file)
        let outcome = try store.save("s1", credential: .password("pw"))
        #expect(outcome.ok && outcome.message.contains(DamagedFile.marker))
        let kept = try #require(try copies(store.file).first)
        #expect(try Data(contentsOf: kept) == old)
    }

    /// #498: a bad row is skipped, the others stay, and the next add keeps every good server.
    @Test func serverListSkipsOnlyTheBadRow() throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = BackendServersStore(dataRoot: dir, policy: .init(mayRead: true, mayWrite: true), serverAccessEnabled: false)
        let original = Data(#"{"version":1,"servers":[{"id":"a","address":"192.0.2.1","username":"ada"},{"id":"","address":"bad"}]}"#.utf8)
        try original.write(to: store.file)
        #expect(try store.list().map(\.id) == ["a"])
        #expect(store.loadProblem() != nil)
        _ = try store.add(.init(name: "b", address: "192.0.2.2", username: "bob"))
        #expect(try store.list().count == 2)
        #expect(try Data(contentsOf: #require(try copies(store.file).first)) == original)
    }

    /// #510: an unreadable Go back record is copied before the first write replaces it.
    @Test func goBackRecordsKeepTheUnreadableFile() async throws {
        let dir = BackendServersS4RealTemp.directory().appendingPathComponent("td-damaged-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let journal = BackendServersFileJournal(storageDirectory: dir, policy: .init(mayRead: true, mayWrite: true))
        let file = dir.appendingPathComponent("server-waybacks.json"), original = Data("{ half written".utf8)
        try original.write(to: file)
        try await journal.forgetServer("gone")
        #expect(try Data(contentsOf: #require(try copies(file).first)) == original)
    }

    /// #108: one project that no longer validates (33 folders) is left out; the others and the project tools still work.
    @Test func oneBadProjectLeavesTheOthers() async throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("projects.json")
        let good = PROJProject(id: "deck", name: "Deck", folders: ["/work/deck"])
        let bad = PROJProject(id: "big", name: "Big", folders: (0...32).map { "/work/f\($0)" })
        try JSONSerialization.data(withJSONObject: ["projects": [try JSONSerialization.jsonObject(with: JSONEncoder().encode(good)),
                                                                  try JSONSerialization.jsonObject(with: JSONEncoder().encode(bad))]]).write(to: file)
        let registry = BackendPROJRegistry(fileURL: file)
        #expect(try await registry.projects().map(\.id).sorted() == ["deck", PROJProjects.independentID].sorted())
        #expect(await registry.loadProblem() != nil)
        #expect(try copies(file).count == 1)
    }

    /// #115 and #18: an agent with an effort it cannot take loses that effort, not every agent; an agent that does not
    /// read is left out but still counts as saved, so it keeps its lead seat.
    @Test func taskAgentsLoadPastAnOldEffortAndKeepUnreadIDs() async throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let persistence = try BackendTaskPersistence(directory: dir, ownership: .exclusive)
        try persistence.write("task-config.json", value: .object([.init("v", .number(1)), .init("agents", .array([
            .object([.init("id", .string("lead")), .init("name", .string("Lead")), .init("effort", .string("ultracode"))]),
            .object([.init("id", .string("coder")), .init("name", .string("Coder")), .init("provider", .string("codex")), .init("effort", .string("ultracode"))]),
            .object([.init("id", .string("ghost")), .init("name", .number(7))]),
        ]))]))
        let config = try BackendTaskConfiguration(persistence: persistence)
        try await config.start()
        let agents = try await config.allAgents()
        #expect(Set(agents.compactMap { $0["id"].string }) == ["lead", "coder"])
        #expect(agents.first { $0["id"].string == "coder" }?["effort"].string != "ultracode")
        #expect(try await config.savedAgentIDs() == ["lead", "coder", "ghost"])
        #expect(try copies(persistence.file("task-config.json")).count == 1)
    }

    /// #383: a profiles file that does not parse is kept before the next profile change replaces it.
    @Test func browserProfilesKeepTheUnreadableFile() async throws {
        let dir = try scratch(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("browser-profiles.json"), original = Data("{ trunc".utf8)
        try original.write(to: file)
        let profiles = try BackendBrowserProfiles(dataRoot: dir, requireWriter: {}, deleteWebsiteData: { _ in })
        try await profiles.open()
        #expect(await profiles.damagedFilesProblem() != nil)
        _ = try await profiles.create(name: "Work")
        #expect(try Data(contentsOf: #require(try copies(file).first)) == original)
    }
}
