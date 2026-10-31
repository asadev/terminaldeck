import Foundation
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

final class BackendServersTransportPortClock: @unchecked Sendable {
    private let lock = NSLock(); private var value: Double = 1000
    var now: Double { lock.withLock { value } }
    func advance(_ amount: Double) { lock.withLock { value += amount } }
}
final class BackendServersTransportPortEvents: @unchecked Sendable {
    private let lock = NSLock(); private var gates: [String: BackendServersSSHOnce<Bool>] = [:]
    func gate(_ name: String) -> BackendServersSSHOnce<Bool> { lock.withLock { if let existing = gates[name] { return existing }; let gate = BackendServersSSHOnce<Bool>(); gates[name] = gate; return gate } }
    func reset(_ name: String) { lock.withLock { gates[name] = BackendServersSSHOnce<Bool>() } }
    func receive(_ name: String) { gate(name).finish(.success(true)) }
}
final class BackendServersTransportPortFixture: @unchecked Sendable {
    let root: URL, store: BackendServersStore, credentials: BackendServersCredentials, pool: BackendServersConnections
    let dialer: BackendServersTransportPortDialer, clock: BackendServersTransportPortClock, events: BackendServersTransportPortEvents
    init(credential: BackendServersCredential? = .password("synthetic-one")) throws {
        let clock = BackendServersTransportPortClock(), events = BackendServersTransportPortEvents()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("transport-port-" + UUID().uuidString)
        let counter = BackendServersConnectionTestIDs()
        let store = BackendServersStore(dataRoot: root, policy: .init(mayRead: true, mayWrite: true), now: { clock.now }, makeID: { counter.next() })
        _ = try store.add(.init(name: "the box", address: "example.test", username: "ada"))
        let credentials = BackendServersCredentials(dataRoot: root, cipher: Self.cipher(), policy: .init(mayRead: true, mayWrite: true), keyValidator: .init { text, opener in
            if BackendServersKeyfiles.describeKey(text, name: "")?.locked == true { return opener == nil ? "That key is locked. What is its passphrase?" : opener == "opens" ? nil : "That passphrase does not open the key." }
            return text.hasPrefix("-----BEGIN") ? nil : "That does not look like a key. Paste the whole file, including its first and last lines."
        })
        if let credential { credentials.holdForSession("one", credential: credential) }
        let dialer = BackendServersTransportPortDialer()
        let pool = BackendServersConnections(store: store, credentials: credentials, dialer: dialer, lifecycle: { _, kind in events.receive(kind) })
        self.root = root; self.store = store; self.credentials = credentials; self.dialer = dialer; self.pool = pool; self.clock = clock; self.events = events
    }
    static func cipher(available: Bool = true) -> BackendBrowserPasswordsCipher { .init(available: { available }, decrypt: { String(decoding: $0.reversed(), as: UTF8.self) }, encrypt: { value, _ in Data(value.utf8.reversed()) }) }
    var client: BackendServersTransportPortClient { dialer.first }
    func cleanup() { credentials.close(); for client in dialer.clients { client.close() }; try? FileManager.default.removeItem(at: root) }
}
final class BackendServersTransportPortDialer: BackendServersSSHDialer, @unchecked Sendable {
    static let key = Data(base64Encoded: "AAAAC3NzaC1lZDI1NTE5AAAAIPUEO0mZueAVQxh2emvO8ztX7nRK0Eb6O6vD8/W+hSV9")!
    private let lock = NSLock(); private var made: [BackendServersTransportPortClient] = []
    var next = BackendServersTransportPortClient(), failure: BackendServersProblem?
    var clients: [BackendServersTransportPortClient] { lock.withLock { made } }
    var first: BackendServersTransportPortClient { lock.withLock { made.first ?? next } }
    func dial(server: BackendServersStoredServer, credential: BackendServersCredential, verifyHostKey: @escaping @Sendable (Data) throws -> Void) async throws -> any BackendServersConnection {
        if let failure { throw failure }; try verifyHostKey(Self.key)
        return lock.withLock { let current = next; made.append(current); next = BackendServersTransportPortClient(); return current }
    }
}
final class BackendServersTransportPortClient: BackendServersConnection, @unchecked Sendable {
    let sftp = BackendServersTransportPortSFTP(), shellStream = BackendServersTransportPortShell(), followed = BackendServersSSHProxyFollow(abortProxy: {})
    let closed = BackendServersSSHEvents<Bool>()
    var commands: [(String, Data?)] = [], closeCount = 0, answer = BackendServersRunResult(code: 0, stdout: ""), absentSFTP = false
    var forwarder: BackendServersForwarder = { _, _ in .opened(BackendServersForwardTestChannel()) }
    func exec(command: String, stdin: Data?, timeoutMilliseconds: Int, maximumOutputBytes: Int) async throws -> BackendServersRunResult { commands.append((command, stdin)); return answer }
    func follow(command: String) async throws -> any BackendServersFollow { commands.append((command, nil)); return followed }
    func shell(size: BackendServersTerminalSize) async throws -> any BackendServersShell { shellStream.resize(size); return shellStream }
    func openSFTP() async throws -> any BackendServersSFTP { if absentSFTP { throw BackendServersProblem("not-a-server", "This server will not let us list its folders. You can still type the path.") }; return sftp }
    func forward(host: String, port: Int) async throws -> any BackendServersDuplex { switch await forwarder(host, port) { case .opened(let channel): return channel; case .refused(let why, let message): throw BackendServersForwardError(refusal: why, message: message) } }
    func reverseForward(bindAddress: String, bindPort: Int) async throws -> any BackendServersReverseForward { throw NativeRPCError(code: "unavailable", message: "The fake does not need reverse forwarding.") }
    func onClose(_ listener: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe { closed.listen { _ in listener() } }
    func drop() { closed.send(true) }
    func close() { closeCount += 1 }
}
final class BackendServersTransportPortShell: BackendServersShell, @unchecked Sendable {
    let text = BackendServersSSHEvents<String>(), closed = BackendServersSSHEvents<Bool>(), decoder = BackendServersSSHUTF8()
    var size = BackendServersTerminalSize(cols: 80, rows: 24), writes: [String] = [], stopped = false
    func onData(_ listener: @escaping @Sendable (String) -> Void) -> BackendServersUnsubscribe { text.listen(listener) }
    func onClose(_ listener: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe { closed.listen { _ in listener() } }
    func bytes(_ bytes: Data) { let value = decoder.decode(bytes); if !value.isEmpty { text.send(value) } }
    func write(_ data: String) { writes.append(data) }
    func resize(_ size: BackendServersTerminalSize) { self.size = size }
    func close() { if !stopped { stopped = true; closed.send(true) } }
}
final class BackendServersTransportPortSFTP: BackendServersSFTP, @unchecked Sendable {
    var home = "/home/kiwi", present: Set<String> = [], refused: [String: UInt32] = [:], made: [String] = [], calls: [String] = []
    var puts: [(String, String)] = [], renames: [(String, String)] = [], unlinked: [String] = [], closeCount = 0, putFails = false
    func realpath(_ path: String) async throws -> String { calls.append("realpath \(path)"); return path == "." ? home : path }
    func list(_ path: String) async throws -> [BackendServersRemoteEntry] { [] }
    func size(_ path: String) async throws -> Int { calls.append("stat \(path)"); if let code = refused[path] { throw BackendServersProblem.sftp(code, path: path) }; if present.contains(path) { return 0 }; throw BackendServersProblem.sftp(2, path: path) }
    func read(_ path: String, from: Int, length: Int) async throws -> Data { Data() }
    func mkdir(_ path: String) async throws { calls.append("mkdir \(path)"); made.append(path); present.insert(path) }
    func put(localPath: String, remotePath: String) async throws { calls.append("put \(remotePath)"); puts.append((localPath, remotePath)); if putFails { throw BackendServersProblem("lost", "The connection to that server stopped.") }; present.insert(remotePath) }
    func rename(_ from: String, to: String) async throws { calls.append("rename \(from) \(to)"); renames.append((from, to)); present.remove(from); present.insert(to) }
    func unlink(_ path: String) async throws { unlinked.append(path); present.remove(path) }
    func close() { closeCount += 1 }
}
final class BackendServersTransportPortRecorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock(); private var recorded: [Value] = []
    func add(_ value: Value) { lock.withLock { recorded.append(value) } }
    var values: [Value] { lock.withLock { recorded } }
}
final class BackendServersTransportPortNetwork: @unchecked Sendable {
    private let lock = NSLock(); private var held: Set<Int> = []
    var occupiedIPv4: Set<Int> = [], occupiedIPv6: Set<Int> = []
    var network: BackendServersReachNetwork { .init(occupied: { [self] port, ipv6 in (ipv6 ? occupiedIPv6 : occupiedIPv4).contains(port) }, bind: { [self] port, _ in let selected = port == 0 ? 58000 : port; lock.withLock { held.insert(selected) }; return .init(localPort: selected, close: { [self] in _ = lock.withLock { held.remove(selected) } }) }) }
    var open: [Int] { lock.withLock { held.sorted() } }
}
