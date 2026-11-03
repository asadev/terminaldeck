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
    /// The person's home, only for servers added from their own SSH settings.
    public let sshHome: URL?
    /// The person's own ssh-agent, offered only the alias's own key files.
    public let agentSocket: URL?
    let sshConfig: BackendDockerMCPServerSSHConfig
    public init(scratchRoot: URL, policy: BackendServersSSHPolicy, sshHome: URL? = nil, agentSocket: URL? = nil,
                sshConfig: BackendDockerMCPServerSSHConfig = .init()) {
        self.scratchRoot = scratchRoot; self.policy = policy; self.sshHome = sshHome; self.agentSocket = agentSocket; self.sshConfig = sshConfig
    }
    /// SSH_AUTH_SOCK when it names a socket this account owns; otherwise none.
    public static func personAgentSocket(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard let path = environment["SSH_AUTH_SOCK"], path.hasPrefix("/"), path.utf8.count < 1024 else { return nil }
        var status = stat()
        guard lstat(path, &status) == 0, (status.st_mode & S_IFMT) == S_IFSOCK else { return nil }
        return URL(fileURLWithPath: path)
    }
    /// Each step of a dial keeps its own limit: the host key scan, then the sign-in
    /// (up to one limit to connect, one more to sign in). A server that never answers
    /// fails at its step's limit.
    static let stepTimeoutSeconds = 20
    static let scanTimeoutMilliseconds = stepTimeoutSeconds * 1000, signInTimeoutMilliseconds = 2 * stepTimeoutSeconds * 1000
    /// The whole dial covers every step plus the quick local lookups, so a slow
    /// server that is still answering is never cut off between two steps.
    static let dialTimeoutMilliseconds = scanTimeoutMilliseconds + signInTimeoutMilliseconds + 10_000
    public func dial(server: BackendServersStoredServer, credential: BackendServersCredential,
                     verifyHostKey: @escaping @Sendable (Data) throws -> Void) async throws -> any BackendServersConnection {
        try await withThrowingTaskGroup(of: (any BackendServersConnection).self) { group in
            group.addTask { try await self.open(server: server, credential: credential, verifyHostKey: verifyHostKey) }
            group.addTask { try await Task.sleep(for: .milliseconds(Self.dialTimeoutMilliseconds)); throw BackendServersProblem("no-answer", "That address did not answer in time.") }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }; return result
        }
    }
    private func open(server saved: BackendServersStoredServer, credential: BackendServersCredential,
                      verifyHostKey: @escaping @Sendable (Data) throws -> Void) async throws -> any BackendServersConnection {
        try Task.checkCancellation()
        var server = saved
        var aliasIdentities: [String] = [], aliasName: String?, trusted: [ScannedKey] = []
        if case .sshConfig(let alias) = credential {
            // The person's own SSH settings decide address, user, port and key
            // files at every connect. ssh reads the key files; this app never does.
            guard let home = sshHome else { throw NativeRPCError(code: "unavailable", message: "This copy of the app cannot use SSH settings.") }
            let resolved = try await sshConfig.resolve(alias: alias, home: home)
            server.address = resolved.hostname; server.username = resolved.user; server.port = resolved.port
            aliasIdentities = resolved.identityFiles.filter { FileManager.default.isReadableFile(atPath: $0) }
            guard !aliasIdentities.isEmpty else {
                throw BackendServersProblem("key-unreadable", "The SSH settings for \(alias) name no key file on this Mac that Terminal Deck can use.")
            }
            aliasName = alias
        }
        // The person's own known_hosts counts for every server, like OpenSSH.
        if let home = sshHome { trusted = await Self.trustedHostKeys(home: home, host: server.address, port: server.port) }
        guard policy.mayConnect else { throw NativeRPCError(code: "unavailable", message: "Native SSH connections have not been enabled by the exclusive backend owner.") }
        guard policy.helperDispatchInstalled, policy.helperExecutable.isFileURL,
              FileManager.default.isExecutableFile(atPath: policy.helperExecutable.path) else {
            throw NativeRPCError(code: "unavailable", message: "The native helper's private server sign-in dispatch is not installed.")
        }
        guard !server.address.isEmpty, !server.address.contains("\0"), !server.username.contains("\0") else { throw BackendServersProblem("no-such-address", "We cannot find a computer at that address. Check the address for a typo.") }
        let directory = try BackendServersSSHPrivateDirectory.make(root: scratchRoot)
        do {
            // Recorded identities (this app's pin, then the person's known_hosts)
            // decide which key TYPE is checked. A server also offering other
            // types is normal; only the same type with a different key is "changed".
            let recordedTypes = Self.recordedTypes(pin: server.hostKey, trusted: trusted)
            var keys = try await Self.scan(server, types: Self.scanOrder(recordedTypes))
            if let first = recordedTypes.first, !keys.contains(where: { $0.algorithm == first }) {
                keys += (try? await Self.scan(server, types: [first])) ?? []   // one retry for the recorded type
            }
            guard !keys.isEmpty else { throw BackendServersProblem("no-answer", "That address did not answer with an identity in time.") }
            let selected: ScannedKey
            switch Self.chooseHostKey(scanned: keys, pin: server.hostKey, trusted: trusted) {
            case .use(let key): selected = key
            case .changed(let expected, let offered):
                throw BackendServersProblem("identity-changed", BackendServersConnections.identityChanged + " " + Self.fingerprints(expected: expected, offered: offered),
                    expected: BackendServersConnections.fingerprintOf(expected.key), offered: BackendServersConnections.fingerprintOf(offered.key))
            case .unconfirmed(let type):
                throw BackendServersProblem("identity-unconfirmed", "This server did not show the kind of identity key (\(Self.typeName(type))) this Mac has on record for it, so it could not be confirmed. Nothing was sent to it. Try again in a moment.")
            }
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
                case .key, .sshConfig: return nil
                }
            }
            try broker.start()
            defer { broker.close() }
            var options = Self.strictOptions(server: server, alias: alias, keyAlgorithm: selected.algorithm, knownHosts: knownHosts,
                                             identityAgent: aliasName == nil ? agent?.socket : agentSocket)
            switch credential {
            case .password:
                options += ["-o", "PubkeyAuthentication=no", "-o", "PreferredAuthentications=keyboard-interactive,password", "-o", "PasswordAuthentication=yes", "-o", "KbdInteractiveAuthentication=yes", "-o", "IdentityFile=none"]
            case .key:
                guard let agent else { throw BackendServersProblem("key-unreadable", "That key could not be read.") }
                let publicIdentity = directory.appendingPathComponent("identity.pub")
                try BackendRemoteServeSecretFile.write(directory: directory, file: publicIdentity, contents: Data(agent.publicIdentity.utf8))
                options += ["-o", "PubkeyAuthentication=yes", "-o", "PreferredAuthentications=publickey", "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no", "-i", publicIdentity.path]
            case .sshConfig:
                // IdentitiesOnly stays on: only this alias's own key files are
                // offered, never every key in the person's agent.
                options += ["-o", "PubkeyAuthentication=yes", "-o", "PreferredAuthentications=publickey", "-o", "PasswordAuthentication=no", "-o", "KbdInteractiveAuthentication=no"]
                    + aliasIdentities.flatMap { ["-i", $0] }
            }
            let control = directory.appendingPathComponent("ctl")
            // ControlMaster=yes only. Adding -M on top switches OpenSSH to "ask"
            // mode, which refuses every exec, shell and Docker channel (DKA2).
            let master = BackendServersSSHProcess(executable: URL(fileURLWithPath: "/usr/bin/ssh"),
                arguments: options + ["-o", "BatchMode=no", "-o", "NumberOfPasswordPrompts=3", "-o", "ControlMaster=yes", "-o", "ControlPersist=no", "-S", control.path, "-N", "-T", "-v", "--", server.address],
                environment: Self.environment(askpass: askpass, broker: broker))
            do {
                try master.start(); try await master.ready(marker: "Entering interactive session.", timeoutMilliseconds: Self.signInTimeoutMilliseconds)
                guard FileManager.default.fileExists(atPath: control.path) else { throw NativeRPCError(code: "unavailable", message: "The private SSH control socket was not created.") }
            } catch {
                master.close(); broker.close()
                if let signal = error as? BackendServersSSHSignal,
                   signal.message.lowercased().contains("host identification has changed") || signal.message.lowercased().contains("host key verification failed") {
                    // Read what the server actually showed in this very exchange.
                    // Same key as checked = a local check problem, never "changed".
                    let expected = BackendServersConnections.fingerprintOf(selected.key)
                    switch Self.masterHostKey(signal.message) {
                    case .some((let type, let fingerprint)) where fingerprint == expected:
                        _ = type
                        throw BackendServersProblem("identity-unconfirmed", "This app could not finish checking this server's identity on this Mac, although the server showed the expected key. Nothing was sent to it.")
                    case .some((let type, let fingerprint)) where type == selected.algorithm:
                        throw BackendServersProblem("identity-changed", BackendServersConnections.identityChanged + " Expected \(expected) (\(Self.typeName(type))), it showed \(fingerprint).",
                            expected: expected, offered: fingerprint)
                    case .some((let type, _)):
                        throw BackendServersProblem("identity-unconfirmed", "This server showed a \(Self.typeName(type)) key instead of the \(Self.typeName(selected.algorithm)) key on record, so it could not be confirmed. Nothing was sent to it.")
                    case .none:
                        throw BackendServersProblem("identity-unconfirmed", "This app could not confirm this server's identity. Nothing was sent to it. Try again in a moment.")
                    }
                }
                if let aliasName, BackendServersProblem.problemFor(error).kind == "sign-in-refused" {
                    throw BackendServersProblem("sign-in-refused", "The server did not accept the key from your SSH settings for \(aliasName). If that key has a passphrase, add it to your Mac's keychain first (in Terminal: ssh-add --apple-use-keychain followed by the key file), then try again.")
                }
                throw error
            }
            // Authentication is complete. No child ever needs these again.
            broker.close(); agent?.close(); try? FileManager.default.removeItem(at: directory.appendingPathComponent("identity.pub")); try? FileManager.default.removeItem(at: askpass)
            return BackendServersSSHClient(server: server, directory: directory, control: control,
                options: Self.strictOptions(server: server, alias: alias, keyAlgorithm: selected.algorithm, knownHosts: knownHosts), master: master)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    struct ScannedKey: Sendable, Equatable { let algorithm: String; let key: Data }
    /// A path inside an ssh -o value. ssh splits unquoted values on spaces, so
    /// "Application Support" became two files and every host check failed
    /// ("Host key verification failed", shown as a changed identity) (DKA2).
    static func optionPath(_ path: String) -> String { "\"" + path.replacingOccurrences(of: "\"", with: "") + "\"" }
    enum HostKeyChoice: Equatable { case use(ScannedKey), changed(expected: ScannedKey, offered: ScannedKey), unconfirmed(String) }
    /// Recorded types first: this app's pin, then the person's known_hosts.
    static func recordedTypes(pin: BackendServersHostKeyRecord?, trusted: [ScannedKey]) -> [String] {
        var types: [String] = []
        for type in [pin?.algorithm].compactMap({ $0 }) + trusted.map(\.algorithm) where !type.isEmpty && !types.contains(type) { types.append(type) }
        return types
    }
    static func scanOrder(_ recorded: [String]) -> [String] {
        func short(_ type: String) -> String { type == "ssh-ed25519" ? "ed25519" : type.hasPrefix("ecdsa-") ? "ecdsa" : type == "ssh-rsa" ? "rsa" : type }
        var order: [String] = []
        for type in recorded.map(short) + ["ed25519", "ecdsa", "rsa"] where ["ed25519", "ecdsa", "rsa"].contains(type) && !order.contains(type) { order.append(type) }
        return order
    }
    /// What OpenSSH does: check the recorded key of the recorded type. Another
    /// type alongside it is fine. Same type, different key = changed. Recorded
    /// type not shown at all = unconfirmed, never "changed".
    static func chooseHostKey(scanned: [ScannedKey], pin: BackendServersHostKeyRecord?, trusted: [ScannedKey]) -> HostKeyChoice {
        let ranked = scanned.sorted { rank($0.algorithm) < rank($1.algorithm) }
        if let pin {
            if let same = ranked.first(where: { BackendServersConnections.fingerprintOf($0.key) == pin.fingerprint }) {
                if trusted.isEmpty || trusted.contains(where: { $0.key == same.key }) || !trusted.contains(where: { $0.algorithm == same.algorithm }) { return .use(same) }
            }
            guard let sameType = ranked.first(where: { $0.algorithm == pin.algorithm }) else { return .unconfirmed(pin.algorithm) }
            let recorded = trusted.first { $0.algorithm == pin.algorithm && BackendServersConnections.fingerprintOf($0.key) == pin.fingerprint }
            return .changed(expected: recorded ?? ScannedKey(algorithm: pin.algorithm, key: Data()), offered: sameType)
        }
        if !trusted.isEmpty {
            if let known = ranked.first(where: { offered in trusted.contains { $0.key == offered.key } }) { return .use(known) }
            for record in trusted { if let sameType = ranked.first(where: { $0.algorithm == record.algorithm }) { return .changed(expected: record, offered: sameType) } }
            return .unconfirmed(trusted[0].algorithm)
        }
        if let pin { return .unconfirmed(pin.algorithm) }
        return ranked.first.map { .use($0) } ?? .unconfirmed("ssh-ed25519")
    }
    static func typeName(_ type: String) -> String {
        type == "ssh-ed25519" ? "ED25519" : type.hasPrefix("ecdsa-") ? "ECDSA" : type.hasPrefix("ssh-rsa") || type.hasPrefix("rsa-") ? "RSA" : type
    }
    static func fingerprints(expected: ScannedKey, offered: ScannedKey) -> String {
        let recorded = expected.key.isEmpty ? "the \(typeName(expected.algorithm)) key on record" : "\(BackendServersConnections.fingerprintOf(expected.key)) (\(typeName(expected.algorithm)))"
        return "Expected \(recorded), it showed \(BackendServersConnections.fingerprintOf(offered.key))."
    }
    /// "debug1: Server host key: ssh-ed25519 SHA256:..." from ssh -v.
    static func masterHostKey(_ said: String) -> (String, String)? {
        guard let line = said.components(separatedBy: .newlines).first(where: { $0.contains("Server host key:") }) else { return nil }
        let words = line.components(separatedBy: "Server host key:")[1].split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 2, words[1].hasPrefix("SHA256:") else { return nil }
        return (words[0], words[1].trimmingCharacters(in: .whitespacesAndNewlines))
    }
    static func scan(_ server: BackendServersStoredServer, types: [String]) async throws -> [ScannedKey] {
        let scan = BackendServersSSHProcess(executable: URL(fileURLWithPath: "/usr/bin/ssh-keyscan"),
            arguments: ["-T", String(stepTimeoutSeconds), "-p", String(server.port), "-t", types.joined(separator: ","), "--", server.address], environment: environment())
        defer { scan.close() }
        try scan.start()
        let answer = try await scan.collect(stdin: nil, timeoutMilliseconds: scanTimeoutMilliseconds, maximumOutputBytes: 65536)
        let keys = scannedKeys(answer.stdout)
        if keys.isEmpty, !answer.stderr.isEmpty, !answer.stderr.lowercased().contains("timed out") {
            throw BackendServersProblem.problemFor(BackendServersSSHSignal(message: answer.stderr))
        }
        return keys
    }
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
            "-o", "UserKnownHostsFile=" + optionPath(knownHosts.path), "-o", "GlobalKnownHostsFile=/dev/null", "-o", "StrictHostKeyChecking=yes",
            "-o", "HostKeyAlias=\(alias)", "-o", "HostKeyAlgorithms=\(algorithms)", "-o", "CheckHostIP=no", "-o", "UpdateHostKeys=no",
            "-o", "IdentityAgent=" + (identityAgent.map { optionPath($0.path) } ?? "none"), "-o", "IdentitiesOnly=yes", "-o", "AddKeysToAgent=no", "-o", "ForwardAgent=no",
            "-o", "PermitLocalCommand=no", "-o", "ProxyCommand=none", "-o", "ProxyJump=none", "-o", "CanonicalizeHostname=no",
            "-o", "ConnectTimeout=\(stepTimeoutSeconds)", "-o", "ServerAliveInterval=0", "-o", "TCPKeepAlive=no", "-o", "ExitOnForwardFailure=yes", "-o", "EscapeChar=none"]
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
