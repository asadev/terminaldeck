import Foundation
import CryptoKit
import Darwin
import TerminalDeckNativeCore

public struct BackendServersRunResult: Codable, Equatable, Sendable {
    public let code: Int?, signal: String?, stdout: String, stderr: String, truncated: Bool
    public init(code: Int?, signal: String? = nil, stdout: String, stderr: String = "", truncated: Bool = false) { self.code = code; self.signal = signal; self.stdout = stdout; self.stderr = stderr; self.truncated = truncated }
    private enum CodingKeys: String, CodingKey { case code, signal, stdout, stderr, truncated }
    public func encode(to encoder: any Encoder) throws {
        var record = encoder.container(keyedBy: CodingKeys.self)
        try record.encode(code, forKey: .code); try record.encode(signal, forKey: .signal)
        try record.encode(stdout, forKey: .stdout); try record.encode(stderr, forKey: .stderr); try record.encode(truncated, forKey: .truncated)
    }
}
public struct BackendServersTerminalSize: Codable, Equatable, Sendable {
    public let cols: Int, rows: Int
    public init(cols: Int, rows: Int) { self.cols = cols; self.rows = rows }
}
public struct BackendServersRemoteEntry: Codable, Equatable, Sendable {
    public let name: String, kind: String
    public init(name: String, kind: String) { self.name = name; self.kind = kind }
}
public struct BackendServersRemoteListing: Codable, Equatable, Sendable {
    public let path: String, entries: [BackendServersRemoteEntry]
    public init(path: String, entries: [BackendServersRemoteEntry]) { self.path = path; self.entries = entries }
}
public struct BackendServersRemoteBytes: Sendable, Equatable { public let bytes: Data; public let size: Int }
public struct BackendServersFollowEnd: Sendable, Equatable { public let code: Int?; public let stderr: String }
public typealias BackendServersUnsubscribe = @Sendable () -> Void
public protocol BackendServersFollow: AnyObject, Sendable {
    func onBytes(_ listener: @escaping @Sendable (Data) -> Void) -> BackendServersUnsubscribe
    func onEnd(_ listener: @escaping @Sendable (BackendServersFollowEnd) -> Void) -> BackendServersUnsubscribe
    func close()
}
public protocol BackendServersShell: AnyObject, Sendable {
    func onData(_ listener: @escaping @Sendable (String) -> Void) -> BackendServersUnsubscribe
    func onClose(_ listener: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe
    func write(_ data: String)
    func resize(_ size: BackendServersTerminalSize)
    func close()
}
public protocol BackendServersDuplex: AnyObject, Sendable {
    func onBytes(_ listener: @escaping @Sendable (Data) -> Void) -> BackendServersUnsubscribe
    func onEnd(_ listener: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe
    func onClose(_ listener: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe
    func write(_ bytes: Data) async throws
    func end() async throws
    func close()
    func pause()
    func resume()
}
public enum BackendServersReverseTarget: Sendable { case tcp(host: String, port: Int), unix(path: String) }
public protocol BackendServersReverseForward: AnyObject, Sendable {
    var port: Int { get }
    func activate(target: BackendServersReverseTarget) async throws
    func close()
}
public protocol BackendServersSFTP: AnyObject, Sendable {
    func realpath(_ path: String) async throws -> String
    func list(_ path: String) async throws -> [BackendServersRemoteEntry]
    func size(_ path: String) async throws -> Int
    func read(_ path: String, from: Int, length: Int) async throws -> Data
    func mkdir(_ path: String) async throws
    func put(localPath: String, remotePath: String) async throws
    func rename(_ from: String, to: String) async throws
    func unlink(_ path: String) async throws
    func close()
}
public protocol BackendServersConnection: AnyObject, Sendable {
    func exec(command: String, stdin: Data?, timeoutMilliseconds: Int, maximumOutputBytes: Int) async throws -> BackendServersRunResult
    /// Docker's fixed byte transport over this already authenticated connection.
    func dockerDialStdio() async throws -> any BackendServersDuplex
    func follow(command: String) async throws -> any BackendServersFollow
    func shell(size: BackendServersTerminalSize) async throws -> any BackendServersShell
    func openSFTP() async throws -> any BackendServersSFTP
    func forward(host: String, port: Int) async throws -> any BackendServersDuplex
    func reverseForward(bindAddress: String, bindPort: Int) async throws -> any BackendServersReverseForward
    func onClose(_ listener: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe
    func close()
}
public struct BackendServersSSHSignal: Error, LocalizedError, Sendable {
    public let level: String, code: String, message: String
    public init(level: String = "", code: String = "", message: String = "") { self.level = level; self.code = code; self.message = message }
    public var errorDescription: String? { message }
}
public struct BackendServersProblem: Error, LocalizedError, Sendable, Equatable {
    public let kind: String, sentence: String
    public let expected: String?, offered: String?
    public init(_ kind: String, _ sentence: String, expected: String? = nil, offered: String? = nil) { self.kind = kind; self.sentence = sentence; self.expected = expected; self.offered = offered }
    public var errorDescription: String? { sentence }
    public var wireValue: NativeRPCValue {
        var fields: [NativeRPCValue.Field] = [.init("ok", .bool(false)), .init("kind", .string(kind)), .init("sentence", .string(sentence))]
        if let expected, let offered { fields.append(.init("identity", .object([.init("expected", .string(expected)), .init("offered", .string(offered))]))) }
        return .object(fields)
    }
    public static func problemFor(_ error: Error?) -> Self {
        if let existing = error as? Self { return existing }
        let signal = error as? BackendServersSSHSignal
        let code = signal?.code ?? "", level = signal?.level ?? "", said = (signal?.message ?? error?.localizedDescription ?? "").lowercased()
        if ["ENOTFOUND", "EAI_AGAIN"].contains(code) || said.contains("could not resolve hostname") { return .init("no-such-address", "We cannot find a computer at that address. Check the address for a typo.") }
        if ["ECONNREFUSED", "EHOSTUNREACH", "ENETUNREACH"].contains(code) || said.contains("connection refused") || said.contains("no route to host") { return .init("no-answer", "That address did not answer. The server may be off, or something in between may be blocking it.") }
        if level == "client-timeout" || code == "ETIMEDOUT" || said.contains("timed out while") || said.contains("connection timed out") { return .init("no-answer", "That address did not answer in time. The server may be off, or something in between may be blocking it.") }
        if level == "client-authentication" || said.contains("authentication methods failed") || said.contains("permission denied (") { return .init("sign-in-refused", "That sign-in was refused. Check the username, and the password or key.") }
        if said.contains("before handshake") || said.contains("kex_exchange_identification: connection closed") { return .init("said-nothing", "Something answered at that address and then closed the connection without saying anything. A busy server does that, so try again in a moment — and if it keeps happening, whatever is listening there is not one we can sign in to.") }
        if level == "protocol" { return .init("not-a-server", "Something answered at that address, but it is not a server we can sign in to.") }
        if level == "handshake" || said.contains("no matching") { return .init("nothing-in-common", "This server is set up in a way this app cannot connect to.") }
        if said.contains("unsupported key") || said.contains("passphrase") || said.contains("invalid format") { return .init("key-unreadable", "That key could not be read.") }
        return .init("lost", "The connection to that server stopped. Nothing was left half-done — try again.")
    }
    public static func sftp(_ code: UInt32, path: String) -> Self {
        if code == 3 { return .init("not-allowed", "This sign-in is not allowed to read \(path).") }
        if code == 2 { return .init("no-such-folder", "There is nothing at \(path) on this server.") }
        return problemFor(nil)
    }
}
public protocol BackendServersSSHDialer: Sendable {
    func dial(server: BackendServersStoredServer, credential: BackendServersCredential,
              verifyHostKey: @escaping @Sendable (Data) throws -> Void) async throws -> any BackendServersConnection
}
/// A caller owns this generation, not whichever connection later reuses its ID.
public struct BackendServersConnectionLease: Equatable, Sendable {
    public let serverID: String, token: UUID
    public init(serverID: String, token: UUID) { self.serverID = serverID; self.token = token }
}

/// The only entry to authenticated server transport. No timer, automatic
/// reconnect, global SSH configuration, agent, or default identity is consulted.
public actor BackendServersConnections {
    public static let handshakeTimeoutMilliseconds = 20_000, commandTimeoutMilliseconds = 30_000, maximumOutputBytes = 4 * 1024 * 1024
    public static let identityChanged = "The computer at this address answered with a different identity than the last time this app connected. That can mean the server was rebuilt — or that something else is answering at that address. Nothing was sent to it."
    private let store: BackendServersStore, credentials: BackendServersCredentials, dialer: any BackendServersSSHDialer
    private let lifecycle: @Sendable (String, String) -> Void
    private struct Live { let token: UUID; let client: Task<any BackendServersConnection, Error>; var users: Int; var ready: (any BackendServersConnection)? }
    private var live: [String: Live] = [:]
    public init(store: BackendServersStore, credentials: BackendServersCredentials, dialer: any BackendServersSSHDialer,
                lifecycle: @escaping @Sendable (String, String) -> Void = { _, _ in }) { self.store = store; self.credentials = credentials; self.dialer = dialer; self.lifecycle = lifecycle }
    public static func quote(_ argument: String) -> String { "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    public static func fingerprintOf(_ key: Data) -> String { "SHA256:" + Data(SHA256.hash(data: key)).base64EncodedString().replacingOccurrences(of: "=", with: "") }
    public static func algorithmOf(_ key: Data) -> String {
        guard key.count >= 4 else { return "" }; let length = key.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= 64, key.count >= 4 + Int(length) else { return "" }
        return String(data: key[4..<(4 + Int(length))], encoding: .ascii) ?? ""
    }
    public func acquire(_ serverID: String) async throws { _ = try await acquireLease(serverID) }
    public func acquireLease(_ serverID: String) async throws -> BackendServersConnectionLease {
        if var entry = live[serverID] {
            entry.users += 1; live[serverID] = entry
            let lease = BackendServersConnectionLease(serverID: serverID, token: entry.token)
            do { _ = try await waitForDial(entry.client); try Task.checkCancellation(); guard live[serverID]?.token == entry.token else { throw CancellationError() }; return lease }
            catch { release(lease); throw error }
        }
        guard let server = try store.get(serverID) else { throw BackendServersProblem("unknown-server", "This app does not know a server by that name.") }
        guard let credential = try credentials.read(serverID) else { throw BackendServersProblem("no-sign-in", "There is no sign-in stored for this server yet. Add the password or key and try again.") }
        let token = UUID(), store = self.store, dialer = self.dialer
        let client = Task<any BackendServersConnection, Error> { [weak self] in
            let connection = try await dialer.dial(server: server, credential: credential) { key in
                let offered = Self.fingerprintOf(key)
                // Re-read immediately at verification. A deliberate forget or
                // an independently completed first use cannot race a stale pin.
                guard let current = try store.get(serverID) else { throw BackendServersProblem("unknown-server", "This app does not know a server by that name.") }
                if let expected = current.hostKey?.fingerprint {
                    guard expected == offered else { throw BackendServersProblem("identity-changed", Self.identityChanged, expected: expected, offered: offered) }
                } else if !(try store.rememberHostKey(serverID, algorithm: Self.algorithmOf(key), fingerprint: offered)) {
                    guard let expected = try store.get(serverID)?.hostKey?.fingerprint, expected == offered else {
                        throw BackendServersProblem("identity-changed", Self.identityChanged, expected: try store.get(serverID)?.hostKey?.fingerprint, offered: offered)
                    }
                }
            }
            do { guard try store.markConnected(serverID) else { throw BackendServersProblem("unknown-server", "This app does not know a server by that name.") } } catch { connection.close(); throw error }
            _ = connection.onClose { [weak self] in Task { await self?.dropped(serverID, token: token) } }
            guard let self, await self.publish(serverID, token: token, client: connection) else { connection.close(); throw CancellationError() }
            return connection
        }
        live[serverID] = .init(token: token, client: client, users: 1, ready: nil)
        do {
            let connection = try await waitForDial(client)
            try Task.checkCancellation()
            guard live[serverID]?.token == token else { connection.close(); throw CancellationError() }
            return .init(serverID: serverID, token: token)
        } catch {
            // A cancelled waiter must not hang up on another joined caller.
            if error is CancellationError { release(.init(serverID: serverID, token: token)) }
            else if live[serverID]?.token == token { live[serverID] = nil }
            if error is CancellationError { throw CancellationError() }
            if let unavailable = error as? NativeRPCError { throw unavailable }
            throw BackendServersProblem.problemFor(error)
        }
    }
    private func waitForDial(_ client: Task<any BackendServersConnection, Error>) async throws -> any BackendServersConnection {
        let answer = BackendServersSSHOnce<any BackendServersConnection>()
        let observer = Task { do { answer.finish(.success(try await client.value)) } catch { answer.finish(.failure(error)) } }
        defer { observer.cancel() }
        // Cancellation removes only this caller's reference in acquireLease's
        // catch. The shared dial lives until its last caller releases it.
        return try await withTaskCancellationHandler { try await answer.value() } onCancel: { answer.finish(.failure(CancellationError())) }
    }
    private func dropped(_ id: String, token: UUID) { if live[id]?.token == token { live[id] = nil; lifecycle(id, "dropped") } }
    private func publish(_ id: String, token: UUID, client: any BackendServersConnection) -> Bool {
        guard var entry = live[id], entry.token == token else { return false }; entry.ready = client; live[id] = entry; return true
    }
    public func release(_ lease: BackendServersConnectionLease) {
        guard live[lease.serverID]?.token == lease.token else { return }
        release(lease.serverID)
    }
    public func release(_ serverID: String) {
        guard var entry = live[serverID] else { return }; entry.users -= 1
        if entry.users > 0 { live[serverID] = entry; return }
        live[serverID] = nil; entry.client.cancel()
        lifecycle(serverID, "released")
        if let client = entry.ready { client.close() } else { Task { if let client = try? await entry.client.value { client.close() } } }
    }
    public func isOpen(_ serverID: String) -> Bool { live[serverID] != nil }
    /// Recovery pins the exact existing generation; a lease cannot authorize
    /// a reconnect or silently attach to a replacement server connection.
    public func isCurrent(_ lease: BackendServersConnectionLease) -> Bool {
        live[lease.serverID]?.token == lease.token && live[lease.serverID]?.ready != nil
    }
    /// Forget/revocation evicts every hold and any pending dial for this ID.
    public func closeServer(_ serverID: String) {
        guard let entry = live.removeValue(forKey: serverID) else { return }
        entry.client.cancel(); if let client = entry.ready { client.close() } else { Task { if let client = try? await entry.client.value { client.close() } } }
    }
    public func closeAll() { let old = live; live = [:]; for entry in old.values { entry.client.cancel(); if let client = entry.ready { client.close() } else { Task { if let client = try? await entry.client.value { client.close() } } } } }
    public func withConnection<T: Sendable>(_ serverID: String, body: @Sendable (any BackendServersConnection) async throws -> T) async throws -> T {
        let lease = try await acquireLease(serverID)
        defer { release(lease) }
        guard let entry = live[serverID], entry.token == lease.token else { throw BackendServersProblem("lost", "That connection is gone.") }
        let client = try await entry.client.value
        try Task.checkCancellation()
        return try await body(client)
    }
    /// Use a previously acquired generation without acquisition or redial.
    /// The holder already owns the reference and releases it after its scope.
    public func withConnection<T: Sendable>(_ lease: BackendServersConnectionLease,
                                           body: @Sendable (any BackendServersConnection) async throws -> T) async throws -> T {
        guard let entry = live[lease.serverID], entry.token == lease.token, let connection = entry.ready else {
            throw CancellationError()
        }
        try Task.checkCancellation()
        return try await body(connection)
    }
    public func run(_ serverID: String, argv: [String]) async throws -> BackendServersRunResult {
        guard !argv.isEmpty else { throw BackendServersProblem("lost", "There was no command to run.") }
        return try await withConnection(serverID) { try await $0.exec(command: argv.map(Self.quote).joined(separator: " "), stdin: nil, timeoutMilliseconds: Self.commandTimeoutMilliseconds, maximumOutputBytes: Self.maximumOutputBytes) }
    }
    public func runScript(_ serverID: String, script: String) async throws -> BackendServersRunResult {
        try await withConnection(serverID) { try await $0.exec(command: "sh -s", stdin: Data(script.utf8), timeoutMilliseconds: Self.commandTimeoutMilliseconds, maximumOutputBytes: Self.maximumOutputBytes) }
    }
    public func shell(_ serverID: String, size: BackendServersTerminalSize, startIn: String? = nil) async throws -> any BackendServersShell {
        let lease = try await acquireLease(serverID)
        do {
            guard let entry = live[serverID], entry.token == lease.token else { throw BackendServersProblem("lost", "That connection is gone.") }
            let client = try await entry.client.value
            let channel = try await client.shell(size: size)
            guard live[serverID]?.token == lease.token, !Task.isCancelled else { channel.close(); throw CancellationError() }
            let shell = BackendServersHeldShell(channel) { [weak self] in Task { await self?.release(lease) } }
            if let startIn, !startIn.isEmpty { shell.write("cd \(Self.quote(startIn))\n") }
            return shell
        } catch { release(lease); if error is CancellationError { throw CancellationError() }; if let unavailable = error as? NativeRPCError { throw unavailable }; throw BackendServersProblem.problemFor(error) }
    }
    public func follow(_ serverID: String, argv: [String]) async throws -> any BackendServersFollow {
        guard !argv.isEmpty else { throw BackendServersProblem("lost", "There was no command to run.") }
        let lease = try await acquireLease(serverID)
        do {
            guard let entry = live[serverID], entry.token == lease.token else { throw BackendServersProblem("lost", "That connection is gone.") }
            let client = try await entry.client.value
            let channel = try await client.follow(command: argv.map(Self.quote).joined(separator: " "))
            guard live[serverID]?.token == lease.token, !Task.isCancelled else { channel.close(); throw CancellationError() }
            return BackendServersHeldFollow(channel) { [weak self] in Task { await self?.release(lease) } }
        } catch { release(lease); if error is CancellationError { throw CancellationError() }; if let unavailable = error as? NativeRPCError { throw unavailable }; throw BackendServersProblem.problemFor(error) }
    }
    public func listDirectory(_ serverID: String, path: String) async throws -> BackendServersRemoteListing {
        try await withConnection(serverID) { client in
            let sftp = try await client.openSFTP(); defer { sftp.close() }
            let absolute = try await sftp.realpath(path.isEmpty ? "." : path)
            let entries = try await sftp.list(absolute)
            return .init(path: absolute, entries: entries.filter { $0.name != "." && $0.name != ".." })
        }
    }
    public func readFileRange(_ serverID: String, path: String, from: Int, length: Int) async throws -> BackendServersRemoteBytes {
        try await withConnection(serverID) { client in
            let sftp = try await client.openSFTP(); defer { sftp.close() }
            let size = try await sftp.size(path), start = max(0, from), count = max(0, min(length, size - start))
            return .init(bytes: count == 0 ? Data() : try await sftp.read(path, from: start, length: count), size: size)
        }
    }
    public func putFile(_ serverID: String, localPath: String, name: String, folder: String) async throws -> String {
        try await withConnection(serverID) { client in
            let sftp = try await client.openSFTP(); defer { sftp.close() }
            let trimmed = folder.replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
            let selected = folder.hasSuffix("/") && trimmed.isEmpty ? "/" : trimmed
            let directory: String
            if selected.hasPrefix("/") { directory = selected }
            else { let home = try await sftp.realpath("."); directory = selected.isEmpty || selected == "." ? home : Self.remoteJoin(home, selected) }
            if !(try await Self.exists(sftp, directory)) { try await sftp.mkdir(directory) }
            for candidate in BackendUploadNames.variants(BackendUploadNames.safeName(name)) {
                let target = Self.remoteJoin(directory, candidate)
                if try await Self.exists(sftp, target) { continue }
                let partial = target + ".part"
                do { try await sftp.put(localPath: localPath, remotePath: partial); try await sftp.rename(partial, to: target) }
                catch { try? await sftp.unlink(partial); throw error }
                return target
            }
            throw BackendServersProblem("lost", "Every variant of that file name is taken on that server.")
        }
    }
    static func remoteJoin(_ directory: String, _ name: String) -> String { directory.hasSuffix("/") ? directory + name : directory + "/" + name }
    private static func exists(_ sftp: any BackendServersSFTP, _ path: String) async throws -> Bool {
        do { _ = try await sftp.size(path); return true } catch let issue as BackendServersProblem where issue.kind == "no-such-folder" { return false }
    }
    /// A UI-selected destination is written by descriptor into a private
    /// partial and moved atomically. SFTP carries binary bytes without UTF-8.
    public func download(_ serverID: String, remotePath: String, localPath: String) async throws -> Int {
        try await withConnection(serverID) { client in
            let sftp = try await client.openSFTP(); defer { sftp.close() }
            let size = try await sftp.size(remotePath), target = URL(fileURLWithPath: localPath)
            let partial = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).\(UUID().uuidString).part")
            let fd = Darwin.open(partial.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw NativeRPCError(code: "unavailable", message: "The selected download destination could not be opened.") }
            defer { Darwin.close(fd); Darwin.unlink(partial.path) }
            var offset = 0
            while offset < size {
                try Task.checkCancellation()
                let bytes = try await sftp.read(remotePath, from: offset, length: min(64 * 1024, size - offset))
                guard !bytes.isEmpty else { throw BackendServersProblem("lost", "That server stopped sending the file before it was complete.") }
                try bytes.withUnsafeBytes { raw in var at = 0; while at < raw.count { let count = Darwin.write(fd, raw.baseAddress!.advanced(by: at), raw.count - at); if count < 0 && errno == EINTR { continue }; guard count > 0 else { throw NativeRPCError(code: "unavailable", message: "The selected download destination could not be written.") }; at += count } }
                offset += bytes.count
            }
            guard Darwin.fsync(fd) == 0 else { throw NativeRPCError(code: "unavailable", message: "The downloaded file could not be saved.") }
            // Exclusive final placement preserves any existing file chosen by
            // a concurrent delivery. The UI picks a free safe-name variant.
            guard Darwin.link(partial.path, target.path) == 0 else { throw NativeRPCError(code: "unavailable", message: "The selected download file already exists or could not be saved.") }
            return offset
        }
    }
}

private final class BackendServersReleaseOnce: @unchecked Sendable {
    private let lock = NSLock(); private var release: BackendServersUnsubscribe?
    init(_ release: @escaping BackendServersUnsubscribe) { self.release = release }
    func finish() { let release = lock.withLock { let old = self.release; self.release = nil; return old }; release?() }
    deinit { finish() }
}
private final class BackendServersHeldFollow: BackendServersFollow, @unchecked Sendable {
    private let channel: any BackendServersFollow, release: BackendServersReleaseOnce
    private var subscription: BackendServersUnsubscribe?
    init(_ channel: any BackendServersFollow, release: @escaping BackendServersUnsubscribe) { self.channel = channel; self.release = .init(release); let once = self.release; subscription = channel.onEnd { _ in once.finish() } }
    func onBytes(_ listener: @escaping @Sendable (Data) -> Void) -> BackendServersUnsubscribe { channel.onBytes(listener) }
    func onEnd(_ listener: @escaping @Sendable (BackendServersFollowEnd) -> Void) -> BackendServersUnsubscribe { channel.onEnd(listener) }
    func close() { channel.close(); release.finish() }
    deinit { subscription?(); channel.close(); release.finish() }
}
private final class BackendServersHeldShell: BackendServersShell, @unchecked Sendable {
    private let channel: any BackendServersShell, release: BackendServersReleaseOnce
    private var subscription: BackendServersUnsubscribe?
    init(_ channel: any BackendServersShell, release: @escaping BackendServersUnsubscribe) { self.channel = channel; self.release = .init(release); let once = self.release; subscription = channel.onClose { once.finish() } }
    func onData(_ listener: @escaping @Sendable (String) -> Void) -> BackendServersUnsubscribe { channel.onData(listener) }
    func onClose(_ listener: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe { channel.onClose(listener) }
    func write(_ data: String) { channel.write(data) }
    func resize(_ size: BackendServersTerminalSize) { channel.resize(size) }
    private let closeLock = NSLock(); private var closedChannel = false
    /// The channel is closed exactly once, however many of close(), the remote end and deinit get there.
    private func closeChannelOnce() { let first = closeLock.withLock { () -> Bool in if closedChannel { return false }; closedChannel = true; return true }; if first { channel.close() } }
    func close() { closeChannelOnce(); release.finish() }
    deinit { subscription?(); closeChannelOnce(); release.finish() }
}
