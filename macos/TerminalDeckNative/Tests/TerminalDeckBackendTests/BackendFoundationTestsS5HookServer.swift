import Foundation
import Darwin
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

// S5 night: src/main/hook-server.test.ts.
// Part 1 (always compiled) needs only BackendSessionHookEvent.parse.
// Part 2 drives a REAL BackendSessionHookServer over its Unix socket. The server needs a
// BackendSessionHookCoordinator, whose only initializer takes a live lifecycle coordinator, account
// attribution and a ledger. Part 2 therefore compiles only when the seam requested in
// macos/NIGHT-REQUESTS.md (S5 hook-server) exists and the flag BACKEND_S5_HOOK_SEAM is set.
// Skipped, with reason: Windows named pipe / .ps1 client / hookAddress cases (hook-server.test.ts:307-424, 444),
// "two racing callers get one server" (:678, TS module singleton; Swift has one owner per instance).

@Suite("Foundation S5: hook agent environment report")
struct BackendFoundationTestsS5HookAgentEnv {
    private func header(_ report: Any) throws -> String {
        Data(try JSONSerialization.data(withJSONObject: report, options: [.fragmentsAllowed])).base64EncodedString()
    }
    private func evidence(_ report: Any, provider: String = "claude") throws -> BackendAccountHookEvidence? {
        BackendSessionHookEvent.parse(provider: provider, event: "SessionStart", sessionID: "s", body: Data("{}".utf8),
            environmentHeader: try header(report), peerPID: 1).agentEnvironment
    }
    // TS hook-server.test.ts:192
    @Test func variablesHomeAndPathProofDecoded() throws {
        let value = try #require(try evidence(["vars": ["CLAUDE_CONFIG_DIR": "/Users/asad/.claude-work"], "path": true, "home": "/Users/asad"]))
        #expect(value.configDirectory == "/Users/asad/.claude-work"); #expect(value.home == "/Users/asad"); #expect(value.environmentWasRead == true)
    }
    // TS hook-server.test.ts:207
    @Test func nonASCIIHomeSurvives() throws {
        let value = try #require(try evidence(["vars": [String: String](), "path": true, "home": "/Users/Иван"]))
        #expect(value.home == "/Users/Иван")
    }
    // TS hook-server.test.ts:212
    @Test func unreadEnvironmentIsUnreadNeverEmpty() throws {
        let value = try #require(try evidence(["vars": [String: String](), "path": false, "home": NSNull()]))
        #expect(value.environmentWasRead == false); #expect(value.configDirectory == nil); #expect(value.home == nil)
    }
    // TS hook-server.test.ts:219
    @Test func nonReportsRefused() throws {
        let direct = { (text: String?) in BackendSessionHookEvent.parse(provider: "claude", event: "Stop", sessionID: "s", body: Data("{}".utf8), environmentHeader: text, peerPID: 1).agentEnvironment }
        #expect(direct(nil) == nil); #expect(direct("") == nil); #expect(direct("not base64 json at all") == nil)
        #expect(try evidence("a string, not an object") == nil); #expect(try evidence([1, 2, 3]) == nil)
    }
    // TS hook-server.test.ts:219 (last expectation): a number where a path belongs is dropped, not stringified
    @Test func numberWhereAPathBelongsIsDropped() throws {
        let value = try #require(try evidence(["vars": ["CLAUDE_CONFIG_DIR": 7], "path": true]))
        #expect(value.configDirectory == nil); #expect(value.environmentWasRead == true); #expect(value.home == nil)
    }
    // TS hook-server.test.ts:608 (unparseable header must not lose the event)
    @Test func unparseableHeaderKeepsTheEvent() {
        let event = BackendSessionHookEvent.parse(provider: "claude", event: "Stop", sessionID: "session-8", body: Data("{}".utf8), environmentHeader: "!!", peerPID: 1)
        #expect(event.event == "Stop"); #expect(event.sessionID == "session-8"); #expect(event.agentEnvironment == nil)
    }
}

/// Collects events delivered to the observer; `wait` resumes once `count` have arrived.
private actor HookEventBox {
    private(set) var events: [BackendSessionHookEvent] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func add(_ event: BackendSessionHookEvent) {
        events.append(event)
        for waiter in waiters where events.count >= waiter.0 { waiter.1.resume() }
        waiters.removeAll { events.count >= $0.0 }
    }
    func wait(count: Int) async {
        if events.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
}

private struct HookReply { let status: Int; let text: String }

private final class HookServerHarness: @unchecked Sendable {
    let scratch: BackendFoundationTestsSessionsScratch
    let configuration: BackendAccountConfiguration
    let coordinator = BackendSessionHookCoordinator.observerOnlyForTesting()
    let box = HookEventBox()
    let server: BackendSessionHookServer
    var endpoint: BackendSessionHookEndpoint { server.endpoint }
    static func configuration(_ scratch: BackendFoundationTestsSessionsScratch) throws -> BackendAccountConfiguration {
        try BackendAccountConfiguration(dataDirectory: scratch.root.appendingPathComponent("data"), homeDirectory: scratch.root, appName: "Terminal Deck", appID: "terminaldeck",
            helperExecutable: scratch.root.appendingPathComponent("never-executed-helper"), inheritedEnvironment: [:])
    }
    init(scratch existing: BackendFoundationTestsSessionsScratch? = nil,
         context: @escaping @Sendable (BackendSessionHookEvent) async throws -> String? = { _ in nil },
         open: (@Sendable (URL, String?) async throws -> BackendSessionHookOpenAnswer)? = nil) async throws {
        scratch = try existing ?? BackendFoundationTestsSessionsScratch()
        configuration = try Self.configuration(scratch)
        server = try BackendSessionHookServer(configuration: configuration, sessionEnvironment: "TERMINALDECK_SESSION_ID", coordinator: coordinator, additionalContext: context, openLink: open)
        let box = self.box
        await coordinator.observe { await box.add($0) }
    }
    deinit { server.stop() }
    /// The per-run token lives only in the 0600 curl config the hook command reads.
    var token: String {
        let text = (try? String(contentsOfFile: endpoint.configPath, encoding: .utf8)) ?? ""
        return text.components(separatedBy: "\n").compactMap { line -> String? in
            line.hasPrefix("header = \"x-terminaldeck-token: ") ? String(line.dropFirst("header = \"x-terminaldeck-token: ".count).dropLast()) : nil
        }.first ?? ""
    }
    /// Raw HTTP over the socket: Host and method must be controllable, as in the TS tests.
    func send(method: String = "POST", path: String = "/hook/claude/Stop", token: String? = nil, host: String? = "localhost",
              body: String = "{}", session: String? = nil, agentEnv: String? = nil, declaredLength: Int? = nil) async throws -> HookReply {
        // The blocking socket read runs on a dispatch thread so it can never starve the cooperative pool the server's tasks need.
        let tokenValue = token ?? self.token
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try self.sendSync(method: method, path: path, token: tokenValue, host: host, body: body, session: session, agentEnv: agentEnv, declaredLength: declaredLength) })
            }
        }
    }
    private func sendSync(method: String = "POST", path: String = "/hook/claude/Stop", token: String? = nil, host: String? = "localhost",
              body: String = "{}", session: String? = nil, agentEnv: String? = nil, declaredLength: Int? = nil) throws -> HookReply {
        var head = "\(method) \(path) HTTP/1.1\r\n"
        if let host { head += "Host: \(host)\r\n" }
        head += "content-type: application/json\r\nx-terminaldeck-token: \(token ?? self.token)\r\n"
        if let session { head += "x-terminaldeck-session: \(session)\r\n" }
        if let agentEnv { head += "x-terminaldeck-agent-env: \(agentEnv)\r\n" }
        head += "Content-Length: \(declaredLength ?? body.utf8.count)\r\n\r\n"
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0); defer { Darwin.close(fd) }
        var noPipe: Int32 = 1; _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX); address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(endpoint.socketPath.utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { output in for i in bytes.indices { output[i] = UInt8(bitPattern: bytes[i]) } }
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard connected == 0 else { throw BackendSessionFailure.unsupported("connect failed: \(errno)") }
        let payload = Data((head + (declaredLength == nil ? body : "")).utf8)
        _ = payload.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, payload.count, 0) }
        var received = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true { let count = Darwin.recv(fd, &buffer, buffer.count, 0); if count <= 0 { break }; received.append(contentsOf: buffer.prefix(count)) }
        let text = String(decoding: received, as: UTF8.self)
        let status = Int(text.split(separator: " ").dropFirst().first ?? "0") ?? 0
        let bodyText = text.range(of: "\r\n\r\n").map { String(text[$0.upperBound...]) } ?? ""
        return HookReply(status: status, text: bodyText)
    }
}

@Suite("Foundation S5: hook endpoint over a real socket")
struct BackendFoundationTestsS5HookEndpoint {
    // TS hook-server.test.ts:426 (POSIX half)
    @Test func listensOnSocketInsideItsOwnDirectory() async throws {
        let h = try await HookServerHarness()
        #expect(h.endpoint.socketPath.hasSuffix("hook.sock") || h.endpoint.socketPath.hasPrefix("/tmp/terminaldeck-hook-"))
        var info = stat(); #expect(lstat(h.endpoint.socketPath, &info) == 0); #expect((info.st_mode & S_IFMT) == S_IFSOCK)
        #expect(h.server.status()["running"].bool == true)
    }
    // TS hook-server.test.ts:471 + :490 — same address across restarts; no TCP port is ever bound (the address is a socket path)
    @Test func sameAddressAfterRestart() async throws {
        let scratch = try BackendFoundationTestsSessionsScratch()
        let first = try await HookServerHarness(scratch: scratch); let address = first.endpoint.socketPath; first.server.stop()
        let second = try await HookServerHarness(scratch: scratch)
        #expect(second.endpoint.socketPath == address); #expect(try await second.send().status == 204)
    }
    // TS hook-server.test.ts:497
    @Test func freshTokenEveryRunAndOwnerOnlyConfig() async throws {
        let a = try await HookServerHarness(), b = try await HookServerHarness()
        #expect(a.token.count >= 32); #expect(a.token != b.token)
        let mode = try FileManager.default.attributesOfItem(atPath: a.endpoint.configPath)[.posixPermissions] as? Int
        #expect(mode.map { $0 & 0o077 } == 0)
        var info = stat(); lstat(a.endpoint.socketPath, &info); #expect(info.st_mode & 0o077 == 0)
    }
    // TS hook-server.test.ts:565
    @Test func refusesAddressAnotherCopyIsServing() async throws {
        let scratch = try BackendFoundationTestsSessionsScratch(), live = try await HookServerHarness(scratch: scratch)
        #expect(throws: (any Error).self) { _ = try BackendSessionHookServer(configuration: live.configuration, sessionEnvironment: "TERMINALDECK_SESSION_ID", coordinator: live.coordinator, additionalContext: { _ in nil }) }
        #expect(try await live.send().status == 204)
    }
    // TS hook-server.test.ts:581
    @Test func stoppedEndpointIsForgotten() async throws {
        let h = try await HookServerHarness(); let socket = h.endpoint.socketPath, config = h.endpoint.configPath
        h.server.stop()
        #expect(!FileManager.default.fileExists(atPath: socket)); #expect(!FileManager.default.fileExists(atPath: config)); #expect(h.server.status()["running"].bool == false)
    }
    // TS hook-server.test.ts:699
    @Test func failedBindDoesNotPoisonNextStart() async throws {
        let scratch = try BackendFoundationTestsSessionsScratch()
        try scratch.write("data", "a regular file where the data directory must go")
        #expect(throws: (any Error).self) { _ = try HookServerHarness.configuration(scratch).dataDirectory; _ = try BackendSessionHookServer(configuration: HookServerHarness.configuration(scratch), sessionEnvironment: "TERMINALDECK_SESSION_ID", coordinator: .observerOnlyForTesting(), additionalContext: { _ in nil }) }
        let fresh = try await HookServerHarness()
        #expect(FileManager.default.fileExists(atPath: fresh.endpoint.socketPath))
    }
    // The session marker is an environment-variable name; anything else is refused (BackendSessionHookServer init guard)
    @Test func invalidSessionMarkerRefused() throws {
        let scratch = try BackendFoundationTestsSessionsScratch()
        #expect(throws: (any Error).self) { _ = try BackendSessionHookServer(configuration: HookServerHarness.configuration(scratch), sessionEnvironment: "not valid", coordinator: .observerOnlyForTesting(), additionalContext: { _ in nil }) }
    }
}

@Suite("Foundation S5: hook endpoint requests")
struct BackendFoundationTestsS5HookRequests {
    // TS hook-server.test.ts:587
    @Test func taggedEventReachesListeners() async throws {
        let h = try await HookServerHarness()
        let reply = try await h.send(path: "/hook/claude/PostToolUse", body: #"{"session_id":"cli-9","tool_name":"Bash"}"#, session: "session-7")
        await h.box.wait(count: 1); let event = await h.box.events[0]
        #expect(reply.status == 204)
        #expect(event.provider == "claude"); #expect(event.event == "PostToolUse"); #expect(event.sessionID == "session-7"); #expect(event.cliSessionID == "cli-9"); #expect(event.toolName == "Bash")
    }
    // TS hook-server.test.ts:609
    @Test func environmentReportReachesListenersAndBadHeaderKeepsEvent() async throws {
        let h = try await HookServerHarness()
        let report = try JSONSerialization.data(withJSONObject: ["vars": ["CLAUDE_CONFIG_DIR": "/Users/asad/.claude-work"], "path": true, "home": "/Users/asad"]).base64EncodedString()
        _ = try await h.send(path: "/hook/claude/SessionStart", session: "session-8", agentEnv: report)
        _ = try await h.send(path: "/hook/claude/Stop", session: "session-8", agentEnv: "!!")
        await h.box.wait(count: 2); let events = await h.box.events
        #expect(events.count == 2)
        let start = try #require(events.first { $0.event == "SessionStart" }), stop = try #require(events.first { $0.event == "Stop" })
        #expect(start.agentEnvironment?.configDirectory == "/Users/asad/.claude-work"); #expect(start.agentEnvironment?.environmentWasRead == true); #expect(start.agentEnvironment?.home == "/Users/asad")
        #expect(stop.agentEnvironment == nil)
    }
    // TS hook-server.test.ts:640
    @Test func missingWrongOrWrongLengthTokenRefused() async throws {
        let h = try await HookServerHarness()
        #expect(try await h.send(token: "").status == 403)
        #expect(try await h.send(token: String(repeating: "b", count: h.token.count)).status == 403)
        #expect(try await h.send(token: "short").status == 403)
        #expect(try await h.send(path: "/hook/claude/Stop", session: "marker").status == 204)
        await h.box.wait(count: 1); #expect(await h.box.events.count == 1)
    }
    // TS hook-server.test.ts:651
    @Test func requestAddressedToSomebodyElseRefused() async throws {
        let h = try await HookServerHarness()
        #expect(try await h.send(host: "evil.example.com").status == 403)
    }
    // TS hook-server.test.ts:133 + :286 — loopback names with or without a port are accepted
    @Test func loopbackHostNamesAccepted() async throws {
        let h = try await HookServerHarness()
        for host in ["localhost", "localhost:80", "127.0.0.1", "127.0.0.1:8080", "[::1]"] { #expect(try await h.send(host: host).status == 204, "\(host)") }
    }
    // TS hook-server.test.ts:290 accepts "[::1]:8080"
    @Test func bracketedIPv6HostWithPortAccepted() async throws {
        let h = try await HookServerHarness()
        #expect(try await h.send(host: "[::1]:8080").status == 204)
    }
    // TS hook-server.test.ts:133 + :656 — only POST /hook/<provider>/<event>
    @Test func onlyPostToHookRoutesAccepted() async throws {
        let h = try await HookServerHarness()
        let get = try await h.send(method: "GET")
        #expect(get.status == 400 || get.status == 405)  // TS answers 405; Swift refuses at the parser with 400
        #expect(try await h.send(path: "/").status == 404)
        #expect(try await h.send(path: "/hook/claude").status == 404)
        #expect(try await h.send(path: "/hook/claude/Stop/extra").status == 404)
        #expect(try await h.send(path: "/../../etc/passwd").status == 404)
        #expect(try await h.send(path: "/hook/claude/Stop?x=1").status == 204)
    }
    // TS hook-server.test.ts:663
    @Test func keepsServingAfterListenerMisbehaves() async throws {
        let h = try await HookServerHarness(context: { _ in throw BackendSessionFailure.invalidInput("subscriber is broken") })
        #expect(try await h.send(path: "/hook/claude/UserPromptSubmit").status == 204)
        #expect(try await h.send(path: "/hook/claude/UserPromptSubmit").status == 204)
    }
    // TS hook-server.test.ts:713 — TS answers 413; Swift refuses the oversize declaration at the parser with 400. Either way: nothing delivered, endpoint still serving.
    @Test func oversizedBodyRefusedWithoutDelivery() async throws {
        let h = try await HookServerHarness()
        let reply = try await h.send(body: "", declaredLength: 2 * 1024 * 1024)
        #expect([400, 413].contains(reply.status))
        #expect(try await h.send(path: "/hook/claude/Stop", session: "after").status == 204)
        await h.box.wait(count: 1); let events = await h.box.events
        #expect(events.count == 1); #expect(events[0].sessionID == "after")
    }
    // TS hook-server.test.ts:742
    @Test func observerCanUnsubscribe() async throws {
        let h = try await HookServerHarness(); let late = HookEventBox()
        let id = await h.coordinator.observe { await late.add($0) }
        _ = try await h.send(session: "one"); await late.wait(count: 1)
        await h.coordinator.removeObserver(id)
        _ = try await h.send(session: "two"); await h.box.wait(count: 2)
        #expect(await late.events.count == 1)
    }
}

@Suite("Foundation S5: hook POST /open")
struct BackendFoundationTestsS5HookOpen {
    // TS hook-server.test.ts:793
    @Test func urlAndSessionHandedToRouterAnswersTwoLines() async throws {
        let seen = HookOpenSeen()
        let h = try await HookServerHarness(open: { url, session in await seen.add(url.absoluteString, session); return .init(route: .tab, line: "Opened in B2 — Terminal Deck.") })
        let reply = try await h.send(path: "/open", body: "https://example.com/x", session: "session-7")
        #expect(reply.status == 200); #expect(reply.text == "tab\nOpened in B2 — Terminal Deck.\n")
        #expect(await seen.rows == ["https://example.com/x|session-7"])
    }
    // TS hook-server.test.ts:814
    @Test func jsonFormAcceptedAsWellAsBareURL() async throws {
        let seen = HookOpenSeen()
        let h = try await HookServerHarness(open: { url, session in await seen.add(url.absoluteString, session); return .init(route: .system, line: "nope") })
        _ = try await h.send(path: "/open", body: #"{"url":"https://example.com/json"}"#)
        #expect(await seen.rows == ["https://example.com/json|nil"])
    }
    // TS hook-server.test.ts:830 — TS also requires the sentence to mention the default browser; Swift's wording is "system browser" (recorded as a text difference)
    @Test func neverAnswersWithoutASentence() async throws {
        let h = try await HookServerHarness()
        let reply = try await h.send(path: "/open", body: "https://example.com/")
        #expect(reply.text.hasPrefix("system\n")); #expect(!(reply.text.split(separator: "\n").dropFirst().first ?? "").isEmpty)
    }
    // TS hook-server.test.ts:843
    @Test func routerFailureFallsBackToMachine() async throws {
        let h = try await HookServerHarness(open: { _, _ in throw BackendSessionFailure.invalidInput("boom") })
        #expect(try await h.send(path: "/open", body: "https://example.com/").text.hasPrefix("system\n"))
    }
    // /open refuses anything that is not an http(s) address (BackendSessionHookServer.respond)
    @Test func nonWebAddressesNeverReachRouter() async throws {
        let seen = HookOpenSeen()
        let h = try await HookServerHarness(open: { url, session in await seen.add(url.absoluteString, session); return .init(route: .tab, line: "x") })
        #expect(try await h.send(path: "/open", body: "file:///etc/passwd").text.hasPrefix("system\n"))
        #expect(await seen.rows.isEmpty)
    }
}

private actor HookOpenSeen {
    private(set) var rows: [String] = []
    func add(_ url: String, _ session: String?) { rows.append(url + "|" + (session ?? "nil")) }
}

private actor HookAsked {
    private(set) var rows: [String] = []
    func add(_ row: String) { rows.append(row) }
}

@Suite("Foundation S5: hook answers carry context")
struct BackendFoundationTestsS5HookAnswers {
    private func envelope(_ event: String, _ context: String) -> NativeRPCValue {
        .object([.init("hookSpecificOutput", .object([.init("hookEventName", .string(event)), .init("additionalContext", .string(context))]))])
    }
    // TS hook-server.test.ts:883
    @Test func userPromptSubmitCarriesContext() async throws {
        let h = try await HookServerHarness(context: { $0.sessionID == "s1" ? "B1 — a page" : nil })
        let reply = try await h.send(path: "/hook/claude/UserPromptSubmit", session: "s1")
        #expect(reply.status == 200); #expect(try NativeRPCValue.parseJSON(Data(reply.text.utf8)) == envelope("UserPromptSubmit", "B1 — a page"))
    }
    // TS hook-server.test.ts:898 — Stop is the same empty 204 and the question is never asked
    @Test func otherEventsStayEmpty204AndAreNotAsked() async throws {
        let asked = HookAsked()
        let h = try await HookServerHarness(context: { await asked.add($0.event); return "B1 — a page" })
        let reply = try await h.send(path: "/hook/claude/Stop", session: "s1")
        #expect(reply.status == 204); #expect(reply.text == ""); #expect(await asked.rows.isEmpty)
    }
    // TS hook-server.test.ts:915
    @Test func postToolUseAsksAndAnswersNothingWhenUnchanged() async throws {
        let asked = HookAsked()
        let h = try await HookServerHarness(context: { await asked.add($0.event); return nil })
        #expect(try await h.send(path: "/hook/claude/PostToolUse", session: "s1").status == 204)
        #expect(await asked.rows == ["PostToolUse"])
    }
    // TS hook-server.test.ts:939
    @Test func envelopeNeverHandedToEventsThatPutATurnOnScreen() async throws {
        let asked = HookAsked()
        let h = try await HookServerHarness(context: { await asked.add($0.provider); return "inside the app" })
        #expect(try await h.send(path: "/hook/gemini/SessionStart", session: "s1").status == 204)
        #expect(try await h.send(path: "/hook/codex/UserPromptSubmit", session: "s1").status == 204)
        #expect(await asked.rows.isEmpty)
        #expect(try await h.send(path: "/hook/claude/SessionStart", session: "s1").status == 200)
        #expect(await asked.rows == ["claude"])
    }
    // TS hook-server.test.ts:963
    @Test func codexBootsAndMidTurnWithItsOwnEnvelope() async throws {
        let h = try await HookServerHarness(context: { $0.provider == "codex" ? "\($0.event) — B1" : nil })
        let boot = try await h.send(path: "/hook/codex/SessionStart", session: "s1"), mid = try await h.send(path: "/hook/codex/PostToolUse", session: "s1")
        #expect(boot.status == 200); #expect(try NativeRPCValue.parseJSON(Data(boot.text.utf8)) == envelope("SessionStart", "SessionStart — B1"))
        #expect(mid.status == 200); #expect(try NativeRPCValue.parseJSON(Data(mid.text.utf8)) == envelope("PostToolUse", "PostToolUse — B1"))
    }
    // TS hook-server.test.ts:994
    @Test func everyAgentHasBothDoors() async throws {
        let h = try await HookServerHarness(context: { _ in "inside the app" })
        let doors = ["claude": ("SessionStart", "PostToolUse"), "codex": ("SessionStart", "PostToolUse"), "gemini": ("BeforeAgent", "AfterTool")]
        for (provider, door) in doors {
            #expect(try await h.send(path: "/hook/\(provider)/\(door.0)", session: "s1").status == 200, "\(provider) boot")
            #expect(try await h.send(path: "/hook/\(provider)/\(door.1)", session: "s1").status == 200, "\(provider) mid-turn")
        }
    }
    // TS hook-server.test.ts:1022
    @Test func codexPromptsAreNotSpent() async throws {
        let asked = HookAsked()
        let h = try await HookServerHarness(context: { await asked.add($0.event); return "inside the app" })
        #expect(try await h.send(path: "/hook/codex/UserPromptSubmit", session: "s1").status == 204)
        #expect(await asked.rows.isEmpty)
    }
    // TS hook-server.test.ts:1040
    @Test func nothingAttachedMeansEmptyAnswer() async throws {
        let h = try await HookServerHarness(context: { _ in nil })
        let reply = try await h.send(path: "/hook/claude/SessionStart", session: "s1")
        #expect(reply.status == 204); #expect(reply.text == "")
    }
}
