import Foundation
import Darwin
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// dev-server.test.ts against BackendDevServers.
/// Skipped (Windows/Electron): none. Blocked (no seam, see NIGHT-REQUESTS REQ S6-C2-2):
/// the clock-driven cases (ninety-second timeout "still running", "output alone => failed",
/// "scan alone => failed") need an injected clock; "never credits a port already listening"
/// and "finds a server that prints nothing, from the scan" need a fake port scan (the
/// discovery type is concrete and runs the real lsof). `commandFor` is not a Swift function:
/// the manager spelling is asserted through the idle state's `command`.
/// Divergence recorded: a session that dies fails with "The session ended..."/"exited without
/// anything listening", not a sentence naming the command; the session id is still kept.
final class BackendFoundationTestsS6C2DevServer: XCTestCase {
    private final class S6C2Sessions: BackendDevSessionAccess, @unchecked Sendable {
        private let lock = NSLock()
        private var next = 0
        private var out: [String: String] = [:]
        private var running: Set<String> = []
        private(set) var opened: [String] = []
        private(set) var typed: [(String, String)] = []
        var refuse: String?
        func openShell(folder: String, context: NativeRPCContext) async throws -> String {
            try lock.withLock {
                if let refuse { throw NativeRPCError(code: "refused", message: refuse) }
                next += 1; let id = "s\(next)"
                running.insert(id); out[id] = "$ "; opened.append(folder)
                return id
            }
        }
        func type(sessionID: String, text: String, context: NativeRPCContext) async throws { lock.withLock { typed.append((sessionID, text)) } }
        func output(sessionID: String, context: NativeRPCContext) async throws -> String { lock.withLock { out[sessionID] ?? "" } }
        func alive(sessionID: String) async -> Bool { lock.withLock { running.contains(sessionID) } }
        func say(_ id: String, _ text: String) { lock.withLock { out[id] = text } }
        func kill(_ id: String) { lock.withLock { _ = running.remove(id) } }
        var typedSnapshot: [(String, String)] { lock.withLock { typed } }
        var openedSnapshot: [String] { lock.withLock { opened } }
    }
    private final class S6C2States: @unchecked Sendable {
        private let lock = NSLock(); private var items: [NativeRPCValue] = []
        func add(_ v: NativeRPCValue) { lock.withLock { items.append(v) } }
        var all: [NativeRPCValue] { lock.withLock { items } }
        func clear() { lock.withLock { items.removeAll() } }
    }
    private struct S6C2NoPorts: BackendDevPortScanning {
        func scan(force: Bool) async throws -> [BackendDevPort] { [] }
    }
    private struct S6C2Rig {
        let base: URL; let servers: BackendDevServers; let sessions: S6C2Sessions
        let context = NativeRPCContext(caller: .nativeApp, ownerID: "s6c2")
        func dispose() { Task { await servers.stop() }; try? FileManager.default.removeItem(at: base) }
        func project(_ files: [String: String]) throws -> String {
            let dir = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, body) in files { try body.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
            return dir.path
        }
        func status(_ folder: String) async throws -> NativeRPCValue { try await servers.status(folder: folder, context: context) }
        func start(_ folder: String) async throws -> NativeRPCValue { try await servers.start(folder: folder, context: context) }
    }
    private var listeners: [Int32] = []
    override func tearDown() { listeners.forEach { Darwin.close($0) }; listeners = [] }

    private func rig() throws -> S6C2Rig {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("s6c2-dev-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let authority = BackendFilesystemAuthority { _ in .init(readRoots: [base], writeRoots: [base]) }
        let files = BackendFilesystemService(authority: authority)
        let sessions = S6C2Sessions()
        // TS dev-server.test.ts:112 scans only the harness's own `listening` set (empty unless a test adds to it),
        // never the machine: every test here prints its port, and a real lsof saw other processes' new listeners
        // (another test binding a port made an exited command "ready") and could stall the start for seconds.
        return S6C2Rig(base: base, servers: BackendDevServers(files: files, sessions: sessions, ports: S6C2NoPorts()), sessions: sessions)
    }
    /// A real loopback listener: the kernel completes connections, which is all a dial needs.
    private func listen() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0; addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        Darwin.listen(fd, 8)
        var bound = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        listeners.append(fd)
        return Int(UInt16(bigEndian: bound.sin_port))
    }
    private func closedPort() -> Int {
        let port = listen(); Darwin.close(listeners.removeLast()); return port
    }
    private func wait(_ seconds: Double = 8, _ condition: () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if await condition() { return true }; try? await Task.sleep(for: .milliseconds(40)) }
        return await condition()
    }
    private let dev = ["package.json": #"{"scripts":{"dev":"vite"}}"#, "pnpm-lock.yaml": ""]

    // MARK: finding the command (:153-:223)
    func testS6C2FindsDevAndBuildsCommandFromLockfile() async throws {
        let r = try rig(); defer { r.dispose() }
        let folder = try r.project(dev)
        let s = try await r.status(folder)
        XCTAssertEqual(s["status"].string, "idle"); XCTAssertEqual(s["script"].string, "dev"); XCTAssertEqual(s["command"].string, "pnpm run dev")
        XCTAssertEqual(s["folder"].string, folder)
    }
    func testS6C2OffersNothingWithoutAUsableScript() async throws {
        let r = try rig(); defer { r.dispose() }
        let bodies: [String?] = [nil, "{ not json", #"{"name":"x"}"#, #"{"scripts":{"build":"tsc","test":"vitest","deploy":"./ship.sh"}}"#]
        for body in bodies {
            let folder = try r.project(body.map { ["package.json": $0] } ?? [:])
            let s = try await r.status(folder)
            XCTAssertEqual(s["status"].string, "no-dev-script", "\(body ?? "no package.json")")
            XCTAssertEqual(s["script"], .missing)
        }
    }
    func testS6C2EmptyScriptIsNotDeclaredAndOrderIsDevStartServe() async throws {
        let r = try rig(); defer { r.dispose() }
        let cases: [(String, String)] = [
            (#"{"scripts":{"dev":"   ","start":"node server.js"}}"#, "start"),
            (#"{"scripts":{"serve":"http-server","start":"node .","dev":"vite"}}"#, "dev"),
            (#"{"scripts":{"serve":"http-server","start":"node ."}}"#, "start"),
            (#"{"scripts":{"serve":"http-server"}}"#, "serve")]
        for (body, expected) in cases {
            let s = try await r.status(try r.project(["package.json": body]))
            XCTAssertEqual(s["script"].string, expected)
        }
    }
    func testS6C2PackageManagerComesFromLockfileOnDisk() async throws {
        let r = try rig(); defer { r.dispose() }
        let pkg = #"{"scripts":{"dev":"x"}}"#
        let cases: [([String], String)] = [(["pnpm-lock.yaml"], "pnpm run dev"), (["yarn.lock"], "yarn run dev"), (["bun.lockb"], "bun run dev"),
            (["bun.lock"], "bun run dev"), (["package-lock.json"], "npm run dev"), (["npm-shrinkwrap.json"], "npm run dev"),
            (["pnpm-lock.yaml", "package-lock.json"], "pnpm run dev"), ([], "npm run dev")]
        for (locks, command) in cases {
            var files = ["package.json": pkg]; locks.forEach { files[$0] = "" }
            let awaited1 = try await r.status(try r.project(files))
            XCTAssertEqual(awaited1["command"].string, command, "\(locks)")
        }
    }

    // MARK: reading the output (:235-:278)
    func testS6C2PortsInOutput() {
        XCTAssertEqual(BackendDevServers.portsInOutput("  ➜  Local:   http://localhost:5173/"), [5173])
        XCTAssertEqual(BackendDevServers.portsInOutput("- Local:        http://127.0.0.1:3000"), [3000])
        XCTAssertEqual(BackendDevServers.portsInOutput("Server running at http://[::1]:4321/"), [4321])
        XCTAssertEqual(BackendDevServers.portsInOutput("Listening on port 8080"), [8080])
        XCTAssertEqual(BackendDevServers.portsInOutput("ready on port 4000"), [4000])
        XCTAssertEqual(BackendDevServers.portsInOutput("http://localhost:99999/ and port 0"), [])
        XCTAssertEqual(BackendDevServers.portsInOutput("http://localhost:3000\nhttp://localhost:3000"), [3000])
    }
    func testS6C2LatestLine() {
        XCTAssertEqual(BackendDevServers.latestLine("one\ntwo\n\n  \n"), "two")
        XCTAssertEqual(BackendDevServers.latestLine("\u{1b}[32mcompiling\u{1b}[0m"), "compiling")
        XCTAssertEqual(BackendDevServers.latestLine("building\u{1b}[2K\u{1b}[1G"), "building")
        XCTAssertEqual(BackendDevServers.latestLine(String(repeating: "x", count: 5000))?.count, 200)
        XCTAssertNil(BackendDevServers.latestLine("\n\n   \n"))
    }

    // MARK: the states (:351-:453)
    func testS6C2NoDevScriptStartsNothing() async throws {
        let r = try rig(); defer { r.dispose() }
        let folder = try r.project([:])
        let s = try await r.start(folder)
        XCTAssertEqual(s["status"].string, "no-dev-script")
        XCTAssertEqual(r.sessions.openedSnapshot, []); XCTAssertEqual(r.sessions.typedSnapshot.count, 0)
    }
    func testS6C2StartAnswersStartingAndTypesTheCommand() async throws {
        let r = try rig(); defer { r.dispose() }
        let folder = try r.project(dev)
        let first = try await r.start(folder)
        XCTAssertEqual(first["status"].string, "starting"); XCTAssertEqual(first["sessionId"].string, "s1")
        let typed = await wait(5) { r.sessions.typedSnapshot.count == 1 }
        XCTAssertTrue(typed)
        XCTAssertEqual(r.sessions.typedSnapshot.first?.0, "s1"); XCTAssertEqual(r.sessions.typedSnapshot.first?.1, "pnpm run dev\r")
    }
    func testS6C2OpenerRefusalPassesThroughUnchanged() async throws {
        let r = try rig(); defer { r.dispose() }
        r.sessions.refuse = "This Mac is not offering that folder to this device."
        let s = try await r.start(try r.project(dev))
        XCTAssertEqual(s["status"].string, "failed")
        XCTAssertEqual(s["message"].string, "This Mac is not offering that folder to this device.")
        XCTAssertEqual(r.sessions.typedSnapshot.count, 0)
    }
    func testS6C2SecondPressWhileStartingStartsNoSecondServer() async throws {
        let r = try rig(); defer { r.dispose() }
        let folder = try r.project(dev)
        _ = try await r.start(folder)
        let awaited2 = try await r.start(folder)
        XCTAssertEqual(awaited2["status"].string, "starting")
        XCTAssertEqual(r.sessions.openedSnapshot, [folder])
        // :498 a trailing separator is the same project
        let awaited3 = try await r.status(folder + "/")
        XCTAssertEqual(awaited3["status"].string, "starting")
    }
    func testS6C2SurfacesLatestLineOnceWhileStarting() async throws {
        let r = try rig(); defer { r.dispose() }
        let states = S6C2States()
        _ = await r.servers.onChange { states.add($0) }
        let folder = try r.project(dev)
        _ = try await r.start(folder)
        r.sessions.say("s1", "$ pnpm run dev\nCompiling /app ...\n")
        let seen = await wait { states.all.contains { $0["note"].string == "Compiling /app ..." } }
        XCTAssertTrue(seen)
        try await Task.sleep(for: .milliseconds(1_600))   // two more polls of unchanged output
        XCTAssertEqual(states.all.filter { $0["note"].string == "Compiling /app ..." }.count, 1)
    }

    // MARK: ready is a port that accepted a connection (:286-:337)
    func testS6C2ReadyOnceSomethingAcceptsAndNamesTheProvedPort() async throws {
        let r = try rig(); defer { r.dispose() }
        let folder = try r.project(dev)
        _ = try await r.start(folder)
        let port = listen()                       // opened AFTER the baseline scan
        r.sessions.say("s1", "$ pnpm run dev\n  ➜  Local:   http://localhost:\(port)/\n")
        let ready = await wait(10) { (try? await r.status(folder))?["status"].string == "ready" }
        XCTAssertTrue(ready)
        let s = try await r.status(folder)
        XCTAssertEqual(s["port"].number, Double(port)); XCTAssertEqual(s["url"].string, "http://localhost:\(port)"); XCTAssertEqual(s["sessionId"].string, "s1")
        // :441 a press while ready answers ready and starts nothing
        let awaited4 = try await r.start(folder)
        XCTAssertEqual(awaited4["status"].string, "ready")
        XCTAssertEqual(r.sessions.openedSnapshot, [folder])
    }
    // :300 (partial) a printed port nobody accepts on never becomes ready
    func testS6C2OutputAloneNeverMakesItReady() async throws {
        let r = try rig(); defer { r.dispose() }
        let folder = try r.project(dev)
        _ = try await r.start(folder)
        r.sessions.say("s1", "$ pnpm run dev\n  ➜  Local:   http://localhost:\(closedPort())/\n")
        try await Task.sleep(for: .milliseconds(2_300))
        let s = try await r.status(folder)
        XCTAssertEqual(s["status"].string, "starting"); XCTAssertEqual(s["port"], .missing)
    }
    // :399 command exits without listening => failed, session kept; :485 restart drops sentence and session
    func testS6C2ExitWithoutListeningFailsKeepingSessionThenRestartIsClean() async throws {
        let r = try rig(); defer { r.dispose() }
        let folder = try r.project(dev)
        _ = try await r.start(folder)
        r.sessions.say("s1", "Error: Cannot find module ‘vite’\n"); r.sessions.kill("s1")
        let failed = await wait(10) { (try? await r.status(folder))?["status"].string == "failed" }
        XCTAssertTrue(failed)
        let final = try await r.status(folder)
        XCTAssertEqual(final["sessionId"].string, "s1")
        XCTAssertNotNil(final["message"].string)
        let again = try await r.start(folder)
        XCTAssertEqual(again["status"].string, "starting"); XCTAssertEqual(again["sessionId"].string, "s2"); XCTAssertEqual(again["message"], .missing)
    }

    // MARK: the state follows the session (:455-:496)
    func testS6C2ReadySessionKilledGoesBackToIdleWithoutAddress() async throws {
        let r = try rig(); defer { r.dispose() }
        let folder = try r.project(dev)
        _ = try await r.start(folder)
        let port = listen(); r.sessions.say("s1", "http://localhost:\(port)/")
        let ready = await wait(10) { (try? await r.status(folder))?["status"].string == "ready" }
        XCTAssertTrue(ready)
        r.sessions.kill("s1")
        let after = try await r.status(folder)
        XCTAssertEqual(after["status"].string, "idle"); XCTAssertEqual(after["url"], .missing); XCTAssertEqual(after["port"], .missing)
    }
    func testS6C2NoteExitPushesIdleStraightAway() async throws {
        let r = try rig(); defer { r.dispose() }
        let folder = try r.project(dev)
        _ = try await r.start(folder)
        let port = listen(); r.sessions.say("s1", "http://localhost:\(port)/")
        let ready = await wait(10) { (try? await r.status(folder))?["status"].string == "ready" }
        XCTAssertTrue(ready)
        let states = S6C2States(); _ = await r.servers.onChange { states.add($0) }
        r.sessions.kill("s1")
        await r.servers.noteExit(sessionID: "s1", context: r.context)
        XCTAssertEqual(states.all.map { $0["status"].string }, ["idle"])
    }

    // MARK: two projects, dispose (:506 :527)
    func testS6C2TwoProjectsBothReachReady() async throws {
        let r = try rig(); defer { r.dispose() }
        let a = try r.project(dev), b = try r.project(dev)
        _ = try await r.start(a); _ = try await r.start(b)
        let pa = listen(), pb = listen()
        r.sessions.say("s1", "Local: http://localhost:\(pa)/"); r.sessions.say("s2", "Local: http://localhost:\(pb)/")
        let both = await wait(12) {
            let x = try? await r.status(a), y = try? await r.status(b)
            return x?["status"].string == "ready" && y?["status"].string == "ready"
        }
        XCTAssertTrue(both)
        let awaited5 = try await r.status(a)
        let awaited6 = try await r.status(b)
        XCTAssertEqual(awaited5["port"].number, Double(pa)); XCTAssertEqual(awaited6["port"].number, Double(pb))
    }
    func testS6C2DisposedServiceWritesNothing() async throws {
        let r = try rig(); defer { r.dispose() }
        let folder = try r.project(dev)
        _ = try await r.start(folder)
        await r.servers.stop()
        let states = S6C2States(); _ = await r.servers.onChange { states.add($0) }
        let port = listen(); r.sessions.say("s1", "http://localhost:\(port)/")
        try await Task.sleep(for: .milliseconds(1_800))
        XCTAssertEqual(states.all.count, 0)
    }
}
