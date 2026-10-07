import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

@Suite("Remote window desks and durable answers")
struct BackendRemoteServeWindowTests: Sendable {
    @Test func asksUseOnlyTheSessionVerbAndArguments() async throws {
        let desk = BackendRemoteServeWindowAsks(makeID: { "question-1" }), wire = BackendRemoteServeWindowTestWire()
        await desk.serve(wire)
        let task = Task { await desk.call(deviceID: "mac", sessionID: "session-1", tool: "browser.read", arguments: "{\"selector\":\"h1\"}") }
        let frame = await wire.next()
        #expect(frame.deviceID == "mac")
        #expect(frame.message.value.fields?.map(\.key).sorted() == ["args", "id", "session", "t", "tool"])
        #expect(frame.message.value["session"].string == "session-1")
        #expect(await desk.answer(id: "question-1", deviceID: "other", result: .init(ok: true, body: "{}")) == false)
        #expect(await desk.answer(id: "question-1", deviceID: "mac", result: .init(ok: true, body: "{\"title\":\"Example\"}")))
        #expect(await task.value == .init(ok: true, body: "{\"title\":\"Example\"}"))
        #expect(await desk.waiting == 0)
        #expect(await desk.answer(id: "question-1", result: .init(ok: true, body: "{}")) == false)
    }
    @Test func absentWireAndZeroListenersRefuseImmediately() async {
        let desk = BackendRemoteServeWindowAsks()
        let first = await desk.call(deviceID: "mac", sessionID: "s", tool: "browser.read", arguments: "{}")
        #expect(!first.ok && first.body.contains("not connected right now"))
        await desk.serve(BackendRemoteServeWindowTestWire(heard: 0))
        let second = await desk.call(deviceID: "mac", sessionID: "s", tool: "browser.read", arguments: "{}")
        #expect(!second.ok && second.body.contains("not connected right now"))
        #expect(await desk.waiting == 0)
    }
    @Test func deadlineProducesTheExactRefusalAndIsBetweenHumanAndMCPDeadlines() async {
        #expect(BackendRemoteServeWindowAsks.timeoutMilliseconds > 45_000 && BackendRemoteServeWindowAsks.timeoutMilliseconds < 60_000)
        let desk = BackendRemoteServeWindowAsks(timeoutMilliseconds: 1)
        await desk.serve(BackendRemoteServeWindowTestWire())
        let answer = await desk.call(deviceID: "mac", sessionID: "s", tool: "browser.handover", arguments: "{}")
        #expect(answer == .refusal("the computer holding that browser window did not answer. It may be asleep or the app may be closed there. Say what you would have done on the page and let the person do it."))
        #expect(await desk.waiting == 0)
    }
    @Test func disconnectSettlesOnlyThatPeerAndRetainsItsWindowClaims() async {
        let desk = BackendRemoteServeWindowAsks(), wire = BackendRemoteServeWindowTestWire()
        await desk.serve(wire); await desk.held(deviceID: "mac", sessions: ["s"])
        let mine = Task { await desk.call(deviceID: "mac", sessionID: "s", tool: "browser.read", arguments: "{}") }
        _ = await wire.next()
        let other = Task { await desk.call(deviceID: "laptop", sessionID: "s", tool: "browser.read", arguments: "{}") }
        _ = await wire.next()
        await desk.gone("mac")
        #expect((await mine.value).body.contains("disconnected before it answered"))
        #expect(await desk.waiting == 1)
        #expect(await desk.holdersOf("s") == ["mac"])
        await desk.stop(); #expect(await other.value == .refusal("this app is shutting down."))
    }
    @Test func holdsReplaceWithoutReorderingAndAreCappedAt128() async {
        let desk = BackendRemoteServeWindowAsks()
        await desk.held(deviceID: "mac", sessions: ["s", "detached"])
        await desk.held(deviceID: "laptop", sessions: ["s"])
        await desk.held(deviceID: "mac", sessions: ["s"])
        #expect(await desk.holdersOf("s") == ["mac", "laptop"])
        #expect(await desk.holdersOf("detached").isEmpty)
        await desk.held(deviceID: "mac", sessions: (0..<129).map { "s\($0)" })
        #expect(await desk.holdersOf("s127") == ["mac"])
        #expect(await desk.holdersOf("s128").isEmpty)
        await desk.held(deviceID: "laptop", sessions: [])
        #expect(await desk.holdersOf("s").isEmpty)
        #expect(await desk.holdersOf("").isEmpty)
    }
    @Test func reachesProbesWithoutSendingAFrame() async {
        let desk = BackendRemoteServeWindowAsks(), wire = BackendRemoteServeWindowTestWire()
        await desk.serve(wire)
        #expect(await desk.reaches("mac")); #expect(await desk.reaches("") == false)
        #expect(await wire.sentCount == 0)
    }
    @Test func explicitAnswersBeatLiveKindsAndSurviveRestart() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let kinds = BackendRemoteServeWindowTestKinds()
        let grants = BackendRemoteServeWindowGrants(directory: dir, kindOf: { await kinds.kind($0) }); await grants.open()
        #expect(try await grants.drives("my-laptop")); #expect(try await grants.list().isEmpty)
        #expect(try await grants.drives("guest") == false)
        _ = try await grants.set(.string("guest"), drives: .bool(true))
        _ = try await grants.set(.string("my-laptop"), drives: .bool(false))
        let loaded = BackendRemoteServeWindowGrants(directory: dir, kindOf: { await kinds.kind($0) }); await loaded.open()
        #expect(try await loaded.drives("guest")); #expect(try await loaded.drives("my-laptop") == false)
        let raw = try NativeRPCValue.parseJSON(Data(contentsOf: grants.file))
        #expect(raw == .object([.init("version", .number(1)), .init("devices", .array([.string("guest")])), .init("denied", .array([.string("my-laptop")]))]))
        #expect(try Data(contentsOf: grants.file).last == 0x0a)
        #expect(try await grants.forget("my-laptop")); #expect(try await grants.drives("my-laptop"))
        #expect(try await grants.forget("missing") == false)
        #expect(try await grants.drives("") == false)
    }
    @Test func kindChangesLandOnTheNextCall() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let kinds = BackendRemoteServeWindowTestKinds()
        let grants = BackendRemoteServeWindowGrants(directory: dir, kindOf: { await kinds.kind($0) }); await grants.open()
        #expect(try await grants.drives("guest") == false)
        await kinds.promote("guest"); #expect(try await grants.drives("guest"))
        _ = try await grants.set(.string("guest"), drives: .string("yes"))
        #expect(try await grants.drives("guest") == false)
    }
    @Test func oldYesOnlyFilesInvalidEntriesAndBothSetsReadCorrectly() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(BackendRemoteServeWindowGrants.fileName)
        try Data("{\"version\":1,\"devices\":[\"a\",7,\"\",null,\" b \"],\"denied\":[\"a\"]}".utf8).write(to: file)
        let grants = BackendRemoteServeWindowGrants(directory: dir); await grants.open()
        #expect(try await grants.list() == ["b"]); #expect(try await grants.drives("a") == false)
        await grants.close()
        try Data("{\"version\":1,\"devices\":[\"old\"]}".utf8).write(to: file); await grants.open()
        #expect(try await grants.drives("old"))
        await grants.close()
        var invalidUTF8 = Data("{\"devices\":[\"a".utf8); invalidUTF8.append(0xff); invalidUTF8.append(Data("\"]}".utf8))
        try invalidUTF8.write(to: file); await grants.open()
        #expect(try await grants.list() == ["a\u{fffd}"])
        #expect(BackendRemoteServeWindowFile.validID("\u{feff}id\u{feff}") == "id")
        #expect(BackendRemoteServeWindowFile.validID("\u{0085}id") == "\u{0085}id")
    }
    @Test func invalidIdsAndOversizeFilesDoNotGrantGuests() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(BackendRemoteServeWindowGrants.fileName)
        try Data(String(repeating: " ", count: 65_537).utf8).write(to: file)
        let grants = BackendRemoteServeWindowGrants(directory: dir); await grants.open()
        for id in [NativeRPCValue.number(42), .string(" "), .string(String(repeating: "x", count: 201))] {
            #expect(try await grants.set(id, drives: .bool(true)) == false)
        }
        #expect(try await grants.list().isEmpty)
    }
    @Test func failedWritesLeaveMemoryAndDiskInAgreement() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(BackendRemoteServeWindowGrants.fileName)
        try Data("{\"version\":1,\"devices\":[\"guest\"],\"denied\":[]}".utf8).write(to: file)
        let grants = BackendRemoteServeWindowGrants(directory: dir, write: { _, _ in throw NativeRPCError(code: "unavailable", message: "disk refused") }); await grants.open()
        do { _ = try await grants.forget("guest"); Issue.record("A failed permission write must throw") } catch {}
        #expect(try await grants.drives("guest"))
        do { _ = try await grants.set(.string("guest"), drives: .bool(false)); Issue.record("A failed permission write must throw") } catch {}
        #expect(try await grants.drives("guest"))
    }
    @Test func deniesBackfillRestoreAndKeepUnknownRowFields() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let denies = BackendRemoteServeWindowDenies(directory: dir, fileName: BackendRemoteServeWindowDenies.machineFileName); await denies.open()
        let row = NativeRPCValue.object([.init("id", .string("machine")), .init("drivesWindows", .bool(false)), .init("unknown", .string("keep"))])
        _ = try await denies.apply(rows: [row], subject: "machine")
        #expect(try await denies.has("machine"))
        let stripped = row.removing("drivesWindows")
        // window-denies.ts:304 `{ ...row, drivesWindows: false }` appends the restored key; JS toEqual ignores key order, so compare by key, not by position.
        let restored = try await denies.apply(rows: [stripped], subject: "machine")
        #expect(restored.count == 1); #expect(restored[0]["id"] == row["id"]); #expect(restored[0]["drivesWindows"] == .bool(false)); #expect(restored[0]["unknown"] == row["unknown"])
        #expect(restored[0].fields?.count == row.fields?.count)
        #expect(try await denies.forget("machine")); #expect(try await denies.list().isEmpty)
        #expect(try await denies.forget("machine") == false)
    }
    @Test func backfillFailureKeepsRecordRefusalsAndDoesNotPreventLoading() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let denies = BackendRemoteServeWindowDenies(directory: dir, fileName: BackendRemoteServeWindowDenies.serverFileName,
                                                   write: { _, _ in throw NativeRPCError(code: "unavailable", message: "disk refused") }); await denies.open()
        let row = NativeRPCValue.object([.init("id", .string("server")), .init("drivesWindows", .bool(false))])
        #expect(try await denies.apply(rows: [row], subject: "server") == [row])
        #expect(try await denies.size() == 0)
    }
    @Test func directionCeilingsRefuseNewIdsButNeverTrapExistingAnswers() async throws {
        let dir = try temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let grants = BackendRemoteServeWindowGrants(directory: dir); await grants.open()
        for n in 0..<64 { _ = try await grants.set(.string("d\(n)"), drives: .bool(true)) }
        #expect(try await grants.set(.string("overflow"), drives: .bool(true)) == false)
        #expect(try await grants.set(.string("d0"), drives: .bool(false)) == false)
        #expect(try await grants.list().count == 63)
        let denies = BackendRemoteServeWindowDenies(directory: dir, fileName: BackendRemoteServeWindowDenies.serverFileName); await denies.open()
        for n in 0..<64 { _ = try await denies.set(.string("s\(n)"), denied: true) }
        #expect(try await denies.set(.string("overflow"), denied: true) == false)
        #expect(try await denies.forget("s0")); #expect(try await denies.size() == 63)
    }
    private func temporary() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("BackendRemoteServeWindowTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); return dir
    }
}

private actor BackendRemoteServeWindowTestKinds {
    private var mine: Set<String> = ["my-laptop"]
    func kind(_ id: String) -> BackendRemoteDeviceKind { mine.contains(id) ? .mine : .guest }
    func promote(_ id: String) { mine.insert(id) }
}
private actor BackendRemoteServeWindowTestWire: BackendRemoteServeWindowWire {
    struct Frame: Sendable { let deviceID: String, message: BackendRemoteServerMessage }
    private let heard: Int
    private var frames: [Frame] = []
    private var waiter: CheckedContinuation<Frame, Never>?
    private(set) var sentCount = 0
    init(heard: Int = 1) { self.heard = heard }
    func ask(deviceID: String, message: BackendRemoteServerMessage) -> Int {
        let frame = Frame(deviceID: deviceID, message: message); sentCount += 1
        if let waiter { self.waiter = nil; waiter.resume(returning: frame) } else { frames.append(frame) }
        return heard
    }
    func reaches(deviceID: String) -> Bool { deviceID == "mac" }
    func next() async -> Frame {
        if !frames.isEmpty { return frames.removeFirst() }
        return await withCheckedContinuation { waiter = $0 }
    }
}
