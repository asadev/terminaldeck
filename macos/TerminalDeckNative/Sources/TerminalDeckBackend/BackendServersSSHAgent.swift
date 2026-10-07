import Foundation
import TerminalDeckNativeCore

/// A fresh, foreground, empty agent receives exactly this connection's key via
/// ssh-add stdin. It has no relationship to SSH_AUTH_SOCK inherited from the
/// desktop, Keychain key discovery, ~/.ssh, or any other server's agent. Only
/// public IdentityFile text is written. The private key never reaches a file.
final class BackendServersSSHAgent: @unchecked Sendable {
    let socket: URL
    let publicIdentity: String
    private let process: BackendServersSSHProcess
    private let lock = NSLock(); private var closed = false
    private init(socket: URL, publicIdentity: String, process: BackendServersSSHProcess) { self.socket = socket; self.publicIdentity = publicIdentity; self.process = process }
    static func load(privateKey: String, passphrase: String?, directory: URL, helper: URL) async throws -> BackendServersSSHAgent {
        try Task.checkCancellation()
        let socket = directory.appendingPathComponent("agent")
        let process = privateProcess(executable: "/usr/bin/ssh-agent", arguments: ["-D", "-a", socket.path], environment: BackendServersSSH.environment())
        var succeeded = false
        defer { if !succeeded { process.close() } }
        do { try process.start(); try await process.end(); try await process.ready(marker: "SSH_AUTH_SOCK=", standardOutput: true, timeoutMilliseconds: 5000) }
        catch is CancellationError { throw CancellationError() }
        catch { throw NativeRPCError(code: "unavailable", message: "The isolated native SSH key reader could not start.") }
        let askpass = try BackendServersSSH.askpassScript(directory: directory, helper: helper)
        defer { try? FileManager.default.removeItem(at: askpass) }
        let opener = BackendServersSSHAgentOpener(passphrase)
        let broker = BackendServersSSHAskpassBroker(directory: directory) { prompt in
            // One attempt, then EOF. ssh-add asks repeatedly on a wrong answer;
            // refusing its retry preserves the distinct bad-passphrase failure.
            prompt.lowercased().contains("passphrase") ? opener.take() : nil
        }
        try broker.start(); defer { broker.close() }
        var environment = BackendServersSSH.environment(askpass: askpass, broker: broker)
        environment["SSH_AUTH_SOCK"] = socket.path
        // Apple's optional keychain behavior must not become an implicit
        // credential source. No keychain switches or ambient keys are used.
        environment["APPLE_SSH_ADD_BEHAVIOR"] = "openssh"
        let load = privateProcess(executable: "/usr/bin/ssh-add", arguments: ["-"], environment: environment)
        try load.start(); defer { load.close() }
        let keyBytes = Data((privateKey.hasSuffix("\n") ? privateKey : privateKey + "\n").utf8)
        let loaded = try await load.collect(stdin: keyBytes, timeoutMilliseconds: 5000, maximumOutputBytes: 65536)
        if loaded.code == 127 { throw NativeRPCError(code: "unavailable", message: "This computer cannot run its native SSH key loader.") }
        guard loaded.code == 0 else {
            let said = loaded.stderr.lowercased()
            if said.contains("bad passphrase") || said.contains("incorrect passphrase") { throw BackendServersSSHAgentFailure(passphrase == nil ? "That key is locked. What is its passphrase?" : "That passphrase does not open the key.") }
            if said.contains("invalid format") || said.contains("error in libcrypto") || said.contains("unsupported") { throw BackendServersSSHAgentFailure("That does not look like a key. Paste the whole file, including its first and last lines.") }
            throw BackendServersSSHAgentFailure("That key could not be read.")
        }
        try Task.checkCancellation()
        // Extraction is a public-key query; it cannot output the private key.
        var publicEnvironment = BackendServersSSH.environment(); publicEnvironment["SSH_AUTH_SOCK"] = socket.path; publicEnvironment["APPLE_SSH_ADD_BEHAVIOR"] = "openssh"
        let list = privateProcess(executable: "/usr/bin/ssh-add", arguments: ["-L"], environment: publicEnvironment)
        try list.start(); defer { list.close() }
        let listed = try await list.collect(stdin: nil, timeoutMilliseconds: 5000, maximumOutputBytes: 65536)
        let rows = listed.stdout.split(separator: "\n").filter { !$0.isEmpty }
        guard listed.code == 0, !listed.truncated, rows.count == 1 else { throw BackendServersSSHAgentFailure("That key could not be read.") }
        let fields = rows[0].split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2, let publicKey = Data(base64Encoded: String(fields[1])), BackendServersConnections.algorithmOf(publicKey) == String(fields[0]) else { throw BackendServersSSHAgentFailure("That key could not be read.") }
        succeeded = true
        return .init(socket: socket, publicIdentity: String(rows[0]) + "\n", process: process)
    }
    private static func privateProcess(executable: String, arguments: [String], environment: [String: String]) -> BackendServersSSHProcess {
        // This constant launcher changes only the child core-dump limit. The
        // private key is stdin to ssh-add; this argv contains paths/flags only.
        .init(executable: URL(fileURLWithPath: "/bin/sh"),
              arguments: ["-c", "ulimit -c 0 || exit 1; exec \"$@\"", "native-private-crypto", executable] + arguments,
              environment: environment)
    }
    func close() { let first = lock.withLock { if closed { return false }; closed = true; return true }; if first { process.close() } }
    deinit { close() }
}
struct BackendServersSSHAgentFailure: Error, LocalizedError, Sendable {
    let sentence: String
    init(_ sentence: String) { self.sentence = sentence }
    var errorDescription: String? { sentence }
}
private final class BackendServersSSHAgentOpener: @unchecked Sendable {
    private let lock = NSLock(); private var value: String?
    init(_ value: String?) { self.value = value }
    func take() -> String? { lock.withLock { let answer = value; value = nil; return answer } }
}
