import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor BackendUIGSessionSimulatorTestSessions {
    var generations = ["s1": "first", "s2": "second"]
    func resolve(_ id: String) throws -> BackendUIGSessionSimulatorIdentity {
        guard let generation = generations[id] else { throw NativeRPCError(code: "not-permitted", message: "Session exited") }
        return .init(sessionID: id, incarnation: generation)
    }
    func replace(_ id: String) { generations[id] = UUID().uuidString }
    func exit(_ id: String) { generations[id] = nil }
}
private actor BackendUIGSessionSimulatorApprovalEnvironment: BackendDeckToolsMachinesEnvironment {
    let source: BackendDeckToolsMachinesContext
    let duringApproval: @Sendable () async throws -> Void
    var policies: [BackendDeckToolsMachinesPolicy] = []
    init(source: BackendDeckToolsMachinesContext, duringApproval: @escaping @Sendable () async throws -> Void) {
        self.source = source; self.duringApproval = duringApproval
    }
    func context(for call: BackendMCPCallContext) -> BackendDeckToolsMachinesContext { source }
    func validate(arguments: NativeRPCValue, schema: NativeRPCValue) throws { try BackendDeckCoreCatalogueSchema.check(schema: schema, arguments: arguments) }
    func execute(context: BackendDeckToolsMachinesContext, policy: BackendDeckToolsMachinesPolicy, operation: @escaping @Sendable () async throws -> BackendDeckToolsMachinesOutput) async throws -> BackendMCPToolReply {
        policies.append(policy); try await duringApproval(); return .value(try await operation().value)
    }
    func failed(call: BackendMCPCallContext, tool: BackendMCPTool, policy: BackendDeckToolsMachinesPolicy?, loggedArguments: NativeRPCValue, error: any Error) -> BackendMCPToolReply { BackendDeckToolsMachinesFactory.failureReply(error) }
    func captured() -> [BackendDeckToolsMachinesPolicy] { policies }
}
private final class BackendUIGSessionSimulatorRecordingFake: BackendUIGSessionSimulatorRecordingProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private(set) var arguments: [String] = []
    var running: Bool { lock.withLock { active } }
    func launched(_ args: [String]) { lock.withLock { arguments = args; active = true } }
    func interrupt() { lock.withLock { active = false } }
    func finished() async -> Int32 {
        let path = lock.withLock { arguments.last }
        if let path { try? Data([1]).write(to: URL(fileURLWithPath: path)) }
        return 0
    }
}
private actor BackendUIGSessionSimulatorTestSink {
    var identities: [BackendUIGSessionSimulatorIdentity] = []
    func send(_ ticket: BackendUIGSessionSimulatorTicket, _ value: NativeRPCValue) -> NativeRPCValue {
        identities.append(ticket.identity); return value.setting("ok", .bool(true))
    }
    func count() -> Int { identities.count }
    func ids() -> [String] { identities.map(\.sessionID) }
}
private final class BackendUIGSessionSimulatorTestWrites: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func write(_ value: String) { lock.withLock { values.append(value) } }
    func captured() -> [String] { lock.withLock { values } }
}
private final class BackendUIGSessionSimulatorTestChanges: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [NativeRPCValue] = []
    func changed(_ value: NativeRPCValue) { lock.withLock { values.append(value) } }
    func captured() -> [NativeRPCValue] { lock.withLock { values } }
}

final class BackendUIGSessionSimulatorTests: XCTestCase, @unchecked Sendable {
    private let id = "ios:AAAA-1111"
    private func rig() -> (BackendUIGSessionSimulatorAttachments, BackendDeckToolsMachinesPortDevices, BackendUIGSessionSimulatorTestSessions) {
        let sessions = BackendUIGSessionSimulatorTestSessions()
        return (BackendUIGSessionSimulatorAttachments(resolveLocalSession: { try await sessions.resolve($0) }), BackendDeckToolsMachinesPortDevices(), sessions)
    }
    private func call(_ tool: String, _ args: NativeRPCValue, attachments: BackendUIGSessionSimulatorAttachments,
                      service: BackendDeckToolsMachinesPortDevices, context: BackendDeckToolsMachinesContext,
                      environment: (any BackendDeckToolsMachinesEnvironment)? = nil) async throws -> BackendMCPToolReply {
        let environment = environment ?? BackendDeckToolsMachinesPortEnvironment(context)
        let definitions = try BackendUIGSessionSimulatorMCP(service: service, attachments: attachments).definitions(environment: environment)
        return try await XCTUnwrap(definitions.first { $0.spec.id == tool }).handler(BackendDeckToolsMachinesPortNativeContext(), args)
    }
    /// 13 Oct: a session with an empty panel was told "this computer has no iOS Simulator, no Android emulator…"
    /// while 22 simulators and two running emulators were there. It now sees the whole Mac, its own panel marked first.
    func testSessionListShowsTheWholeMacWithItsOwnPanelMarkedFirst() async throws {
        let (attachments, service, _) = rig()
        _ = try await attachments.attach(sessionID: "s1", deviceID: id, service: service)
        let mine = try await call("devices.list", .object([]), attachments: attachments, service: service, context: BackendDeckToolsMachinesPortContext(.session, session: "s1"))
        let other = try await call("devices.list", .object([]), attachments: attachments, service: service, context: BackendDeckToolsMachinesPortContext(.session, session: "s2"))
        let mineRows = mine.structuredContent?["devices"].elements ?? [], otherRows = other.structuredContent?["devices"].elements ?? []
        XCTAssertEqual(mineRows.compactMap { $0["id"].string }, [id, "avd:Pixel_9", "android:R58M123"])
        XCTAssertEqual(mineRows.map { $0["inThisPanel"].bool }, [true, false, false]); XCTAssertEqual(mine.structuredContent?["inThisPanel"], .number(1))
        XCTAssertEqual(otherRows.count, 3); XCTAssertTrue(otherRows.allSatisfy { $0["inThisPanel"].bool == false })
        XCTAssertEqual(other.structuredContent?["empty"], .bool(false)); XCTAssertEqual(other.structuredContent?["emptyReason"], .string(""))
        XCTAssertTrue(other.structuredContent?["note"].string?.contains("devices_open_app") == true)
    }
    func testSessionStillDrivesOnlyItsPanelAndHearsWhyByAnyIdSpelling() async throws {
        let (attachments, service, _) = rig()
        _ = try await attachments.attach(sessionID: "s1", deviceID: id, service: service); await service.clear()
        let context = BackendDeckToolsMachinesPortContext(.session, session: "s2")
        let tap = try await call("devices.tap", BackendDeckToolsMachinesPortObject(["deviceId": .string("android:R58M123"), "x": .number(0.5), "y": .number(0.5)]), attachments: attachments, service: service, context: context)
        let said = tap.content.compactMap { $0["text"].string }.joined(separator: " ")
        XCTAssertTrue(tap.isError); XCTAssertTrue(said.contains("is not in this session") && said.contains("devices_open_app"), said)
        let seen = await service.names(); XCTAssertFalse(seen.contains("tap"))
    }
    func testWrongDeviceAndRemoteSessionNeverReachInput() async throws {
        let (attachments, service, _) = rig()
        _ = try await attachments.attach(sessionID: "s1", deviceID: id, service: service); await service.clear()
        let args = BackendDeckToolsMachinesPortObject(["deviceId": .string("android:R58M123"), "x": .number(0.5), "y": .number(0.5)])
        let wrong = try await call("devices.tap", args, attachments: attachments, service: service, context: BackendDeckToolsMachinesPortContext(.session, session: "s1"))
        let remote = try await call("devices.tap", args.setting("deviceId", .string(id)), attachments: attachments, service: service, context: BackendDeckToolsMachinesPortContext(.session, session: "s1", machine: "remote"))
        XCTAssertTrue(wrong.isError); XCTAssertTrue(remote.isError)
        let seen = await service.names(); XCTAssertFalse(seen.contains("tap"))
    }
    func testDetachAndReattachSameDeviceInvalidatesApprovalTicket() async throws {
        let (attachments, service, _) = rig()
        let before = try await attachments.attach(sessionID: "s1", deviceID: id, service: service)
        let context = BackendDeckToolsMachinesPortContext(.session, session: "s1")
        let environment = BackendUIGSessionSimulatorApprovalEnvironment(source: context) {
            _ = try await attachments.detach(sessionID: "s1")
            _ = try await attachments.attach(sessionID: "s1", deviceID: "ios:AAAA-1111", service: service)
        }
        let result = try await call("devices.type", BackendDeckToolsMachinesPortObject(["deviceId": .string(id), "text": .string("secret")]), attachments: attachments, service: service, context: context, environment: environment)
        XCTAssertTrue(result.isError)
        let seen = await service.names(); XCTAssertFalse(seen.contains("type"))
        let after = try await attachments.snapshot(sessionID: "s1"); XCTAssertNotEqual(before.revision, after.revision)
        let policies = await environment.captured(); XCTAssertEqual(policies.first?.spends, "device-input"); XCTAssertEqual(policies.first?.loggedArguments["text"].string, "[6 characters]")
    }
    func testReplacedAndExitedSessionInvalidateTicketAndAttachment() async throws {
        let (attachments, service, sessions) = rig()
        let ticket = try await attachments.attach(sessionID: "s1", deviceID: id, service: service)
        await sessions.replace("s1")
        do { try await attachments.validate(ticket); XCTFail("replacement accepted") } catch {}
        let next = try await attachments.snapshot(sessionID: "s1"); XCTAssertNil(next.deviceID)
        await sessions.exit("s1")
        do { _ = try await attachments.snapshot(sessionID: "s1"); XCTFail("exit accepted") } catch {}
    }
    func testSessionCannotSpoofIdentityOrManageBinding() async throws {
        let (attachments, service, _) = rig(), context = BackendDeckToolsMachinesPortContext(.session, session: "s1")
        let spoof = try await call("devices.attached", BackendDeckToolsMachinesPortObject(["sessionId": .string("s2")]), attachments: attachments, service: service, context: context)
        let manage = try await call("devices.attach", BackendDeckToolsMachinesPortObject(["sessionId": .string("s1"), "deviceId": .string(id)]), attachments: attachments, service: service, context: context)
        XCTAssertTrue(spoof.isError); XCTAssertTrue(manage.isError)
        let ticket = try await attachments.snapshot(sessionID: "s1"); XCTAssertNil(ticket.deviceID)
    }
    func testOwnerAttachUsesAlterAndOwnerAnswer() async throws {
        let (attachments, service, _) = rig(), environment = BackendUIGSessionSimulatorApprovalEnvironment(source: BackendDeckToolsMachinesPortContext()) {}
        let result = try await call("devices.attach", BackendDeckToolsMachinesPortObject(["sessionId": .string("s2"), "deviceId": .string(id)]), attachments: attachments, service: service, context: BackendDeckToolsMachinesPortContext(), environment: environment)
        XCTAssertFalse(result.isError); XCTAssertEqual(result.structuredContent?["sessionId"].string, "s2")
        let policies = await environment.captured(); XCTAssertEqual(policies.first?.tier, .alter); XCTAssertEqual(policies.first?.ownerMustAnswer, true)
    }
    func testAnnotationsRequireSuccessfulHandoffToThisIncarnation() async throws {
        let (attachments, service, sessions) = rig()
        let ticket = try await attachments.attach(sessionID: "s1", deviceID: id, service: service)
        await service.store([BackendDeckToolsMachinesPortRound("mine", "device"), BackendDeckToolsMachinesPortRound("other", "device"), BackendDeckToolsMachinesPortRound("browser", "browser")])
        try await attachments.noteSent(roundID: "mine", ticket: ticket)
        let scoped = BackendUIGSessionSimulatorDeviceService(base: service, attachments: attachments, ticket: ticket)
        let rows = try await scoped.rounds(); XCTAssertEqual(rows.compactMap { $0["id"].string }, ["mine"])
        await sessions.replace("s1")
        let replacement = try await attachments.attach(sessionID: "s1", deviceID: id, service: service)
        let newRows = try await BackendUIGSessionSimulatorDeviceService(base: service, attachments: attachments, ticket: replacement).rounds()
        XCTAssertEqual(newRows.count, 0)
    }
    func testAndroidBootRekeysOnlyItsOwnBinding() async throws {
        let (attachments, service, _) = rig()
        let ticket = try await attachments.attach(sessionID: "s1", deviceID: "avd:Pixel_9", service: service)
        _ = try await attachments.attach(sessionID: "s2", deviceID: id, service: service)
        let scoped = BackendUIGSessionSimulatorDeviceService(base: service, attachments: attachments, ticket: ticket)
        let boot = try await scoped.boot("avd:Pixel_9")
        // Inventory follows a successful real boot: the AVD becomes a live emulator serial.
        let rows = await service.list()
        await service.inventory(rows.filter { $0["id"].string != "avd:Pixel_9" } + [BackendDeckToolsMachinesPortDevices.entry(BackendDeckToolsMachinesPortObject([
            "id": boot["id"], "platform": .string("android"), "kind": .string("emulator"), "avd": .string("Pixel_9")]))])
        _ = try await scoped.open(try boot["id"].requireString("id"))
        let mine = try await attachments.snapshot(sessionID: "s1"), other = try await attachments.snapshot(sessionID: "s2")
        XCTAssertEqual(mine.deviceID, "android:emulator-5554"); XCTAssertEqual(other.deviceID, id)
    }
    func testRecordingOwnsHeadlessCommandAndStopsOnDetach() async throws {
        let (attachments, service, _) = rig(), fake = BackendUIGSessionSimulatorRecordingFake()
        let deviceID = "ios:" + UUID().uuidString
        await service.inventory([BackendDeckToolsMachinesPortDevices.entry(BackendDeckToolsMachinesPortObject(["id": .string(deviceID)]))])
        let ticket = try await attachments.attach(sessionID: "s1", deviceID: deviceID, service: service)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("UIG-recording-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let recorder = BackendUIGSessionSimulatorRecording(attachments: attachments, service: service, picturesDirectory: folder, launch: { args in fake.launched(args); return fake })
        let start = try await recorder.start(ticket); XCTAssertEqual(start["recording"].bool, true)
        XCTAssertEqual(Array(fake.arguments.prefix(5)), ["simctl", "io", String(deviceID.dropFirst(4)), "recordVideo", "--codec=h264"])
        XCTAssertFalse(fake.arguments.contains { $0.contains("Simulator.app") || $0 == "open" })
        let stop = try await recorder.stop(ticket); XCTAssertEqual(stop["recording"].bool, false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try stop["path"].requireString("path")))
        _ = try await recorder.start(ticket); XCTAssertTrue(fake.running)
        _ = try await attachments.detach(sessionID: "s1"); XCTAssertFalse(fake.running)
    }
    /// PFRAME #57: a running Android emulator records through the adb recorder (never simctl).
    func testRecordingRunsAndroidThroughTheAdbRecorder() async throws {
        let (attachments, service, _) = rig(), fake = BackendUIGSessionSimulatorRecordingFake()
        let deviceID = "android:emulator-5554"
        await service.inventory([BackendDeckToolsMachinesPortDevices.entry(BackendDeckToolsMachinesPortObject(["id": .string(deviceID), "platform": .string("android"), "kind": .string("emulator"), "name": .string("Pixel 9")]))])
        let ticket = try await attachments.attach(sessionID: "s1", deviceID: deviceID, service: service)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("UIG-android-recording-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let serials = BackendDeckCoreSecurityTestBox<[String]>([])
        let recorder = BackendUIGSessionSimulatorRecording(attachments: attachments, service: service, picturesDirectory: folder,
            launch: { _ in XCTFail("simctl launched for Android"); return BackendUIGSessionSimulatorRecordingFake() },
            androidLaunch: { serial, file in serials.edit { $0.append(serial) }; fake.launched([file.path]); return fake })
        let status = try await recorder.status(ticket); XCTAssertEqual(status["canRecord"].bool, true)
        let start = try await recorder.start(ticket); XCTAssertEqual(start["recording"].bool, true)
        XCTAssertEqual(serials.get(), ["emulator-5554"])
        let stop = try await recorder.stop(ticket); XCTAssertEqual(stop["recording"].bool, false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try stop["path"].requireString("path")))
    }
    /// ANDROID live run (10 Oct): the engine's list can answer a busy streaming emulator as "unknown"; adb decides then.
    func testRecordingAsksAdbWhenTheListIsUnsureOfAnAndroidDevice() async throws {
        let (attachments, service, _) = rig()
        let deviceID = "android:emulator-5600"
        await service.inventory([BackendDeckToolsMachinesPortDevices.entry(BackendDeckToolsMachinesPortObject(["id": .string(deviceID), "platform": .string("android"), "kind": .string("emulator"), "name": .string("Pixel 8"), "state": .string("unknown")]))])
        let ticket = try await attachments.attach(sessionID: "s1", deviceID: deviceID, service: service)
        let asked = BackendDeckCoreSecurityTestBox<[String]>([])
        for (ready, expected) in [(true, true), (false, false)] {
            let recorder = BackendUIGSessionSimulatorRecording(attachments: attachments, service: service, picturesDirectory: URL(fileURLWithPath: "/fixture/pictures"),
                launch: { _ in XCTFail("simctl launched for Android"); return BackendUIGSessionSimulatorRecordingFake() },
                androidReady: { serial in asked.edit { $0.append(serial) }; return ready })
            let status = try await recorder.status(ticket)
            XCTAssertEqual(status["canRecord"].bool, expected)
        }
        XCTAssertEqual(asked.get(), ["emulator-5600", "emulator-5600"])
    }
    func testRecordingCapabilityRefusesAndroidWithoutLaunching() async throws {
        let (attachments, service, _) = rig()
        let ticket = try await attachments.attach(sessionID: "s1", deviceID: "avd:Pixel_9", service: service)
        let recorder = BackendUIGSessionSimulatorRecording(attachments: attachments, service: service, picturesDirectory: URL(fileURLWithPath: "/fixture/pictures"), launch: { _ in XCTFail("Android recorder launched"); return BackendUIGSessionSimulatorRecordingFake() })
        let status = try await recorder.status(ticket); XCTAssertEqual(status["canRecord"].bool, false)
        do { _ = try await recorder.start(ticket); XCTFail("unsupported record success") } catch {}
    }
    func testSendChannelPinsSessionAndRejectsStaleTicket() async throws {
        let (attachments, service, _) = rig(), sink = BackendUIGSessionSimulatorTestSink(), registry = NativeChannelRegistry()
        let manager = BackendAppDeviceManager(locate: { .unavailable("fixture") }, platform: .init(environment: [:], home: "/fixture"), picturesDirectory: { URL(fileURLWithPath: "/fixture") })
        let viewer = BackendUIGSessionSimulatorViewer(manager: manager, attachments: attachments, authorizeMutation: { _ in }, publish: { _, _ in })
        try await BackendUIGSessionSimulatorChannels.register(registry: registry, ownerID: "uig-fixture", attachments: attachments, service: service, viewer: viewer, requireLocalUI: { context in
            guard context.caller == .nativeApp else { throw NativeRPCError(code: "not-permitted", message: "Local only") }
        }, authorizeMutation: { _ in }, send: { await sink.send($0, $1) })
        let context = NativeRPCContext(caller: .nativeApp, ownerID: "uig-fixture")
        let ticket = try await attachments.attach(sessionID: "s1", deviceID: id, service: service)
        for channel in ["session-simulator:record", "session-simulator:recording"] {
            do {
                _ = try await registry.invoke(channel, context: context, arguments: [ticket.value])
                XCTFail("Dock-only recording action registered")
            } catch let error as NativeRPCError { XCTAssertEqual(error.code, "missing-handler") }
        }
        _ = try await registry.invoke("session-simulator:send", context: context, arguments: [ticket.value, .object([])])
        let sent = await sink.ids(); XCTAssertEqual(sent, ["s1"])
        _ = try await attachments.detach(sessionID: "s1")
        do { _ = try await registry.invoke("session-simulator:send", context: context, arguments: [ticket.value, .object([])]); XCTFail("stale send accepted") } catch {}
        let count = await sink.count(); XCTAssertEqual(count, 1)
        await viewer.stop()
    }
    func testHandoffRechecksAttachmentBeforeReturnSubmission() async throws {
        let (attachments, service, _) = rig(), writes = BackendUIGSessionSimulatorTestWrites()
        let ticket = try await attachments.attach(sessionID: "s1", deviceID: id, service: service)
        do {
            _ = try await BackendUIGSessionSimulatorHandoff.send(ticket: ticket, message: "One composed screenshot message", attachments: attachments,
                gap: { _ = try await attachments.detach(sessionID: "s1") }, write: { _, value in writes.write(value) })
            XCTFail("detached handoff submitted")
        } catch {}
        XCTAssertEqual(writes.captured(), Array(Handoff.terminalWrites("One composed screenshot message").prefix(1)))
    }
    func testAttachmentChangeEventCoversOwnerRebindDetachAndExitWithoutPolling() async throws {
        let sessions = BackendUIGSessionSimulatorTestSessions(), changes = BackendUIGSessionSimulatorTestChanges(), service = BackendDeckToolsMachinesPortDevices()
        let attachments = BackendUIGSessionSimulatorAttachments(resolveLocalSession: { try await sessions.resolve($0) }, attachmentChanged: { changes.changed($0) })
        let first = try await attachments.attach(sessionID: "s1", deviceID: id, service: service)
        let count = changes.captured().count
        _ = try await attachments.attach(sessionID: "s1", deviceID: id, service: service)
        XCTAssertEqual(changes.captured().count, count)
        let next = try await attachments.attach(sessionID: "s1", deviceID: "avd:Pixel_9", service: service)
        _ = try await attachments.detach(sessionID: "s1")
        await attachments.invalidate(sessionID: "s1")
        let events = changes.captured()
        XCTAssertEqual(events.count, 5)
        XCTAssertEqual(events[1]["attachmentToken"].string, first.revision.uuidString)
        XCTAssertEqual(events[2]["attachmentToken"].string, next.revision.uuidString)
        XCTAssertEqual(events[3]["deviceId"], .null)
        XCTAssertEqual(events[4]["invalidated"].bool, true)
        XCTAssertTrue(events.allSatisfy { $0["sessionId"].string == "s1" })
    }
}
