import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// AM8 / S18: a memory store that never activated Cloud gains no Cloud table, trigger, journal row, folder or file.
@Suite("Cloud gate off — memory writes stay exactly local")
struct CloudGateInertTests {
    @Test func ordinaryMemoryWritesCreateNoCloudStateWhileTheGateIsOff_S18() async throws {
        let f = try CloudBrainMemoryFixture()
        try await f.seed()
        try f.write("hoot/notes/b.md", "---\nid: n-fixture-b\ndate: 1970-01-01T00:16:40Z\nseat: hoot\ntype: note\n---\n# Note\nAnother decision.\n")
        _ = try await f.store.reindex()
        _ = try await f.store.appendDiary(.init(stamp: .hoot, role: .user, text: "after", externalID: "five"))
        #expect(try await f.store.cloudFixtureSchemaNames().isEmpty)
        #expect(!(await f.store.cloudMemoryEnabled))
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".cloud-local").path))
        #expect(!FileManager.default.fileExists(atPath: f.base.appendingPathComponent("Data/cloud").path))
        #expect(!FileManager.default.fileExists(atPath: f.stateRoot.path))
        #expect(try await f.store.cloudFixtureTempTriggers().isEmpty)
        // The rewind fence is inert, and the backup retention path is unchanged without a capture marker.
        #expect(try await f.store.cloudRewindBelongsToAnotherStore(7) == false)
        #expect(try await f.store.cloudFixtureSchemaNames().isEmpty)
        await f.close()
    }
    @Test func signingOutStopsMemoryCaptureAndLeavesNothingInMemoryDb_S18() async throws {
        let f = try CloudBrainMemoryFixture(); try await f.seed()
        try await f.activate("I02")
        #expect(try await f.store.cloudFixtureTempTriggers().contains { $0.hasPrefix("cloud_memory_diary_") })
        #expect(try await f.store.cloudFixtureMainCloudObjects().isEmpty)
        try await f.store.cloudSuspendCapture()
        #expect(!(await f.store.cloudMemoryEnabled))
        #expect(try await f.store.cloudFixtureTempTriggers().isEmpty)
        #expect(try await f.store.cloudFixtureMainCloudObjects().isEmpty)
        // A write while signed out is plain local memory: nothing is journaled anywhere.
        _ = try await f.store.appendDiary(.init(stamp: .hoot, role: .user, text: "while signed out", externalID: "six"))
        #expect(try await f.store.cloudFixtureMainCloudObjects().isEmpty)
        // The launch pointer is gone and the account is marked interrupted, so its next activation runs the reconcile.
        #expect(!FileManager.default.fileExists(atPath: f.base.appendingPathComponent("Data/cloud/memory-capture.json").path))
        #expect(FileManager.default.fileExists(atPath: f.stateRoot.appendingPathComponent("capture-gap").path))
        try await f.capture()
        #expect(try await f.store.cloudFixtureJournalRows("I02").isEmpty)
        await f.close()
    }
    @Test func aSignedOutFolderNeverResumesCaptureAtLaunchEvenWithAStalePointer_AM8() async throws {
        let f = try CloudBrainMemoryFixture()
        let cloud = f.base.appendingPathComponent("Data/cloud", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        let pointer = cloud.appendingPathComponent(DeckMemoryStore.cloudCaptureFile)
        try Data(#"{"stateRoot":"\#(f.stateRoot.path)"}"#.utf8).write(to: pointer)
        try Data().write(to: cloud.appendingPathComponent("signed-out"))
        try await f.store.start()
        #expect(!FileManager.default.fileExists(atPath: pointer.path))
        #expect(try await f.store.cloudFixtureTempTriggers().isEmpty)
        #expect(!(await f.store.cloudMemoryEnabled))
        #expect(!FileManager.default.fileExists(atPath: f.stateRoot.path))
        await f.close()
    }
    @Test func aCapturePointerAloneNeverSwitchesCaptureOn_M2() async throws {
        let f = try CloudBrainMemoryFixture()
        let cloud = f.base.appendingPathComponent("Data/cloud", isDirectory: true)
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        try Data(#"{"stateRoot":"\#(f.stateRoot.path)"}"#.utf8).write(to: cloud.appendingPathComponent(DeckMemoryStore.cloudCaptureFile))
        try await f.store.start()
        #expect(!(await f.store.cloudMemoryEnabled))
        #expect(try await f.store.cloudFixtureTempTriggers().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.stateRoot.path))
        _ = try await f.store.appendDiary(.init(stamp: .hoot, role: .user, text: "local only", externalID: "m2"))
        #expect(try await f.store.cloudFixtureSchemaNames().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: f.stateRoot.path))
        await f.close()
    }
    @Test func signedOutAccountRegistersNoTools_S18() async throws {
        let f = try CloudAccountFixture.make()
        #expect(try await BackendCloudAccountTools.registrations(service: f.account, now: f.clock.now(), signin: { _ in }).isEmpty)
    }
    @Test func theOneThingThatRunsWithNobodySignedInCostsNoFileKeychainOrNetworkWork_releaseCondition() throws {
        // With nobody signed in ONE piece of this lane's code still runs: the Mac reach input path notes the time
        // of every event it posts (a phone controlling this Mac), because a trust press must be able to tell. What
        // it does per event: one lock and one comparison for the in-process mark, and at most ten times a second
        // one message to the system's notify service for the system-wide record. Read from the file itself: it
        // has no file, Keychain, settings or network call at all.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/TerminalDeckBackend/BackendRemoteInputGuard.swift"), encoding: .utf8)
        for forbidden in ["FileManager", "FileHandle", "write(to", "SecItem", "UserDefaults", "URLSession", "URLRequest", "sqlite"] {
            #expect(!source.contains(forbidden), "\(forbidden)")
        }
        #expect(source.contains("notify_set_state"))
        #expect(BackendRemoteInputMark.sharedWriteInterval == 100_000_000)
        // A burst far faster than a phone can send: every event still moves the in-process mark, and the whole
        // burst is over in well under a second.
        let started = BackendRemoteInputMark.now()
        for _ in 0..<5_000 { BackendRemoteInputMark.posted() }
        let took = BackendRemoteInputMark.now() - started
        #expect(BackendRemoteInputMark.inProcessMark() >= started)
        #expect(took < 1_000_000_000)
    }
}

extension DeckMemoryStore {
    func cloudFixtureSchemaNames() throws -> [String] {
        try db.rows("SELECT name FROM sqlite_master WHERE name LIKE 'cloud%'").map { $0.text(0) }
    }
}
