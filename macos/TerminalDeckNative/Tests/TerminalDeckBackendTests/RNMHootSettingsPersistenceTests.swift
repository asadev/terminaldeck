import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

struct RNMHootSettingsPersistenceTests {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RNM-settings-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func atomicWriteBackSurvivesFreshStoreAndCarriesEnvelopeFields() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        let initial: NativeRPCValue = .object([.init("version", .number(1)), .init("customEnvelope", .string("kept")),
            .init("values", .object([.init("copilot.home", .string(root.appendingPathComponent("copilot").path)),
                .init("copilot.interactive", .bool(false)), .init("appearance.theme", .string("light"))]))])
        try initial.encodedJSON().write(to: file)
        let store = BackendAppSettingsStore(userData: root, writable: true)
        let plan = try await store.migrateRNMHootSettings(legacyDefaultHome: root.appendingPathComponent("copilot").path,
            hootDefaultHome: root.appendingPathComponent("hoot").path)
        #expect(plan.copiedKeys == ["hoot.home", "hoot.interactive"])
        let disk = try NativeRPCValue.parseJSON(Data(contentsOf: file))
        #expect(disk["customEnvelope"] == .string("kept"))
        #expect(disk["values"] == plan.values)
        let reopened = BackendAppSettingsStore(userData: root, writable: true)
        #expect(await reopened.value("hoot.interactive") == .bool(false))
        #expect(!((try await reopened.migrateRNMHootSettings()).needsWrite))
        #expect(try NativeRPCValue.parseJSON(Data(contentsOf: file)) == disk)
    }

    @Test func readOnlyFailureDoesNotPublishUncommittedNewKeysOrChangeDisk() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        let initial: NativeRPCValue = .object([.init("version", .number(1)),
            .init("values", .object([.init("copilot.interactive", .bool(true))]))])
        let bytes = try initial.encodedJSON()
        try bytes.write(to: file)
        let store = BackendAppSettingsStore(userData: root)
        do {
            _ = try await store.migrateRNMHootSettings()
            Issue.record("A read-only owner must refuse settings migration")
        } catch let error as NativeRPCError { #expect(error.code == "unavailable") }
        #expect(await store.value("hoot.interactive") == .missing)
        #expect(await store.value("copilot.interactive") == .bool(true))
        #expect(try Data(contentsOf: file) == bytes)
        let writer = BackendAppSettingsStore(userData: root, writable: true)
        #expect((try await writer.migrateRNMHootSettings()).needsWrite)
        #expect(await writer.value("hoot.interactive") == .bool(true))
    }

    @Test func conflictsAndResetRemainSettledAcrossRestarts() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BackendAppSettingsStore(userData: root, writable: true)
        _ = try await store.patch(.object([.init("hoot.interactive", .bool(false)),
            .init("copilot.interactive", .bool(true))]))
        #expect((try await store.migrateRNMHootSettings()).preservedKeys == ["hoot.interactive"])
        _ = try await store.patch(.object([.init("hoot.interactive", .null)]))
        let reopened = BackendAppSettingsStore(userData: root, writable: true)
        #expect(!((try await reopened.migrateRNMHootSettings()).needsWrite))
        #expect(await reopened.value("hoot.interactive") == .missing)
        #expect(await reopened.value("copilot.interactive") == .missing)
    }

    @Test func failedDiskCommitRetainsLegacyCacheAndCanRetry() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        let initial: NativeRPCValue = .object([.init("version", .number(1)),
            .init("values", .object([.init("copilot.interactive", .bool(false))]))])
        let bytes = try initial.encodedJSON()
        try bytes.write(to: file)
        let store = BackendAppSettingsStore(userData: root, writable: true)
        #expect(await store.value("copilot.interactive") == .bool(false))
        // Replace only this fixture's already-loaded file with a directory.
        // Atomic settings replacement must fail; cached values must not change.
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        do {
            _ = try await store.migrateRNMHootSettings()
            Issue.record("Replacing a directory with settings JSON must fail")
        } catch { }
        #expect(await store.value("hoot.interactive") == .missing)
        #expect(await store.value("copilot.interactive") == .bool(false))
        try FileManager.default.removeItem(at: file)
        try bytes.write(to: file)
        #expect((try await store.migrateRNMHootSettings()).needsWrite)
        #expect(await store.value("hoot.interactive") == .bool(false))
        #expect(await store.value("copilot.interactive") == .missing)
    }

    @Test func unsupportedV2RefusesBeforeReplacementAndKeepsOriginalAcrossRestart() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("settings.json")
        let original: NativeRPCValue = .object([.init("version", .number(2)), .init("futureEnvelope", .string("preserved")),
            .init("values", .object([.init("copilot.interactive", .bool(false)), .init("custom.future", .string("kept"))]))])
        let bytes = try original.encodedJSON()
        try bytes.write(to: file)
        let store = BackendAppSettingsStore(userData: root, writable: true)
        let snapshot = await store.get()
        do {
            _ = try await store.migrateRNMHootSettings()
            Issue.record("Unsupported settings must be refused before backup or replacement")
        } catch let failure as NativeRPCError { #expect(failure.code == "hoot-migration") }
        #expect(await store.get() == snapshot)
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["settings.json"])
        // A fresh owner still sees the same future-version source and refuses;
        // no missing canonical file can turn it into first-launch defaults.
        let reopened = BackendAppSettingsStore(userData: root, writable: true)
        #expect(await reopened.value("copilot.interactive") == .bool(false))
        #expect(await reopened.value("custom.future") == .string("kept"))
        do {
            _ = try await reopened.migrateRNMHootSettings()
            Issue.record("Restart must retain the unsupported-source refusal")
        } catch let failure as NativeRPCError { #expect(failure.code == "hoot-migration") }
        #expect(await reopened.value("hoot.interactive") == .missing)
        #expect(try Data(contentsOf: file) == bytes)
    }
}
