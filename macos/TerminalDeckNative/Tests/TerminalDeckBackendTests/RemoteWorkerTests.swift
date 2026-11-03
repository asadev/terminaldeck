import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private struct Seen: @unchecked Sendable { let method: String; let path: String; let headers: [String: String]; let body: [String: Any]? }

private final class FakeWorker: BackendRemoteWorkerTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [Seen] = []
    var handler: @Sendable (Seen) throws -> BackendRemoteWorkerResponse = { _ in throw BackendRemoteWorkerTransportFailure.unreachable }
    var seen: [Seen] { lock.withLock { log } }
    func count(_ method: String, _ prefix: String) -> Int { seen.filter { $0.method == method && $0.path.hasPrefix(prefix) }.count }
    func send(method: String, url: URL, headers: [String: String], body: Data?, timeoutMilliseconds: Int) async throws -> BackendRemoteWorkerResponse {
        let item = Seen(method: method, path: url.path, headers: headers, body: body.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] })
        lock.withLock { log.append(item) }
        return try handler(item)
    }
}
private func reply(_ status: Int, _ object: [String: Any]) -> BackendRemoteWorkerResponse { .init(status: status, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data()) }
private func reply(_ object: [String: Any]) -> BackendRemoteWorkerResponse { reply(200, object) }
private final class Counter: @unchecked Sendable { private let lock = NSLock(); private var n = 0; func next() -> String { lock.withLock { n += 1; return "id\(n)" } } }
nonisolated(unsafe) private let capabilities: [String: Any] = ["protocol": 1, "service": "fixture-worker", "capabilities": ["start", "status", "stop", "resume", "tokens"], "models": ["fast", "deep"]]

final class RemoteWorkerContractTests: XCTestCase {
    func testAddressRulesAcceptSecureAndLocalOnly() throws {
        XCTAssertEqual(try RemoteWorkerContract.normalizedBase("https://Worker.example.com/api/").absoluteString, "https://worker.example.com/api")
        XCTAssertNoThrow(try RemoteWorkerContract.normalizedBase("http://localhost:8080"))
        for bad in ["http://worker.example.com", "https://user:pw@worker.example.com", "https://worker.example.com?x=1", "https://worker.example.com#f", "ftp://x.com", "not a url", "https://worker.example.com/../x"] {
            XCTAssertThrowsError(try RemoteWorkerContract.normalizedBase(bad), bad)
        }
    }
    func testCapabilityAnswerIsStrict() throws {
        let good = try RemoteWorkerCapabilities.decode(capabilities)
        XCTAssertTrue(good.stop && good.resume && good.tokens); XCTAssertEqual(good.models, ["fast", "deep"])
        XCTAssertThrowsError(try RemoteWorkerCapabilities.decode(["protocol": 2, "service": "x", "capabilities": ["start", "status"]]))
        XCTAssertThrowsError(try RemoteWorkerCapabilities.decode(["protocol": 1, "service": "x", "capabilities": ["start"]]))
        XCTAssertThrowsError(try RemoteWorkerCapabilities.decode(["protocol": 1, "service": "x", "capabilities": ["start", "status"], "models": ["../etc"]]))
    }
    func testStatesOnlyMoveForwardAndUsageIsBounded() throws {
        XCTAssertTrue(RemoteWorkerState.running.accepts(.completed)); XCTAssertFalse(RemoteWorkerState.completed.accepts(.running))
        XCTAssertFalse(RemoteWorkerState.stopped.accepts(.completed)); XCTAssertFalse(RemoteWorkerState.stopRequested.accepts(.running))
        XCTAssertNil(try RemoteWorkerUsage.decode(nil, revision: 1)); XCTAssertNil(try RemoteWorkerUsage.decode([:], revision: 1))
        XCTAssertEqual(try RemoteWorkerUsage.decode(["input": 5, "output": 7], revision: 2)?.shownTotal, 12)
        XCTAssertThrowsError(try RemoteWorkerUsage.decode(["input": -1], revision: 1))
        XCTAssertThrowsError(try RemoteWorkerUsage.decode(["total": RemoteWorkerContract.maxTokenCount + 1], revision: 1))
        XCTAssertFalse(RemoteWorkerContract.validID("a/b")); XCTAssertFalse(RemoteWorkerContract.validID("..")); XCTAssertTrue(RemoteWorkerContract.validID("run_1.a-b:c"))
    }
}

final class RemoteWorkerServiceTests: XCTestCase {
    private var root: URL!
    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("remote-workers-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func make(_ worker: FakeWorker, secrets: BackendConnectedTasksSecrets = BackendConnectedTasksMemorySecrets(), ids: Counter = Counter(),
                      now: @escaping @Sendable () -> Date = { Date() }) -> BackendRemoteWorkers {
        BackendRemoteWorkers(root: root, transport: worker, secrets: secrets, now: now, newID: { ids.next() }, sleep: { _ in try await Task.sleep(nanoseconds: 3_600_000_000_000) })
    }
    /// A worker that knows run `remote-1`, whose answers the test scripts through `status`.
    private func standard(_ worker: FakeWorker, status: @escaping @Sendable () -> [String: Any] = { ["runId": "remote-1", "state": "running", "revision": 1] }) {
        worker.handler = { seen in
            switch (seen.method, seen.path) {
            case ("GET", "/v1/capabilities"): return reply(capabilities)
            case ("POST", "/v1/runs"): return reply(202, ["requestId": seen.body?["requestId"] as? String ?? "", "runId": "remote-1", "state": "running", "revision": 1])
            case ("GET", "/v1/runs/remote-1"): return reply(status())
            case ("POST", "/v1/runs/remote-1/stop"): return reply(["requestId": seen.body?["requestId"] as? String ?? "", "runId": "remote-1", "state": "stop_requested"])
            case ("POST", "/v1/runs/remote-1/resume"): return reply(202, ["requestId": seen.body?["requestId"] as? String ?? "", "runId": "remote-2", "state": "running", "revision": 1])
            default: return reply(404, [:])
            }
        }
    }
    private func ready(_ service: BackendRemoteWorkers) async throws -> String {
        let connection = try await service.saveConnection(id: nil, label: "Build box", baseURL: "https://worker.example.com", profile: nil)
        try await service.setCredential(connection.id, token: "SECRET-TOKEN-123")
        let check = try await service.check(connection.id); XCTAssertTrue(check.ok)
        return connection.id
    }

    func testCheckStartsNothingAndNeverShowsTheToken() async throws {
        let worker = FakeWorker(); standard(worker); let service = make(worker)
        let id = try await ready(service)
        XCTAssertEqual(worker.count("POST", "/v1/runs"), 0)
        XCTAssertEqual(worker.seen.first?.headers["Authorization"], "Bearer SECRET-TOKEN-123")
        let savedCheck = try await service.connection(id).lastCheck
        let shown = BackendRemoteWorkersMCP.projectCheck(try XCTUnwrap(savedCheck)).compact
        XCTAssertFalse(shown.contains("SECRET")); XCTAssertTrue(shown.contains("fixture-worker"))
        let listed = try await BackendRemoteWorkersMCP.perform("list", args: .object([]), service: service).compact
        XCTAssertFalse(listed.contains("SECRET")); XCTAssertTrue(listed.contains("\"credential\":\"saved\""))
        // wrong protocol is a refusal, not "connected"
        worker.handler = { _ in reply(["protocol": 9, "service": "x", "capabilities": ["start", "status"]]) }
        let bad = try await service.check(id); XCTAssertFalse(bad.ok); XCTAssertNotNil(bad.error)
    }

    func testStartIsSavedBeforeSendingAndUsesTheRequestAsIdempotencyKey() async throws {
        let worker = FakeWorker(); standard(worker)
        let file = root.appendingPathComponent("remote-workers/runs.json")
        let base = worker.handler
        let sawSaved = Box(false)
        worker.handler = { seen in
            if seen.method == "POST", seen.path == "/v1/runs" { sawSaved.value = ((try? String(contentsOf: file)) ?? "").contains("\"state\":\"starting\"") }
            return try base(seen)
        }
        let service = make(worker); let id = try await ready(service)
        let run = try await service.start(connectionID: id, prompt: "Build the report\nwith details", model: "fast")
        XCTAssertTrue(sawSaved.value, "the run must be on disk as starting before the POST")
        let post = try XCTUnwrap(worker.seen.first { $0.method == "POST" && $0.path == "/v1/runs" })
        XCTAssertEqual(post.headers["Idempotency-Key"], run.requestID); XCTAssertEqual(post.body?["requestId"] as? String, run.requestID)
        XCTAssertEqual(post.body?["model"] as? String, "fast")
        XCTAssertEqual(run.state, .running); XCTAssertEqual(run.remoteID, "remote-1"); XCTAssertEqual(run.title, "Build the report")
        XCTAssertEqual(run.executionKind, "remote_http")
        await XCTAssertThrowsErrorAsync(try await service.start(connectionID: id, prompt: "x", model: "bogus"))
        let text = try String(contentsOf: root.appendingPathComponent("remote-workers/connections.json")) + String(contentsOf: file)
        XCTAssertFalse(text.contains("SECRET-TOKEN-123"))
        await service.stopObserving()
    }

    func testLostStartAnswerStaysUnknownAndReconcilesWithoutASecondRun() async throws {
        let worker = FakeWorker(); standard(worker); let service = make(worker); let id = try await ready(service)
        let base = worker.handler
        worker.handler = { seen in
            if seen.method == "POST", seen.path == "/v1/runs" { throw BackendRemoteWorkerTransportFailure.timeout }
            if seen.method == "GET", seen.path.hasPrefix("/v1/requests/") { return reply(["runId": "remote-1", "requestId": String(seen.path.dropFirst("/v1/requests/".count)), "state": "running", "revision": 1]) }
            return try base(seen)
        }
        let run = try await service.start(connectionID: id, prompt: "Do it")
        XCTAssertEqual(run.state, .unknown); XCTAssertNil(run.remoteID); XCTAssertTrue(run.note?.contains("Not known") == true)
        await XCTAssertThrowsErrorAsync(try await service.stop(run.id))
        let found = try await service.refresh(run.id)
        XCTAssertEqual(found.state, .running); XCTAssertEqual(found.remoteID, "remote-1")
        XCTAssertEqual(worker.count("POST", "/v1/runs"), 1, "no second Start was sent")
        await service.stopObserving()
    }

    /// Review paperclip #4: "never started" needs several not-found answers and a grace window after the start attempt.
    func testRequestNeverSeenByWorkerFailsOnlyWhenWorkerSaysNoRecord() async throws {
        let clock = Box(Date(timeIntervalSince1970: 1_000_000))
        let worker = FakeWorker(); standard(worker); let service = make(worker, now: { clock.value }); let id = try await ready(service)
        let base = worker.handler
        worker.handler = { seen in
            if seen.method == "POST", seen.path == "/v1/runs" { return reply(500, [:]) }
            if seen.path.hasPrefix("/v1/requests/") { return reply(404, [:]) }
            return try base(seen)
        }
        let run = try await service.start(connectionID: id, prompt: "Do it")
        XCTAssertEqual(run.state, .unknown)
        for _ in 0..<4 { let early = try await service.refresh(run.id); XCTAssertEqual(early.state, .unknown, "a first not-found inside the grace window is not final") }
        clock.value = clock.value.addingTimeInterval(BackendRemoteWorkers.notFoundGrace + 1)
        let after = try await service.refresh(run.id); XCTAssertEqual(after.state, .failed)
        XCTAssertEqual(worker.count("POST", "/v1/runs"), 1)
    }
    func testSlowWorkerThatRegistersLateIsFollowedNotFailed() async throws {
        let worker = FakeWorker(); standard(worker); let service = make(worker); let id = try await ready(service)
        let base = worker.handler, known = Box(false)
        worker.handler = { seen in
            if seen.method == "POST", seen.path == "/v1/runs" { throw BackendRemoteWorkerTransportFailure.timeout }
            if seen.path.hasPrefix("/v1/requests/") {
                guard known.value else { return reply(404, [:]) }
                return reply(["runId": "remote-1", "requestId": String(seen.path.dropFirst("/v1/requests/".count)), "state": "running", "revision": 1])
            }
            return try base(seen)
        }
        let run = try await service.start(connectionID: id, prompt: "Slow start")
        let early = try await service.refresh(run.id); XCTAssertEqual(early.state, .unknown)
        known.value = true
        let found = try await service.refresh(run.id); XCTAssertEqual(found.state, .running); XCTAssertEqual(found.remoteID, "remote-1")
        XCTAssertEqual(worker.count("POST", "/v1/runs"), 1)
        await service.stopObserving()
    }
    /// Review paperclip #5: an unchanged read-back does not rewrite runs.json.
    func testUnchangedReadBackDoesNotRewriteRuns() async throws {
        let worker = FakeWorker(); standard(worker); let service = make(worker); let id = try await ready(service)
        _ = try await service.start(connectionID: id, prompt: "Steady")
        let file = root.appendingPathComponent("remote-workers/runs.json")
        _ = await service.tick()
        let before = try Data(contentsOf: file)
        _ = await service.tick(); _ = await service.tick()
        XCTAssertEqual(try Data(contentsOf: file), before)
        await service.stopObserving()
    }

    func testStaleDuplicateAndLateStatusNeverRegressOrDoubleCountTokens() async throws {
        let worker = FakeWorker(); let script = Box<[String: Any]>(["runId": "remote-1", "state": "running", "revision": 1])
        standard(worker, status: { script.value }); let service = make(worker); let id = try await ready(service)
        let run = try await service.start(connectionID: id, prompt: "Count")
        script.value = ["runId": "remote-1", "state": "running", "revision": 2, "usage": ["input": 40, "output": 60, "total": 100]]
        var now = try await service.refresh(run.id); XCTAssertEqual(now.usage?.total, 100)
        now = try await service.refresh(run.id); XCTAssertEqual(now.usage?.total, 100, "repeat refresh must not add again")
        script.value = ["runId": "remote-1", "state": "running", "revision": 1, "usage": ["total": 5]]
        now = try await service.refresh(run.id); XCTAssertEqual(now.usage?.total, 100); XCTAssertEqual(now.revision, 2)
        script.value = ["runId": "remote-1", "state": "completed", "revision": 3, "result": "All done", "usage": ["total": 130]]
        now = try await service.refresh(run.id); XCTAssertEqual(now.state, .completed); XCTAssertEqual(now.usage?.total, 130); XCTAssertEqual(now.result, "All done")
        script.value = ["runId": "remote-1", "state": "running", "revision": 4]
        let seenBefore = worker.seen.count
        now = try await service.refresh(run.id); XCTAssertEqual(now.state, .completed)
        XCTAssertEqual(worker.seen.count, seenBefore, "an ended run is not asked again")
        // a different run identity in an answer is a protocol error, not applied
        let second = try await service.start(connectionID: id, prompt: "Other")
        script.value = ["runId": "someone-else", "state": "failed", "revision": 9]
        let wrong = try await service.refresh(second.id); XCTAssertEqual(wrong.state, .running); XCTAssertNotNil(wrong.note)
        let noUsage = BackendRemoteWorkersMCP.project(try await service.run(second.id))
        XCTAssertNil(noUsage["tokens"]["total"].number); XCTAssertEqual(noUsage["tokens"]["text"].string, "Not reported")
        await service.stopObserving()
    }

    func testStopIsUnconfirmedOnTimeoutThenConfirmedWithTheSameRequest() async throws {
        let worker = FakeWorker(); standard(worker); let service = make(worker); let id = try await ready(service)
        let run = try await service.start(connectionID: id, prompt: "Long job")
        let base = worker.handler, timeouts = Box(true)
        worker.handler = { seen in
            if seen.path.hasSuffix("/stop"), timeouts.value { throw BackendRemoteWorkerTransportFailure.timeout }
            if seen.method == "GET", seen.path == "/v1/runs/remote-1", !timeouts.value { return reply(["runId": "remote-1", "state": "stopped", "revision": 5]) }
            return try base(seen)
        }
        let lost = try await service.stop(run.id)
        XCTAssertEqual(lost.state, .stopRequested); XCTAssertFalse(lost.stopConfirmed); XCTAssertTrue(lost.note?.contains("unconfirmed") == true)
        let firstKey = try XCTUnwrap(worker.seen.last { $0.path.hasSuffix("/stop") }?.body?["requestId"] as? String)
        timeouts.value = false
        _ = try await service.stop(run.id)
        let keys = worker.seen.filter { $0.path.hasSuffix("/stop") }.compactMap { $0.body?["requestId"] as? String }
        XCTAssertEqual(Set(keys), [firstKey], "a retried stop keeps its request identity")
        let done = try await service.refresh(run.id); XCTAssertEqual(done.state, .stopped); XCTAssertTrue(done.stopConfirmed)
        await service.stopObserving()
    }

    func testStopAndResumeNeedAdvertisedCapabilitiesAndResumeLinksANewAttempt() async throws {
        let worker = FakeWorker(); standard(worker)
        let base = worker.handler
        worker.handler = { seen in
            if seen.path == "/v1/capabilities" { return reply(["protocol": 1, "service": "plain", "capabilities": ["start", "status"]]) }
            return try base(seen)
        }
        let plain = make(worker); let id = try await ready(plain)
        let run = try await plain.start(connectionID: id, prompt: "Plain")
        await XCTAssertThrowsErrorAsync(try await plain.stop(run.id)); XCTAssertEqual(worker.count("POST", "/v1/runs/remote-1/stop"), 0)
        await plain.stopObserving()

        let rich = FakeWorker(); standard(rich); let service = BackendRemoteWorkers(root: root.appendingPathComponent("rich"), transport: rich, secrets: BackendConnectedTasksMemorySecrets(), newID: { UUID().uuidString.lowercased() }, sleep: { _ in try await Task.sleep(nanoseconds: 3_600_000_000_000) })
        let rid = try await ready(service)
        let first = try await service.start(connectionID: rid, prompt: "First")
        await XCTAssertThrowsErrorAsync(try await service.resume(first.id, message: "more"))   // still running
        let script = Box<[String: Any]>(["runId": "remote-1", "state": "completed", "revision": 2, "result": "ok"])
        let base2 = rich.handler
        rich.handler = { seen in seen.path == "/v1/runs/remote-1" ? reply(script.value) : try base2(seen) }
        _ = try await service.refresh(first.id)
        let second = try await service.resume(first.id, message: "Now add tests")
        XCTAssertEqual(second.attempt, 2); XCTAssertEqual(second.previous, first.id); XCTAssertEqual(second.remoteID, "remote-2"); XCTAssertNotEqual(second.id, first.id)
        let kept = try await service.run(first.id); XCTAssertEqual(kept.state, .completed); XCTAssertEqual(kept.result, "ok")
        let body = try XCTUnwrap(rich.seen.last { $0.path.hasSuffix("/resume") }?.body)
        XCTAssertEqual(body["message"] as? String, "Now add tests"); XCTAssertEqual(body["requestId"] as? String, second.requestID)
        await XCTAssertThrowsErrorAsync(try await service.resume(first.id, message: "again"))   // already continuing
        await service.stopObserving()
    }

    func testRestartNeverStartsAgainAndOnlyReadsBack() async throws {
        let worker = FakeWorker(); standard(worker); let secrets = BackendConnectedTasksMemorySecrets()
        let first = make(worker, secrets: secrets); let id = try await ready(first)
        let base = worker.handler
        worker.handler = { seen in if seen.method == "POST", seen.path == "/v1/runs" { throw BackendRemoteWorkerTransportFailure.timeout }; return try base(seen) }
        let lost = try await first.start(connectionID: id, prompt: "Mid-flight")
        XCTAssertEqual(lost.state, .unknown)
        await first.stopObserving()
        let posts = worker.count("POST", "")
        // simulate an app that died while "starting": rewrite the saved state
        let file = root.appendingPathComponent("remote-workers/runs.json")
        try String(contentsOf: file).replacingOccurrences(of: "\"state\":\"unknown\"", with: "\"state\":\"starting\"").write(to: file, atomically: true, encoding: .utf8)
        worker.handler = { seen in
            if seen.path.hasPrefix("/v1/requests/") { return reply(["runId": "remote-1", "requestId": String(seen.path.dropFirst("/v1/requests/".count)), "state": "running", "revision": 1]) }
            return try base(seen)
        }
        let reopened = make(worker, secrets: secrets)
        await reopened.reconcile()
        let before = try await reopened.run(lost.id)
        XCTAssertTrue([RemoteWorkerState.unknown, .running].contains(before.state))
        _ = try await reopened.refresh(lost.id)
        let reread = try await reopened.run(lost.id); XCTAssertEqual(reread.state, .running)
        XCTAssertEqual(worker.count("POST", ""), posts, "restart sent no new Start/Resume/Stop")
        await reopened.stopObserving()
    }

    /// Review paperclip #3: the address cannot change under an active run, and the owner can abandon a run it cannot control.
    func testEditingTheAddressCannotRedirectAnExistingRun() async throws {
        let worker = FakeWorker(); standard(worker); let service = make(worker); let id = try await ready(service)
        let run = try await service.start(connectionID: id, prompt: "Pinned")
        await XCTAssertThrowsErrorAsync(try await service.saveConnection(id: id, label: "Moved", baseURL: "https://evil.example.com", profile: nil))
        _ = try await service.saveConnection(id: id, label: "Renamed only", baseURL: "https://worker.example.com", profile: nil)
        await XCTAssertThrowsErrorAsync(try await service.removeConnection(id))   // still has an active run
        let seen = worker.seen.count
        let abandoned = try await BackendRemoteWorkersMCP.perform("abandon", args: .object([.init("run", .string(run.id))]), service: service)
        XCTAssertEqual(abandoned["state"], .string("failed")); XCTAssertEqual(abandoned["canAbandon"], .bool(false))
        XCTAssertEqual(worker.seen.count, seen, "abandon sends nothing")
        try await service.saveConnection(id: id, label: "Moved", baseURL: "https://other.example.com", profile: nil)
        try await service.removeConnection(id)
        await service.stopObserving()
    }

    func testObserverReadsBackOnceForAllActiveRunsAndEndsItself() async throws {
        let worker = FakeWorker(); let script = Box<[String: Any]>(["runId": "remote-1", "state": "completed", "revision": 2])
        standard(worker, status: { script.value }); let service = make(worker); let id = try await ready(service)
        let run = try await service.start(connectionID: id, prompt: "Watch")
        let reachable = await service.tick()
        let watched = try await service.run(run.id); XCTAssertTrue(reachable); XCTAssertEqual(watched.state, .completed)
        let reads = worker.count("GET", "/v1/runs/")
        _ = await service.tick()
        XCTAssertEqual(worker.count("GET", "/v1/runs/"), reads, "finished runs are not polled")
        await service.stopObserving()
    }

    /// #506: with more active runs than one read-back covers, the next read-back carries on where the last one stopped.
    func testReadBackReachesEveryRunWhenMoreAreActiveThanOneTickReads() async throws {
        let worker = FakeWorker(), starts = Counter()
        worker.handler = { seen in
            if seen.method == "GET", seen.path == "/v1/capabilities" { return reply(capabilities) }
            if seen.method == "POST", seen.path == "/v1/runs" {
                return reply(202, ["requestId": seen.body?["requestId"] as? String ?? "", "runId": "remote-" + starts.next(), "state": "running", "revision": 1])
            }
            if seen.method == "GET", seen.path.hasPrefix("/v1/runs/") { return reply(["runId": String(seen.path.dropFirst("/v1/runs/".count)), "state": "running", "revision": 1]) }
            return reply(404, [:])
        }
        let service = make(worker)
        for index in 0..<3 {
            let connection = try await service.saveConnection(id: nil, label: "Box \(index)", baseURL: "https://worker\(index).example.com", profile: nil)
            try await service.setCredential(connection.id, token: "SECRET-TOKEN-123")
            for _ in 0..<BackendRemoteWorkers.maxActivePerConnection { _ = try await service.start(connectionID: connection.id, prompt: "Job") }
        }
        let before = worker.seen.count
        _ = await service.tick(); _ = await service.tick()
        let read = Set(worker.seen.dropFirst(before).filter { $0.method == "GET" && $0.path.hasPrefix("/v1/runs/") }.map(\.path))
        XCTAssertEqual(read.count, 3 * BackendRemoteWorkers.maxActivePerConnection)
        await service.stopObserving()
    }
}

/// A real loopback HTTP server, so redirect, size and TLS rules are proven on the production transport.
private final class LoopbackServer: @unchecked Sendable {
    private(set) var port: UInt16 = 0
    private let descriptor: Int32
    private let lock = NSLock()
    private var paths: [String] = []
    var hits: [String] { lock.withLock { paths } }
    init() {
        descriptor = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1; setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = 0
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(descriptor, 8)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
        port = UInt16(bigEndian: address.sin_port)
        let listener = descriptor
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 { break }
                var buffer = [UInt8](repeating: 0, count: 4096)
                let count = read(client, &buffer, buffer.count)
                let line = String(decoding: buffer.prefix(max(0, count)), as: UTF8.self).split(separator: "\r\n").first.map(String.init) ?? ""
                let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                lock.withLock { paths.append(path) }
                var out: [UInt8]
                switch path {
                case "/redirect": out = Array("HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:\(port)/elsewhere\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                case "/big": out = Array("HTTP/1.1 200 OK\r\nContent-Length: \(BackendRemoteWorkerURLSession.maximumResponseBytes + 10)\r\nConnection: close\r\n\r\n".utf8) + [UInt8](repeating: 65, count: BackendRemoteWorkerURLSession.maximumResponseBytes + 10)
                default: let body = #"{"ok":true}"#; out = Array("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
                }
                var sent = 0
                while sent < out.count { let n = out.withUnsafeBufferPointer { write(client, $0.baseAddress! + sent, $0.count - sent) }; if n <= 0 { break }; sent += n }
                close(client)
            }
        }
    }
    func stop() { shutdown(descriptor, SHUT_RDWR); close(descriptor) }
}

final class RemoteWorkerHTTPTests: XCTestCase {
    func testProductionTransportNeverFollowsARedirectAndBoundsTheAnswer() async throws {
        let server = LoopbackServer(); defer { server.stop() }
        let transport = BackendRemoteWorkerURLSession()
        let base = "http://127.0.0.1:\(server.port)"
        let redirected = try await transport.send(method: "GET", url: URL(string: base + "/redirect")!, headers: ["Authorization": "Bearer T"], body: nil, timeoutMilliseconds: 5000)
        XCTAssertEqual(redirected.status, 302)
        XCTAssertFalse(server.hits.contains("/elsewhere"), "the redirect target was never contacted")
        let ok = try await transport.send(method: "GET", url: URL(string: base + "/ok")!, headers: [:], body: nil, timeoutMilliseconds: 5000)
        XCTAssertEqual(ok.status, 200); XCTAssertEqual(String(decoding: ok.body, as: UTF8.self), #"{"ok":true}"#)
        do { _ = try await transport.send(method: "GET", url: URL(string: base + "/big")!, headers: [:], body: nil, timeoutMilliseconds: 5000); XCTFail("an oversized answer must stop") }
        catch { XCTAssertEqual(error as? BackendRemoteWorkerTransportFailure, .tooLarge) }
        do { _ = try await transport.send(method: "GET", url: URL(string: "http://worker.example.com/ok")!, headers: [:], body: nil, timeoutMilliseconds: 5000); XCTFail("plain http to a remote host") }
        catch { XCTAssertEqual(error as? BackendRemoteWorkerTransportFailure, .secureConnection) }
    }
}

final class RemoteWorkerOperationTests: XCTestCase {
    func testNativeChannelAndMCPToolsReachTheSameServiceActions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("remote-ops-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = FakeWorker()
        worker.handler = { seen in
            switch (seen.method, seen.path) {
            case ("GET", "/v1/capabilities"): return reply(capabilities)
            case ("POST", "/v1/runs"): return reply(202, ["requestId": seen.body?["requestId"] as? String ?? "", "runId": "remote-1", "state": "running", "revision": 1])
            default: return reply(404, [:])
            }
        }
        let counter = Counter()
        let service = BackendRemoteWorkers(root: root, transport: worker, secrets: BackendConnectedTasksMemorySecrets(), newID: { counter.next() }, sleep: { _ in try await Task.sleep(nanoseconds: 3_600_000_000_000) })
        let allowOwner = BackendRemoteWorkersAccess(verify: { call, configuration in
            if case .tool(let context) = call, configuration, !context.allowedTiers.contains(.alter) { throw NativeRPCError(code: "not-granted", message: "no") }
        })
        let definitions = try BackendRemoteWorkersMCP.definitions(service: service, access: allowOwner)
        XCTAssertEqual(Set(definitions.map(\.spec.id)), Set(BackendRemoteWorkersMCP.operations.map { "agents.remote_" + $0.name }))
        let registry = NativeChannelRegistry(); let owner = NativeRPCContext(caller: .nativeApp, ownerID: BackendCompositionRoot.appOwnerID)
        try await BackendRemoteWorkersMCP.register(registry: registry, ownerID: "fixture", service: service, requireOwnerUI: { _ in })
        func channel(_ op: String, _ fields: [NativeRPCValue.Field] = []) async throws -> NativeRPCValue {
            try await registry.invoke(BackendRemoteWorkersMCP.channel, context: owner, arguments: [.object([.init("op", .string(op))] + fields)])
        }
        func tool(_ op: String, _ fields: [NativeRPCValue.Field] = []) async throws -> NativeRPCValue {
            let definition = try XCTUnwrap(definitions.first { $0.spec.id == "agents.remote_" + op })
            let context = BackendMCPCallContext(sessionID: "", machineID: "", projectRoot: nil, attended: true, allowedTools: Set(definitions.map(\.spec.wireName)), allowedTiers: [.read, .act, .alter], cancellation: .init())
            let reply = try await definition.handler(context, .object(fields))
            XCTAssertFalse(reply.isError, reply.content.description)
            return try XCTUnwrap(reply.structuredContent)
        }
        let saved = try await channel("connection_set", [.init("label", .string("Box")), .init("url", .string("https://worker.example.com"))])
        let id = try XCTUnwrap(saved["id"].string)
        let viaTool = try await tool("get", [.init("connection", .string(id))])
        XCTAssertEqual(viaTool["connection"]["label"].string, "Box")
        _ = try await tool("credential_set", [.init("connection", .string(id)), .init("token", .string("TOP-SECRET"))])
        XCTAssertEqual(BackendRemoteWorkersMCP.safeArguments(.object([.init("token", .string("TOP-SECRET"))]))["token"].string, "[hidden]")
        let checked = try await channel("check", [.init("connection", .string(id))]); XCTAssertEqual(checked["ok"].bool, true)
        let again = try await tool("check", [.init("connection", .string(id))]); XCTAssertEqual(again["ok"].bool, true)
        XCTAssertEqual(worker.count("GET", "/v1/capabilities"), 2)
        let started = try await tool("start", [.init("connection", .string(id)), .init("prompt", .string("Do the thing"))])
        XCTAssertEqual(started["state"].string, "running"); XCTAssertEqual(started["executionKind"].string, "remote_http")
        let listed = try await channel("list"); XCTAssertEqual(listed["runs"].elements?.count, 1)
        XCTAssertFalse(listed.compact.contains("TOP-SECRET"))
        XCTAssertEqual(worker.count("POST", "/v1/runs"), 1)
        // a caller without the alter tier cannot change the worker's address or token
        let limited = try XCTUnwrap(definitions.first { $0.spec.id == "agents.remote_connection_set" })
        let weak = BackendMCPCallContext(sessionID: "", machineID: "", projectRoot: nil, attended: true, allowedTools: ["agents_remote_connection_set"], allowedTiers: [.read, .act], cancellation: .init())
        let refused = try await limited.handler(weak, .object([.init("label", .string("x")), .init("url", .string("https://evil.example.com"))]))
        XCTAssertTrue(refused.isError)
        let remaining = await service.connections(); XCTAssertEqual(remaining.first?.baseURL, "https://worker.example.com")
        await service.stopObserving()
    }
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock(); private var stored: T
    init(_ value: T) { stored = value }
    var value: T { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
}
private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expression(); XCTFail("expected an error", file: file, line: line) } catch {}
}
