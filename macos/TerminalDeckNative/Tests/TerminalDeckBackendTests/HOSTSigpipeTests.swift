// HOSTLOST (9 Oct 2026): Asad's managed agents host (the 01:54 helper) exited "due to SIGPIPE | sent by
// TerminalDeckNativeHelper[61184]" at 19:28:41 and took every hosted session with it; the app then
// showed those sessions frozen. A host must survive any reader going away, and the app must see a
// dead or replaced host. Real processes, owned /tmp scratch.
#if TD_HOST_INTEGRATED
import Foundation
import Darwin
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class HOSTSigpipeTests: XCTestCase, @unchecked Sendable {
    private func scratch() throws -> URL {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath().appendingPathComponent("tdh-pipe-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private let history = "i=0; while [ $i -lt 20000 ]; do echo \"history line $i ..........................................\"; i=$((i+1)); done; echo HISTORY-DONE; while IFS= read -r l; do echo \"got-$l\"; done"

    /// The account broker writes a `security` child's input; a child that exits without reading it
    /// must be an EPIPE for the writer, never SIGPIPE for the process (this test process would die).
    func testSecurityRunnerSurvivesAChildThatNeverReadsItsInput() throws {
        for _ in 0..<5 {
            let answer = BackendAccountRealSecurity.runBlocking([], stdin: String(repeating: "x", count: 4 * 1024 * 1024), executable: "/usr/bin/true", timeout: 5)
            XCTAssertEqual(answer.code, 0)
        }
    }

    /// Clients that vanish in the middle of a large reply, 50 times: the host keeps answering.
    func testInProcessHostSurvivesClientsKilledMidSnapshotFiftyTimes() async throws {
        let root = try scratch(), paths = try BackendHOSTPaths(dataDirectory: root); _ = try paths.secret(create: true)
        let manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
        let server = try BackendHOSTServer(paths: paths, hostVersion: "pipe-fixture", manager: manager,
            launch: { try manager.hostCreate($0) }, snapshot: { manager.hostSnapshot($0) }, onIdle: {})
        let client = try BackendHOSTClient(paths: paths)
        defer { client.detach(); server.stopListening(); manager.beginShutdown() }
        var launch = try BackendHOSTProtocol.Launch(id: UUID().uuidString.lowercased(), input: BackendCreateSessionInput(cwd: root.path, provider: "shell"),
            spawn: BackendSpawnSpec(provider: "shell", command: "/bin/sh", args: ["-c", history], path: "/usr/bin:/bin", env: [:]), inheritedEnvironment: ["HOME": root.path])
        launch.ownerIndependent = true
        let session = try client.create(launch)
        try await waitForHistory(client, session.id)
        try killClientsMidSnapshot(paths: paths, instance: client.hello.instance, id: session.id, times: 50)
        XCTAssertNotNil(try client.snapshot(session.id)?.pid)
        try client.stopAll()
    }

    /// The REAL helper binary (release build in the gate: TD_HOST_REAL_HELPER; the old 01:54 helper:
    /// TD_HOST_OLD_HELPER): 50 clients killed mid-snapshot plus 50 viewport-only requests (what the new
    /// app sends) must leave it alive; then it is killed, and the app's bridge reports its session lost.
    func testRealHelperSurvivesKilledClientsAndTheAppSeesItsDeath() async throws {
        let env = ProcessInfo.processInfo.environment
        let helpers = [env["TD_HOST_REAL_HELPER"], env["TD_HOST_OLD_HELPER"]].compactMap { $0 }.filter { FileManager.default.isExecutableFile(atPath: $0) }
        try XCTSkipIf(helpers.isEmpty, "Set TD_HOST_REAL_HELPER / TD_HOST_OLD_HELPER to a helper binary to run this proof.")
        for helperPath in helpers {
            let root = try scratch(), paths = try BackendHOSTPaths(dataDirectory: root); _ = try paths.secret(create: true)
            let helper = Process(); helper.executableURL = URL(fileURLWithPath: helperPath)
            helper.arguments = ["--session-host", root.path, "pipe-proof-v1"]
            helper.standardOutput = FileHandle.nullDevice; helper.standardError = FileHandle.nullDevice
            try helper.run()
            addTeardownBlock { if helper.isRunning { helper.terminate() } }
            var client: BackendHOSTClient?
            for _ in 0..<100 where client == nil { client = try? BackendHOSTClient(paths: paths); if client == nil { try await Task.sleep(for: .milliseconds(100)) } }
            let first = try XCTUnwrap(client, "the helper did not open its socket: " + helperPath)
            let app = BackendPTYManager(inheritedEnvironment: ["HOME": root.path], onEvent: { _ in })
            let bridge = BackendHOSTManagerBridge(client: first, write: { try first.write($0, bytes: $1, expectedCreatedAt: $2) },
                drain: { try await first.drain(timeoutMilliseconds: $0) }, setWatched: { try first.setWatched($0) },
                stampIndependent: { $0.ownerIndependent = true })
            let lost = HOSTPipeLost(), ready = XCTestExpectation(description: "attached")
            bridge.onHostLost { lost.record($0) }
            try app.installHOSTFrontend(bridge, ready: { ready.fulfill() }, disconnected: {})
            await fulfillment(of: [ready], timeout: 5)
            let session = try app.createHOST(BackendCreateSessionInput(cwd: root.path, provider: "shell"),
                spawn: BackendSpawnSpec(provider: "shell", command: "/bin/sh", args: ["-c", history], path: "/usr/bin:/bin", env: [:]),
                context: BackendLaunchContext(), machineID: "", independent: true)
            try await waitForHistory(first, session.id)
            let pid = try XCTUnwrap(try first.snapshot(session.id)?.pid)
            try killClientsMidSnapshot(paths: paths, instance: first.hello.instance, id: session.id, times: 50)
            for _ in 0..<50 { _ = try first.viewport(session.id) }
            XCTAssertTrue(helper.isRunning, "the helper must survive clients that vanish mid-reply: " + helperPath)
            XCTAssertEqual(try first.snapshot(session.id)?.pid, pid, "the same session is still there")
            XCTAssertNil(lost.ids, "a live host is never reported lost")
            // Now the host really dies: the app's bridge must say so (within its bounded check).
            XCTAssertEqual(Darwin.kill(helper.processIdentifier, SIGKILL), 0)
            let until = Date().addingTimeInterval(10)
            while lost.ids == nil, Date() < until { try await Task.sleep(for: .milliseconds(100)) }
            XCTAssertEqual(lost.ids, [session.id], "the app sees its host die and names the session it lost")
            XCTAssertTrue(bridge.anyHostLost)
            app.detachHOSTFrontend()
            _ = Darwin.kill(-pid, SIGKILL) // the orphaned scratch shell
        }
    }

    private func waitForHistory(_ client: BackendHOSTClient, _ id: String) async throws {
        let until = Date().addingTimeInterval(60)
        while Date() < until {
            if (try client.snapshot(id)?.replay ?? "").contains("HISTORY-DONE") { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTFail("history never finished")
    }
    /// A raw control connection asks for the full snapshot (megabytes), reads 4 bytes and is gone.
    private func killClientsMidSnapshot(paths: BackendHOSTPaths, instance: UUID, id: String, times: Int) throws {
        let secret = try paths.secret(create: false)
        for _ in 0..<times {
            let fd = try BackendHOSTSocket.connect(paths.socket)
            var request = BackendHOSTProtocol.Request(secret: secret, operation: .snapshot, id: id); request.instance = instance
            try BackendHOSTSocket.write(request, to: fd, maximum: BackendHOSTProtocol.maximumRequestBytes)
            var four = [UInt8](repeating: 0, count: 4); _ = Darwin.recv(fd, &four, 4, 0)
            var linger = linger(l_onoff: 1, l_linger: 0) // reset, not a polite close
            _ = setsockopt(fd, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<linger>.size))
            Darwin.close(fd)
        }
    }
}

private final class HOSTPipeLost: @unchecked Sendable {
    private let lock = NSLock(); private var value: [String]?
    func record(_ ids: [String]) { lock.withLock { value = ids } }
    var ids: [String]? { lock.withLock { value } }
}
#endif
