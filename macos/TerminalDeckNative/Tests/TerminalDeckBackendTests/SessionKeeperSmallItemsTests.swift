import Foundation
import Darwin
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor KeeperGateCount {
    var active = 0, peak = 0, finished = 0
    func began() { active += 1; peak = max(peak, active) }
    func ended() { active -= 1; finished += 1 }
}
final class SessionKeeperSmallItemsTests: XCTestCase, @unchecked Sendable {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("keeper-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    func testDrainDeadlineRoundTripsAndLegacyRequestsKeepTheirDefault() throws {
        var request = BackendHOSTProtocol.Request(secret: "fixture", operation: .drain)
        XCTAssertEqual(request.drainTimeout, 2_000)
        request.drainTimeoutMilliseconds = 1_200
        let decoded = try JSONDecoder().decode(BackendHOSTProtocol.Request.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded.drainTimeout, 1_200)
        XCTAssertEqual(BackendHOSTClient.replyDeadlineMilliseconds(decoded), 11_200)
        request.drainTimeoutMilliseconds = Int.max; XCTAssertEqual(request.drainTimeout, 60_000)
        request.drainTimeoutMilliseconds = -1; XCTAssertEqual(request.drainTimeout, 0)
    }
    func testSharedGateSerializesAcrossSuspensions() async {
        let gate = BackendSessionAsyncGate(), count = KeeperGateCount()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await gate.enter(); await count.began(); await Task.yield()
                    await count.ended(); gate.leave()
                }
            }
        }
        let peak = await count.peak, finished = await count.finished
        XCTAssertEqual(peak, 1); XCTAssertEqual(finished, 20); XCTAssertFalse(gate.isBusy)
    }
    func testDifferentSessionSwitchesDoNotBlockEachOther() async {
        let gate = BackendSessionAsyncGate()
        await gate.enter("first")
        await gate.enter("second")
        XCTAssertTrue(gate.isBusy)
        gate.leave("second"); XCTAssertTrue(gate.isBusy)
        gate.leave("first"); XCTAssertFalse(gate.isBusy)
    }
    func testUngatedSpawnStillReportsExecFailure() throws {
        let root = try scratch()
        XCTAssertThrowsError(try BackendPTYProcess.spawn(command: root.appendingPathComponent("missing").path,
            args: [], environment: [:], cwd: root.path, cols: 80, rows: 24, queue: DispatchQueue(label: "keeper.missing")))
    }
    func testGateRefusalNeverExecutesTheChild() throws {
        let root = try scratch(), marker = root.appendingPathComponent("executed")
        XCTAssertThrowsError(try BackendPTYProcess.spawn(command: "/bin/sh", args: ["-c", "touch executed"],
            environment: ["PATH": "/usr/bin:/bin"], cwd: root.path, cols: 80, rows: 24,
            queue: DispatchQueue(label: "keeper.refused"), beforeExec: { pid in
                XCTAssertEqual(Darwin.kill(pid, 0), 0)
                XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
                throw BackendHOSTFailure.unavailable
            }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }
    func testGatedSpawnReleasesAfterItsCallback() async throws {
        let root = try scratch(), marker = root.appendingPathComponent("executed")
        let queue = DispatchQueue(label: "keeper.accepted"), exited = expectation(description: "owned child exited")
        let prepared = expectation(description: "ownership callback completed before exec")
        let process = try BackendPTYProcess.spawn(command: "/bin/sh", args: ["-c", "printf done > executed"],
            environment: [:], cwd: root.path, cols: 80, rows: 24, queue: queue, beforeExec: { _ in
                XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path)); prepared.fulfill()
            })
        defer { queue.sync { process.terminate() } }
        queue.sync { process.onExit = { code in XCTAssertEqual(code, 0); exited.fulfill() }; process.start() }
        await fulfillment(of: [prepared, exited], timeout: 5)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "done")
    }
    func testUnifiedManagerCreateRegistersAndDrainsItsChild() async throws {
        let root = try scratch(), manager = BackendPTYManager(inheritedEnvironment: ["HOME": root.path], onEvent: { _ in })
        let meta = try manager.create(.init(cwd: root.path, provider: "shell"),
            spawn: .init(provider: "shell", command: "/bin/sh", args: ["-c", "exit 0"], path: "/usr/bin:/bin", env: [:]))
        XCTAssertEqual(manager.list().first?.id, meta.id)
        let drained = await manager.drain(timeoutMilliseconds: 2_000)
        XCTAssertTrue(drained)
    }
}
