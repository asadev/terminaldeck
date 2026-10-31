import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Server-control transport wiring without SSH or live sockets")
struct BackendDockerMCPTransportWiringTests {
    @Test func lateDockerChannelClosesWhenCancelledWithoutDroppingAnotherLease() async throws {
        let app = try fixture(delayed: true); defer { app.cleanup() }
        let other = try await app.pool.acquireLease("fixture-server")
        let operation = Task { try await app.pool.dockerDialStdio("fixture-server") }
        defer { operation.cancel(); app.client.open.finish(.success(())) }
        try await app.client.waitUntilEntered()
        operation.cancel(); app.client.open.finish(.success(()))
        do {
            let channel = try await operation.value; channel.close()
            Issue.record("The cancelled Docker opener returned a channel")
        } catch { #expect(error is CancellationError) }
        #expect(app.client.channel.closeCount == 1)
        #expect(await app.pool.isOpen("fixture-server"))
        #expect(app.client.closeCount == 0)
        await app.pool.release(other)
        #expect(!(await app.pool.isOpen("fixture-server")))
        #expect(app.client.closeCount == 1)
    }

    @Test func lateCaddyChannelClosesAndPreservesCancellation() async throws {
        let app = try fixture(delayed: true); defer { app.cleanup() }
        let other = try await app.pool.acquireLease("fixture-server")
        let operation = Task { try await app.pool.caddyAdmin("fixture-server") }
        defer { operation.cancel(); app.client.open.finish(.success(())) }
        try await app.client.waitUntilEntered()
        operation.cancel(); app.client.open.finish(.success(()))
        do {
            let channel = try await operation.value; channel.close()
            Issue.record("The cancelled Caddy opener returned a channel")
        } catch { #expect(error is CancellationError) }
        #expect(app.client.channel.closeCount == 1)
        #expect(await app.pool.isOpen("fixture-server"))
        #expect(app.client.closeCount == 0)
        #expect(app.client.forwards == [.init(host: "127.0.0.1", port: 2019)])
        await app.pool.release(other)
    }

    @Test func caddyUsesExistingPrivateForwardAndReleasesOnClose() async throws {
        let app = try fixture(delayed: false); defer { app.cleanup() }
        let channel = try await app.pool.caddyAdmin("fixture-server")
        #expect(await app.pool.isOpen("fixture-server"))
        #expect(app.dialer.count == 1)
        #expect(app.client.forwards == [.init(host: "127.0.0.1", port: 2019)])
        try await channel.write(Data("HTTP request".utf8))
        #expect(app.client.channel.writes == [Data("HTTP request".utf8)])
        channel.close(); channel.close()
        #expect(await app.waitForRelease())
        #expect(!(await app.pool.isOpen("fixture-server")))
        #expect(app.client.closeCount == 1)
        #expect(app.client.channel.closeCount == 1)
    }

    @Test func dockerUsesExistingConnectionAndReleasesWhenPeerCloses() async throws {
        let app = try fixture(delayed: false); defer { app.cleanup() }
        let channel = try await app.pool.dockerDialStdio("fixture-server")
        #expect(await app.pool.isOpen("fixture-server"))
        #expect(app.client.dockerOpens == 1)
        #expect(app.client.forwards.isEmpty)
        #expect(app.dialer.count == 1)
        app.client.channel.close()
        #expect(await app.waitForRelease())
        #expect(!(await app.pool.isOpen("fixture-server")))
        channel.close()
        #expect(app.client.closeCount == 1)
        #expect(app.client.channel.closeCount == 1)
    }

    @Test func unsupportedConnectionNeverFallsBackToExecOrAnotherTransport() async throws {
        // The existing test connection implements exec, but deliberately does
        // not supply Docker byte transport. The default must refuse it.
        let client = BackendServersConnectionTestClient()
        do { _ = try await client.dockerDialStdio(); Issue.record("Unsupported byte transport succeeded") }
        catch let error as NativeRPCError { #expect(error.code == "unavailable") }
        #expect(client.commands.isEmpty)
    }

    @Test func failedChannelOpenReleasesLeaseAndWithholdsDependencyText() async throws {
        let app = try fixture(delayed: false, failOpen: true); defer { app.cleanup() }
        do { _ = try await app.pool.dockerDialStdio("fixture-server"); Issue.record("A failed opener succeeded") }
        catch let error as NativeRPCError {
            #expect(error.code == "unavailable")
            #expect(!error.message.contains("fixture-secret"))
            #expect(error.details == .missing)
        }
        #expect(!(await app.pool.isOpen("fixture-server")))
        #expect(app.client.closeCount == 1)
    }

    private func fixture(delayed: Bool, failOpen: Bool = false) throws -> BackendDockerMCPWiringFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("docker-mcp-wiring-" + UUID().uuidString)
        let store = BackendServersStore(dataRoot: root, policy: .init(mayRead: true, mayWrite: true), makeID: { "fixture-server" })
        _ = try store.add(.init(name: "Fixture", address: "fixture.invalid", username: "fixture"))
        let cipher = BackendBrowserPasswordsCipher(available: { false }, decrypt: { _ in throw CancellationError() }, encrypt: { _, _ in throw CancellationError() })
        let credentials = BackendServersCredentials(dataRoot: root, cipher: cipher, policy: .init(mayRead: true, mayWrite: true), keyValidator: .init { _, _ in nil })
        credentials.holdForSession("fixture-server", credential: .password("synthetic-test-value"))
        let client = BackendDockerMCPWiringConnection(delayed: delayed, failOpen: failOpen)
        let dialer = BackendDockerMCPWiringDialer(client: client)
        let released = BackendServersSSHOnce<Bool>()
        let pool = BackendServersConnections(store: store, credentials: credentials, dialer: dialer,
                                              lifecycle: { _, action in if action == "released" { released.finish(.success(true)) } })
        return .init(root: root, credentials: credentials, client: client, dialer: dialer, pool: pool, released: released)
    }
}

private struct BackendDockerMCPWiringFixture: Sendable {
    let root: URL
    let credentials: BackendServersCredentials
    let client: BackendDockerMCPWiringConnection
    let dialer: BackendDockerMCPWiringDialer
    let pool: BackendServersConnections
    let released: BackendServersSSHOnce<Bool>
    func cleanup() { client.close(); credentials.close(); try? FileManager.default.removeItem(at: root) }
    func waitForRelease() async -> Bool {
        let timer = Task { do { try await Task.sleep(for: .seconds(2)) } catch { return }; released.finish(.success(false)) }
        defer { timer.cancel() }
        return (try? await released.value()) ?? false
    }
}

private final class BackendDockerMCPWiringDialer: BackendServersSSHDialer, @unchecked Sendable {
    private let client: BackendDockerMCPWiringConnection
    private let lock = NSLock()
    private var calls = 0
    init(client: BackendDockerMCPWiringConnection) { self.client = client }
    var count: Int { lock.withLock { calls } }
    func dial(server: BackendServersStoredServer, credential: BackendServersCredential,
              verifyHostKey: @escaping @Sendable (Data) throws -> Void) async throws -> any BackendServersConnection {
        lock.withLock { calls += 1 }
        try verifyHostKey(BackendServersConnectionTestDialer.key)
        return client
    }
}

private final class BackendDockerMCPWiringConnection: BackendServersConnection, @unchecked Sendable {
    struct Forward: Equatable, Sendable { let host: String; let port: Int }
    let channel = BackendDockerMCPWiringDuplex()
    let entered = BackendServersSSHOnce<Void>(), open = BackendServersSSHOnce<Void>()
    private let lock = NSLock(), closing = BackendServersSSHEvents<Bool>()
    private let failOpen: Bool
    private var stopped = false, opens = 0, forwarded: [Forward] = []
    init(delayed: Bool, failOpen: Bool) { self.failOpen = failOpen; if !delayed { open.finish(.success(())) } }
    var closeCount: Int { lock.withLock { stopped ? 1 : 0 } }
    var dockerOpens: Int { lock.withLock { opens } }
    var forwards: [Forward] { lock.withLock { forwarded } }
    func waitUntilEntered() async throws {
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            entered.finish(.failure(NativeRPCError(code: "test-timeout", message: "The fake server opener did not start within its test deadline.")))
        }
        defer { deadline.cancel() }
        try await entered.value()
    }
    private func makeChannel() async throws -> any BackendServersDuplex {
        entered.finish(.success(()))
        // Intentionally ignores cancellation to model a transport handing back
        // a late channel. The pool's ownership boundary must close it.
        try await open.value()
        if failOpen { throw NativeRPCError(code: "private-ssh-error", message: "fixture-secret dependency text", details: .string("fixture-secret")) }
        return channel
    }
    func dockerDialStdio() async throws -> any BackendServersDuplex { lock.withLock { opens += 1 }; return try await makeChannel() }
    func forward(host: String, port: Int) async throws -> any BackendServersDuplex { lock.withLock { forwarded.append(.init(host: host, port: port)) }; return try await makeChannel() }
    func exec(command: String, stdin: Data?, timeoutMilliseconds: Int, maximumOutputBytes: Int) async throws -> BackendServersRunResult { throw unavailable() }
    func follow(command: String) async throws -> any BackendServersFollow { throw unavailable() }
    func shell(size: BackendServersTerminalSize) async throws -> any BackendServersShell { throw unavailable() }
    func openSFTP() async throws -> any BackendServersSFTP { throw unavailable() }
    func reverseForward(bindAddress: String, bindPort: Int) async throws -> any BackendServersReverseForward { throw unavailable() }
    func onClose(_ listener: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe { closing.listen { _ in listener() } }
    func close() { let first = lock.withLock { if stopped { return false }; stopped = true; return true }; if first { channel.close(); closing.send(true) } }
    private func unavailable() -> NativeRPCError { .init(code: "unavailable", message: "This fixture has no unrelated transport operation.") }
}

private final class BackendDockerMCPWiringDuplex: BackendServersDuplex, @unchecked Sendable {
    private let lock = NSLock(), closing = BackendServersSSHEvents<Bool>(replayLatest: true), ending = BackendServersSSHEvents<Bool>(replayLatest: true)
    private var stopped = false, output: [Data] = []
    var closeCount: Int { lock.withLock { stopped ? 1 : 0 } }
    var writes: [Data] { lock.withLock { output } }
    func onBytes(_ listener: @escaping @Sendable (Data) -> Void) -> BackendServersUnsubscribe { {} }
    func onEnd(_ listener: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe { ending.listen { _ in listener() } }
    func onClose(_ listener: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe { closing.listen { _ in listener() } }
    func write(_ bytes: Data) async throws { lock.withLock { output.append(bytes) } }
    func end() async throws { ending.send(true) }
    func pause() {}
    func resume() {}
    func close() { let first = lock.withLock { if stopped { return false }; stopped = true; return true }; if first { closing.send(true) } }
}
