// SCROLL (9 Oct 2026): Asad's hosted terminals scrolled broken and slow. A sample of his app showed
// the session bar's controls read and the usage panel asking for the screen of a HOSTED session
// on every output chunk, each time as a FULL snapshot (whole replay + whole scrollback rebuilt
// under the helper's PTY lock, JSON-encoded, sent, decoded). Real processes, real host
// server/client, owned /tmp scratch. Run it with -c release for the numbers that matter.
#if TD_HOST_INTEGRATED
import Foundation
import Darwin
import XCTest
@testable import TerminalDeckBackend

final class HOSTScreenCostTests: XCTestCase, @unchecked Sendable {
    private func ms(_ start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }

    func testHostedScreenIsViewportOnlyCachedAndKeepsOutputFlowing() async throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath().appendingPathComponent("tdh-scr-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let paths = try BackendHOSTPaths(dataDirectory: root); _ = try paths.secret(create: true)
        let helper = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
        let server = try BackendHOSTServer(paths: paths, hostVersion: "scroll-fixture", manager: helper,
            launch: { try helper.hostCreate($0) }, snapshot: { helper.hostSnapshot($0) }, onIdle: {})
        let client = try BackendHOSTClient(paths: paths)
        let ticks = HOSTScreenTicks()
        let app = BackendPTYManager(inheritedEnvironment: ["HOME": root.path, "LANG": "en_US.UTF-8"], onEvent: { event in
            if case .data(let id, let text) = event { ticks.add(id, text) }
        })
        let bridge = BackendHOSTManagerBridge(client: client, write: { try client.write($0, bytes: $1, expectedCreatedAt: $2) },
            drain: { try await client.drain(timeoutMilliseconds: $0) }, setWatched: { try client.setWatched($0) },
            stampIndependent: { $0.ownerIndependent = true })
        let ready = XCTestExpectation(description: "attached")
        try app.installHOSTFrontend(bridge, ready: { ready.fulfill() }, disconnected: {})
        await fulfillment(of: [ready], timeout: 5)
        defer { client.detach(); server.stopListening(); helper.beginShutdown(); app.beginShutdown() }
        // A long scrollback (20,000 lines), then continuous output (about 100 lines a second).
        let script = "i=0; while [ $i -lt 20000 ]; do echo \"history line $i ............................................\"; i=$((i+1)); done; echo HISTORY-DONE; " +
            "while :; do echo tick; /bin/sleep 0.01; done"
        let input = BackendCreateSessionInput(cwd: root.path, cols: 120, rows: 40, provider: "shell")
        let hosted = try app.createHOST(input, spawn: BackendSpawnSpec(provider: "shell", command: "/bin/sh", args: ["-c", script], path: "/usr/bin:/bin", env: [:]),
            context: BackendLaunchContext(), machineID: "", independent: true)
        ticks.target = hosted.id
        let local = try app.create(input, spawn: BackendSpawnSpec(provider: "shell", command: "/bin/sh", args: ["-c", script], path: "/usr/bin:/bin", env: [:]))
        let deadline = Date().addingTimeInterval(60)
        while (helper.scrollback(hosted.id).contains("HISTORY-DONE") == false || app.scrollback(local.id).contains("HISTORY-DONE") == false), Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(helper.scrollback(hosted.id).contains("HISTORY-DONE"))

        // His app read the screen from about ten threads at once (session bar controls, usage panel,
        // readiness probes). Eight concurrent readers for two seconds each, counting output meanwhile.
        func cpu() -> Double { var u = rusage(); getrusage(RUSAGE_SELF, &u)
            return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1_000_000 }
        func storm(_ body: @escaping @Sendable () throws -> Void) -> (calls: Int, perCallMs: Double, ticks: Int, cpu: Double) {
            ticks.reset(); let counter = HOSTScreenTicks(), begin = DispatchTime.now().uptimeNanoseconds, cpu0 = cpu()
            DispatchQueue.concurrentPerform(iterations: 8) { _ in
                var calls = 0
                while Double(DispatchTime.now().uptimeNanoseconds - begin) / 1_000_000 < 2_000 { try? body(); calls += 1 }
                counter.bump(calls)
            }
            return (counter.count, 8 * 2_000 / Double(max(counter.count, 1)), ticks.count, cpu() - cpu0)
        }
        let full = storm { _ = try bridge.snapshot(hosted.id) }
        let fullBytes = try (bridge.snapshot(hosted.id)).map { try JSONEncoder().encode($0).count } ?? 0
        let viewport = storm { _ = try client.viewport(hosted.id) }
        let cached = storm { _ = app.screen(hosted.id) }
        let idle = storm { usleep(1_000) }
        let fullMs = full.perCallMs, viewportMs = viewport.perCallMs, screenMs = cached.perCallMs
        let fullCalls = full.calls, viewportCalls = viewport.calls, screenCalls = cached.calls
        let ticksDuringFull = full.ticks, ticksDuringViewport = viewport.ticks, ticksDuringScreen = cached.ticks
        // In-app session for comparison (its own SwiftTerm buffer, no socket).
        let start = DispatchTime.now().uptimeNanoseconds; var localCalls = 0
        while ms(start) < 1_000 { _ = app.screen(local.id); localCalls += 1 }
        let localMs = 1_000 / Double(max(localCalls, 1))
        let screen = try XCTUnwrap(app.screen(hosted.id))
        XCTAssertTrue(screen.contains("tick") || screen.contains("history line"))
        let cpuFull = full.cpu / Double(max(full.calls, 1)) * 1_000, cpuViewport = viewport.cpu / Double(max(viewport.calls, 1)) * 1_000
        let cpuCached = cached.cpu / Double(max(cached.calls, 1)) * 1_000
        let report = String(format: "SCROLLBENCH 8 concurrent readers x 2 s, hosted session with 20,000 lines of scrollback and live output | full snapshot (before): %.3f ms wall, %.3f ms CPU per read, %d bytes | viewport-only: %.3f ms wall, %.4f ms CPU per read | cached between outputs (after): %.4f ms wall, %.5f ms CPU per read | in-app session screen: %.4f ms per read",
            fullMs, cpuFull, fullBytes, viewportMs, cpuViewport, screenMs, cpuCached, localMs)
        print(report)
        try report.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("td-scrollbench.txt"), atomically: true, encoding: .utf8)
        _ = (fullCalls, viewportCalls, screenCalls, ticksDuringFull, ticksDuringViewport, ticksDuringScreen, idle)
        XCTAssertLessThan(cpuViewport * 10, cpuFull, "a viewport read must cost far less CPU than a full snapshot")
        XCTAssertLessThan(cpuCached, cpuViewport, "repeated reads between outputs come from the cache")
        XCTAssertLessThan(viewportMs * 10, fullMs)
    }
}

extension HOSTScreenCostTests {
    /// The cache never hides new output for long: each change shows within the freshness bound.
    func testCachedScreenFollowsNewOutput() async throws {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true).resolvingSymlinksInPath().appendingPathComponent("tdh-scr-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let paths = try BackendHOSTPaths(dataDirectory: root); _ = try paths.secret(create: true)
        let helper = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
        let server = try BackendHOSTServer(paths: paths, hostVersion: "scroll-fixture", manager: helper,
            launch: { try helper.hostCreate($0) }, snapshot: { helper.hostSnapshot($0) }, onIdle: {})
        let client = try BackendHOSTClient(paths: paths)
        let app = BackendPTYManager(inheritedEnvironment: ["HOME": root.path], onEvent: { _ in })
        let bridge = BackendHOSTManagerBridge(client: client, write: { try client.write($0, bytes: $1, expectedCreatedAt: $2) },
            drain: { try await client.drain(timeoutMilliseconds: $0) }, setWatched: { try client.setWatched($0) },
            stampIndependent: { $0.ownerIndependent = true })
        let ready = XCTestExpectation(description: "attached")
        try app.installHOSTFrontend(bridge, ready: { ready.fulfill() }, disconnected: {})
        await fulfillment(of: [ready], timeout: 5)
        defer { client.detach(); server.stopListening(); helper.beginShutdown(); app.beginShutdown() }
        let hosted = try app.createHOST(BackendCreateSessionInput(cwd: root.path, provider: "shell"),
            spawn: BackendSpawnSpec(provider: "shell", command: "/bin/sh", args: ["-c", "while IFS= read -r line; do printf 'got-%s\\n' \"$line\"; done"], path: "/usr/bin:/bin", env: [:]),
            context: BackendLaunchContext(), machineID: "", independent: true)
        for word in ["alpha", "beta", "gamma"] {
            try bridge.write(hosted.id, bytes: Data((word + "\n").utf8), expectedCreatedAt: nil)
            let until = Date().addingTimeInterval(2)
            var seen = false
            while !seen, Date() < until { seen = app.screen(hosted.id)?.contains("got-" + word) == true; if !seen { try await Task.sleep(for: .milliseconds(20)) } }
            XCTAssertTrue(seen, "the screen shows new output (" + word + ") within the freshness bound")
        }
    }
}

private final class HOSTScreenTicks: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0, id = ""
    var target: String { get { lock.withLock { id } } set { lock.withLock { id = newValue } } }
    func add(_ session: String, _ text: String) { let n = text.components(separatedBy: "tick").count - 1; lock.withLock { if session == id { value += n } } }
    func reset() { lock.withLock { value = 0 } }
    func bump(_ n: Int) { lock.withLock { value += n } }
    var count: Int { lock.withLock { value } }
}
#endif
