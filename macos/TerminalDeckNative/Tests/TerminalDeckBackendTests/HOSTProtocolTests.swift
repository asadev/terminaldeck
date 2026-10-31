import Foundation
import Darwin
import XCTest
@testable import TerminalDeckBackend

final class HOSTProtocolTests: XCTestCase, @unchecked Sendable {
    override func setUpWithError() throws {
    }

    private func scratch() throws -> URL {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath().appendingPathComponent("tdh-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
    private func launch(_ directory: URL, id: String = UUID().uuidString.lowercased()) throws -> BackendHOSTProtocol.Launch {
        let input = BackendCreateSessionInput(cwd: directory.path, provider: "shell")
        let spec = BackendSpawnSpec(provider: "shell", command: "/bin/sh", args: ["-i"], path: "/usr/bin:/bin",
                                    env: ["HOST_TEST_VALUE": "Unicode 🦉\nsecond line"], removeEnv: ["REMOVE_THIS"])
        return try .init(id: id, input: input, spawn: spec,
                         inheritedEnvironment: ["REMOVE_THIS": "gone", "CLAUDECODE": "parent", "HOME": directory.path],
                         openShim: (directory.path + "/shim", directory.path + "/shim/open"))
    }
    func testResolvedLaunchRoundTripKeepsPolicyAndExactAppEnvironment() throws {
        let original = try launch(scratch())
        let decoded = try JSONDecoder().decode(BackendHOSTProtocol.Launch.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(decoded.id, original.id); XCTAssertEqual(decoded.metadata, original.metadata)
        XCTAssertEqual(decoded.input, original.input); XCTAssertEqual(decoded.command, original.command)
        XCTAssertEqual(decoded.arguments, original.arguments); XCTAssertEqual(decoded.environment, original.environment)
        XCTAssertNil(decoded.environment["CLAUDECODE"]); XCTAssertNil(decoded.environment["REMOVE_THIS"])
        XCTAssertEqual(decoded.environment["TERM"], "xterm-256color")
        XCTAssertEqual(decoded.environment[BackendSessionEnvironment.sessionVariable], decoded.id)
        XCTAssertEqual(decoded.environment["BROWSER"], original.cwd + "/shim/open")
        XCTAssertEqual(decoded.environment["PATH"], original.cwd + "/shim:/usr/bin:/bin")
    }
    func testProtocolEventsRoundTripEveryExistingEvent() throws {
        let id = UUID().uuidString.lowercased()
        let events: [BackendSessionEvent] = [.data(id: id, text: "split 🦉\u{1b}[31m"), .exit(id: id, exitCode: 137),
                                            .status(id: id, status: .working), .removed(id: id, reason: .replaced)]
        for event in events {
            let encoded = BackendHOSTProtocol.Event(sequence: 42, event: event)
            let decoded = try JSONDecoder().decode(BackendHOSTProtocol.Event.self, from: JSONEncoder().encode(encoded))
            let reencoded = BackendHOSTProtocol.Event(sequence: decoded.sequence, event: try decoded.sessionEvent())
            XCTAssertEqual(reencoded.sequence, 42); XCTAssertEqual(reencoded.id, id)
            XCTAssertEqual(reencoded.kind, encoded.kind); XCTAssertEqual(reencoded.text, encoded.text)
            XCTAssertEqual(reencoded.exitCode, encoded.exitCode); XCTAssertEqual(reencoded.status, encoded.status)
            XCTAssertEqual(reencoded.reason, encoded.reason)
        }
    }
    func testFramingRoundTrip() throws {
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { Darwin.close(pair[0]); Darwin.close(pair[1]) }
        for fd in pair { try BackendHOSTSocket.secure(fd) }
        let original = BackendHOSTProtocol.Request(secret: "test-secret", operation: .hello)
        try BackendHOSTSocket.write(original, to: pair[0])
        let decoded = try BackendHOSTSocket.read(BackendHOSTProtocol.Request.self, from: pair[1], maximum: BackendHOSTProtocol.maximumRequestBytes)
        XCTAssertEqual(decoded.secret, original.secret); XCTAssertEqual(decoded.operation, .hello)
    }
    func testOversizedRequestIsRefusedBeforeBodyRead() throws {
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { Darwin.close(pair[0]); Darwin.close(pair[1]) }
        var count = UInt32(BackendHOSTProtocol.maximumRequestBytes + 1).bigEndian
        XCTAssertEqual(Darwin.write(pair[0], &count, 4), 4)
        XCTAssertThrowsError(try BackendHOSTSocket.read(BackendHOSTProtocol.Request.self, from: pair[1], maximum: BackendHOSTProtocol.maximumRequestBytes))
    }
    func testPartialHeaderHitsTotalFrameDeadline() throws {
        var pair: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair), 0)
        defer { Darwin.close(pair[0]); Darwin.close(pair[1]) }
        var byte: UInt8 = 0
        XCTAssertEqual(Darwin.write(pair[0], &byte, 1), 1)
        let started = DispatchTime.now().uptimeNanoseconds
        XCTAssertThrowsError(try BackendHOSTSocket.read(BackendHOSTProtocol.Request.self, from: pair[1], frameTimeoutMilliseconds: 20)) { error in
            guard case BackendHOSTFailure.io(let code) = error else { return XCTFail("Expected a bounded read failure.") }
            XCTAssertEqual(code, ETIMEDOUT)
        }
        XCTAssertLessThan(DispatchTime.now().uptimeNanoseconds - started, 1_000_000_000)
    }

    private func attachedFixture(trace: HOSTReceiptTrace) async throws -> (BackendHOSTServer, BackendHOSTClient, UUID, BackendSessionMeta) {
        let root = try scratch(), paths = try BackendHOSTPaths(dataDirectory: root); _ = try paths.secret(create: true)
        let manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
        let server = try BackendHOSTServer(paths: paths, hostVersion: "receipt-fixture", manager: manager,
            launch: { $0.metadata }, snapshot: { _ in nil }, onIdle: {})
        let client = try BackendHOSTClient(paths: paths), ready = expectation(description: "attached fixture")
        try client.attach(onSnapshot: { _ in trace.append("snapshot") }, onEvent: { trace.append($0.kind.rawValue) }, onReady: { ready.fulfill() }, onDisconnect: {})
        await fulfillment(of: [ready], timeout: 5)
        return (server, client, try XCTUnwrap(client.hostTestingGeneration()), try launch(root).metadata)
    }
    func testRemovalReplyBeforeReceiptsStillDeliversOneRemovalAndOneExit() async throws {
        let trace = HOSTReceiptTrace(), (server, client, generation, meta) = try await attachedFixture(trace: trace)
        defer { client.detach(); server.stopListening() }
        try client.hostTestingReceive(.init(snapshot: .init(sequence: 1, session: meta, pid: 123,
            replay: "", screen: nil, scrollbackText: nil, status: .idle)), generation: generation)
        try client.remove(meta.id) // RPC reply wins the race; tombstone already exists.
        let removed = BackendHOSTProtocol.Event(sequence: 2, event: .removed(id: meta.id, reason: .stopped))
        let exited = BackendHOSTProtocol.Event(sequence: 3, event: .exit(id: meta.id, exitCode: 137))
        for event in [removed, exited, removed, exited] { try client.hostTestingReceive(.init(event: event), generation: generation) }
        XCTAssertEqual(trace.values, ["snapshot", "removed", "exit"])
        XCTAssertTrue(client.cachedSessions().isEmpty)
        try client.hostTestingReceive(.init(snapshot: .init(sequence: 1, session: meta, pid: 123,
            replay: "stale", screen: nil, scrollbackText: nil, status: .idle)), generation: generation)
        XCTAssertTrue(client.cachedSessions().isEmpty)
    }
    func testRefreshCoveringExitDoesNotSwallowExitOrReplayOldData() async throws {
        let trace = HOSTReceiptTrace(), (server, client, generation, live) = try await attachedFixture(trace: trace)
        defer { client.detach(); server.stopListening() }
        var meta = live; meta.exitCode = 0
        try client.hostTestingReceive(.init(snapshot: .init(sequence: 10, session: meta, pid: nil,
            replay: "already replayed", screen: nil, scrollbackText: nil, status: .exited)), generation: generation)
        let exit = BackendHOSTProtocol.Event(sequence: 9, event: .exit(id: meta.id, exitCode: 0))
        try client.hostTestingReceive(.init(event: exit), generation: generation)
        try client.hostTestingReceive(.init(event: exit), generation: generation)
        try client.hostTestingReceive(.init(event: .init(sequence: 8, event: .data(id: meta.id, text: "already replayed"))), generation: generation)
        XCTAssertEqual(trace.values, ["snapshot", "exit"])
        XCTAssertEqual(client.cachedSessions().first?.exitCode, 0)
    }
    func testNewSessionDuringHydrationGetsSnapshotBeforeItsFollowingOutput() async throws {
        let trace = HOSTReceiptTrace(), (server, client, generation, meta) = try await attachedFixture(trace: trace)
        defer { client.detach(); server.stopListening() }
        try client.hostTestingReceive(.init(event: .init(sequence: 5, event: .data(id: meta.id, text: "following"))), generation: generation)
        XCTAssertTrue(trace.values.isEmpty)
        try client.hostTestingReceive(.init(snapshot: .init(sequence: 4, session: meta, pid: 123,
            replay: "before", screen: nil, scrollbackText: nil, status: .idle)), generation: generation)
        XCTAssertEqual(trace.values, ["snapshot", "data"])
        XCTAssertEqual(client.cachedSessions().first?.id, meta.id)
    }
    func testUnknownSessionExitWaitsForEarlierOutputAndNeverRestoresLiveMetadata() async throws {
        let trace = HOSTReceiptTrace(), (server, client, generation, meta) = try await attachedFixture(trace: trace)
        defer { client.detach(); server.stopListening() }
        try client.hostTestingReceive(.init(event: .init(sequence: 5, event: .data(id: meta.id, text: "final output"))), generation: generation)
        try client.hostTestingReceive(.init(event: .init(sequence: 6, event: .exit(id: meta.id, exitCode: 7))), generation: generation)
        XCTAssertTrue(trace.values.isEmpty)
        try client.hostTestingReceive(.init(snapshot: .init(sequence: 4, session: meta, pid: 123,
            replay: "before", screen: nil, scrollbackText: nil, status: .idle)), generation: generation)
        XCTAssertEqual(trace.values, ["snapshot", "data", "exit"])
        XCTAssertEqual(client.cachedSessions().first?.exitCode, 7)
        XCTAssertNil(client.cachedPID(meta.id))
    }
    func testOldGenerationAndSetupFailureCannotReplaceCurrentAttachment() async throws {
        let trace = HOSTReceiptTrace(), (server, client, oldGeneration, meta) = try await attachedFixture(trace: trace)
        defer { client.detach(); server.stopListening() }
        let ready = expectation(description: "new attachment")
        try client.attach(onSnapshot: { _ in trace.append("new snapshot") }, onEvent: { _ in }, onReady: { ready.fulfill() }, onDisconnect: {})
        await fulfillment(of: [ready], timeout: 5)
        let current = try XCTUnwrap(client.hostTestingGeneration())
        XCTAssertNotEqual(oldGeneration, current)
        client.hostTestingSetupFailed(generation: oldGeneration)
        try client.hostTestingReceive(.init(snapshot: .init(sequence: 2, session: meta, pid: 123,
            replay: "stale", screen: nil, scrollbackText: nil, status: .idle)), generation: oldGeneration)
        XCTAssertTrue(client.cachedSessions().isEmpty); XCTAssertTrue(client.isConnected)
        try client.hostTestingReceive(.init(snapshot: .init(sequence: 3, session: meta, pid: 123,
            replay: "current", screen: nil, scrollbackText: nil, status: .idle)), generation: current)
        XCTAssertEqual(trace.values, ["new snapshot"])
    }
    func testSecretIsStablePrivateAndSymlinksAreRefused() throws {
        let root = try scratch(), paths = try BackendHOSTPaths(dataDirectory: root)
        let first = try paths.secret(create: true)
        XCTAssertEqual(first.count, 64); XCTAssertEqual(try paths.secret(create: true), first)
        var directory = stat(), secret = stat()
        XCTAssertEqual(lstat(paths.directory.path, &directory), 0); XCTAssertEqual(directory.st_mode & 0o777, 0o700)
        XCTAssertEqual(lstat(paths.secretFile.path, &secret), 0); XCTAssertEqual(secret.st_mode & 0o777, 0o600)
        let other = root.appendingPathComponent("other")
        try Data(first.utf8).write(to: other)
        try FileManager.default.removeItem(at: paths.secretFile)
        XCTAssertEqual(symlink(other.path, paths.secretFile.path), 0)
        XCTAssertThrowsError(try paths.secret(create: false))
    }
    func testInsecureHostDirectoryIsRefusedWithoutChangingItsMode() throws {
        let paths = try BackendHOSTPaths(dataDirectory: scratch())
        try FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        XCTAssertThrowsError(try paths.secret(create: true))
        var info = stat(); XCTAssertEqual(lstat(paths.directory.path, &info), 0); XCTAssertEqual(info.st_mode & 0o777, 0o755)
    }
    func testScratchLaunchAgentCannotUseProductionLabel() throws {
        let root = try scratch(), paths = try BackendHOSTPaths(dataDirectory: root)
        let plan = try BackendHOSTLaunchAgent(paths: paths, version: "test-v1", launchAgentsDirectory: root)
        XCTAssertNotEqual(plan.label, BackendHOSTLaunchAgent.productionLabel)
        XCTAssertThrowsError(try BackendHOSTLaunchAgent(paths: paths, version: "v1", launchAgentsDirectory: root, label: BackendHOSTLaunchAgent.productionLabel))
        let raw = try XCTUnwrap(PropertyListSerialization.propertyList(from: plan.propertyList(), format: nil) as? [String: Any])
        XCTAssertEqual(raw["RunAtLoad"] as? Bool, false)
        XCTAssertEqual(raw["AbandonProcessGroup"] as? Bool, false)
        // PERF (9 Oct): the host serves live terminals: never launchd's CPU/IO-clamped Background type.
        XCTAssertEqual(raw["ProcessType"] as? String, "Interactive")
        XCTAssertNil(raw["LowPriorityIO"]); XCTAssertNil(raw["LowPriorityBackgroundIO"]); XCTAssertNil(raw["Nice"])
        let keep = try XCTUnwrap(raw["KeepAlive"] as? [String: Any])
        XCTAssertEqual(keep["PathState"] as? [String: Bool], [paths.activeFile.path: true])
        XCTAssertEqual(raw["ProgramArguments"] as? [String], [plan.helper.path, "--session-host", root.resolvingSymlinksInPath().path, "test-v1"])
    }
    func testFallbackAndUpdateNeverClaimUnsafeDetach() throws {
        let resources = BackendHOSTReadiness()
        XCTAssertEqual(BackendHOSTPolicy.exit(keep: true, installingUpdate: false, hostConnected: false, resources: resources), .stayResident)
        XCTAssertEqual(BackendHOSTPolicy.exit(keep: false, installingUpdate: true, hostConnected: true, resources: resources), .stayResident)
        XCTAssertEqual(BackendHOSTPolicy.exit(keep: false, installingUpdate: false, hostConnected: true, resources: resources), .stop)
        XCTAssertThrowsError(try BackendHOSTClient(paths: BackendHOSTPaths(dataDirectory: scratch())))
        XCTAssertEqual(BackendHOSTPolicy.fallbackMessage, "Sessions won't survive updates right now.")
    }
    func testEveryResourceMustBeReadyBeforeKeepOrUpdateCanDetach() {
        var resources = BackendHOSTReadiness()
        resources.accountLeases = true; resources.hookEndpoint = true; resources.mcpGrantsAndFiles = true
        resources.pendingSwitches = true
        XCTAssertFalse(resources.safeToDetach)
        resources.taskAndReceiverClaims = true
        XCTAssertEqual(BackendHOSTPolicy.exit(keep: true, installingUpdate: false, hostConnected: true, resources: resources), .detach)
        XCTAssertEqual(BackendHOSTPolicy.exit(keep: false, installingUpdate: true, hostConnected: true, resources: resources), .detach)
    }
    func testSavedTabMatchingUsesIdentityInsteadOfFolder() throws {
        let row = try launch(scratch()).metadata
        XCTAssertFalse(BackendHOSTPolicy.claimed(savedID: nil, tabKey: nil, provider: "shell", conversation: nil, attached: [row]))
        XCTAssertTrue(BackendHOSTPolicy.claimed(savedID: row.id, tabKey: nil, provider: "shell", conversation: nil, attached: [row]))
    }
    func testAuthenticatedServerRoundTripAndIdempotentLaunch() throws {
        let root = try scratch(), paths = try BackendHOSTPaths(dataDirectory: root)
        _ = try paths.secret(create: true)
        let manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in }), calls = HOSTCallCount()
        let server = try BackendHOSTServer(paths: paths, hostVersion: "older-compatible", manager: manager,
                                          launch: { value in calls.increment(); return value.metadata }, snapshot: { _ in nil }, onIdle: {})
        defer { server.stopListening() }
        let client = try BackendHOSTClient(paths: paths), value = try launch(root)
        XCTAssertEqual(client.hello.hostVersion, "older-compatible")
        XCTAssertEqual(try client.create(value).id, value.id)
        XCTAssertEqual(try client.create(value).id, value.id)
        XCTAssertEqual(calls.value, 1)
        try client.remove(value.id)
        XCTAssertThrowsError(try client.create(value))
        XCTAssertEqual(calls.value, 1)
        try client.stopAll()
    }
    /// 18 Oct (#79): a removed session's launch records are forgotten once its replay window has passed, so a
    /// host that runs for months never reaches the launch-record limit ("close finished sessions").
    func testRemovedLaunchRecordsAreForgottenAfterTheirReplayWindow() throws {
        let root = try scratch(), paths = try BackendHOSTPaths(dataDirectory: root)
        _ = try paths.secret(create: true)
        let manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in }), calls = HOSTCallCount()
        let server = try BackendHOSTServer(paths: paths, hostVersion: "replay-window", manager: manager,
                                          launch: { value in calls.increment(); return value.metadata }, snapshot: { _ in nil }, onIdle: {}, replayWindow: 0)
        defer { server.stopListening() }
        let client = try BackendHOSTClient(paths: paths)
        for _ in 0..<40 { let value = try launch(root); _ = try client.create(value); try client.remove(value.id) }
        XCTAssertEqual(calls.value, 40)
        XCTAssertEqual(server.retainedLaunches, 0)
        try client.stopAll()
    }
    func testWrongSecretAndVersionCannotLaunchAProcess() throws {
        let root = try scratch(), paths = try BackendHOSTPaths(dataDirectory: root)
        let secret = try paths.secret(create: true), calls = HOSTCallCount()
        let manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
        let server = try BackendHOSTServer(paths: paths, hostVersion: "fixture", manager: manager,
                                          launch: { value in calls.increment(); return value.metadata }, snapshot: { _ in nil }, onIdle: {})
        defer { server.stopListening() }
        for wrongVersion in [false, true] {
            let fd = try BackendHOSTSocket.connect(paths.socket)
            defer { Darwin.close(fd) }
            var request = BackendHOSTProtocol.Request(secret: wrongVersion ? secret : "wrong", operation: .create)
            request.launch = try launch(root); request.instance = server.hello.instance
            if wrongVersion { request.protocolVersion += 1 }
            try BackendHOSTSocket.write(request, to: fd)
            let response = try BackendHOSTSocket.read(BackendHOSTProtocol.Response.self, from: fd)
            XCTAssertNotNil(response.error)
            XCTAssertNil(response.session)
        }
        XCTAssertEqual(calls.value, 0); XCTAssertTrue(manager.list().isEmpty)
    }
}

private final class HOSTCallCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
private final class HOSTReceiptTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var trace: [String] = []
    var values: [String] { lock.withLock { trace } }
    func append(_ value: String) { lock.withLock { trace.append(value) } }
}
