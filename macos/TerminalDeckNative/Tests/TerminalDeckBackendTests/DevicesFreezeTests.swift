import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

// Devices freeze (Asad, 26 Oct 2026): every devices_* tool timed out, devices_attached included, until the app
// restarted. Seen live: an `adb devices` the device list ran was never reaped (a zombie child of the app for
// hours), so its end never came, the shared device list waited for it forever, and every device call waited
// for that list. These tests stand in a step that never returns and require the next call to answer.

/// A device service whose first list never answers (the lost `adb devices`); every later list answers at once.
private actor DevicesFreezeService: BackendDeckToolsMachinesDeviceService {
    private var lists = 0
    private var stuck: [CheckedContinuation<Void, Never>] = []
    let row = NativeRPCValue.object([.init("id", .string("ios:AAAA-1111")), .init("platform", .string("ios")),
                                     .init("kind", .string("simulator")), .init("state", .string("ready")),
                                     .init("available", .bool(true)), .init("name", .string("iPhone 17"))])
    func listCalls() -> Int { lists }
    /// Lets the stuck list go at the end of a test, so nothing is left suspended.
    func release() { let waiting = stuck; stuck = []; for one in waiting { one.resume() } }
    func unavailable() async -> String? { nil }
    func list() async throws -> [NativeRPCValue] {
        lists += 1
        if lists == 1 { await withCheckedContinuation { stuck.append($0) } }
        return [row]
    }
    func boot(_ id: String) async throws -> NativeRPCValue { .object([.init("ok", .bool(true))]) }
    func shutDown(_ id: String) async throws -> NativeRPCValue { .object([.init("ok", .bool(true))]) }
    func open(_ id: String) async throws -> NativeRPCValue { row }
    func screenshot(_ id: String) async throws -> NativeRPCValue { .object([]) }
    func tap(_ id: String, x: Double, y: Double, holdMS: Int?) async throws {}
    func swipe(_ id: String, from: NativeRPCValue, to: NativeRPCValue, durationMS: Int) async throws {}
    func type(_ id: String, text: String) async throws {}
    func key(_ id: String, key: String, modifiers: [String]) async throws {}
    func button(_ id: String, button: String) async throws {}
    func rotate(_ id: String, to: String) async throws -> String { to }
    func tree(_ id: String, scope: String) async throws -> BackendDeckToolsMachinesDeviceTreeAnswer {
        throw NativeRPCError(code: "unavailable", message: "No tree in this test.")
    }
    func rounds() async throws -> [NativeRPCValue] { [] }
}

/// The calling session's view of the tool door: no approvals, every failure answered in words.
private struct DevicesFreezeEnvironment: BackendDeckToolsMachinesEnvironment {
    let source = BackendDeckToolsMachinesContext(kind: .session, attended: true, sessionID: "s1", machineID: "", keyID: nil,
        rpc: .init(caller: .nativeApp, ownerID: "devices-freeze-test"), startedByCopilot: { _ in false }, noteStarted: { _ in })
    func context(for call: BackendMCPCallContext) async throws -> BackendDeckToolsMachinesContext { source }
    func validate(arguments: NativeRPCValue, schema: NativeRPCValue) async throws {}
    func execute(context: BackendDeckToolsMachinesContext, policy: BackendDeckToolsMachinesPolicy,
                 operation: @escaping @Sendable () async throws -> BackendDeckToolsMachinesOutput) async throws -> BackendMCPToolReply {
        .value(try await operation().value)
    }
    func failed(call: BackendMCPCallContext, tool: BackendMCPTool, policy: BackendDeckToolsMachinesPolicy?,
                loggedArguments: NativeRPCValue, error: any Error) async -> BackendMCPToolReply {
        BackendDeckToolsMachinesFactory.failureReply(error)
    }
}

/// A command runner whose child's end is never reported, as with the unreaped `adb devices`.
private actor DevicesFreezeNeverEnds: BackendAppSessionCommandExecuting {
    private var commands: [String] = []
    private var stuck: [CheckedContinuation<Void, Never>] = []
    func started() -> [String] { commands }
    func release() { let waiting = stuck; stuck = []; for one in waiting { one.resume() } }
    func run(_ command: String, arguments: [String], environment: [String: String], cwd: String,
             timeoutMilliseconds: Int, maximumBytes: Int) async -> BackendAppSessionCommandResult {
        commands.append(command)
        await withCheckedContinuation { stuck.append($0) } // never resumed by the "child": its exit is lost
        return BackendAppSessionCommandResult(stdout: "late", exitCode: 0)
    }
    func detach(_ command: String, arguments: [String], environment: [String: String], cwd: String) async throws {}
}

private final class DevicesFreezeFlag: @unchecked Sendable {
    private let lock = NSLock(); private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

final class DevicesFreezeTests: XCTestCase {
    private func call(_ tool: String, _ attachments: BackendUIGSessionSimulatorAttachments,
                      _ service: DevicesFreezeService) async throws -> BackendMCPToolReply {
        let definitions = try BackendUIGSessionSimulatorMCP(service: service, attachments: attachments)
            .definitions(environment: DevicesFreezeEnvironment())
        let native = BackendMCPCallContext(sessionID: "s1", machineID: "", projectRoot: nil, attended: true, allowedTools: [],
                                           allowedTiers: [.read, .act, .alter], cancellation: .init())
        return try await XCTUnwrap(definitions.first { $0.spec.id == tool }).handler(native, .object([]))
    }
    private func text(_ reply: BackendMCPToolReply) -> String { reply.content.compactMap { $0["text"].string }.joined(separator: "\n") }
    private func waitUntil(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The regression: one device list never answers, and the next device calls (devices_attached, devices_list)
    /// still answer, quickly; the stuck list is let go, so the call after them asks for a fresh one.
    func testDeviceListThatNeverAnswersDoesNotHoldTheNextDeviceCall() async throws {
        let service = DevicesFreezeService()
        let attachments = BackendUIGSessionSimulatorAttachments(
            resolveLocalSession: { .init(sessionID: $0, incarnation: "first") }, inventoryWait: 0.3)
        let stuck = Task { try await attachments.refresh(service: service) }
        try await waitUntil { await service.listCalls() >= 1 }

        let started = Date()
        let attached = try await call("devices.attached", attachments, service)
        XCTAssertFalse(attached.isError, text(attached))
        XCTAssertTrue(text(attached).contains("\"sessionId\":\"s1\""), text(attached))
        let listed = try await call("devices.list", attachments, service)
        XCTAssertFalse(listed.isError, text(listed))
        XCTAssertTrue(text(listed).contains("ios:AAAA-1111"), text(listed))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "a stuck device list must never hold the next device call")

        // The stuck list no longer stands in the way: the next refresh asks the device service again and answers.
        let before = await service.listCalls()
        try await attachments.refresh(service: service)
        let after = await service.listCalls()
        XCTAssertGreaterThan(after, before)

        await service.release()
        _ = try? await stuck.value
    }

    /// The root path: a device command whose end is never reported (the zombie `adb devices`) is let go at its
    /// own limit plus the grace, as a failed run, instead of holding the device list forever.
    func testDeviceCommandWhoseEndIsNeverReportedIsLetGoAtItsDeadline() async throws {
        let executor = DevicesFreezeNeverEnds()
        let quick = Date()
        let answer = await BackendAppDeviceDeadline.command(executor, "/usr/bin/true", arguments: [], environment: [:], cwd: "/",
                                                            timeoutMilliseconds: 100, maximumBytes: 1_024, graceMilliseconds: 100)
        XCTAssertFalse(answer.ok)
        XCTAssertTrue(answer.killed)
        XCTAssertLessThan(Date().timeIntervalSince(quick), 3)

        // Through the device platform the inventory uses (`ps`, a 5 s limit): it comes back empty, not never.
        let platform = BackendAppDevicePlatform(environment: ["PATH": "/usr/bin:/bin"], home: NSTemporaryDirectory(),
                                                executor: executor, commandGraceMilliseconds: 100)
        let started = Date()
        let running = await platform.runningAVDs()
        XCTAssertEqual(running, [])
        XCTAssertLessThan(Date().timeIntervalSince(started), 9)
        let commands = await executor.started()
        XCTAssertEqual(commands, ["/usr/bin/true", "/bin/ps"])
        await executor.release()
    }

    /// A tool call that gives up (its caller cancelled) stops waiting at once and cancels the step it waited for.
    func testCancelledCallerStopsWaitingAndCancelsTheStep() async throws {
        let cancelled = DevicesFreezeFlag()
        let waiting = Task {
            try await BackendAppDeviceDeadline.run(within: 60, "A step") {
                do { try await Task.sleep(for: .seconds(60)) } catch { cancelled.set(); throw error }
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        let started = Date()
        waiting.cancel()
        do { try await waiting.value; XCTFail("a cancelled caller must not get an answer") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        try await waitUntil { cancelled.isSet }
        XCTAssertTrue(cancelled.isSet, "the step itself is cancelled with its caller")
    }

    /// Past its deadline a step answers in words, and a step that answers in time is passed straight through.
    func testDeadlineAnswersInWordsAndPassesTimelyAnswersThrough() async throws {
        let value = try await BackendAppDeviceDeadline.run(within: 5, "A quick step") { 42 }
        XCTAssertEqual(value, 42)
        do {
            _ = try await BackendAppDeviceDeadline.run(within: 0.1, "The device list") { try await Task.sleep(for: .seconds(30)) }
            XCTFail("a step past its deadline must not answer")
        } catch let expired as BackendAppDeviceDeadline.Expired {
            XCTAssertEqual(expired.what, "The device list")
            XCTAssertTrue(expired.localizedDescription.contains("did not answer in time"))
        }
    }
}
