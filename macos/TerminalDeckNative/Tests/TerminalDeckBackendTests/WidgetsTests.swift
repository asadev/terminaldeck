import CryptoKit
import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

final class WidgetsTests: XCTestCase {
    func testRelayCapabilityAndAccess() throws {
        XCTAssertTrue(BackendRemoteProtocol.capabilities.contains("widgets"))
        for level in [BackendINT2PhoneAccessLevel.look, .work, .full] { XCTAssertTrue(level.permits("widgets.read")) }
        XCTAssertFalse(BackendINT2PhoneAccessLevel.hoot.permits("widgets.read"))
        guard case .message(let message) = BackendRemoteProtocol.parseClientMessage(#"{"t":"widgets.read","rid":"request"}"#) else { return XCTFail("read refused") }
        XCTAssertEqual(message["rid"].string, "request")
        let frame = try BackendWidgets.frame(.empty, rid: "request")
        XCTAssertEqual(frame.value["rid"].string, "request"); XCTAssertEqual(frame.kind, .widgetsSnapshot)
    }
    func testReaderReceivesDeviceAndRefreshDoesNotReuseOtherDeviceSnapshot() async throws {
        actor Reads {
            var devices: [String] = []
            func read(_ device: String?) -> DeckWidgetSnapshot { devices.append(device ?? "local"); return .init(machineId: device) }
            func values() -> [String] { devices }
        }
        let reads = Reads()
        let service = BackendWidgets(read: { device, _ in await reads.read(device) }, send: { _, _ in })
        let feature = await service.feature()
        for device in ["allowed", "restricted"] {
            let context = BackendRemoteHostContext(connectionID: UUID(), deviceID: device, kind: .guest, address: "test", peerPublicKey: nil,
                claimedCapabilities: ["widgets"], reach: .init(kind: .guest, unrestricted: false, folders: [], accounts: nil, drivesWindows: false), phoneAccess: .look)
            let messages = try await feature.handle(BackendRemoteClientMessage(.object([.init("t", .string("widgets.read"))])), context)
            XCTAssertEqual(messages.first?.value["snapshot"]["machineId"].string, device)
        }
        await service.changed()
        let devices = await reads.values()
        XCTAssertEqual(devices.filter { $0 == "allowed" }.count, 2); XCTAssertEqual(devices.filter { $0 == "restricted" }.count, 2)
    }
    /// Post-24 (phone-terminal item 1): a frame went to every phone on every status change, about twice a second
    /// while agents worked. Now: what a phone shows changed -> at once; CPU or memory alone -> at most every 15 s;
    /// nothing -> once a minute. Two phones of one device share one read.
    func testPhonesGetAFrameOnlyWhenWhatTheyShowChanged() async throws {
        let base = DeckWidgetSnapshot(updatedAt: 1, connected: true, needsYouCount: 1, cpuPercent: 10, memoryPercent: 40)
        var cpu = base; cpu.cpuPercent = 55; cpu.updatedAt = 2
        var needs = base; needs.needsYouCount = 2; needs.updatedAt = 3
        typealias D = BackendWidgets.SendDecision
        XCTAssertEqual(BackendWidgets.sendDecision(previous: nil, sentAt: nil, metricsAt: nil, next: base, now: 0), D.withMetrics)
        XCTAssertEqual(BackendWidgets.sendDecision(previous: base, sentAt: 0, metricsAt: 0, next: base, now: 30), D.skip, "nothing changed")
        XCTAssertEqual(BackendWidgets.sendDecision(previous: base, sentAt: 0, metricsAt: 0, next: base, now: 60), D.withMetrics, "once a minute")
        XCTAssertEqual(BackendWidgets.sendDecision(previous: base, sentAt: 0, metricsAt: 0, next: cpu, now: 5), D.skip, "CPU alone, too soon")
        XCTAssertEqual(BackendWidgets.sendDecision(previous: base, sentAt: 0, metricsAt: 0, next: cpu, now: 15), D.withMetrics)
        XCTAssertEqual(BackendWidgets.sendDecision(previous: base, sentAt: 0, metricsAt: 0, next: needs, now: 1), D.shown, "needs you: at once")

        actor Box {
            var reads = 0, sends = 0, now = 0.0, value: DeckWidgetSnapshot
            init(_ value: DeckWidgetSnapshot) { self.value = value }
            func read() -> DeckWidgetSnapshot { reads += 1; return value }
            func sent() { sends += 1 }
            func set(_ v: DeckWidgetSnapshot, at t: Double) { value = v; now = t }
            func time() -> Double { now }
            func counts() -> (Int, Int) { (reads, sends) }
        }
        let box = Box(base)
        let service = BackendWidgets(read: { _, _ in await box.read() }, send: { _, _ in await box.sent() }, clock: { 0 })
        let feature = await service.feature()
        for _ in 0..<2 { // two phones of the same device
            let context = BackendRemoteHostContext(connectionID: UUID(), deviceID: "phone", kind: .guest, address: "test", peerPublicKey: nil,
                claimedCapabilities: ["widgets"], reach: .init(kind: .guest, unrestricted: false, folders: [], accounts: nil, drivesWindows: false), phoneAccess: .look)
            _ = try await feature.handle(BackendRemoteClientMessage(.object([.init("t", .string("widgets.read"))])), context)
        }
        for _ in 0..<10 { await service.changed() } // ten status events, nothing shown changed
        var (reads, sends) = await box.counts()
        XCTAssertEqual(reads, 2 + 10, "one read per refresh for the device, not one per phone")
        XCTAssertEqual(sends, 0)
        await box.set(needs, at: 0)
        await service.changed()
        (reads, sends) = await box.counts()
        XCTAssertEqual(sends, 2, "needs you changed: both phones at once")
    }

    func testDueTasksExcludeDoneFutureAndMalformedDate() throws {
        let tasks = try NativeRPCValue.parseJSON(Data(#"[{"local":true,"id":"due","title":"Due","dueDate":"2025-01-01"},{"local":true,"id":"done","dueDate":"2025-01-01","crmStatus":"Done"},{"local":true,"id":"future","dueDate":"2035-01-01"},{"local":true,"id":"bad","dueDate":"0000-99-99"},{"local":true,"id":"archived","dueDate":"2025-01-01","archivedAt":1000},{"id":"connected","local":false,"dueDate":"2025-01-01"}]"#.utf8)).elements!
        XCTAssertEqual(BackendWidgets.dueTasks(tasks, at: Date(timeIntervalSince1970: 1_770_000_000)).compactMap { $0["id"].string }, ["due"])
    }
    func testTaskDrillInCarriesLifecycleExclusionsFromRealTaskRecord() throws {
        let raw = try NativeRPCValue.parseJSON(Data(#"{"id":"local:task","keyId":"local","externalTaskId":"task","title":"Done earlier","crmStatus":"To-Do","project":"/test","completedAt":1000,"archivedAt":2000,"deletedAt":3000}"#.utf8))
        let record = try BackendTaskRecord(raw)
        let row = BackendTaskMCP.taskView(record, agents: [])
        let meta = BackendINT2PhoneTasks.meta(row)
        XCTAssertEqual(meta["completed"].string, "1")
        XCTAssertEqual(meta["archived"].string, "1")
        XCTAssertEqual(meta["deleted"].string, "1")
    }
    func testWeeklyUsesIndicatorFirstWindowAndRejectsExpired() {
        let date = Date(timeIntervalSince1970: 2_000_000), now = date.timeIntervalSince1970 * 1000
        let account = BackendUsageAccount(provider: "codex", id: "test", name: "Test", configDirectory: nil)
        func row(_ used: Double, reset: Double) -> BackendUsageReading {
            .init(account: account, window: .weekly, windowMinutes: 10080, label: "Week", used: .reported(fraction: used), resets: .at(reset), observedAt: now, reportedAt: now, source: "test")
        }
        let report = BackendUsageReport(sessionID: nil, account: account, readings: [row(0.25, reset: now + 1000), row(0.9, reset: now + 1000)], reason: nil, assembledAt: now)
        XCTAssertEqual(BackendWidgets.weeklyRemaining(report, at: date), 75)
        XCTAssertNil(BackendWidgets.weeklyRemaining(report, at: date.addingTimeInterval(2)))
        XCTAssertNil(BackendWidgets.weeklyRemaining(nil, at: date))
    }
    func testPushSnapshotOnlyInsideEncryptedAlert() throws {
        let key = SymmetricKey(size: .bits256)
        let notice = BackendPhonePush.Notice(kind: .needsYou, session: "session", agent: "Codex", title: "Private session", folder: "/test")
        let snapshot = try BackendWidgets.wire(.init(updatedAt: 1000, connected: true, needsYouCount: 1, needsYou: [.init(id: "session", name: "Private session", agent: "Codex")]))
        let sealed = try BackendPhonePush.seal(notice, wants: .init(), hostID: "host", mac: "Mac", at: Date(), key: key, widgetSnapshot: snapshot)
        XCTAssertFalse(sealed.contains("Private session"))
        let decoded = try decrypt(sealed, key: key)
        XCTAssertEqual(decoded["widgetSnapshot"], snapshot)
    }
    func testOversizedPushKeepsOriginalAlertWithoutSnapshot() throws {
        let key = SymmetricKey(size: .bits256)
        let notice = BackendPhonePush.Notice(kind: .needsYou, session: "session", agent: "Codex", title: "Answer", folder: "/test")
        let snapshot = NativeRPCValue.object([.init("oversized", .string(String(repeating: "x", count: 5000)))])
        let sealed = try BackendPhonePush.seal(notice, wants: .init(), hostID: "host", mac: "Mac", at: Date(), key: key, widgetSnapshot: snapshot)
        let decoded = try decrypt(sealed, key: key)
        XCTAssertTrue(decoded["widgetSnapshot"].isNullish); XCTAssertEqual(decoded["session"].string, "session")
        XCTAssertLessThan(sealed.utf8.count, 2000)
    }
    private func decrypt(_ text: String, key: SymmetricKey) throws -> NativeRPCValue {
        var base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base.count % 4 != 0 { base += "=" }
        let box = try AES.GCM.SealedBox(combined: XCTUnwrap(Data(base64Encoded: base)))
        return try NativeRPCValue.parseJSON(AES.GCM.open(box, using: key))
    }
}
