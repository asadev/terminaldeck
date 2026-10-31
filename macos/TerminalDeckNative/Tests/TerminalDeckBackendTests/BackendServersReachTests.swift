import Foundation
@preconcurrency import Network
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

@Suite("Server page reach, same-port ladder and draining")
struct BackendServersReachTests {
    @Test func portRowsCollapseFamiliesKeepUnknownAndExcludeNonpagesByName() {
        let listeners: [BackendServersListenerFact] = [.init(address: "0.0.0.0", port: 8000), .init(address: "[::]", port: 8000, program: "nginx"), .init(address: "127.0.0.1", port: 6001), .init(address: "*", port: 22, program: "sshd"), .init(address: "*", port: 53, program: "systemd-resolve"), .init(address: "*", port: 3306, program: "node")]
        let ports = BackendServersReach.portsFrom(listeners)
        #expect(ports.map(\.port) == [3306, 8000, 6001])
        #expect(ports.first { $0.port == 8000 }?.process == "nginx")
        #expect(ports.last?.guessed == true && ports.allSatisfy { !$0.ours })
    }
    @Test func portsRefusalThirdStateUnknownServerAndConnectionRelease() async throws {
        let app = try application(body: Data("test".utf8)); defer { app.cleanup() }
        let listed = await app.reach.ports("one")
        #expect(listed["ok"].bool == true && listed["ports"].elements?.count == 1 && listed["cannot"] == .null)
        #expect(!(await app.pool.isOpen("one")))
        #expect(await app.reach.ports("unknown")["message"].string == "This app does not know that server.")
        app.client.setRefusal(.prohibited)
        #expect(await app.reach.ports("one")["message"].string == BackendServersForward.willNotForward)
        await app.reach.stop()
    }
    @Test(.disabled("Superseded by TransportPortReachTests fake bindings and byte-stream tests; tests-port forbids runtime socket execution.")) func nativeListenerCarries288KiBAndReusesOneServerHoldForTwoTabs() async throws {
        let body = Data(repeating: UInt8(ascii: "q"), count: 288 * 1024), app = try application(body: body)
        defer { app.cleanup() }
        let port = try await freePort()
        async let first = app.reach.reach("one", port: port)
        async let second = app.reach.reach("one", port: port)
        let answers = await (first, second)
        #expect(answers.0 == answers.1 && answers.0["ok"].bool == true)
        #expect(answers.0["port"].number == Double(port) && answers.0["localPort"].number == Double(port) && answers.0["sameNumber"].bool == true)
        let url = try #require(answers.0["url"].string.flatMap(URL.init(string:)))
        let (bytes, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200 && bytes == body)
        #expect(await app.pool.isOpen("one")); #expect(app.client.dials == 1)
        #expect(await app.reach.openPorts("one") == [port])
        #expect(await app.reach.closeReach("one", port: port)); #expect(await app.reach.openPorts("one").isEmpty)
        #expect(await app.reach.closeReach("one", port: port)); await app.reach.stop()
        #expect(!(await app.pool.isOpen("one")))
    }
    @Test func refusedForwardLeavesNoListenerAndDifferentFailureForAnEmptyService() async throws {
        let app = try application(body: Data()); defer { app.cleanup() }
        let port = 49152; app.client.setRefusal(.prohibited)
        #expect(await app.reach.reach("one", port: port)["message"].string == BackendServersForward.willNotForward)
        #expect(await app.reach.openPorts("one").isEmpty)
        app.client.setRefusal(.unreachable)
        #expect(await app.reach.reach("one", port: port)["message"].string == "Nothing is answering on port \(port) on box.")
        #expect(await app.reach.closeReach("never-held", port: port)); await app.reach.stop()
    }
    private func application(body: Data) throws -> BackendServersReachTestApp {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("servers-reach-" + UUID().uuidString)
        let store = BackendServersStore(dataRoot: root, policy: .init(mayRead: true, mayWrite: true), makeID: { "one" })
        _ = try store.add(.init(name: "box", address: "fixture.example", username: "fixture"))
        let cipher = BackendBrowserPasswordsCipher(available: { false }, decrypt: { _ in throw CancellationError() }, encrypt: { _, _ in throw CancellationError() })
        let credentials = BackendServersCredentials(dataRoot: root, cipher: cipher, policy: .init(mayRead: true, mayWrite: true), keyValidator: .init { _, _ in nil })
        credentials.holdForSession("one", credential: .password("synthetic-fixture"))
        let client = BackendServersReachTestClient(body: body), pool = BackendServersConnections(store: store, credentials: credentials, dialer: client)
        let reach = BackendServersReach(connections: pool, ownPorts: .init(), servers: { try store.list() }, facts: { id in var facts = BackendServersFacts(serverId: id, measuredAt: 1); facts.listeners = .yes([.init(address: "127.0.0.1", port: 8000, program: "nginx")], measuredAt: 1, how: "fixture"); return facts }, tunnelsDropped: { _ in })
        return .init(root: root, client: client, pool: pool, reach: reach)
    }
    private func freePort() async throws -> Int {
        let parameters = NWParameters.tcp; parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters), ready = BackendServersSSHOnce<Int>()
        listener.newConnectionHandler = { $0.cancel() }; listener.stateUpdateHandler = { state in switch state { case .ready: if let port = listener.port { ready.finish(.success(Int(port.rawValue))) }; case .failed(let error): ready.finish(.failure(error)); default: break } }
        listener.start(queue: DispatchQueue(label: "servers.test.free-port")); defer { listener.cancel() }; return try await ready.value()
    }
}
struct BackendServersReachTestApp: Sendable { let root: URL, client: BackendServersReachTestClient, pool: BackendServersConnections, reach: BackendServersReach; func cleanup() { client.close(); try? FileManager.default.removeItem(at: root) } }
final class BackendServersReachTestClient: BackendServersSSHDialer, BackendServersConnection, @unchecked Sendable {
    private let body: Data, lock = NSLock(); private var refusal: BackendServersForwardRefusal?, count = 0
    init(body: Data) { self.body = body }
    var dials: Int { lock.withLock { count } }; func setRefusal(_ value: BackendServersForwardRefusal?) { lock.withLock { refusal = value } }
    func dial(server: BackendServersStoredServer, credential: BackendServersCredential, verifyHostKey: @escaping @Sendable (Data) throws -> Void) async throws -> any BackendServersConnection { try verifyHostKey(BackendServersConnectionTestDialer.key); lock.withLock { count += 1 }; return self }
    func exec(command: String, stdin: Data?, timeoutMilliseconds: Int, maximumOutputBytes: Int) async throws -> BackendServersRunResult { .init(code: 0, stdout: "") }
    func follow(command: String) async throws -> any BackendServersFollow { throw CancellationError() }
    func shell(size: BackendServersTerminalSize) async throws -> any BackendServersShell { throw CancellationError() }
    func openSFTP() async throws -> any BackendServersSFTP { throw CancellationError() }
    func forward(host: String, port: Int) async throws -> any BackendServersDuplex {
        if let refusal = lock.withLock({ refusal }) { throw BackendServersForwardError(refusal: refusal, message: "synthetic refusal") }
        if port == 1 { throw BackendServersForwardError(refusal: .unreachable, message: "connect failed") }
        return BackendServersReachTestHTTP(body: body)
    }
    func reverseForward(bindAddress: String, bindPort: Int) async throws -> any BackendServersReverseForward { throw CancellationError() }
    func onClose(_ listener: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe { {} }
    func close() {}
}
final class BackendServersReachTestHTTP: BackendServersDuplex, @unchecked Sendable {
    private let body: Data, bytes = BackendServersSSHEvents<Data>(), ends = BackendServersSSHEvents<Bool>(), closes = BackendServersSSHEvents<Bool>(), lock = NSLock()
    private var request = Data(), responded = false, stopped = false
    init(body: Data) { self.body = body }
    func onBytes(_ listener: @escaping @Sendable (Data) -> Void) -> BackendServersUnsubscribe { bytes.listen(listener) }
    func onEnd(_ listener: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe { ends.listen { _ in listener() } }
    func onClose(_ listener: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe { closes.listen { _ in listener() } }
    func write(_ part: Data) async throws {
        let answer = lock.withLock { () -> Bool in request.append(part); if responded || !String(decoding: request, as: UTF8.self).contains("\r\n\r\n") { return false }; responded = true; return true }
        guard answer else { return }
        bytes.send(Data("HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8))
        var at = 0; while at < body.count { let end = min(body.count, at + 8192); bytes.send(Data(body[at..<end])); at = end }
        ends.send(true); closes.send(true)
    }
    func end() async throws {}
    func close() { lock.withLock { stopped = true } }
    func pause() {}; func resume() {}
}
