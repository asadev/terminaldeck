import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Pinned recovery transport without authority or live SSH")
struct BackendDockerMCPRecoveryLeaseTests {
    @Test func invalidLifetimeNeverDials() async throws {
        let app = try fixture(); defer { app.cleanup() }
        for lifetime in [0, -1, 3901, Double.nan, Double.infinity] {
            do { _ = try await app.acquire(lifetime); Issue.record("Invalid recovery lifetime acquired a connection") }
            catch { #expect((error as? NativeRPCError)?.code == "unavailable") }
        }
        #expect(app.dialer.count == 0)
    }

    @Test func commandsUsePinnedConnectionAndRemainingDeadline() async throws {
        let app = try fixture(); defer { app.cleanup() }
        let lease = try await app.acquire(20)
        let first = try await lease.execute(command: "sealed-recovery-one", stdin: nil, timeoutMilliseconds: 60000, maximumOutputBytes: 1024)
        #expect(first.code == 0)
        app.clock.advance(1)
        _ = try await lease.execute(command: "sealed-recovery-two", stdin: Data("sealed".utf8), timeoutMilliseconds: 60000, maximumOutputBytes: 1024)
        #expect(app.dialer.count == 1)
        #expect(app.dialer.clients[0].commandTimeouts == [20000, 19000])
        await lease.close(); await lease.close()
        #expect(!(await app.pool.isOpen("recovery-server")))
        #expect(app.dialer.clients[0].closeCount == 1)
    }

    @Test func closeOnlyEndsOwnedByteChannelAndLeavesOtherLeaseAlive() async throws {
        let app = try fixture(reply: false); defer { app.cleanup() }
        let other = try await app.pool.acquireLease("recovery-server")
        let lease = try await app.acquire(20), client = app.dialer.clients[0]
        let external = try await client.dockerDialStdio()
        let request = Task { try await lease.dockerTransport().request(.init(path: "/version")) }
        defer { request.cancel() }
        try await client.waitFor(client.wrote)
        await lease.close()
        do { _ = try await request.value; Issue.record("A revoked recovery HTTP call succeeded") }
        catch { #expect(error is CancellationError || (error as? NativeRPCError)?.code == "cancelled" || (error as? NativeRPCError)?.code == "unavailable") }
        #expect(client.byteChannels.count == 2)
        #expect(client.byteChannels[0].closeCount == 0)
        #expect(client.byteChannels[1].closeCount == 1)
        #expect(client.closeCount == 0)
        #expect(await app.pool.isCurrent(other))
        external.close(); await app.pool.release(other)
    }

    @Test func closeCancelsOwnedCommandButNotAnotherCallerCommand() async throws {
        let app = try fixture(); defer { app.cleanup() }
        let other = try await app.pool.acquireLease("recovery-server")
        let lease = try await app.acquire(20), client = app.dialer.clients[0]
        let external = Task { try await client.exec(command: "other-wait", stdin: nil, timeoutMilliseconds: 60000, maximumOutputBytes: 1024) }
        let owned = Task { try await lease.execute(command: "owned-wait", stdin: nil, timeoutMilliseconds: 60000, maximumOutputBytes: 1024) }
        defer { external.cancel(); owned.cancel(); client.finishOther() }
        try await client.waitFor(client.ownedStarted); try await client.waitFor(client.otherStarted)
        await lease.close()
        do { _ = try await owned.value; Issue.record("A revoked owned command succeeded") }
        catch { #expect(error is CancellationError) }
        #expect(client.ownedCancellations == 1)
        #expect(client.otherCancellations == 0)
        #expect(client.closeCount == 0)
        #expect(await app.pool.isCurrent(other))
        client.finishOther(); #expect(try await external.value.code == 0)
        await app.pool.release(other)
    }

    @Test func cancellingOneRequestDoesNotRevokeTheRemainingRecoveryWindow() async throws {
        let app = try fixture(); defer { app.cleanup() }
        let lease = try await app.acquire(20), client = app.dialer.clients[0]
        let request = Task { try await lease.execute(command: "owned-wait", stdin: nil, timeoutMilliseconds: 60000, maximumOutputBytes: 1024) }
        defer { request.cancel() }
        try await client.waitFor(client.ownedStarted)
        request.cancel()
        do { _ = try await request.value; Issue.record("Cancelled recovery command succeeded") }
        catch { #expect(error is CancellationError) }
        try await lease.requireCurrent()
        #expect(try await lease.execute(command: "next-sealed-step", stdin: nil, timeoutMilliseconds: 1000, maximumOutputBytes: 1024).code == 0)
        #expect(client.closeCount == 0)
        #expect(app.dialer.count == 1)
        await lease.close()
    }

    @Test func expiryRefusesRequestsWithoutRedialOrSharedMasterClose() async throws {
        let app = try fixture(); defer { app.cleanup() }
        let other = try await app.pool.acquireLease("recovery-server")
        let lease = try await app.acquire(2)
        app.clock.advance(3)
        do { try await lease.requireCurrent(); Issue.record("Expired recovery lease remained current") }
        catch { #expect((error as? NativeRPCError)?.code == "unavailable") }
        do { _ = try await lease.dockerTransport().request(.init(path: "/version")); Issue.record("Expired lease sent HTTP") }
        catch { #expect((error as? NativeRPCError)?.code == "unavailable") }
        #expect(app.dialer.count == 1)
        #expect(app.dialer.clients[0].byteChannels.isEmpty)
        #expect(app.dialer.clients[0].closeCount == 0)
        #expect(await app.pool.isCurrent(other))
        await app.pool.release(other)
    }

    @Test func serverForgetInvalidatesPinnedLifetimeWithoutReconnect() async throws {
        let app = try fixture(); defer { app.cleanup() }
        let other = try await app.pool.acquireLease("recovery-server")
        let lease = try await app.acquire(20)
        await app.room.beginForgetting("recovery-server")
        do { try await lease.requireCurrent(); Issue.record("Forgotten server allowed recovery") }
        catch { #expect((error as? NativeRPCError)?.code == "unavailable") }
        #expect(app.dialer.count == 1)
        #expect(app.dialer.clients[0].closeCount == 0)
        #expect(await app.pool.isCurrent(other))
        await app.pool.release(other)
    }

    @Test func replacementGenerationCannotBeUsedByOldLeaseOrReleasedByIt() async throws {
        let app = try fixture(); defer { app.cleanup() }
        let lease = try await app.acquire(20)
        await app.pool.closeServer("recovery-server")
        let newer = try await app.pool.acquireLease("recovery-server")
        do { _ = try await lease.execute(command: "must-not-run", stdin: nil, timeoutMilliseconds: 1000, maximumOutputBytes: 1024); Issue.record("Old recovery lease used replacement server") }
        catch { #expect((error as? NativeRPCError)?.code == "unavailable") }
        await lease.close()
        #expect(app.dialer.count == 2)
        #expect(app.dialer.clients[1].commands.isEmpty)
        #expect(app.dialer.clients[1].closeCount == 0)
        #expect(await app.pool.isCurrent(newer))
        await app.pool.release(newer)
    }

    @Test func expiryDuringCaptureReleasesExactlyOneReference() async throws {
        let app = try fixture(); defer { app.cleanup() }
        let other = try await app.pool.acquireLease("recovery-server")
        let reads = BackendDockerMCPRecoveryTestClock()
        do {
            _ = try await BackendDockerMCPRecoveryLease.acquire(pool: app.pool, room: app.room,
                serverID: "recovery-server", lifetimeSeconds: 20, monotonic: { reads.nextCaptureTime() })
            Issue.record("Expired capture returned a lease")
        } catch { #expect((error as? NativeRPCError)?.code == "unavailable") }
        #expect(await app.pool.isCurrent(other))
        #expect(app.dialer.clients[0].closeCount == 0)
        await app.pool.release(other)
    }

    @Test func dockerAndCaddyRequestsUseOnlyPinnedConnectionAndPrivateHost() async throws {
        let app = try fixture(); defer { app.cleanup() }
        let other = try await app.pool.acquireLease("recovery-server")
        let lease = try await app.acquire(20)
        #expect(try await lease.dockerTransport().request(.init(path: "/version")).status == 200)
        #expect(try await lease.caddyTransport().request(.init(path: "/config/")).status == 200)
        let client = app.dialer.clients[0]
        #expect(app.dialer.count == 1)
        #expect(client.forwards == [.init(host: "127.0.0.1", port: 2019)])
        #expect(String(decoding: client.byteChannels[1].writes[0], as: UTF8.self).contains("host: 127.0.0.1:2019\r\n"))
        #expect(client.byteChannels.allSatisfy { $0.closeCount == 1 })
        await lease.close()
        #expect(client.closeCount == 0)
        #expect(await app.pool.isCurrent(other))
        await app.pool.release(other)
    }

    @Test func childReturnedAfterRevocationIsClosedBeforeAnyRequestBytes() async throws {
        let app = try fixture(delayedOpen: true); defer { app.cleanup() }
        let other = try await app.pool.acquireLease("recovery-server")
        let lease = try await app.acquire(20), client = app.dialer.clients[0]
        let request = Task { try await lease.dockerTransport().request(.init(path: "/version")) }
        defer { request.cancel(); client.finishOpen() }
        try await client.waitFor(client.openStarted)
        await lease.close()
        client.finishOpen()
        do { _ = try await request.value; Issue.record("A late child was used after recovery revocation") }
        catch { #expect((error as? NativeRPCError)?.code == "unavailable" || (error as? NativeRPCError)?.code == "cancelled") }
        #expect(client.byteChannels.count == 1)
        #expect(client.byteChannels[0].writes.isEmpty)
        #expect(client.byteChannels[0].closeCount == 1)
        #expect(client.closeCount == 0)
        #expect(await app.pool.isCurrent(other))
        await app.pool.release(other)
    }

    @Test func pinnedConnectionBorrowNeverDialsAReplacementAfterRevocation() async throws {
        let app = try fixture(); defer { app.cleanup() }
        let original = try await app.pool.acquireLease("recovery-server")
        #expect(await app.pool.isCurrent(original))
        await app.pool.closeServer("recovery-server")
        do {
            _ = try await app.pool.withConnection(original) { $0 }
            Issue.record("Revoked pin borrowed a replacement connection")
        } catch { #expect(error is CancellationError) }
        #expect(app.dialer.count == 1)
        #expect(!(await app.pool.isOpen("recovery-server")))
    }

    @Test func borrowedBodyFailureDoesNotReleaseTheHeldReference() async throws {
        let app = try fixture(); defer { app.cleanup() }
        let other = try await app.pool.acquireLease("recovery-server")
        let borrowed = try await app.pool.acquireLease("recovery-server")
        do {
            _ = try await app.pool.withConnection(borrowed) { _ -> Bool in throw CancellationError() }
            Issue.record("Borrowed body failure returned success")
        } catch { #expect(error is CancellationError) }
        await app.pool.release(borrowed)
        #expect(await app.pool.isCurrent(other))
        #expect(app.dialer.clients[0].closeCount == 0)
        await app.pool.release(other)
        #expect(!(await app.pool.isOpen("recovery-server")))
        #expect(app.dialer.clients[0].closeCount == 1)
    }

    private func fixture(reply: Bool = true, delayedOpen: Bool = false) throws -> BackendDockerMCPRecoveryTestFixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("docker-recovery-lease-" + UUID().uuidString)
        let store = BackendServersStore(dataRoot: root, policy: .init(mayRead: true, mayWrite: true), makeID: { "recovery-server" })
        _ = try store.add(.init(name: "Recovery fixture", address: "recovery.invalid", username: "fixture"))
        let cipher = BackendBrowserPasswordsCipher(available: { false }, decrypt: { _ in throw CancellationError() }, encrypt: { _, _ in throw CancellationError() })
        let credentials = BackendServersCredentials(dataRoot: root, cipher: cipher, policy: .init(mayRead: true, mayWrite: true), keyValidator: .init { _, _ in nil })
        credentials.holdForSession("recovery-server", credential: .password("synthetic-test-value"))
        let dialer = BackendDockerMCPRecoveryTestDialer(reply: reply, delayedOpen: delayedOpen)
        let pool = BackendServersConnections(store: store, credentials: credentials, dialer: dialer)
        let room = BackendServersCoordinator(store: store, connections: pool, grants: .init(assistantName: "fixture"),
            journal: BackendServersMemoryJournal(), storageDirectory: root, authorize: { _, _ in }, download: nil)
        return .init(root: root, credentials: credentials, dialer: dialer, pool: pool, room: room, clock: .init())
    }
}

private struct BackendDockerMCPRecoveryTestFixture: Sendable {
    let root: URL, credentials: BackendServersCredentials, dialer: BackendDockerMCPRecoveryTestDialer
    let pool: BackendServersConnections, room: BackendServersCoordinator, clock: BackendDockerMCPRecoveryTestClock
    func acquire(_ seconds: Double) async throws -> BackendDockerMCPRecoveryLease {
        try await BackendDockerMCPRecoveryLease.acquire(pool: pool, room: room, serverID: "recovery-server", lifetimeSeconds: seconds, monotonic: { clock.now })
    }
    func cleanup() { for client in dialer.clients { client.close() }; credentials.close(); try? FileManager.default.removeItem(at: root) }
}

private final class BackendDockerMCPRecoveryTestClock: @unchecked Sendable {
    private let lock = NSLock(); private var seconds = 100.0, captures = 0
    var now: Double { lock.withLock { seconds } }
    func advance(_ value: Double) { lock.withLock { seconds += value } }
    func nextCaptureTime() -> Double { lock.withLock { captures += 1; return captures == 1 ? 100 : 200 } }
}

private final class BackendDockerMCPRecoveryTestDialer: BackendServersSSHDialer, @unchecked Sendable {
    private let lock = NSLock(), reply: Bool, delayedOpen: Bool
    private var made: [BackendDockerMCPRecoveryTestConnection] = []
    init(reply: Bool, delayedOpen: Bool) { self.reply = reply; self.delayedOpen = delayedOpen }
    var count: Int { lock.withLock { made.count } }
    var clients: [BackendDockerMCPRecoveryTestConnection] { lock.withLock { made } }
    func dial(server: BackendServersStoredServer, credential: BackendServersCredential, verifyHostKey: @escaping @Sendable (Data) throws -> Void) async throws -> any BackendServersConnection {
        try verifyHostKey(BackendServersConnectionTestDialer.key)
        let client = BackendDockerMCPRecoveryTestConnection(reply: reply, delayedOpen: delayedOpen)
        lock.withLock { made.append(client) }; return client
    }
}

private final class BackendDockerMCPRecoveryTestConnection: BackendServersConnection, @unchecked Sendable {
    struct Forward: Equatable, Sendable { let host: String; let port: Int }
    private let lock = NSLock(), closing = BackendServersSSHEvents<Bool>(replayLatest: true), reply: Bool, delayedOpen: Bool
    private var stopped = false, children: [BackendDockerMCPRecoveryTestDuplex] = [], runs: [String] = [], timeouts: [Int] = [], forwarded: [Forward] = []
    private var ownCancelled = 0, otherCancelled = 0
    let wrote = BackendServersSSHOnce<Void>(), ownedStarted = BackendServersSSHOnce<Void>(), otherStarted = BackendServersSSHOnce<Void>()
    let openStarted = BackendServersSSHOnce<Void>()
    private let openResult = BackendServersSSHOnce<Void>()
    private let ownedResult = BackendServersSSHOnce<BackendServersRunResult>(), otherResult = BackendServersSSHOnce<BackendServersRunResult>()
    init(reply: Bool, delayedOpen: Bool) { self.reply = reply; self.delayedOpen = delayedOpen }
    var closeCount: Int { lock.withLock { stopped ? 1 : 0 } }
    var byteChannels: [BackendDockerMCPRecoveryTestDuplex] { lock.withLock { children } }
    var commands: [String] { lock.withLock { runs } }
    var commandTimeouts: [Int] { lock.withLock { timeouts } }
    var forwards: [Forward] { lock.withLock { forwarded } }
    var ownedCancellations: Int { lock.withLock { ownCancelled } }
    var otherCancellations: Int { lock.withLock { otherCancelled } }
    func exec(command: String, stdin: Data?, timeoutMilliseconds: Int, maximumOutputBytes: Int) async throws -> BackendServersRunResult {
        lock.withLock { runs.append(command); timeouts.append(timeoutMilliseconds) }
        if command == "owned-wait" {
            ownedStarted.finish(.success(()))
            return try await withTaskCancellationHandler { try await ownedResult.value() } onCancel: {
                self.lock.withLock { self.ownCancelled += 1 }; self.ownedResult.finish(.failure(CancellationError()))
            }
        }
        if command == "other-wait" {
            otherStarted.finish(.success(()))
            return try await withTaskCancellationHandler { try await otherResult.value() } onCancel: {
                self.lock.withLock { self.otherCancelled += 1 }; self.otherResult.finish(.failure(CancellationError()))
            }
        }
        return .init(code: 0, stdout: "synthetic recovery output")
    }
    func finishOther() { otherResult.finish(.success(.init(code: 0, stdout: "other caller finished"))) }
    func finishOpen() { openResult.finish(.success(())) }
    func waitFor(_ gate: BackendServersSSHOnce<Void>) async throws {
        let timer = Task { do { try await Task.sleep(for: .seconds(5)) } catch { return }; gate.finish(.failure(NativeRPCError(code: "test-timeout", message: "Recovery fixture did not reach its expected boundary."))) }
        defer { timer.cancel() }; try await gate.value()
    }
    private func child() -> BackendDockerMCPRecoveryTestDuplex {
        let channel = BackendDockerMCPRecoveryTestDuplex(reply: reply, wrote: wrote)
        lock.withLock { children.append(channel) }; return channel
    }
    func dockerDialStdio() async throws -> any BackendServersDuplex {
        if delayedOpen { openStarted.finish(.success(())); try await openResult.value() }
        return child()
    }
    func forward(host: String, port: Int) async throws -> any BackendServersDuplex { lock.withLock { forwarded.append(.init(host: host, port: port)) }; return child() }
    func follow(command: String) async throws -> any BackendServersFollow { throw unavailable() }
    func shell(size: BackendServersTerminalSize) async throws -> any BackendServersShell { throw unavailable() }
    func openSFTP() async throws -> any BackendServersSFTP { throw unavailable() }
    func reverseForward(bindAddress: String, bindPort: Int) async throws -> any BackendServersReverseForward { throw unavailable() }
    func onClose(_ listener: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe { closing.listen { _ in listener() } }
    func close() {
        let first = lock.withLock { if stopped { return false }; stopped = true; return true }
        if first { finishOpen(); for child in byteChannels { child.close() }; ownedResult.finish(.failure(CancellationError())); otherResult.finish(.failure(CancellationError())); closing.send(true) }
    }
    private func unavailable() -> NativeRPCError { .init(code: "unavailable", message: "Recovery fixture has no unrelated operation.") }
}

private final class BackendDockerMCPRecoveryTestDuplex: BackendServersDuplex, @unchecked Sendable {
    private let lock = NSLock(), output = BackendServersSSHEvents<Data>(), closing = BackendServersSSHEvents<Bool>(replayLatest: true), ending = BackendServersSSHEvents<Bool>(replayLatest: true)
    private let reply: Bool, wrote: BackendServersSSHOnce<Void>
    private var stopped = false, sent = false, stored: [Data] = []
    init(reply: Bool, wrote: BackendServersSSHOnce<Void>) { self.reply = reply; self.wrote = wrote }
    var closeCount: Int { lock.withLock { stopped ? 1 : 0 } }
    var writes: [Data] { lock.withLock { stored } }
    func onBytes(_ listener: @escaping @Sendable (Data) -> Void) -> BackendServersUnsubscribe { output.listen(listener) }
    func onEnd(_ listener: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe { ending.listen { _ in listener() } }
    func onClose(_ listener: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe { closing.listen { _ in listener() } }
    func write(_ bytes: Data) async throws {
        let first = lock.withLock { stored.append(bytes); if sent { return false }; sent = true; return true }
        wrote.finish(.success(()))
        if first && reply { output.send(Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}".utf8)) }
    }
    func end() async throws { ending.send(true) }
    func pause() {}
    func resume() {}
    func close() { let first = lock.withLock { if stopped { return false }; stopped = true; return true }; if first { closing.send(true) } }
}
