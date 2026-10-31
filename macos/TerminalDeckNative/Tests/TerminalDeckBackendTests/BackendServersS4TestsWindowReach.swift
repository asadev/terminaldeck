import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

// Port of src/main/servers/window-reach.test.ts (17 cases). The rules half uses a
// fake connection; the "what it carries" half exercises the real private
// loopback sink (BackendServersSSHReverseLease) with a fake control command and
// plain 127.0.0.1 POSIX sockets. No SSH, no live data. Waits are poll()s that
// return the moment data arrives; the timeouts only matter on failure.

final class BackendServersS4ReachConnection: BackendServersConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [(String, Int)] = []
    let lease: BackendServersWindowTestLease
    let failure: Error?
    init(port: Int = 40404, failure: Error? = nil) { lease = .init(port: port); self.failure = failure }
    var requests: [(String, Int)] { lock.withLock { asked } }
    func reverseForward(bindAddress: String, bindPort: Int) async throws -> any BackendServersReverseForward {
        lock.withLock { asked.append((bindAddress, bindPort)) }
        if let failure { throw failure }
        return lease
    }
    func exec(command: String, stdin: Data?, timeoutMilliseconds: Int, maximumOutputBytes: Int) async throws -> BackendServersRunResult { throw BackendServersSetupFailure.unavailable("Unused test operation") }
    func follow(command: String) async throws -> any BackendServersFollow { throw BackendServersSetupFailure.unavailable("Unused test operation") }
    func shell(size: BackendServersTerminalSize) async throws -> any BackendServersShell { throw BackendServersSetupFailure.unavailable("Unused test operation") }
    func openSFTP() async throws -> any BackendServersSFTP { throw BackendServersSetupFailure.unavailable("Unused test operation") }
    func forward(host: String, port: Int) async throws -> any BackendServersDuplex { throw BackendServersSetupFailure.unavailable("Unused test operation") }
    func onClose(_ callback: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe { {} }
    func close() {}
}

@Suite("window-reach.test.ts — rules (fake connection)")
struct BackendServersS4WindowReachRulesTests {
    private let loopback = BackendServersRunResult(code: 0, stdout: "loopback\n")

    // 118: asks for its own loopback, never a name and never the wildcard
    @Test func asksForItsOwnLoopbackWithPortZero() async {
        let client = BackendServersS4ReachConnection()
        _ = await BackendServersWindowReachRules.open(connection: client, local: .port(1234), runScript: { _ in loopback })
        #expect(client.requests.count == 1)
        #expect(client.requests[0].0 == BackendServersWindowReachRules.loopback && client.requests[0].0 == "127.0.0.1")
        #expect(client.requests[0].1 == 0)
    }
    // 129: checks the port it was given, not the one it asked for
    @Test func checksThePortTheServerChose() async {
        let client = BackendServersS4ReachConnection(port: 51515)
        let asked = BackendServersS4Box<[String]>([])
        _ = await BackendServersWindowReachRules.open(connection: client, local: .port(1234), runScript: { script in asked.mutate { $0.append(script) }; return loopback })
        #expect(asked.value.first?.contains("p=51515") == true)
    }
    // 143: reads the one word out of whatever noise came with it
    @Test func readsTheOneWordOutOfNoise() {
        #expect(BackendServersWindowReachRules.readBindAnswer("loopback\n") == .loopback)
        #expect(BackendServersWindowReachRules.readBindAnswer("bash: warning: setlocale\npublic\n") == .public)
        #expect(BackendServersWindowReachRules.readBindAnswer("") == .unknown)
        #expect(BackendServersWindowReachRules.readBindAnswer("something else entirely") == .unknown)
    }
    // 150: quotes the v6 loopback so the shell reads it as five characters
    @Test func quotesTheV6LoopbackPattern() {
        #expect(BackendServersWindowReachRules.bindCheckScript(80).contains("\"[::1]:\"*"))
    }
    // 156: has a way to answer for a machine with neither tool
    @Test func answersForAMachineWithNeitherTool() {
        let script = BackendServersWindowReachRules.bindCheckScript(80)
        #expect(script.contains("command -v ss") && script.contains("command -v netstat") && script.contains("echo unknown"))
    }
    // 165: says what the SSH settings would have to change when the bind fails
    @Test func bindFailureSaysWhatSettingsToChange() async {
        let client = BackendServersS4ReachConnection(failure: BackendServersProblem("not-allowed", "administratively prohibited"))
        let result = await BackendServersWindowReachRules.open(connection: client, local: .port(1234), runScript: { _ in loopback })
        guard case .refused(let why) = result else { Issue.record("Expected a refusal"); return }
        #expect(why == BackendServersWindowReachRules.cannotForward && why.contains("AllowTcpForwarding") && why.contains("PermitListen"))
        #expect(client.lease.activation == nil)
    }
    // 173: refuses a server that answered with no port at all
    @Test func refusesAServerThatAnsweredWithNoPort() async {
        let client = BackendServersS4ReachConnection(port: 0)
        let result = await BackendServersWindowReachRules.open(connection: client, local: .port(1234), runScript: { _ in loopback })
        guard case .refused(let why) = result else { Issue.record("Expected a refusal"); return }
        #expect(why == BackendServersWindowReachRules.cannotForward && client.lease.activation == nil)
    }
    // 181: takes the port back down when it landed on every interface
    @Test func publicBindIsClosedAgainWithItsExactSentence() async {
        let client = BackendServersS4ReachConnection()
        let result = await BackendServersWindowReachRules.open(connection: client, local: .port(1234), runScript: { _ in .init(code: 0, stdout: "public\n") })
        guard case .refused(let why) = result else { Issue.record("Expected a refusal"); return }
        #expect(why == BackendServersWindowReachRules.boundTooWidely && why.contains("GatewayPorts yes"))
        #expect(client.lease.closeCount == 1 && client.lease.activation == nil)
    }
    // 198: takes it back down when the server could not be asked at all
    @Test func unaskableServerIsClosedAgainWithItsExactSentence() async {
        let client = BackendServersS4ReachConnection()
        let result = await BackendServersWindowReachRules.open(connection: client, local: .port(1234), runScript: { _ in .init(code: 0, stdout: "") })
        guard case .refused(let why) = result else { Issue.record("Expected a refusal"); return }
        #expect(why == BackendServersWindowReachRules.cannotTellWhereBound && why.contains("neither `ss` nor `netstat`"))
        #expect(client.lease.closeCount == 1 && client.lease.activation == nil)
    }
    // 208: treats a connection that died mid-check as not knowing
    @Test func connectionDyingMidCheckIsNotKnowing() async {
        struct NotConnected: Error {}
        let client = BackendServersS4ReachConnection()
        let result = await BackendServersWindowReachRules.open(connection: client, local: .port(1234), runScript: { _ in throw NotConnected() })
        guard case .refused(let why) = result else { Issue.record("Expected a refusal"); return }
        #expect(why == BackendServersWindowReachRules.cannotTellWhereBound && client.lease.closeCount == 1 && client.lease.activation == nil)
    }
    // 241: answers the port the server chose (and activates the proved local end)
    @Test func answersThePortTheServerChoseAfterActivation() async {
        let client = BackendServersS4ReachConnection()
        let result = await BackendServersWindowReachRules.open(connection: client, local: .port(1234), runScript: { _ in loopback })
        guard case .opened(let reach) = result else { Issue.record("Expected an open reach"); return }
        #expect(reach.port == 40404 && client.lease.activation == "tcp:127.0.0.1:1234")
    }
    // 292-adjacent: the TS ceiling constant equals the native one
    @Test func streamCeilingIsSixteen() { #expect(BackendServersWindowReachRules.maximumReachStreams == 16) }
}

final class BackendServersS4Box<Value>: @unchecked Sendable {
    private let lock = NSLock(); private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func mutate(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}

// MARK: - plain loopback socket helpers

enum BackendServersS4Sockets {
    static func listen() -> (fd: Int32, port: Int) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = 0
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        Darwin.listen(fd, 32)
        var bound = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        return (fd, Int(UInt16(bigEndian: bound.sin_port)))
    }
    static func connect(_ port: Int) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = UInt16(port).bigEndian
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        return fd
    }
    /// nil on timeout.
    static func accept(_ listener: Int32, seconds: Double) -> Int32? {
        var pfd = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, Int32(seconds * 1000)) > 0 else { return nil }
        let fd = Darwin.accept(listener, nil, nil); return fd >= 0 ? fd : nil
    }
    /// Bytes read; empty Data at EOF or reset; nil on timeout.
    static func read(_ fd: Int32, seconds: Double = 5) -> Data? {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, Int32(seconds * 1000)) > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(fd, &buffer, buffer.count)
        return count > 0 ? Data(buffer[0..<count]) : Data()
    }
    static func write(_ fd: Int32, _ text: String) { let bytes = Array(text.utf8); _ = Darwin.write(fd, bytes, bytes.count) }
}

@Suite("window-reach.test.ts — what it carries (real private loopback sink, fake control channel)", .serialized)
struct BackendServersS4WindowReachCarryTests {
    private struct Live {
        let lease: BackendServersSSHReverseLease, localPort: Int, calls: BackendServersS4Box<[(String, String)]>
        let cancelled: BackendServersSSHOnce<Bool>
    }
    private func prepared() async throws -> Live {
        let calls = BackendServersS4Box<[(String, String)]>([]), cancelled = BackendServersSSHOnce<Bool>()
        let lease = try await BackendServersSSHReverseLease.prepare(requestedPort: 0, command: { verb, spec in
            calls.mutate { $0.append((verb, spec)) }
            if verb == "cancel" { cancelled.finish(.success(true)) }
            return .init(code: 0, stdout: "40404\n")
        })
        let spec = calls.value.first?.1 ?? ""
        let local = Int(spec.split(separator: ":").last ?? "") ?? 0
        return Live(lease: lease, localPort: local, calls: calls, cancelled: cancelled)
    }

    // 241: answers the port the server chose
    @Test func answersThePortTheServerChose() async throws {
        let live = try await prepared(); defer { live.lease.close() }
        #expect(live.lease.port == 40404)
        #expect(live.calls.value.first?.0 == "forward" && live.calls.value.first?.1.hasPrefix("127.0.0.1:0:127.0.0.1:") == true)
        #expect(live.localPort > 0)
    }
    // 253 (native form): a lease's private sink serves nobody before activation, and never dials
    @Test func refusesEveryConnectionBeforeActivation() async throws {
        let live = try await prepared(); defer { live.lease.close() }
        let endpoint = BackendServersS4Sockets.listen(); defer { close(endpoint.fd) }
        let client = BackendServersS4Sockets.connect(live.localPort); defer { close(client) }
        #expect(BackendServersS4Sockets.read(client) == Data())
        #expect(BackendServersS4Sockets.accept(endpoint.fd, seconds: 0.2) == nil)
    }
    // 246: dials this machine's endpoint for a connection on its own port
    @Test func dialsThisMachinesEndpointAfterActivation() async throws {
        let live = try await prepared(); defer { live.lease.close() }
        let endpoint = BackendServersS4Sockets.listen(); defer { close(endpoint.fd) }
        try await live.lease.activate(target: .tcp(host: "127.0.0.1", port: endpoint.port))
        let client = BackendServersS4Sockets.connect(live.localPort); defer { close(client) }
        let accepted = BackendServersS4Sockets.accept(endpoint.fd, seconds: 5)
        #expect(accepted != nil)
        if let accepted { close(accepted) }
    }
    // 262: carries bytes both ways
    @Test func carriesBytesBothWays() async throws {
        let live = try await prepared(); defer { live.lease.close() }
        let endpoint = BackendServersS4Sockets.listen(); defer { close(endpoint.fd) }
        try await live.lease.activate(target: .tcp(host: "127.0.0.1", port: endpoint.port))
        let client = BackendServersS4Sockets.connect(live.localPort); defer { close(client) }
        guard let accepted = BackendServersS4Sockets.accept(endpoint.fd, seconds: 5) else { Issue.record("Endpoint was never dialled"); return }
        defer { close(accepted) }
        BackendServersS4Sockets.write(client, "POST /mcp")
        #expect(BackendServersS4Sockets.read(accepted).map { String(decoding: $0, as: UTF8.self) } == "POST /mcp")
        BackendServersS4Sockets.write(accepted, "200 OK")
        #expect(BackendServersS4Sockets.read(client).map { String(decoding: $0, as: UTF8.self) } == "200 OK")
    }
    // 274: ends the other side rather than destroying it when one goes (the tail still arrives)
    @Test func halfCloseEndsTheOtherSideAndTheTailStillArrives() async throws {
        let live = try await prepared(); defer { live.lease.close() }
        let endpoint = BackendServersS4Sockets.listen(); defer { close(endpoint.fd) }
        try await live.lease.activate(target: .tcp(host: "127.0.0.1", port: endpoint.port))
        let client = BackendServersS4Sockets.connect(live.localPort); defer { close(client) }
        guard let accepted = BackendServersS4Sockets.accept(endpoint.fd, seconds: 5) else { Issue.record("Endpoint was never dialled"); return }
        defer { close(accepted) }
        BackendServersS4Sockets.write(client, "request"); shutdown(client, SHUT_WR)
        var seen = ""
        while let part = BackendServersS4Sockets.read(accepted), !part.isEmpty { seen += String(decoding: part, as: UTF8.self) }
        #expect(seen == "request")
        BackendServersS4Sockets.write(accepted, "the last bytes"); shutdown(accepted, SHUT_WR)
        var tail = ""
        while let part = BackendServersS4Sockets.read(client), !part.isEmpty { tail += String(decoding: part, as: UTF8.self) }
        #expect(tail == "the last bytes")
    }
    // 286: refuses past its ceiling rather than queueing
    @Test func refusesTheSeventeenthStream() async throws {
        let live = try await prepared(); defer { live.lease.close() }
        let endpoint = BackendServersS4Sockets.listen(); defer { close(endpoint.fd) }
        try await live.lease.activate(target: .tcp(host: "127.0.0.1", port: endpoint.port))
        var fds: [Int32] = []; defer { for fd in fds { close(fd) } }
        for _ in 0..<BackendServersWindowReachRules.maximumReachStreams {
            let client = BackendServersS4Sockets.connect(live.localPort); fds.append(client)
            guard let accepted = BackendServersS4Sockets.accept(endpoint.fd, seconds: 5) else { Issue.record("Stream was not accepted"); return }
            fds.append(accepted)
        }
        let extra = BackendServersS4Sockets.connect(live.localPort); defer { close(extra) }
        #expect(BackendServersS4Sockets.read(extra) == Data())
        #expect(BackendServersS4Sockets.accept(endpoint.fd, seconds: 0.2) == nil)
    }
    // 295: closing it stops listening, unbinds, and drops what is open; idempotent
    @Test func closeUnbindsOnceAndDropsOpenStreams() async throws {
        let live = try await prepared()
        let endpoint = BackendServersS4Sockets.listen(); defer { close(endpoint.fd) }
        try await live.lease.activate(target: .tcp(host: "127.0.0.1", port: endpoint.port))
        let client = BackendServersS4Sockets.connect(live.localPort); defer { close(client) }
        guard let accepted = BackendServersS4Sockets.accept(endpoint.fd, seconds: 5) else { Issue.record("Endpoint was never dialled"); return }
        defer { close(accepted) }
        let closedEvents = BackendServersS4Box<Int>(0)
        _ = live.lease.onClose { closedEvents.mutate { $0 += 1 } }
        live.lease.close()
        _ = try await live.cancelled.value()
        #expect(live.calls.value.map(\.0) == ["forward", "cancel"])
        #expect(live.calls.value.last?.1 == "127.0.0.1:40404:127.0.0.1:\(live.localPort)")
        #expect(BackendServersS4Sockets.read(client) == Data())
        live.lease.close()
        #expect(live.calls.value.count == 2 && closedEvents.value == 1)
        // The listener is gone: a new connection to the sink never reaches the endpoint.
        let late = BackendServersS4Sockets.connect(live.localPort); defer { close(late) }
        #expect(BackendServersS4Sockets.accept(endpoint.fd, seconds: 0.2) == nil)
    }
    // activation guards (native-only, but they are the loopback-only half of the same argument)
    @Test func activationRefusesNonLoopbackAndRelativeHookPaths() async throws {
        let live = try await prepared(); defer { live.lease.close() }
        await #expect(throws: (any Error).self) { try await live.lease.activate(target: .tcp(host: "10.0.0.5", port: 80)) }
        await #expect(throws: (any Error).self) { try await live.lease.activate(target: .tcp(host: "127.0.0.1", port: 0)) }
        await #expect(throws: (any Error).self) { try await live.lease.activate(target: .unix(path: "relative.sock")) }
    }
    // control-channel refusals while preparing
    @Test func prepareRefusesWhenTheServerWillNotOpenOrNamesNoPort() async {
        await #expect(throws: BackendServersProblem.self) {
            _ = try await BackendServersSSHReverseLease.prepare(requestedPort: 0, command: { _, _ in .init(code: 1, stdout: "") })
        }
        await #expect(throws: (any Error).self) {
            _ = try await BackendServersSSHReverseLease.prepare(requestedPort: 0, command: { _, _ in .init(code: 0, stdout: "not a port") })
        }
        await #expect(throws: (any Error).self) {
            _ = try await BackendServersSSHReverseLease.prepare(requestedPort: 0, command: { _, _ in .init(code: 0, stdout: "0") })
        }
    }
}

// Window-reach case the native design replaces:
//   253 "refuses a connection for a different forward on the same connection" — the TS shared one ssh2
//   'tcp connection' listener per client and had to filter by destPort. The native lease owns a private
//   loopback sink per reach, so another forward's traffic can never arrive; the closest native proof is
//   refusesEveryConnectionBeforeActivation above (and the 16-stream / activation guards).
