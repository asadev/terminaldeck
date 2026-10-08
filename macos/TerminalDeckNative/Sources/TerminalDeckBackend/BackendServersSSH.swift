import Foundation
import Darwin
import TerminalDeckNativeCore

public struct BackendServersSSHPolicy: Sendable {
    public let mayConnect: Bool
    public let helperExecutable: URL
    /// The exclusive facade must have installed the early ASKPASS dispatch in
    /// this exact helper. This is a capability assertion, not a probing flag.
    public let helperDispatchInstalled: Bool
    public init(mayConnect: Bool, helperExecutable: URL, helperDispatchInstalled: Bool) { self.mayConnect = mayConnect; self.helperExecutable = helperExecutable; self.helperDispatchInstalled = helperDispatchInstalled }
}

/// Native system-SSH implementation. Public-key scanning sends no credential;
/// its selected key is verified/persisted before a private strict-known-host
/// connection is attempted. StrictHostKeyChecking is never disabled. The
/// authentication connection verifies that exact key again, closing the scan-
/// to-connect race. The private master owns all subsequent exec/subsystems.
public struct BackendServersSSH: BackendServersSSHDialer, Sendable {
    public let scratchRoot: URL
    public let policy: BackendServersSSHPolicy
    public init(scratchRoot: URL, policy: BackendServersSSHPolicy) { self.scratchRoot = scratchRoot; self.policy = policy }
    public func dial(server: BackendServersStoredServer, credential: BackendServersCredential,
                     verifyHostKey: @escaping @Sendable (Data) throws -> Void) async throws -> any BackendServersConnection {
        try await withThrowingTaskGroup(of: (any BackendServersConnection).self) { group in
            group.addTask { try await self.open(server: server, credential: credential, verifyHostKey: verifyHostKey) }
            group.addTask { try await Task.sleep(for: .milliseconds(20_000)); throw BackendServersProblem("no-answer", "That address did not answer in time.") }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }; return result
        }
    }
    private func open(server: BackendServersStoredServer, credential: BackendServersCredential,
                      verifyHostKey: @escaping @Sendable (Data) throws -> Void) async throws -> any BackendServersConnection {
        try Task.checkCancellation()
        guard policy.mayConnect else { throw NativeRPCError(code: "unavailable", message: "Native SSH connections have not been enabled by the exclusive backend owner.") }
        guard policy.helperDispatchInstalled, policy.helperExecutable.isFileURL,
              FileManager.default.isExecutableFile(atPath: policy.helperExecutable.path) else {
            throw NativeRPCError(code: "unavailable", message: "The native helper's private server sign-in dispatch is not installed.")
        }
        guard !server.address.isEmpty, !server.address.contains("\0"), !server.username.contains("\0") else { throw BackendServersProblem("no-such-address", "We cannot find a computer at that address. Check the address for a typo.") }
        let directory = try BackendServersSSHPrivateDirectory.make(root: scratchRoot)
        do {
            let scan = BackendServersSSHProcess(executable: URL(fileURLWithPath: "/usr/bin/ssh-keyscan"),
                arguments: ["-T", "20", "-p", String(server.port), "-t", "ed25519,ecdsa,rsa", "--", server.address], environment: Self.environment())
            try scan.start()
            let answer = try await scan.collect(stdin: nil, timeoutMilliseconds: 20_000, maximumOutputBytes: 65536)
            let keys = Self.scannedKeys(answer.stdout)
            guard !keys.isEmpty else { throw BackendServersProblem.problemFor(BackendServersSSHSignal(message: answer.stderr.isEmpty ? "timed out while waiting for the SSH host key" : answer.stderr)) }
            let selected = server.hostKey.flatMap { pin in keys.first { BackendServersConnections.fingerprintOf($0.key) == pin.fingerprint } } ?? keys[0]
            try verifyHostKey(selected.key)
            try Task.checkCancellation()
            let alias = "native-server-" + UUID().uuidString.lowercased()
            let knownHosts = directory.appendingPathComponent("known_hosts")
            try BackendRemoteServeSecretFile.write(directory: directory, file: knownHosts, contents: Data("\(alias) \(selected.algorithm) \(selected.key.base64EncodedString())\n".utf8))
            var agent: BackendServersSSHAgent?
            defer { agent?.close() }
            if case .key(let text, let opener) = credential {
                do { agent = try await BackendServersSSHAgent.load(privateKey: text, passphrase: opener, directory: directory, helper: policy.helperExecutable) }
                catch let issue as BackendServersSSHAgentFailure { throw BackendServersProblem("key-unreadable", issue.sentence) }
            }
            try Task.checkCancellation()
            try verifyHostKey(selected.key)
            let askpass = try Self.askpassScript(directory: directory, helper: policy.helperExecutable)
            let broker = BackendServersSSHAskpassBroker(directory: directory) { prompt in
                let lower = prompt.lowercased()
                guard !lower.contains("authenticity of host"), !lower.contains("continue connecting"), !lower.contains("key fingerprint") else { return nil }
                do { try verifyHostKey(selected.key) } catch { return nil }
                switch credential {
                case .password(let value): return value
                case .key: return nil
                }
            }
            try broker.start()
            defer { broker.close() }
            var options = Self.strictOptions(server: server, alias: alias, keyAlgorithm: selected.algorithm, knownHosts: knownHosts, identityAgent: agent?.socket)
            switch credential {
            case .password:
                options += ["-o", "PubkeyAuthentication=no", "-o", "PreferredAuthentications=keyboard-interactive,password", "-o", "PasswordAuthentication=yes", "-o", "KbdInteractiveAuthentication=yes", "-o", "IdentityFile=none"]
            case .key:
                guard let agent else { throw BackendServersProblem("key-unreadable", "That key could not be read.") }
                let publicIdentity = directory.appendingPathComponent("identity.pub")
                try BackendRemoteServeSecretFile.write(directory: directory, file: publicIdentity, contents: Data(agent.publicIdentity.utf8))
                options += ["-o", "PubkeyAuthentication=yes", "-o", "PreferredAuthentications=publickey", "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no", "-i", publicIdentity.path]
            }
            let control = directory.appendingPathComponent("ctl")
            let master = BackendServersSSHProcess(executable: URL(fileURLWithPath: "/usr/bin/ssh"),
                arguments: options + ["-o", "BatchMode=no", "-o", "NumberOfPasswordPrompts=3", "-o", "ControlMaster=yes", "-o", "ControlPersist=no", "-S", control.path, "-M", "-N", "-T", "-v", "--", server.address],
                environment: Self.environment(askpass: askpass, broker: broker))
            do {
                try master.start(); try await master.ready(marker: "Entering interactive session.", timeoutMilliseconds: 20_000)
                guard FileManager.default.fileExists(atPath: control.path) else { throw NativeRPCError(code: "unavailable", message: "The private SSH control socket was not created.") }
            } catch {
                master.close(); broker.close()
                if let signal = error as? BackendServersSSHSignal,
                   signal.message.lowercased().contains("host identification has changed") || (error as? BackendServersSSHSignal)?.message.lowercased().contains("host key verification failed") == true {
                    let said = (error as? BackendServersSSHSignal)?.message ?? ""
                    let match = said.range(of: #"SHA256:[A-Za-z0-9+/]+"#, options: .regularExpression)
                    throw BackendServersProblem("identity-changed", BackendServersConnections.identityChanged,
                        expected: BackendServersConnections.fingerprintOf(selected.key), offered: match.map { String(said[$0]) } ?? "The server offered a different key during authentication.")
                }
                throw error
            }
            // Authentication is complete. No child ever needs these again.
            broker.close(); agent?.close(); try? FileManager.default.removeItem(at: directory.appendingPathComponent("identity.pub")); try? FileManager.default.removeItem(at: askpass)
            return BackendServersSSHClient(server: server, directory: directory, control: control,
                options: Self.strictOptions(server: server, alias: alias, keyAlgorithm: selected.algorithm, knownHosts: knownHosts), master: master)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    struct ScannedKey: Sendable { let algorithm: String; let key: Data }
    static func scannedKeys(_ text: String) -> [ScannedKey] {
        text.split(separator: "\n").compactMap { line in
            let bits = line.split(whereSeparator: \.isWhitespace)
            guard bits.count >= 3, !bits[0].hasPrefix("#"), let key = Data(base64Encoded: String(bits[2])), BackendServersConnections.algorithmOf(key) == String(bits[1]) else { return nil }
            return .init(algorithm: String(bits[1]), key: key)
        }.sorted { rank($0.algorithm) < rank($1.algorithm) }
    }
    private static func rank(_ algorithm: String) -> Int { algorithm == "ssh-ed25519" ? 0 : algorithm.hasPrefix("ecdsa-") ? 1 : 2 }
    static func strictOptions(server: BackendServersStoredServer, alias: String, keyAlgorithm: String, knownHosts: URL, identityAgent: URL? = nil) -> [String] {
        let algorithms = keyAlgorithm == "ssh-rsa" ? "rsa-sha2-512,rsa-sha2-256" : keyAlgorithm
        return ["-F", "/dev/null", "-p", String(server.port), "-l", server.username,
            "-o", "UserKnownHostsFile=\(knownHosts.path)", "-o", "GlobalKnownHostsFile=/dev/null", "-o", "StrictHostKeyChecking=yes",
            "-o", "HostKeyAlias=\(alias)", "-o", "HostKeyAlgorithms=\(algorithms)", "-o", "CheckHostIP=no", "-o", "UpdateHostKeys=no",
            "-o", "IdentityAgent=\(identityAgent?.path ?? "none")", "-o", "IdentitiesOnly=yes", "-o", "AddKeysToAgent=no", "-o", "ForwardAgent=no",
            "-o", "PermitLocalCommand=no", "-o", "ProxyCommand=none", "-o", "ProxyJump=none", "-o", "CanonicalizeHostname=no",
            "-o", "ConnectTimeout=20", "-o", "ServerAliveInterval=0", "-o", "TCPKeepAlive=no", "-o", "ExitOnForwardFailure=yes", "-o", "EscapeChar=none"]
    }
    static func environment(askpass: URL? = nil, broker: BackendServersSSHAskpassBroker? = nil) -> [String: String] {
        // Explicitly reconstructed. SSH_AUTH_SOCK, user SSH config and inherited
        // DYLD/loader settings cannot creep into a credential-bearing child.
        var env = ["PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C", "TERM": "xterm-256color", "HOME": "/var/empty"]
        if let askpass, let broker { env["SSH_ASKPASS"] = askpass.path; env["SSH_ASKPASS_REQUIRE"] = "force"; env["DISPLAY"] = "native-private-askpass"; env[BackendServersSSHAskpass.socketEnvironment] = broker.socket.path }
        return env
    }
    static func askpassScript(directory: URL, helper: URL) throws -> URL {
        let file = directory.appendingPathComponent("askpass")
        let script = "#!/bin/sh\nexec \(BackendServersConnections.quote(helper.path)) \(BackendServersSSHAskpass.dispatchArgument) \"$@\"\n"
        try BackendRemoteServeSecretFile.write(directory: directory, file: file, contents: Data(script.utf8))
        guard Darwin.chmod(file.path, 0o700) == 0 else { throw NativeRPCError(code: "unavailable", message: "The private sign-in helper could not be made executable.") }; return file
    }
    /// Native key parser via an empty isolated agent and ssh-add stdin. No
    /// private-key file, inherited agent, keychain fallback or secret argv/env.
    public func keyValidator() -> BackendServersKeyValidator {
        .init { text, opener in
            guard policy.helperDispatchInstalled, policy.helperExecutable.isFileURL,
                  FileManager.default.isExecutableFile(atPath: policy.helperExecutable.path) else { throw NativeRPCError(code: "unavailable", message: "The native helper's private key-reader dispatch is not installed.") }
            guard let offer = BackendServersKeyfiles.describeKey(text, name: "") else { return "That does not look like a key. Paste the whole file, including its first and last lines." }
            if offer.locked == true && opener == nil { return "That key is locked. What is its passphrase?" }
            let directory = try BackendServersSSHPrivateDirectory.make(root: scratchRoot)
            defer { try? FileManager.default.removeItem(at: directory) }
            do { let agent = try await BackendServersSSHAgent.load(privateKey: text, passphrase: opener, directory: directory, helper: policy.helperExecutable); agent.close(); return nil }
            catch let issue as BackendServersSSHAgentFailure { return issue.sentence }
        }
    }
}

enum BackendServersSSHPrivateDirectory {
    static func make(root: URL) throws -> URL {
        guard root.isFileURL, root.path.hasPrefix("/") else { throw NativeRPCError.invalidArguments("SSH needs an explicit absolute private scratch root.") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var status = stat()
        guard lstat(root.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFDIR, status.st_uid == getuid(), status.st_mode & 0o077 == 0 else {
            throw NativeRPCError(code: "unavailable", message: "The explicit SSH scratch root must be a private directory owned by this account.")
        }
        var template = Array(root.appendingPathComponent("s.XXXXXX").path.utf8CString)
        guard let made = mkdtemp(&template) else { throw NativeRPCError(code: "unavailable", message: "The private SSH connection directory could not be created.") }
        let directory = URL(fileURLWithPath: String(cString: made), isDirectory: true)
        guard directory.appendingPathComponent("ctl").path.utf8.count < 104 else { try? FileManager.default.removeItem(at: directory); throw NativeRPCError(code: "unavailable", message: "The explicit SSH scratch root is too long for a private control socket.") }
        return directory
    }
}

final class BackendServersSSHClient: BackendServersConnection, @unchecked Sendable {
    private let server: BackendServersStoredServer, directory: URL, control: URL, options: [String], master: BackendServersSSHProcess
    private let lock = NSLock(); private var stopped = false, children: [UUID: @Sendable () -> Void] = [:]
    private let closed = BackendServersSSHEvents<Bool>(retainBeforeSubscription: true, replayLatest: true)
    private var closeSubscription: BackendServersUnsubscribe?
    init(server: BackendServersStoredServer, directory: URL, control: URL, options: [String], master: BackendServersSSHProcess) {
        self.server = server; self.directory = directory; self.control = control; self.options = options; self.master = master
        closeSubscription = master.onClose { [weak self] in self?.close() }
    }
    private func childOptions() throws -> [String] {
        guard isCurrent else { throw BackendServersProblem("lost", "That connection is gone.") }
        return options + ["-S", control.path, "-o", "ControlMaster=no", "-o", "BatchMode=yes", "-o", "PubkeyAuthentication=no", "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no", "-o", "IdentityFile=none"]
    }
    private var isCurrent: Bool { lock.withLock { !stopped } && master.process.isRunning && FileManager.default.fileExists(atPath: control.path) }
    private func track(_ close: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID(), shouldClose = lock.withLock { if stopped { return true }; children[id] = close; return false }; if shouldClose { close() }; return id
    }
    private func child(extra: [String], command: String? = nil) throws -> BackendServersSSHProcess {
        var arguments = try childOptions() + extra + ["--", server.address]; if let command { arguments.append(command) }
        let process = BackendServersSSHProcess(executable: URL(fileURLWithPath: "/usr/bin/ssh"), arguments: arguments, environment: BackendServersSSH.environment())
        let id = track { process.close() }; _ = process.onClose { [weak self] in _ = self?.lock.withLock { self?.children.removeValue(forKey: id) } }
        try process.start(); return process
    }
    func exec(command: String, stdin: Data?, timeoutMilliseconds: Int, maximumOutputBytes: Int) async throws -> BackendServersRunResult {
        _ = try childOptions()
        let proxy = BackendServersSSHProxy(controlSocket: control, isCurrent: { [weak self] in self?.isCurrent == true })
        let id = track { proxy.close() }
        defer { proxy.close(); _ = lock.withLock { children.removeValue(forKey: id) } }
        // The proxy preserves RFC4254 exit-signal directly. Unsupported mux
        // mode refuses explicitly; there is no lossy process-status fallback.
        return try await proxy.execute(command: command, stdin: stdin, timeoutMilliseconds: timeoutMilliseconds, maximumOutputBytes: maximumOutputBytes)
    }
    func follow(command: String) async throws -> any BackendServersFollow {
        _ = try childOptions()
        let proxy = BackendServersSSHProxy(controlSocket: control, isCurrent: { [weak self] in self?.isCurrent == true })
        let id = track { proxy.close() }
        do {
            let stream = try await proxy.follow(command: command, maximumStderrBytes: 8192)
            return BackendServersSSHTrackedFollow(stream) { [weak self] in _ = self?.lock.withLock { self?.children.removeValue(forKey: id) } }
        } catch { proxy.close(); _ = lock.withLock { children.removeValue(forKey: id) }; throw error }
    }
    func shell(size: BackendServersTerminalSize) async throws -> any BackendServersShell {
        let shell = try BackendServersSSHPty(executable: URL(fileURLWithPath: "/usr/bin/ssh"), arguments: childOptions() + ["-tt", "--", server.address], environment: BackendServersSSH.environment(), size: size)
        let id = track { shell.close() }; _ = shell.onClose { [weak self] in _ = self?.lock.withLock { self?.children.removeValue(forKey: id) } }; return shell
    }
    func dockerDialStdio() async throws -> any BackendServersDuplex {
        try Task.checkCancellation()
        // child() attaches only to our existing authenticated SSH master;
        // childOptions() disables independent sign-in and credential fallback.
        let channel = try child(extra: ["-T"], command: "docker system dial-stdio")
        // Never surface SSH stderr through Docker output. Drain it so the
        // existing process's bounded pre-subscription queue cannot block.
        _ = channel.stderr.listen { _ in }
        return channel
    }
    func openSFTP() async throws -> any BackendServersSFTP {
        do { let channel = try child(extra: ["-T", "-s"], command: "sftp"); return try await BackendServersSSHSFTP.open(channel) }
        catch { if error is BackendServersProblem { throw error }; throw BackendServersProblem("not-a-server", "This server will not let us list its folders. You can still type the path.") }
    }
    func forward(host: String, port: Int) async throws -> any BackendServersDuplex {
        guard ["127.0.0.1", "::1"].contains(host), (1...65535).contains(port) else { throw NativeRPCError.invalidArguments("A server forward must name its own loopback and a port.") }
        let target = host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        let channel = try child(extra: ["-T", "-v", "-W", target])
        do { try await channel.ready(marker: "mux_client_request_stdio_fwd: master session id:", timeoutMilliseconds: 5000); return channel }
        catch { channel.close(); throw BackendServersForwardError.from(error) }
    }
    func reverseForward(bindAddress: String, bindPort: Int) async throws -> any BackendServersReverseForward {
        guard bindAddress == "127.0.0.1", (0...65535).contains(bindPort) else { throw NativeRPCError.invalidArguments("A reverse server endpoint must bind its own loopback.") }
        let lease = try await BackendServersSSHReverseLease.prepare(requestedPort: bindPort, command: { [weak self] verb, specification in
            guard let self else { throw CancellationError() }
            let channel = try child(extra: ["-O", verb, "-R", specification]); defer { channel.close() }
            return try await channel.collect(stdin: nil, timeoutMilliseconds: 5000, maximumOutputBytes: 65536)
        })
        let id = track { lease.close() }; _ = lease.onClose { [weak self] in _ = self?.lock.withLock { self?.children.removeValue(forKey: id) } }; return lease
    }
    func onClose(_ listener: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe { closed.listen { _ in listener() } }
    func close() {
        let values = lock.withLock { () -> (Bool, [@Sendable () -> Void]) in guard !stopped else { return (false, []) }; stopped = true; let old = Array(children.values); children = [:]; return (true, old) }
        guard values.0 else { return }
        for close in values.1 { close() }; master.close(); closed.send(true)
        try? FileManager.default.removeItem(at: directory)
    }
    deinit { closeSubscription?(); close() }
}
private final class BackendServersSSHTrackedFollow: BackendServersFollow, @unchecked Sendable {
    private let stream: any BackendServersFollow, lock = NSLock()
    private var untrack: BackendServersUnsubscribe?, ended: BackendServersUnsubscribe?
    init(_ stream: any BackendServersFollow, untrack: @escaping BackendServersUnsubscribe) {
        self.stream = stream; self.untrack = untrack
        ended = stream.onEnd { [weak self] _ in self?.finish() }
    }
    private func finish() { let call = lock.withLock { let old = untrack; untrack = nil; return old }; call?() }
    func onBytes(_ listener: @escaping @Sendable (Data) -> Void) -> BackendServersUnsubscribe { stream.onBytes(listener) }
    func onEnd(_ listener: @escaping @Sendable (BackendServersFollowEnd) -> Void) -> BackendServersUnsubscribe { stream.onEnd(listener) }
    func close() { stream.close(); finish() }
    deinit { ended?(); stream.close(); finish() }
}
