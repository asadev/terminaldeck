import Foundation
import TerminalDeckNativeCore

public enum BackendRemoteServeSSHFailure: String, Sendable { case auth, noSSHD = "no-sshd", timeout, badKey = "bad-key" }
public struct BackendRemoteServeSSHSignal: Error, Sendable {
    public let level: String; public let code: String; public let message: String
    public init(level: String = "", code: String = "", message: String = "") { self.level = level; self.code = code; self.message = message }
}
/// Supplied by the native SSH connection owner. Authenticate and disconnect only.
/// No shell, command, PTY, forwarding, agent, key file or retained/logged secret.
/// Cancellation MUST destroy the socket, including during keyboard-interactive.
public protocol BackendRemoteServeSSHTransport: Sendable {
    func authenticateLoopback(port: Int, username: String, secret: String, method: String,
                              keyboardInteractive: Bool, timeoutMilliseconds: Int) async throws
}
public struct BackendRemoteServeSSHVerifier: Sendable {
    private let transport: (any BackendRemoteServeSSHTransport)?
    private let sleep: @Sendable (Int) async throws -> Void
    public init(transport: (any BackendRemoteServeSSHTransport)?,
                sleep: @escaping @Sendable (Int) async throws -> Void = { try await Task.sleep(for: .milliseconds($0)) }) {
        self.transport = transport; self.sleep = sleep
    }
    public static func classify(_ signal: BackendRemoteServeSSHSignal) -> BackendRemoteServeSSHFailure {
        let said = signal.message.lowercased()
        if signal.level == "client-authentication" || said.contains("authentication methods failed") { return .auth }
        if signal.level == "client-timeout" || signal.code == "ETIMEDOUT" || said.contains("timed out while") { return .timeout }
        if said.contains("privatekey") || said.contains("private key") || said.contains("passphrase") { return .badKey }
        return .noSSHD
    }
    public func verify(username: String, secret: String, method: String, port: Int,
                       timeoutMilliseconds: Int = 10_000) async throws -> BackendRemoteServeSSHFailure? {
        guard let transport else { throw NativeRPCError(code: "unavailable", message: "The native loopback SSH login verifier is unavailable.") }
        let gate = Gate()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.install(continuation)
                let probe = Task {
                    do {
                        try await transport.authenticateLoopback(port: port, username: username, secret: secret,
                            method: method, keyboardInteractive: method == "password", timeoutMilliseconds: timeoutMilliseconds)
                        gate.finish(nil)
                    } catch let signal as BackendRemoteServeSSHSignal { gate.finish(Self.classify(signal)) }
                    catch is CancellationError { gate.finish(.timeout) }
                    catch { gate.finish(method == "key" ? .badKey : .noSSHD) }
                }
                let deadline = Task {
                    do { try await sleep(max(1, timeoutMilliseconds)) }
                    catch { return }
                    gate.finish(.timeout)
                }
                gate.tasks(probe, deadline)
            }
        } onCancel: { gate.finish(.timeout) }
    }
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<BackendRemoteServeSSHFailure?, Never>?
        private var workers: [Task<Void, Never>] = []
        private var settled = false
        private var answer: BackendRemoteServeSSHFailure?
        func install(_ value: CheckedContinuation<BackendRemoteServeSSHFailure?, Never>) {
            lock.lock()
            if settled { let result = answer; lock.unlock(); value.resume(returning: result) }
            else { continuation = value; lock.unlock() }
        }
        func tasks(_ first: Task<Void, Never>, _ second: Task<Void, Never>) {
            lock.lock(); if settled { lock.unlock(); first.cancel(); second.cancel() }
            else { workers = [first, second]; lock.unlock() }
        }
        func finish(_ result: BackendRemoteServeSSHFailure?) {
            lock.lock(); guard !settled else { lock.unlock(); return }
            settled = true; answer = result
            let pending = continuation, running = workers; continuation = nil; workers = []; lock.unlock()
            for task in running { task.cancel() }; pending?.resume(returning: result)
        }
    }
}

/// Complete enroll.ts ordering. Replace the host's Bool-only verifier branch
/// with signIn; a missing SSH adapter cannot be mistaken for a wrong password.
public actor BackendRemoteServeEnrollment {
    public static let refused = "That sign-in was refused. Check the username, and the password or key, then try again."
    public static let badKey = "That private key could not be read. If it has a passphrase, sign in with the account password instead."
    public static let slow = "The server did not answer its own sign-in in time. Try again in a moment."
    public static let busy = "The server is busy checking another sign-in. Try again in a moment."
    public static let noRoom = "That login was accepted, but this machine is already holding as many devices as it can. Remove one from its device list, then try again."
    public static let notSaved = "That login was accepted, but this machine could not save the new device. Check that its state folder is writable, then try again."
    public static func noSSHD(_ port: Int) -> String {
        "Sign-in could not be checked here: nothing answered SSH on 127.0.0.1 port \(port). If this machine's SSH is on another port, set TERMINALDECK_SSHD_PORT to it and restart, then try again — or pair with a code instead."
    }
    public static func port(environment: [String: String]) -> Int {
        func parsed(_ value: String?) -> Int? {
            guard let raw = value?.remoteServeTrimmed, !raw.isEmpty else { return nil }
            // JavaScript Number also accepts a whole decimal exponent or hex.
            let number: Double?
            if raw.lowercased().hasPrefix("0x") { number = UInt64(raw.dropFirst(2), radix: 16).map(Double.init) }
            else if raw.lowercased().hasPrefix("0b") { number = UInt64(raw.dropFirst(2), radix: 2).map(Double.init) }
            else if raw.lowercased().hasPrefix("0o") { number = UInt64(raw.dropFirst(2), radix: 8).map(Double.init) }
            else { number = Double(raw) }
            guard let n = number, n.isFinite, n.rounded() == n, n > 0, n <= 65535 else { return nil }; return Int(n)
        }
        if let override = parsed(environment["TERMINALDECK_SSHD_PORT"]) { return override }
        let parts = BackendRemoteServeText.words(environment["SSH_CONNECTION"] ?? "")
        return parsed(parts.count > 3 ? String(parts[3]) : nil) ?? 22
    }
    private let trust: BackendRemoteTrustStore
    private let verifier: BackendRemoteServeSSHVerifier
    private let environment: [String: String]
    private var probes = 0
    public init(trust: BackendRemoteTrustStore, verifier: BackendRemoteServeSSHVerifier, environment: [String: String]) {
        self.trust = trust; self.verifier = verifier; self.environment = environment
    }
    public func signIn(username: String, secret: String, method: String, deviceName: String,
                       address: String, peerPublicKey: Data) async throws -> BackendRemoteCredential {
        guard await trust.enrollmentAllowed(address: address) else { throw NativeRPCError(code: "unauthorized", message: Self.refused) }
        guard probes < 2 else { throw NativeRPCError(code: "unavailable", message: Self.busy) }
        let port = Self.port(environment: environment)
        probes += 1
        let failure: BackendRemoteServeSSHFailure?
        do { failure = try await verifier.verify(username: username, secret: secret, method: method, port: port) }
        catch { probes -= 1; throw error }
        probes -= 1
        if let failure {
            switch failure {
            case .auth: await trust.noteEnrollmentFailure(address: address); throw NativeRPCError(code: "unauthorized", message: Self.refused)
            case .badKey: throw NativeRPCError(code: "unauthorized", message: Self.badKey)
            case .timeout: throw NativeRPCError(code: "unavailable", message: Self.slow)
            case .noSSHD: throw NativeRPCError(code: "unavailable", message: Self.noSSHD(port))
            }
        }
        do { return try await trust.enrollVerifiedDevice(name: deviceName, address: address, publicKey: peerPublicKey) }
        catch BackendRemoteTrustFailure.denied(let reason) {
            if reason == "This host has too many paired devices." { throw NativeRPCError(code: "unavailable", message: Self.noRoom) }
            throw NativeRPCError(code: "unauthorized", message: Self.refused)
        } catch { throw NativeRPCError(code: "unavailable", message: Self.notSaved) }
    }
}
