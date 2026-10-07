import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendRemoteServeHostPortTests: XCTestCase {
    func testSSHPasswordAndKeyConfigurations() async throws {
        for method in ["password", "key"] {
            let peer = SSHPeer(.ready), clock = Clock()
            let answer = try await BackendRemoteServeSSHVerifier(transport: peer, sleep: { try await clock.wait($0) })
                .verify(username: "asad", secret: "fixture-secret", method: method, port: 2222)
            XCTAssertNil(answer)
            let config = await peer.config
            XCTAssertEqual(config?.username, "asad"); XCTAssertEqual(config?.port, 2222)
            XCTAssertEqual(config?.method, method); XCTAssertEqual(config?.keyboard, method == "password")
            XCTAssertEqual(config?.secret, "fixture-secret")
            // The transport contract has no shell/exec/forward methods, and
            // the verifier has no target-host option beyond fixed loopback.
            let count = await peer.calls; XCTAssertEqual(count, 1)
        }
    }
    func testSSHFailureClassificationEverySourceSignal() async throws {
        let fixtures: [(BackendRemoteServeSSHSignal, BackendRemoteServeSSHFailure)] = [
            (.init(level: "client-authentication"), .auth),
            (.init(message: "All configured authentication methods failed"), .auth),
            (.init(code: "ECONNREFUSED", message: "socket failed"), .noSSHD),
            (.init(level: "protocol", message: "Connection lost before handshake"), .noSSHD),
            (.init(level: "client-timeout"), .timeout),
            (.init(code: "ETIMEDOUT"), .timeout),
            (.init(message: "Cannot parse privateKey: Unsupported key format"), .badKey),
            (.init(message: "Encrypted private OpenSSH key detected, but no passphrase given"), .badKey)]
        for (signal, expected) in fixtures {
            let peer = SSHPeer(.signal(signal)), clock = Clock()
            let result = try await BackendRemoteServeSSHVerifier(transport: peer, sleep: { try await clock.wait($0) })
                .verify(username: "asad", secret: "fixture-secret", method: "password", port: 22)
            XCTAssertEqual(result, expected)
        }
        for (method, expected) in [("key", BackendRemoteServeSSHFailure.badKey), ("password", .noSSHD)] {
            let clock = Clock()
            let result = try await BackendRemoteServeSSHVerifier(transport: SSHPeer(.throwsBefore), sleep: { try await clock.wait($0) })
                .verify(username: "asad", secret: "fixture-secret", method: method, port: 22)
            XCTAssertEqual(result, expected)
        }
    }
    func testSilentSSHUsesFakeDeadlineAndIgnoresLateError() async throws {
        let peer = SSHPeer(.silent), clock = Clock()
        let verifier = BackendRemoteServeSSHVerifier(transport: peer, sleep: { try await clock.wait($0) })
        let pending = Task { try await verifier.verify(username: "asad", secret: "fixture-secret", method: "password", port: 22, timeoutMilliseconds: 10) }
        await clock.armed(); await clock.advance(9)
        let remaining = await clock.count; XCTAssertEqual(remaining, 1)
        await clock.advance(1)
        let result = try await pending.value; XCTAssertEqual(result, .timeout)
        await peer.cancelled(); await peer.lateError()
        let stable = try await pending.value; XCTAssertEqual(stable, .timeout)
    }
    func testEnrollmentDistinctSentencesAndPortPrecedence() {
        let sentences = [BackendRemoteServeEnrollment.refused, BackendRemoteServeEnrollment.badKey, BackendRemoteServeEnrollment.slow,
            BackendRemoteServeEnrollment.busy, BackendRemoteServeEnrollment.noRoom, BackendRemoteServeEnrollment.notSaved,
            BackendRemoteServeEnrollment.noSSHD(22), BackendRemoteServeEnrollment.noSSHD(2222)]
        XCTAssertEqual(Set(sentences).count, sentences.count)
        for sentence in sentences {
            XCTAssertNotEqual(sentence, "Sign-in is not switched on for this machine. Pair it with a code instead.")
            XCTAssertNil(sentence.range(of: "asad|hunter2|password:", options: [.regularExpression, .caseInsensitive]))
        }
        XCTAssertTrue(BackendRemoteServeEnrollment.noSSHD(2222).contains("127.0.0.1 port 2222"))
        XCTAssertTrue(BackendRemoteServeEnrollment.noSSHD(2222).contains("TERMINALDECK_SSHD_PORT"))
        let examples: [([String: String], Int)] = [([:],22),(["TERMINALDECK_SSHD_PORT":"2200"],2200),
            (["SSH_CONNECTION":"100.64.0.9 51875 100.86.107.119 2222"],2222),
            (["TERMINALDECK_SSHD_PORT":"2200","SSH_CONNECTION":"a b c 2222"],2200),(["SSH_CONNECTION":"not-a-connection-string"],22)]
        for (env, port) in examples { XCTAssertEqual(BackendRemoteServeEnrollment.port(environment: env), port) }
    }
    func testEnrollmentRefusalsCountOnlyAuthenticationAndNeverEchoSecret() async throws {
        for (signal, code, message, counts) in [
            (BackendRemoteServeSSHSignal(level: "client-authentication"), "unauthorized", BackendRemoteServeEnrollment.refused, true),
            (.init(message: "Cannot parse privateKey"), "unauthorized", BackendRemoteServeEnrollment.badKey, false),
            (.init(level: "client-timeout"), "unavailable", BackendRemoteServeEnrollment.slow, false),
            (.init(code: "ECONNREFUSED"), "unavailable", BackendRemoteServeEnrollment.noSSHD(2222), false)] {
            let dir = temporary(), trust = BackendRemoteTrustStore(directory: dir, clock: { 1_760_000_000_000 })
            defer { try? FileManager.default.removeItem(at: dir) }
            let peer = SSHPeer(.signal(signal)), clock = Clock()
            let access = BackendRemoteServeEnrollment(trust: trust,
                verifier: .init(transport: peer, sleep: { try await clock.wait($0) }), environment: ["TERMINALDECK_SSHD_PORT":"2222"])
            for _ in 0..<5 {
                do { _ = try await Self.signIn(access); XCTFail("Expected refusal") }
                catch let error as NativeRPCError { XCTAssertEqual(error.code, code); XCTAssertEqual(error.message, message); XCTAssertFalse(error.message.contains("fixture-secret")) }
            }
            let allowed = await trust.enrollmentAllowed(address: "100.86.107.119")
            XCTAssertEqual(allowed, !counts)
            let before = await peer.calls
            do { _ = try await Self.signIn(access); XCTFail("Expected refusal") } catch {}
            let after = await peer.calls; XCTAssertEqual(after, before + (counts ? 0 : 1))
        }
    }
    func testEnrollmentTwoProbeGateWithFakeConnections() async throws {
        let dir = temporary(), trust = BackendRemoteTrustStore(directory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let peer = SSHPeer(.silent), clock = Clock()
        let access = BackendRemoteServeEnrollment(trust: trust, verifier: .init(transport: peer, sleep: { try await clock.wait($0) }), environment: [:])
        let first = Task { try await Self.signIn(access) }, second = Task { try await Self.signIn(access) }
        await peer.connected(2)
        do { _ = try await Self.signIn(access); XCTFail("Third probe must be refused") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "unavailable"); XCTAssertEqual(error.message, BackendRemoteServeEnrollment.busy) }
        await peer.failAll(.init(level: "client-authentication"))
        do { _ = try await first.value } catch {}; do { _ = try await second.value } catch {}
        let count = await peer.calls; XCTAssertEqual(count, 2)
    }
    func testHostLifecycleExactFactProjectionAndNote() {
        let facts = NativeRPCValue.object([.init("version", .string("0.14.0")), .init("address", .string("terminaldeck://slot.relay")),
            .init("pid", .number(4242)), .init("startedAt", .number(1_900_000_000_000)), .init("uptimeSeconds", .number(3600)), .init("managed", .string("systemd"))])
        let expected = NativeRPCValue.object([.init("running", .bool(true))] + facts.fields! + [.init("note", .null)])
        XCTAssertEqual(BackendRemoteServeLifecycle.wire(facts, note: nil), expected)
        let note = BackendRemoteServeLifecycle.wire(facts, note: "Restarting over the relay.")
        XCTAssertEqual(note["note"].string, "Restarting over the relay."); XCTAssertEqual(note["running"], .bool(true))
    }
    func testEnrollmentMintKeyKindAndNewIdentityAfterRevoke() async throws {
        let dir = temporary(); defer { try? FileManager.default.removeItem(at: dir) }
        let trust = BackendRemoteTrustStore(directory: dir, clock: { 1_760_000_000_000 })
        try await trust.open()
        let peer = SSHPeer(.ready), clock = Clock()
        let access = BackendRemoteServeEnrollment(trust: trust, verifier: .init(transport: peer, sleep: { try await clock.wait($0) }), environment: [:])
        let key = Data(repeating: 7, count: 32)
        let first = try await Self.signIn(access)
        XCTAssertTrue(first.device.approved)
        let kind = await trust.kindOf(first.device.id); XCTAssertEqual(kind, .mine)
        let bound = await trust.deviceHoldsKey(first.device.id, key: key), other = await trust.deviceHoldsKey(first.device.id, key: Data(repeating: 8, count: 32))
        XCTAssertTrue(bound); XCTAssertFalse(other)
        let removed = try await trust.revoke(first.device.id); XCTAssertTrue(removed)
        let second = try await Self.signIn(access); XCTAssertNotEqual(first.device.id, second.device.id)
        XCTAssertFalse(first.credential.contains("fixture-secret")); XCTAssertFalse(second.credential.contains("fixture-secret"))
        for file in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            let contents = try Data(contentsOf: file); XCTAssertFalse(String(decoding: contents, as: UTF8.self).contains("fixture-secret"))
        }
        await trust.close()
    }
    private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("BackendRemoteServeHostPort-" + UUID().uuidString) }
    private static func signIn(_ access: BackendRemoteServeEnrollment) async throws -> BackendRemoteCredential {
        try await access.signIn(username: "asad", secret: "fixture-secret", method: "password", deviceName: "Asad’s iPhone", address: "100.86.107.119", peerPublicKey: Data(repeating: 7, count: 32))
    }
    private enum Failure: Error { case configuration }
    private actor Clock {
        struct Wait { let at: Int; let continuation: CheckedContinuation<Void, Error> }
        var now = 0, waits: [UUID: Wait] = [:], armedWaiters: [CheckedContinuation<Void, Never>] = []
        var count: Int { waits.count }
        func wait(_ milliseconds: Int) async throws {
            let id = UUID()
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { continuation in
                    waits[id] = Wait(at: now + milliseconds, continuation: continuation)
                    let listeners = armedWaiters; armedWaiters = []; for listener in listeners { listener.resume() }
                }
            } onCancel: { Task { await self.cancel(id) } }
        }
        func armed() async { if !waits.isEmpty { return }; await withCheckedContinuation { armedWaiters.append($0) } }
        func advance(_ milliseconds: Int) {
            now += milliseconds
            for id in waits.filter({ $0.value.at <= now }).map(\.key) { waits.removeValue(forKey: id)?.continuation.resume() }
        }
        private func cancel(_ id: UUID) { waits.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError()) }
    }
    private actor SSHPeer: BackendRemoteServeSSHTransport {
        enum Mode: Sendable { case ready, signal(BackendRemoteServeSSHSignal), throwsBefore, silent }
        struct Config: Sendable { let username: String; let secret: String; let method: String; let port: Int; let keyboard: Bool }
        let mode: Mode
        var config: Config?, calls = 0, wasCancelled = false
        var pending: [CheckedContinuation<Void, Error>] = []
        var connectionWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
        var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
        init(_ mode: Mode) { self.mode = mode }
        func authenticateLoopback(port: Int, username: String, secret: String, method: String, keyboardInteractive: Bool, timeoutMilliseconds: Int) async throws {
            calls += 1; config = .init(username: username, secret: secret, method: method, port: port, keyboard: keyboardInteractive)
            switch mode {
            case .ready: return
            case .signal(let signal): throw signal
            case .throwsBefore: throw Failure.configuration
            case .silent:
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { continuation in
                        pending.append(continuation)
                        let ready = connectionWaiters.filter { calls >= $0.0 }; connectionWaiters.removeAll { calls >= $0.0 }
                        for listener in ready { listener.1.resume() }
                    }
                } onCancel: { Task { await self.noteCancelled() } }
            }
        }
        func connected(_ count: Int) async { if calls >= count, pending.count >= count { return }; await withCheckedContinuation { connectionWaiters.append((count,$0)) } }
        func cancelled() async { if wasCancelled { return }; await withCheckedContinuation { cancellationWaiters.append($0) } }
        private func noteCancelled() { wasCancelled = true; let listeners = cancellationWaiters; cancellationWaiters = []; for listener in listeners { listener.resume() } }
        func failAll(_ signal: BackendRemoteServeSSHSignal) { let calls = pending; pending = []; for call in calls { call.resume(throwing: signal) } }
        func lateError() { failAll(.init(message: "too late")) }
    }
}
