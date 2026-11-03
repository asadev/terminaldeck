import AppKit
@preconcurrency import AVFoundation
import Foundation
import SwiftUI
import XCTest
import TerminalDeckBackend
@testable import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor
final class P61ScreenModelCoverageTests: XCTestCase {
    private func scratch() throws -> URL {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/p61-screen-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testComposerKeepsMentionIdentityAndSerializesItsVisibleText() {
        let mention = HootMention(id: "agent-id", kind: .agent, name: "Same name", project: "/fixture")
        var draft = HootComposerDraft()
        draft.text = "Ask "
        draft.insert(mention)
        draft.text += " please"
        XCTAssertEqual(draft.plainText, "Ask Same name please")
        XCTAssertEqual(draft.wire["mentions"].elements?.first?["id"], .string("agent-id"))
        draft.text = "Mention removed"
        XCTAssertTrue(draft.activeMentions.isEmpty)
        XCTAssertEqual(mention.wire["id"], .string("agent-id"))
        XCTAssertEqual(mention.wire["project"], .string("/fixture"))
    }

    func testPastedAttachmentCleanupLeavesUnrelatedFilesAlone() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let own = try HootPastedFiles.make(Data([1, 2, 3]), type: "png", in: root)
        let other = root.appendingPathComponent("keep.png")
        try Data([4]).write(to: other)
        HootPastedFiles.discard([own, other], in: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: own.path))
        XCTAssertEqual(try Data(contentsOf: other), Data([4]))
    }

    func testVoiceWithoutHardwareDoesNotRequestPermissionOrWriteText() async {
        let voice = HootComposerVoice(available: false, observeHardware: false)
        voice.viewAppeared(); voice.viewAppeared()
        XCTAssertFalse(voice.viewDisappeared())
        XCTAssertTrue(voice.viewDisappeared())
        await voice.start { _ in XCTFail("A missing microphone changed the draft") }
        XCTAssertFalse(voice.recording)
        XCTAssertFalse(voice.starting)
        XCTAssertEqual(voice.problem, "No microphone connected")
        let wav = NarrationKeyListener.wav([0, 1, -1], rate: 16_000)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(wav.count, 50)
        XCTAssertEqual(Array(wav.suffix(6)), [0, 0, 255, 127, 1, 128])
    }

    func testSpeechListenerFlushesSyntheticAudioAndBalancesItsPendingSignal() async throws {
        let events = P61SpeechEvents()
        let listener = NarrationKeyListener(heard: { events.append($0) }, transcribe: { data in
            XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
            return .success("fixture speech")
        })
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<16_000 { channel[index] = 0.2 }
        try await listener.start(format: format)
        listener.feed(buffer, at: 0)
        await listener.finish()
        let final: [String] = events.snapshot.compactMap { event in
            if case .final(let words, _, _) = event { return words.map(\.text).joined(separator: " ") }
            return nil
        }
        let pending: [Bool] = events.snapshot.compactMap { event in
            if case .waiting(let value) = event { return value }; return nil
        }
        XCTAssertEqual(final, ["fixture speech"])
        XCTAssertEqual(pending, [true, false])
    }

    func testIslandOnlyAcceptsKeyboardWhenExpandedAndNeverBecomesMain() {
        let frame = NSRect(x: 10, y: 20, width: 300, height: 40)
        _ = NSApplication.shared
        let panel = IslandPanel(frame: frame)
        defer { panel.close() }
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        panel.allowsKey = { true }
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertEqual(panel.constrainFrameRect(frame, to: nil), frame)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(panel.isVisible)
    }

    func testTaskFieldRefusalRollsBackAndValidationNeverCallsTheBackend() async {
        var calls: [String] = []
        let transport = NativeFIXESTaskThreadTransport(invoke: { name, _ in
            calls.append(name)
            return .object([.init("ok", .bool(false)), .init("error", .string("Not allowed"))])
        }, observe: { _ in .init {} })
        let task = TaskDetailModel(row: TaskRow(id: "fixture"), agents: [], threadTransport: transport, loadOnOpen: false)
        let store = FieldsStore(model: task)
        let field = TaskField(id: "n", taskId: "fixture", label: "Number", kind: .number, config: FieldConfig(), value: .number(3))
        store.fields = [field]
        await store.commitValue(field, .number(7))
        XCTAssertEqual(store.field("n")?.value, .number(3))
        XCTAssertEqual(store.errors["n"], "Not allowed")
        XCTAssertEqual(calls, ["updateTaskFieldValue"])
        await store.commitValue(field, .string("not a number"))
        XCTAssertEqual(calls.count, 1)
        XCTAssertNotNil(store.errors["n"])
    }

    func testMcpInstallDraftCancellationForgetsOnlyThatServersSecrets() {
        let model = McpStoreModel()
        model.setValue("one", "TOKEN", "fixture-one")
        model.setValue("two", "TOKEN", "fixture-two")
        model.ask("one", true)
        XCTAssertEqual(model.asking, "one")
        model.ask("one", false)
        XCTAssertEqual(model.asking, "")
        XCTAssertNil(model.values["one"])
        XCTAssertEqual(model.values["two"]?["TOKEN"], "fixture-two")
        model.addOwn()
        XCTAssertEqual(model.form?.mode, .add)
    }

    func testGitHubFilteringUsesTheSameRepoAndAuthorShownOnTheRow() {
        let model = NativeGHWorkspaceModel(cwd: "/fixture", pageFocus: nil)
        model.items = [
            NativeGHItem(raw: CodingAIJSON(["id": 1, "number": 4, "title": "Fix attach", "repository": ["full_name": "owner/deck"], "user": ["login": "alice"]]), area: .pulls, fallbackRepo: ""),
            NativeGHItem(raw: CodingAIJSON(["id": 2, "title": "Other", "repository_url": "https://api.github.com/repos/owner/other"]), area: .issues, fallbackRepo: "")
        ]
        for query in [" attach ", "OWNER/DECK", "alice", "#4"] {
            model.query = query
            XCTAssertEqual(model.shownItems.map(\.id), ["1"], query)
        }
        model.query = "missing"
        XCTAssertTrue(model.shownItems.isEmpty)
        model.query = " "
        XCTAssertEqual(model.shownItems.count, 2)
        XCTAssertEqual(model.items[1].repo, "owner/other")
    }

    func testReplacingAConnectedTaskQuestionCancelsTheOldOneAndAnswersOnlyOnce() {
        let store = ConnectedTasksStore()
        var first: [Bool] = [], second: [Bool] = []
        store.requestYes("First?", system: "Fixture") { first.append($0) }
        store.requestYes("Second?", system: "Fixture") { second.append($0) }
        XCTAssertEqual(first, [false])
        XCTAssertTrue(second.isEmpty)
        store.answer(.send)
        store.answer(.send)
        XCTAssertEqual(second, [true])
        XCTAssertNil(store.asking)
        XCTAssertTrue(store.isStale("unknown"))
    }

    func testSplitArrangementSurvivesReloadWithoutChangingAnotherRow() throws {
        let defaults = P61MemoryDefaults(name: "p61-arrangement-" + UUID().uuidString)
        let layout = NativePaneArrangement(defaults: defaults, known: { ["a", "b", "c"] })
        XCTAssertTrue(layout.move("a", relativeTo: "b", after: true, current: ["a", "b"]))
        XCTAssertEqual(layout.arranged(["a", "b"]), ["b", "a"])
        XCTAssertEqual(layout.arranged(["a", "c"]), ["a", "c"])
        XCTAssertFalse(layout.move("missing", relativeTo: "b", after: true, current: ["a", "b"]))
        let reloaded = NativePaneArrangement(defaults: defaults, known: { ["a", "b", "c"] })
        XCTAssertEqual(reloaded.arranged(["a", "b"]), ["b", "a"])
        let oldOwner = UUID(), newOwner = UUID()
        layout.setDocked("a", width: 200, owner: oldOwner)
        layout.setDocked("a", width: 240, owner: newOwner)
        layout.setDocked("a", width: nil, owner: oldOwner)
        XCTAssertEqual(layout.dockedSimulators["a"]?.width, 240)
        layout.setDocked("a", width: nil, owner: newOwner)
        XCTAssertNil(layout.dockedSimulators["a"])
    }

    func testTranscriptWatcherReadsScratchUpdatesAndStopsAfterUnwatch() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config"), project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let folder = config.appendingPathComponent("projects/" + NativeTranscriptPaths.encodeProjectPath(project.path))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("fixture.jsonl")
        func prompt(_ text: String, id: String) throws -> Data {
            var line = try JSONSerialization.data(withJSONObject: ["type": "user", "uuid": id, "message": ["role": "user", "content": text], "origin": ["kind": "human"]])
            line.append(10); return line
        }
        try prompt("First", id: "one").write(to: file)
        let backend = NativeTranscriptBackend()
        backend.configure(scope: .init(configDirectory: config.path, projectFolders: [project.path]))
        defer { backend.stop() }
        var text: [String] = [], failures: [String] = []
        let watcher = try await backend.watch(["transcriptPath": file.path], onUpdate: { text = $0.messages.map(\.text) }, onFailure: { failures.append($0) })
        await settle { text.contains("First") }
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd(); try handle.write(contentsOf: prompt("Second", id: "two")); try handle.close()
        await settle { text.contains("Second") }
        backend.unwatch(watcher)
        XCTAssertTrue(failures.isEmpty)
        let newest = try await backend.newestTranscript(cwd: project.path)
        XCTAssertEqual(newest?.path, file.path)
        do { _ = try await backend.readTail(path: root.appendingPathComponent("outside.jsonl").path, from: 0); XCTFail("Out-of-scope transcript accepted") } catch {}
    }

    func testAppsOptionsPartialReadFailureDoesNotHideEditableOptionsAndRevertClearsPassword() async throws {
        let options = try NativeAppsOptions().value()
        var channels: [String] = []
        let model = NativeAppsSRV2OptionsModel(serverID: "server", appID: "app", transport: { channel, payload in
            channels.append(channel)
            XCTAssertEqual(payload["serverId"] as? String, "server")
            if channel == "apps:options:read" { return .object([.init("options", options), .init("summary", .array([]))]) }
            throw NativeRPCError(code: "fixture", message: "Variables unavailable")
        })
        model.loadIfNeeded()
        await settle { !model.loading }
        XCTAssertNotNil(model.saved)
        XCTAssertNil(model.loadProblem)
        XCTAssertNotNil(model.variablesProblem)
        XCTAssertNotNil(model.routerProblem)
        XCTAssertEqual(Set(channels), ["apps:options:read", "apps:variables:read", "apps:router:read"])
        model.newPassword = "fixture secret"; model.changingPassword = true
        XCTAssertTrue(model.isChanged(.web))
        model.revert(.web)
        XCTAssertEqual(model.newPassword, "")
        XCTAssertFalse(model.changingPassword)
        XCTAssertFalse(model.isChanged(.web))
    }

    private func settle(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        XCTAssertTrue(condition(), "Fixture did not settle", file: file, line: line)
    }

    private func updateReceipt(_ root: URL) -> NativeStagedUpdate {
        let release = NativeUpdateRelease(schemaVersion: 1, channel: "stable", version: "999.0.0", bundleIdentifier: "fixture", architecture: "arm64",
            url: URL(string: "https://example.invalid/update.zip")!, sha512: "fixture", size: 1, releaseDate: "2026-10-19", releaseNotes: nil)
        return NativeStagedUpdate(release: release, directory: root, archive: root.appendingPathComponent("update.zip"), bundle: root.appendingPathComponent("Fixture.app"))
    }

    func testUpdaterFailedQuitKeepsTheAppOpenAndAnOrdinarySecondQuitCanProceed() async throws {
        let root = try scratch(), receipt = updateReceipt(try scratch())
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: receipt.directory) }
        var arms = 0
        let updater = NativeAppUpdater(dataRoot: root, operations: .init(feed: { receipt.release }, stage: { _, _ in receipt }, install: { _ in }), armForQuit: { _, relaunch in
            XCTAssertFalse(relaunch)
            arms += 1
            throw NativeRPCError(code: "fixture-update", message: "Helper refused")
        })
        _ = await updater.handle("update:check")
        XCTAssertEqual(updater.rawState["phase"] as? String, "available")
        _ = await updater.handle("update:download")
        XCTAssertEqual(updater.rawState["phase"] as? String, "ready")
        XCTAssertFalse(updater.prepareForQuit())
        XCTAssertEqual(updater.rawState["phase"] as? String, "error")
        XCTAssertFalse(updater.relaunchOnQuit)
        XCTAssertTrue(updater.prepareForQuit())
        XCTAssertEqual(arms, 1)
    }

    func testUpdaterInstallFailureClearsRelaunchAndKeepsItsErrorVisible() async throws {
        let root = try scratch(), receipt = updateReceipt(try scratch())
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: receipt.directory) }
        let updater = NativeAppUpdater(dataRoot: root, operations: .init(feed: { receipt.release }, stage: { _, _ in receipt }, install: { _ in
            throw NativeRPCError(code: "fixture-update", message: "Install refused")
        }))
        _ = await updater.handle("update:check")
        _ = await updater.handle("update:download")
        _ = await updater.handle("update:install")
        XCTAssertFalse(updater.relaunchOnQuit)
        XCTAssertEqual(updater.rawState["phase"] as? String, "error")
        XCTAssertTrue(updater.prepareForQuit())
    }

    func testUpdaterSuccessfulQuitArmsOnceAndCarriesRelaunchChoice() async throws {
        let root = try scratch(), receipt = updateReceipt(try scratch())
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: receipt.directory) }
        var arms = 0
        let updater = NativeAppUpdater(dataRoot: root, operations: .init(feed: { receipt.release }, stage: { _, _ in receipt }, install: { _ in }), armForQuit: { staged, relaunch in
            XCTAssertEqual(staged.release.version, "999.0.0")
            XCTAssertTrue(relaunch)
            arms += 1
        })
        _ = await updater.handle("update:check")
        _ = await updater.handle("update:download")
        _ = await updater.handle("update:install")
        XCTAssertTrue(updater.relaunchOnQuit)
        XCTAssertTrue(updater.prepareForQuit())
        XCTAssertTrue(updater.prepareForQuit())
        XCTAssertEqual(arms, 1)
    }

    func testDevelopmentUpdaterNeverArmsQuitOrCreatesStaging() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let updater = NativeAppUpdater(bundle: .main, dataRoot: root)
        XCTAssertEqual(updater.rawState["phase"] as? String, "unsupported")
        for channel in ["update:get", "update:check", "update:download", "update:install"] {
            let answer = await updater.handle(channel)
            XCTAssertEqual(answer?["phase"] as? String, "unsupported")
            XCTAssertFalse(updater.relaunchOnQuit)
        }
        let missing = await updater.handle("not-an-update")
        XCTAssertNil(missing)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }
}

private final class P61MemoryDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    init(name: String) { super.init(suiteName: name)! }
    override func data(forKey defaultName: String) -> Data? { values[defaultName] as? Data }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}

private final class P61SpeechEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [NarrationHeard] = []
    var snapshot: [NarrationHeard] { lock.withLock { values } }
    func append(_ value: NarrationHeard) { lock.withLock { values.append(value) } }
}
