import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

// Draft only: copy into the backend test target after HOOTSIM-engine.patch
// is applied and the required one-build wrapper can compile each product save.
private actor HOOTSIMEngineEnvironment: BackendDeckToolsMachinesEnvironment {
    let source: BackendDeckToolsMachinesContext
    let approve: @Sendable (BackendDeckToolsMachinesPolicy) async throws -> Void
    private var policies: [BackendDeckToolsMachinesPolicy] = []
    init(source: BackendDeckToolsMachinesContext,
         approve: @escaping @Sendable (BackendDeckToolsMachinesPolicy) async throws -> Void = { _ in }) {
        self.source = source; self.approve = approve
    }
    func context(for call: BackendMCPCallContext) -> BackendDeckToolsMachinesContext { source }
    func validate(arguments: NativeRPCValue, schema: NativeRPCValue) throws {
        try BackendDeckCoreCatalogueSchema.check(schema: schema, arguments: arguments)
    }
    func execute(context: BackendDeckToolsMachinesContext, policy: BackendDeckToolsMachinesPolicy,
                 operation: @escaping @Sendable () async throws -> BackendDeckToolsMachinesOutput) async throws -> BackendMCPToolReply {
        policies.append(policy)
        try await approve(policy)
        return .value(try await operation().value)
    }
    func failed(call: BackendMCPCallContext, tool: BackendMCPTool, policy: BackendDeckToolsMachinesPolicy?,
                loggedArguments: NativeRPCValue, error: any Error) -> BackendMCPToolReply {
        BackendDeckToolsMachinesFactory.failureReply(error)
    }
    func captured() -> [BackendDeckToolsMachinesPolicy] { policies }
}
private final class HOOTSIMEngineRecordProcess: BackendUIGSessionSimulatorRecordingProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var launches: [[String]] = []
    var running: Bool { lock.withLock { active } }
    func launch(_ arguments: [String]) { lock.withLock { active = true; launches.append(arguments) } }
    func captured() -> [[String]] { lock.withLock { launches } }
    func interrupt() { lock.withLock { active = false } }
    func finished() async -> Int32 {
        if let path = lock.withLock({ launches.last?.last }) { try? Data([1]).write(to: URL(fileURLWithPath: path)) }
        return 0
    }
}
final class HOOTSIMEngineTests: XCTestCase, @unchecked Sendable {
    typealias V = NativeRPCValue
    private struct Rig: Sendable {
        let service: BackendDeckToolsMachinesPortDevices
        let attachments: BackendUIGSessionSimulatorAttachments
        let recording: BackendUIGSessionSimulatorRecording
        let process: HOOTSIMEngineRecordProcess
        let folder: URL
        let first: String
        let second: String
        func finish() async { await recording.stopAll(); try? FileManager.default.removeItem(at: folder) }
    }
    private func rig() async throws -> Rig {
        let service = BackendDeckToolsMachinesPortDevices()
        let first = "ios:" + UUID().uuidString, second = "ios:" + UUID().uuidString
        await service.inventory([first, second].map { BackendDeckToolsMachinesPortDevices.entry(.object([.init("id", .string($0))])) })
        let attachments = BackendUIGSessionSimulatorAttachments(resolveLocalSession: { id in
            guard id == "s1" else { throw NativeRPCError(code: "not-permitted", message: "Session exited") }
            return .init(sessionID: id, incarnation: "scratch-one")
        })
        _ = try await attachments.attach(sessionID: "s1", deviceID: first, slot: 0, service: service)
        _ = try await attachments.attach(sessionID: "s1", deviceID: second, slot: 1, service: service)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HOOTSIM-engine-" + UUID().uuidString + ".noindex")
        let process = HOOTSIMEngineRecordProcess()
        let recorder = BackendUIGSessionSimulatorRecording(attachments: attachments, service: service, picturesDirectory: folder,
            launch: { args in process.launch(args); return process })
        return Rig(service: service, attachments: attachments, recording: recorder, process: process, folder: folder, first: first, second: second)
    }
    private func definitions(_ rig: Rig, _ environment: HOOTSIMEngineEnvironment) throws -> [BackendDeckToolsDefinition] {
        try BackendUIGSessionSimulatorMCP(service: rig.service, attachments: rig.attachments, recording: rig.recording).definitions(environment: environment)
    }
    private func call(_ id: String, _ args: V, rig: Rig, environment: HOOTSIMEngineEnvironment) async throws -> BackendMCPToolReply {
        let row = try XCTUnwrap(definitions(rig, environment).first { $0.spec.id == id })
        return try await row.handler(BackendDeckToolsMachinesPortNativeContext(), args)
    }
    func testIndexedCatalogueKeepsOneSharedDeviceFamilyAndRecorder() async throws {
        let rig = try await rig(), environment = HOOTSIMEngineEnvironment(source: BackendDeckToolsMachinesPortContext())
        let rows = try definitions(rig, environment)
        let ids = rows.map(\.spec.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertEqual(Set(ids), Set(BackendDeckToolsMachinesDevices.ids + ["devices.attached", "devices.attach", "devices.detach", "devices.record", "devices.recording"]))
        XCTAssertTrue(rows.allSatisfy { !$0.spec.advertised })
        await rig.finish()
    }
    func testHootListsExistingToolsRunBeforeAndAfterItsLeaseIsBound() throws {
        let metadata = try BackendDeckCoreCatalogueDescribe.tools(catalogue: { [] }).metadata
        for caller in [BackendDeckCoreSecurityCaller.local,
                       BackendDeckCoreSecurityCaller(kind: .local, tiers: [.read, .act, .alter], sessionID: "hoot-scratch")] {
            let rows = try BackendDeckCoreCatalogueDescribe.wireListing(metadata: metadata, caller: caller, granted: nil)
            XCTAssertTrue(rows.contains { $0["name"].string == BackendDeckCoreCatalogueDescribe.runWire })
            XCTAssertLessThanOrEqual(rows.count, BackendDeckCoreCatalogueRules.maxCatalogueTools)
        }
        let refused = try BackendDeckCoreCatalogueDescribe.wireListing(metadata: metadata, caller: .local, granted: [BackendDeckCoreCatalogueDescribe.id])
        XCTAssertFalse(refused.contains { $0["name"].string == BackendDeckCoreCatalogueDescribe.runWire })
    }
    func testHootReadsAreFreeAndDeviceChangesRequireAnOwnerAnswer() async throws {
        let rig = try await rig(), context = BackendDeckToolsMachinesPortContext()
        let devices = BackendDeckToolsMachinesDevices(service: rig.service)
        let rows = try definitions(rig, HOOTSIMEngineEnvironment(source: context))
        for id in BackendDeckToolsMachinesDevices.ids where id != "devices.find" {
            let spec = try XCTUnwrap(rows.first { $0.spec.id == id }?.spec)
            var args = V.object([.init("deviceId", .string(rig.first))])
            if id == "devices.tap" { args = args.setting("x", .number(0.5)).setting("y", .number(0.5)) }
            if id == "devices.swipe" { args = args.setting("direction", .string("up")) }
            if id == "devices.type" { args = args.setting("text", .string("secret")) }
            if id == "devices.button" { args = args.setting("button", .string("home")) }
            let policy = try await devices.policy(spec, args, context)
            XCTAssertEqual(policy.ownerMustAnswer, spec.tier != .read, id)
            if id == "devices.type" { XCTAssertEqual(policy.loggedArguments["text"].string, "[6 characters]") }
        }
        await rig.finish()
    }
    func testDeniedHootInputDoesNotReachTheSharedEngine() async throws {
        let rig = try await rig()
        await rig.service.clear()
        let environment = HOOTSIMEngineEnvironment(source: BackendDeckToolsMachinesPortContext()) { policy in
            XCTAssertTrue(policy.ownerMustAnswer)
            throw BackendDeckCoreSecurityRefusal(.declined, "Denied")
        }
        let result = try await call("devices.tap", .object([.init("deviceId", .string(rig.first)), .init("x", .number(0.5)), .init("y", .number(0.5))]), rig: rig, environment: environment)
        XCTAssertTrue(result.isError)
        let inputs = await rig.service.names()
        XCTAssertFalse(inputs.contains("tap"))
        await rig.finish()
    }
    func testTwoPhoneRecordingRequiresAnExplicitDevice() async throws {
        let rig = try await rig(), environment = HOOTSIMEngineEnvironment(source: BackendDeckToolsMachinesPortContext())
        for id in ["devices.record", "devices.recording"] {
            let result = try await call(id, .object([.init("sessionId", .string("s1")), .init("action", .string("start"))].filter { id == "devices.record" || $0.key != "action" }), rig: rig, environment: environment)
            XCTAssertTrue(result.isError, id)
        }
        XCTAssertTrue(rig.process.captured().isEmpty)
        let policies = await environment.captured()
        XCTAssertTrue(policies.isEmpty)
        await rig.finish()
    }
    func testHootRecordsTheSecondPhoneThroughTheExistingRecorder() async throws {
        let rig = try await rig(), environment = HOOTSIMEngineEnvironment(source: BackendDeckToolsMachinesPortContext())
        let args = V.object([.init("sessionId", .string("s1")), .init("deviceId", .string(rig.second)), .init("action", .string("start"))])
        let result = try await call("devices.record", args, rig: rig, environment: environment)
        XCTAssertFalse(result.isError)
        XCTAssertEqual(result.structuredContent?["deviceId"].string, rig.second)
        XCTAssertEqual(result.structuredContent?["slot"].number, 1)
        XCTAssertEqual(rig.process.captured().first?[2], String(rig.second.dropFirst(4)))
        let policies = await environment.captured()
        XCTAssertEqual(policies.first?.ownerMustAnswer, true)
        let status = try await call("devices.recording", args.removing("action"), rig: rig, environment: environment)
        XCTAssertFalse(status.isError)
        let after = await environment.captured()
        XCTAssertEqual(after.last?.tier, .read)
        XCTAssertEqual(after.last?.ownerMustAnswer, false)
        await rig.finish()
    }
    func testRecordingRechecksAttachmentAfterApprovalBeforeStarting() async throws {
        let rig = try await rig()
        let environment = HOOTSIMEngineEnvironment(source: BackendDeckToolsMachinesPortContext()) { _ in
            _ = try await rig.attachments.detach(sessionID: "s1", slot: 1)
            _ = try await rig.attachments.attach(sessionID: "s1", deviceID: rig.second, slot: 1, service: rig.service)
        }
        let result = try await call("devices.record", .object([.init("sessionId", .string("s1")), .init("deviceId", .string(rig.second)), .init("action", .string("start"))]), rig: rig, environment: environment)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(rig.process.captured().isEmpty)
        await rig.finish()
    }
    func testOrdinarySessionCannotRecordAnotherSessionsPhone() async throws {
        let rig = try await rig(), environment = HOOTSIMEngineEnvironment(source: BackendDeckToolsMachinesPortContext(.session, session: "s1"))
        let result = try await call("devices.record", .object([.init("sessionId", .string("s1")), .init("deviceId", .string(rig.second)), .init("action", .string("start"))]), rig: rig, environment: environment)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(rig.process.captured().isEmpty)
        await rig.finish()
    }
}

extension HOOTSIMEngineTests {
    func testAndroidEmulatorRecordsThroughTheSharedInjectedRecorderWithoutBooting() async throws {
        let service = BackendDeckToolsMachinesPortDevices(), device = "android:emulator-5554"
        await service.inventory([BackendDeckToolsMachinesPortDevices.entry(.object([.init("id", .string(device)),
            .init("platform", .string("android")), .init("kind", .string("emulator")), .init("state", .string("ready"))]))])
        let attachments = BackendUIGSessionSimulatorAttachments(resolveLocalSession: { .init(sessionID: $0, incarnation: "stub-android") })
        _ = try await attachments.attach(sessionID: "s1", deviceID: device, service: service)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HOOTSIM-android-record-" + UUID().uuidString + ".noindex")
        defer { try? FileManager.default.removeItem(at: folder) }
        let fake = HOOTSIMEngineRecordProcess(), environment = HOOTSIMEngineEnvironment(source: BackendDeckToolsMachinesPortContext())
        let recorder = BackendUIGSessionSimulatorRecording(attachments: attachments, service: service, picturesDirectory: folder,
            launch: { _ in XCTFail("Android must not use simctl"); throw NativeRPCError(code: "fixture", message: "Unexpected iOS recorder") },
            androidLaunch: { serial, file in fake.launch(["stub-adb", serial, file.path]); return fake })
        let tools = try BackendUIGSessionSimulatorMCP(service: service, attachments: attachments, recording: recorder).definitions(environment: environment)
        let record = try XCTUnwrap(tools.first { $0.spec.id == "devices.record" }), status = try XCTUnwrap(tools.first { $0.spec.id == "devices.recording" })
        let args = V.object([.init("sessionId", .string("s1")), .init("deviceId", .string(device))])
        let started = try await record.handler(BackendDeckToolsMachinesPortNativeContext(), args.setting("action", .string("start")))
        XCTAssertFalse(started.isError); XCTAssertEqual(fake.captured().first.map { Array($0.dropLast()) }, ["stub-adb", "emulator-5554"])
        let running = try await status.handler(BackendDeckToolsMachinesPortNativeContext(), args)
        XCTAssertEqual(running.structuredContent?["recording"].bool, true)
        let stopped = try await record.handler(BackendDeckToolsMachinesPortNativeContext(), args.setting("action", .string("stop")))
        XCTAssertFalse(stopped.isError); XCTAssertEqual(stopped.structuredContent?["recording"].bool, false)
        let policies = await environment.captured()
        XCTAssertEqual(policies.map(\.ownerMustAnswer), [true, false, true])
        let operations = await service.names(); XCTAssertFalse(operations.contains("boot"))
        await recorder.stopAll()
    }
    func testHootAndPanelReadTheSameServiceAndScreenshotAndTreeRemainFree() async throws {
        let rig = try await rig(), environment = HOOTSIMEngineEnvironment(source: BackendDeckToolsMachinesPortContext())
        let hoot = BackendUIGSessionSimulatorMCP(service: rig.service, attachments: rig.attachments, recording: rig.recording)
        let panel = BackendDeckToolsMachinesDevices(service: rig.service)
        XCTAssertTrue((hoot.service as AnyObject) === (panel.service as AnyObject))
        await rig.service.clear()
        let tools = try hoot.definitions(environment: environment)
        let args = V.object([.init("deviceId", .string(rig.first))])
        for id in ["devices.screenshot", "devices.tree"] {
            let tool = try XCTUnwrap(tools.first { $0.spec.id == id })
            let read = try await tool.handler(BackendDeckToolsMachinesPortNativeContext(), args)
            XCTAssertFalse(read.isError, id)
        }
        let policies = await environment.captured()
        XCTAssertTrue(policies.allSatisfy { $0.tier == .read && !$0.ownerMustAnswer })
        let operations = await rig.service.names()
        XCTAssertTrue(operations.contains("screenshot")); XCTAssertTrue(operations.contains("tree")); XCTAssertFalse(operations.contains("boot"))
        await rig.finish()
    }
}
