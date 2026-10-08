import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

private struct INT2AGSFixtureCipher: BackendAccountVaultCipher {
    func available() -> Bool { true }
    func prepareForWrites(existingVault: Bool) throws {}
    func encrypt(_ text: String, existingVault: Bool) throws -> Data { Data(("fixture:" + text).utf8) }
    func decrypt(_ blob: Data) throws -> String { String(decoding: blob.dropFirst(8), as: UTF8.self) }
}
private actor INT2AGSChangeReader {
    var configuration: BackendTaskConfiguration?
    var id: String?
    var model: String?
    func bind(_ config: BackendTaskConfiguration, id: String) { configuration = config; self.id = id }
    func changed() async {
        guard let configuration, let id else { return }
        model = try? await configuration.agent(id)?["model"].string
    }
}
@Suite("INT2 canonical agent settings integration")
struct INT2AGSIntegrationTests {
    private func fixture(changed: @escaping @Sendable () async -> Void = {}) async throws -> (BackendTaskConfiguration, BackendAGSStore, String) {
        let persistence = try BackendTaskPersistence(directory: FileManager.default.temporaryDirectory.appendingPathComponent("INT2AGS-" + UUID().uuidString), ownership: .memory)
        let config = try BackendTaskConfiguration(persistence: persistence, changed: changed)
        let store = BackendAGSStore(persistence: persistence, cipher: INT2AGSFixtureCipher())
        try await config.start(); try await store.start(); try await config.bindAGS(store)
        let profile = try await config.saveAgent(.object([.init("id", .string("fixture-agent")), .init("name", .string("Fixture agent")), .init("provider", .string("claude"))]))
        return (config, store, try profile["id"].requireString("agent"))
    }
    @Test func combinedPublicationReleasesReadersBeforeChangeCallback() async throws {
        let reader = INT2AGSChangeReader()
        let (config, store, id) = try await fixture(changed: { await reader.changed() })
        await reader.bind(config, id: id)
        let revision = try await store.currentRevision()
        _ = try await config.saveSettingsForProfile(id, settings: .init(model: "sonnet"), expectedRevision: revision)
        #expect(await reader.model == "sonnet")
        #expect(try await config.agent(id)?["model"].string == "sonnet")
        #expect(try await store.profile(id)?.model == "sonnet")
        #expect(try await store.currentRevision() == revision + 1)
        try await config.stop()
    }
    @Test func staleRevisionLeavesBothCanonicalAndPrivateRecordsUnchanged() async throws {
        let (config, store, id) = try await fixture()
        let before = try await config.agent(id), revision = try await store.currentRevision()
        let privateBefore = try await store.profile(id)
        do {
            _ = try await config.saveSettingsForProfile(id, settings: .init(model: "sonnet", environment: ["FIXTURE_VALUE": "private"]), expectedRevision: revision + 1)
            Issue.record("A stale combined save succeeded")
        } catch {}
        #expect(try await config.agent(id) == before)
        #expect(try await store.profile(id) == privateBefore)
        #expect(try await store.currentRevision() == revision)
        try await config.stop()
    }
    @Test func newProfileWithoutCallerChosenIdentifierPublishesBothRecords() async throws {
        let (config, store, _) = try await fixture()
        var draft = AgentDraft(nil)
        draft.name = "Another fixture agent"; draft.provider = "claude"
        #expect(draft.id.isEmpty)
        let submitted = try AgentForm.payload(draft, agents: []).get()
        let profile = try await config.saveAgent(.object([.init("id", .string(submitted.id)),
            .init("name", .string(submitted.name)), .init("provider", .string(submitted.provider ?? "claude"))]))
        let id = try profile["id"].requireString("generated agent id", nonempty: true)
        #expect(try await config.agent(id) != nil)
        #expect(try await store.profile(id)?.provider == "claude")
        try await config.stop()
    }
    @Test func enabledAlertHookRefusesWithoutAnActualProducer() async throws {
        let persistence = try BackendTaskPersistence(directory: FileManager.default.temporaryDirectory.appendingPathComponent("INT2AGS-" + UUID().uuidString), ownership: .memory)
        let store = BackendAGSStore(persistence: persistence, cipher: INT2AGSFixtureCipher(), supportedAppEvents: ["session.started", "task.finished", "receiver.event"])
        try await store.start()
        let revision = try await store.currentRevision()
        do {
            try await store.saveDefaults(.init(hooks: [.init(event: "alert.raised", command: "/usr/bin/true", enabled: true)]), expectedRevision: revision)
            Issue.record("A hook with no producer was enabled")
        } catch {}
        #expect(try await store.defaults().hooks.isEmpty)
        #expect(try await store.currentRevision() == revision)
    }
}
