// 22 Oct 2026 (Asad, "your session has been dead because of this 128 limit … remove this thing"): the session
// host had a fixed limit of 128 sessions (finished chats counted too). There is no session-count limit now;
// a finished job's history leaves the list and comes back into the app's list when it is opened again.
import Foundation
import Darwin
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private final class HOSTLimitBox<Value>: @unchecked Sendable {
    private let lock = NSLock(); private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func update(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}

final class HOSTSessionLimitTests: XCTestCase, @unchecked Sendable {
    private func scratch() throws -> URL {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath().appendingPathComponent("tdh-limit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    private func launch(_ directory: URL) throws -> BackendHOSTProtocol.Launch {
        let input = BackendCreateSessionInput(cwd: directory.path, provider: "shell")
        let spec = BackendSpawnSpec(provider: "shell", command: "/bin/sh", args: ["-i"], path: "/usr/bin:/bin")
        return try .init(id: UUID().uuidString.lowercased(), input: input, spawn: spec, inheritedEnvironment: ["HOME": directory.path], openShim: nil)
    }
    private func register(_ manager: BackendPTYManager, _ meta: BackendSessionMeta) throws {
        try manager.registerChat(meta, controls: .init(send: { _ in }, stop: {}, text: { "" }, pid: { nil }))
    }
    private func until(_ condition: @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// 22 Oct (Reviewer, finding 5): launchd starts the helper with 256 open files (about 75 chats). It raises its
    /// own soft limit to the hard one, within the system's per-process limit and the ceiling, and never lowers it.
    func testTheHelperRaisesItsOwnOpenFileLimitAndNeverLowersIt() throws {
        var original = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &original), 0)
        defer { var back = original; _ = setrlimit(RLIMIT_NOFILE, &back) }
        var launchd = original; launchd.rlim_cur = 256
        XCTAssertEqual(setrlimit(RLIMIT_NOFILE, &launchd), 0)
        var perProcess: Int32 = 0, size = MemoryLayout<Int32>.size
        XCTAssertEqual(sysctlbyname("kern.maxfilesperproc", &perProcess, &size, nil, 0), 0)
        let expected = min(BackendHOSTOpenFiles.ceiling, original.rlim_max, rlim_t(perProcess))
        let raised = BackendHOSTOpenFiles.raise()
        var now = rlimit(); XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &now), 0)
        XCTAssertEqual(raised, expected); XCTAssertEqual(now.rlim_cur, expected)
        XCTAssertGreaterThan(raised, 256)
        XCTAssertEqual(BackendHOSTOpenFiles.raise(ceiling: 300), raised) // never lowered
    }

    /// 22 Oct (Reviewer, finding 5): out of file descriptors, the listener used to fire again at once without
    /// accepting (a spin). It pauses briefly, and the waiting connection is taken once a descriptor is free.
    func testOutOfFileDescriptorsTheListenerPausesThenTakesTheWaitingConnection() throws {
        let root = try scratch(), paths = try BackendHOSTPaths(dataDirectory: root)
        _ = try paths.secret(create: true)
        let manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
        let server = try BackendHOSTServer(paths: paths, hostVersion: "out-of-files", manager: manager,
            launch: { $0.metadata }, snapshot: { _ in nil }, onIdle: {})
        defer { server.stopListening() }
        var address = try BackendHOSTSocket.address(paths.socket)
        let waiting = Darwin.socket(AF_UNIX, SOCK_STREAM, 0) // made before the descriptors run out
        XCTAssertGreaterThanOrEqual(waiting, 0)
        defer { Darwin.close(waiting) }
        var original = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &original), 0)
        let lowestFree = Darwin.open("/dev/null", O_RDONLY) // the next descriptor accept would take
        XCTAssertGreaterThanOrEqual(lowestFree, 0); Darwin.close(lowestFree)
        var tight = original; tight.rlim_cur = rlim_t(lowestFree)
        XCTAssertEqual(setrlimit(RLIMIT_NOFILE, &tight), 0)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(waiting, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        Thread.sleep(forTimeInterval: 0.7)
        let tries = server.outOfDescriptors
        var back = original; XCTAssertEqual(setrlimit(RLIMIT_NOFILE, &back), 0)
        XCTAssertEqual(connected, 0)
        XCTAssertGreaterThan(tries, 0)
        XCTAssertLessThan(tries, 12, "a pause between tries, never a spin")
        // Descriptors free again: the queued connection is taken and the app's next one is answered.
        Darwin.shutdown(waiting, SHUT_RDWR)
        let client = try BackendHOSTClient(paths: paths)
        XCTAssertEqual(client.hello.hostVersion, "out-of-files")
    }

    func testTheHostStartsMoreSessionsThanTheOldLimit() throws {
        let root = try scratch(), paths = try BackendHOSTPaths(dataDirectory: root)
        _ = try paths.secret(create: true)
        let manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
        let server = try BackendHOSTServer(paths: paths, hostVersion: "no-session-limit", manager: manager,
            launch: { [self] value in try register(manager, value.metadata); return value.metadata }, snapshot: { _ in nil }, onIdle: {})
        defer { server.stopListening() }
        let client = try BackendHOSTClient(paths: paths)
        for _ in 0..<140 { let value = try launch(root); XCTAssertEqual(try client.create(value).id, value.id) }
        XCTAssertEqual(manager.list().count, 140)
        try client.stopAll()
    }

    func testAnOpenedHistoryReturnsToTheAppListOnlyWhenAskedAndLeavesAgain() async throws {
        let root = try scratch(), paths = try BackendHOSTPaths(dataDirectory: root)
        _ = try paths.secret(create: true)
        let helper = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
        let launched = HOSTLimitBox<[String: BackendSessionMeta]>([:])
        let server = try BackendHOSTServer(paths: paths, hostVersion: "readmit", manager: helper,
            launch: { [self] value in try register(helper, value.metadata); launched.update { $0[value.id] = value.metadata }; return value.metadata },
            snapshot: { id in helper.list().first { $0.id == id }.map { BackendHOSTProtocol.Snapshot(sequence: 0, session: $0, pid: nil, replay: "", screen: nil, scrollbackText: nil, status: .completed) } },
            onIdle: {},
            resource: { [self] method, payload in
                // The helper's chats.open: a finished job's kept history registered again.
                guard method == "chats.open", let id = try NativeRPCValue.parseJSON(payload)["id"].string, var meta = launched.value[id] else { throw BackendHOSTFailure.unavailable }
                meta.exitCode = 0; try register(helper, meta)
                return try JSONEncoder().encode(meta)
            })
        defer { server.stopListening() }
        let client = try BackendHOSTClient(paths: paths)
        let bridge = BackendHOSTManagerBridge(client: client, write: { try client.write($0, bytes: $1, expectedCreatedAt: $2) },
            drain: { try await client.drain(timeoutMilliseconds: $0) }, setWatched: { try client.setWatched($0) },
            stampIndependent: { $0.ownerIndependent = true })
        let ready = XCTestExpectation(description: "attached")
        try bridge.attach(snapshot: { _ in }, event: { _ in }, ready: { ready.fulfill() }, disconnected: {})
        await fulfillment(of: [ready], timeout: 5)
        defer { bridge.detach() }
        let first = try client.create(try launch(root)).id, second = try client.create(try launch(root)).id
        try await until { Set(bridge.list().map(\.id)) == [first, second] }
        try client.remove(first); try client.remove(second)
        try await until { bridge.list().isEmpty }
        // Opened by something else: the removed row stays out (a late snapshot never resurrects it).
        _ = try await client.resource("chats.open", arguments: .object([.init("id", .string(first))]))
        // Opened by this app: it comes back, finished.
        bridge.readmit(second)
        _ = try await client.resource("chats.open", arguments: .object([.init("id", .string(second))]))
        try await until { bridge.list().contains { $0.id == second } }
        XCTAssertEqual(bridge.list().map(\.id), [second])
        XCTAssertEqual(bridge.list().first?.exitCode, 0)
        // Closing it again takes it out again.
        try client.remove(second)
        try await until { bridge.list().isEmpty }
        try client.stopAll()
    }
}
