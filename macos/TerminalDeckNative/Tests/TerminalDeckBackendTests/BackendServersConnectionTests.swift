import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

@Suite("Server transport rules without a server")
struct BackendServersConnectionTests {
    @Test func argumentsFingerprintsAndAlgorithms() {
        #expect(BackendServersConnections.quote("a b") == "'a b'")
        #expect(BackendServersConnections.quote("it's") == "'it'\\''s'")
        #expect(BackendServersConnections.quote("$(reboot)") == "'$(reboot)'")
        #expect(BackendServersConnections.quote("`x`") == "'`x`'")
        let key = BackendServersConnectionTestDialer.key
        #expect(BackendServersConnections.algorithmOf(key) == "ssh-ed25519")
        #expect(BackendServersConnections.algorithmOf(Data([1, 2])) == "")
        #expect(BackendServersConnections.algorithmOf(Data(repeating: 0, count: 8)) == "")
        #expect(BackendServersConnections.fingerprintOf(key).hasPrefix("SHA256:"))
        #expect(!BackendServersConnections.fingerprintOf(key).contains("="))
    }
    @Test func transportResultEncodesExplicitNullableFields() throws {
        let result = BackendServersRunResult(code: nil, stdout: "")
        let raw = try NativeRPCValue.parseJSON(JSONEncoder().encode(result))
        #expect(raw["code"] == .null && raw["signal"] == .null)
        #expect(raw.fields?.map(\.key).sorted() == ["code", "signal", "stderr", "stdout", "truncated"])
    }
    @Test func errorSignalsPreserveExactRefusalsAndNeverGuessWrongHalf() {
        let cases: [(BackendServersSSHSignal, String)] = [(.init(code: "ENOTFOUND"), "no-such-address"), (.init(code: "ECONNREFUSED"), "no-answer"), (.init(level: "client-timeout"), "no-answer"), (.init(level: "client-authentication"), "sign-in-refused"), (.init(level: "protocol"), "not-a-server"), (.init(level: "protocol", message: "Connection lost before handshake"), "said-nothing"), (.init(level: "handshake", message: "no matching cipher"), "nothing-in-common"), (.init(message: "Unsupported key format"), "key-unreadable")]
        for (signal, kind) in cases { let issue = BackendServersProblem.problemFor(signal); #expect(issue.kind == kind && issue.sentence.hasSuffix(".")) }
        let login = BackendServersProblem.problemFor(BackendServersSSHSignal(level: "client-authentication"))
        #expect(login.sentence.contains("username") && login.sentence.contains("password or key") && !login.sentence.contains("is wrong"))
        #expect(BackendServersProblem.problemFor(BackendServersSSHSignal(message: "Connection lost before handshake")).sentence.contains("try again"))
        let original = BackendServersProblem("identity-changed", BackendServersConnections.identityChanged)
        #expect(BackendServersProblem.problemFor(original) == original)
        #expect(BackendServersProblem.problemFor(nil).kind == "lost")
    }
    @Test func refcountsOneDoorAndReleaseAfterThrow() async throws {
        let app = try makeApp(); defer { app.cleanup() }
        try await app.pool.acquire("one"); try await app.pool.acquire("one")
        #expect(app.dialer.count == 1 && app.client.closeCount == 0)
        await app.pool.release("one"); #expect(await app.pool.isOpen("one"))
        _ = try await app.pool.run("one", argv: ["echo", "a b", "$(reboot)"])
        #expect(app.dialer.count == 1 && app.client.commands.last?.0 == "'echo' 'a b' '$(reboot)'")
        await app.pool.release("one"); #expect(!(await app.pool.isOpen("one")))
        do { _ = try await app.pool.withConnection("one") { _ -> Bool in throw CancellationError() }; Issue.record("Did not throw") } catch {}
        #expect(!(await app.pool.isOpen("one")))
        await app.pool.closeAll()
    }
    @Test func unknownAndMissingCredentialNeverDial() async throws {
        let app = try makeApp(); defer { app.cleanup() }
        do { try await app.pool.acquire("unknown"); Issue.record("Dialed unknown") } catch let issue as BackendServersProblem { #expect(issue.kind == "unknown-server") }
        app.credentials.close()
        do { try await app.pool.acquire("one"); Issue.record("Dialed without sign-in") } catch let issue as BackendServersProblem { #expect(issue.kind == "no-sign-in") }
        #expect(app.dialer.count == 0)
    }
    @Test func changedIdentityStopsBeforeAuthenticationAndDoesNotReplacePin() async throws {
        let app = try makeApp(); defer { app.cleanup() }
        _ = try app.store.rememberHostKey("one", algorithm: "ssh-ed25519", fingerprint: "SHA256:original")
        do { try await app.pool.acquire("one"); Issue.record("Accepted changed identity") } catch let issue as BackendServersProblem {
            #expect(issue.kind == "identity-changed" && issue.expected == "SHA256:original" && issue.offered == BackendServersConnections.fingerprintOf(BackendServersConnectionTestDialer.key))
        }
        #expect(app.dialer.authenticatedIDs.isEmpty)
        #expect(try app.store.get("one")?.hostKey?.fingerprint == "SHA256:original")
    }
    @Test func credentialsNeverCrossServerIDs() async throws {
        let app = try makeApp(); defer { app.cleanup() }
        _ = try app.store.add(.init(name: "two", address: "second.example", username: "other"))
        let second = try app.store.list().last!
        app.credentials.holdForSession(second.id, credential: .key(privateKey: "only-server-two", passphrase: "two-opener"))
        _ = try await app.pool.run("one", argv: ["true"]); _ = try await app.pool.run(second.id, argv: ["true"])
        #expect(app.dialer.seen["one"] == .password("only-server-one"))
        #expect(app.dialer.seen[second.id] == .key(privateKey: "only-server-two", passphrase: "two-opener"))
        #expect(app.dialer.seen["unknown"] == nil)
        await app.pool.closeAll()
    }
    @Test func scriptIsStdinAndCommandResultRetainsAllFields() async throws {
        let app = try makeApp(); defer { app.cleanup() }
        let script = "printf '%s\\n' 'script that must be stdin'"
        let result = try await app.pool.runScript("one", script: script)
        #expect(app.client.commands.last?.0 == "sh -s" && app.client.commands.last?.1 == Data(script.utf8))
        #expect(result.code == 0 && result.signal == nil && !result.truncated)
        #expect(BackendServersConnections.commandTimeoutMilliseconds == 30_000 && BackendServersConnections.maximumOutputBytes == 4 * 1024 * 1024)
        do { _ = try await app.pool.run("one", argv: []); Issue.record("Ran empty command") } catch let issue as BackendServersProblem { #expect(issue.sentence == "There was no command to run.") }
    }
    @Test func bytesAndUnicodeBoundariesStayWhole() {
        let bytes = Data("before é🧭 after".utf8), decoder = BackendServersSSHUTF8()
        let text = decoder.decode(Data(bytes.prefix(8))) + decoder.decode(Data(bytes.dropFirst(8)))
        #expect(text == "before é🧭 after")
        let output = BackendServersSSHBuffer(maximum: 100)
        output.takeOutput(Data(bytes.prefix(8))); output.takeOutput(Data(bytes.dropFirst(8)))
        #expect(output.outputText == "before é🧭 after")
        let capped = BackendServersSSHBuffer(maximum: 3); capped.takeOutput(Data([1, 2, 3])); capped.takeError(Data([4])); #expect(capped.truncated)
    }
    @Test func shellSizeStartFolderAndFollowingReleaseExactlyOnce() async throws {
        let releases = AsyncStream<String>.makeStream()
        defer { releases.continuation.finish() }
        let app = try makeApp(lifecycle: { id, phase in
            if id == "one", phase == "released" { releases.continuation.yield(phase) }
        }); defer { app.cleanup() }
        func nextRelease() async throws -> String? {
            let result = BackendServersSSHOnce<String?>()
            let observer = Task {
                var iterator = releases.stream.makeAsyncIterator()
                result.finish(.success(await iterator.next()))
            }
            let timeout = Task {
                try await Task.sleep(for: .seconds(2))
                result.finish(.failure(BackendServersProblem("test-timeout", "The connection never published its release.")))
            }
            defer { observer.cancel(); timeout.cancel() }
            return try await result.value()
        }
        let shell = try await app.pool.shell("one", size: .init(cols: 91, rows: 33), startIn: "/my folder/$(reboot)")
        #expect(app.client.shellHandle.size == .init(cols: 91, rows: 33))
        #expect(app.client.shellHandle.writes == ["cd '/my folder/$(reboot)'\n"])
        shell.resize(.init(cols: 120, rows: 40)); #expect(app.client.shellHandle.size == .init(cols: 120, rows: 40))
        shell.close(); shell.close()
        #expect(try await nextRelease() == "released")
        #expect(!(await app.pool.isOpen("one")))
        #expect(app.client.closeCount == 1)
        let follow = try await app.pool.follow("one", argv: ["tail", "-f", "/my log"])
        #expect(app.client.followCommand == "'tail' '-f' '/my log'")
        #expect(await app.pool.isOpen("one"))
        follow.close(); follow.close()
        #expect(try await nextRelease() == "released")
        #expect(!(await app.pool.isOpen("one")))
        #expect(app.client.closeCount == 2)
    }
    @Test func listingRangesAndSafePartialDelivery() async throws {
        let app = try makeApp(); defer { app.cleanup() }
        app.client.sftpHandle.files["/home/custom/report.txt"] = Data("existing".utf8)
        let listing = try await app.pool.listDirectory("one", path: "")
        #expect(listing.path == "/home/custom" && listing.entries.map(\.name) == ["project with spaces", "link"])
        let range = try await app.pool.readFileRange("one", path: "/home/custom/report.txt", from: 1, length: 3)
        #expect(range.size == 8 && range.bytes == Data("xis".utf8))
        let placed = try await app.pool.putFile("one", localPath: "/explicit/source", name: "../../report.txt", folder: "")
        #expect(placed == "/home/custom/report (2).txt")
        #expect(app.client.sftpHandle.puts.last == "/home/custom/report (2).txt.part")
        #expect(app.client.sftpHandle.renames.last?.0 == "/home/custom/report (2).txt.part")
        #expect(app.client.sftpHandle.files["/home/custom/report.txt"] == Data("existing".utf8))
        #expect(app.client.sftpHandle.closeCount == 3)
        let rootPlaced = try await app.pool.putFile("one", localPath: "/explicit/source", name: "image.png", folder: "////")
        #expect(rootPlaced == "/image.png")
    }
    @Test func failedDeliveryCleansOnlyOwnPartialAndPermissionIsNotFreeName() async throws {
        let app = try makeApp(); defer { app.cleanup() }
        app.client.sftpHandle.failPut = true
        do { _ = try await app.pool.putFile("one", localPath: "/source", name: "a.jpg", folder: "/picked"); Issue.record("False transfer success") } catch {}
        #expect(app.client.sftpHandle.unlinked == ["/picked/a.jpg.part"])
        app.client.sftpHandle.failPut = false; app.client.sftpHandle.denied = "/private"
        do { _ = try await app.pool.putFile("one", localPath: "/source", name: "a.jpg", folder: "/private"); Issue.record("False permission success") } catch let issue as BackendServersProblem { #expect(issue.kind == "not-allowed") }
        #expect(app.client.sftpHandle.puts.count == 1)
    }
    @Test func binaryDownloadIsAtomicAndNeverOverwrites() async throws {
        let app = try makeApp(); defer { app.cleanup() }
        app.client.sftpHandle.files["/remote/binary"] = Data([0, 255, 1, 128])
        let target = app.root.appendingPathComponent("chosen.bin")
        #expect(try await app.pool.download("one", remotePath: "/remote/binary", localPath: target.path) == 4)
        #expect(try Data(contentsOf: target) == Data([0, 255, 1, 128]))
        do { _ = try await app.pool.download("one", remotePath: "/remote/binary", localPath: target.path); Issue.record("Overwrote existing destination") } catch {}
        #expect(try Data(contentsOf: target) == Data([0, 255, 1, 128]))
        #expect(try FileManager.default.contentsOfDirectory(atPath: app.root.path).allSatisfy { !$0.hasSuffix(".part") })
    }
    @Test func oldCommandReleaseCannotEvictANewerGeneration() async throws {
        let app = try makeApp(); defer { app.cleanup() }
        let entered = BackendServersSSHOnce<Bool>(), finish = BackendServersSSHOnce<Bool>()
        let old = Task { try await app.pool.withConnection("one") { _ in entered.finish(.success(true)); return try await finish.value() } }
        _ = try await entered.value()
        await app.pool.closeServer("one")
        let newer = try await app.pool.acquireLease("one")
        finish.finish(.success(true)); #expect(try await old.value)
        #expect(await app.pool.isOpen("one")); await app.pool.release(newer)
        #expect(!(await app.pool.isOpen("one")))
    }
    @Test func forcedCloseEvictsEveryLeaseAndStaleLeaseReleaseIsHarmless() async throws {
        let app = try makeApp(); defer { app.cleanup() }
        let first = try await app.pool.acquireLease("one"), second = try await app.pool.acquireLease("one")
        #expect(first.token == second.token)
        await app.pool.closeServer("one"); #expect(!(await app.pool.isOpen("one")))
        let fresh = try await app.pool.acquireLease("one")
        #expect(fresh.token != first.token)
        await app.pool.release(first); await app.pool.release(second)
        #expect(await app.pool.isOpen("one")); await app.pool.release(fresh)
    }
    private func makeApp(lifecycle: @escaping @Sendable (String, String) -> Void = { _, _ in }) throws -> BackendServersConnectionTestApp {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("servers-connection-" + UUID().uuidString), ids = BackendServersConnectionTestIDs()
        let store = BackendServersStore(dataRoot: root, policy: .init(mayRead: true, mayWrite: true), makeID: { ids.next() })
        _ = try store.add(.init(name: "one", address: "first.example", username: "root"))
        let cipher = BackendBrowserPasswordsCipher(available: { false }, decrypt: { _ in throw CancellationError() }, encrypt: { _, _ in throw CancellationError() })
        let credentials = BackendServersCredentials(dataRoot: root, cipher: cipher, policy: .init(mayRead: true, mayWrite: true), keyValidator: .init { _, _ in nil })
        credentials.holdForSession("one", credential: .password("only-server-one"))
        let client = BackendServersConnectionTestClient(), dialer = BackendServersConnectionTestDialer(client)
        return .init(root: root, store: store, credentials: credentials, client: client, dialer: dialer, pool: .init(store: store, credentials: credentials, dialer: dialer, lifecycle: lifecycle))
    }
}
struct BackendServersConnectionTestApp: Sendable {
    let root: URL, store: BackendServersStore, credentials: BackendServersCredentials, client: BackendServersConnectionTestClient, dialer: BackendServersConnectionTestDialer, pool: BackendServersConnections
    func cleanup() { client.close(); credentials.close(); try? FileManager.default.removeItem(at: root) }
}
final class BackendServersConnectionTestIDs: @unchecked Sendable { private let lock = NSLock(); private var count = 0; func next() -> String { lock.withLock { count += 1; return count == 1 ? "one" : "two-\(count)" } } }
final class BackendServersConnectionTestDialer: BackendServersSSHDialer, @unchecked Sendable {
    static let key = Data([0, 0, 0, 11]) + Data("ssh-ed25519".utf8) + Data(repeating: 7, count: 32)
    private let lock = NSLock(), client: BackendServersConnectionTestClient
    private var made = 0, signed: [String] = [], received: [String: BackendServersCredential] = [:]
    init(_ client: BackendServersConnectionTestClient) { self.client = client }
    var count: Int { lock.withLock { made } }; var authenticatedIDs: [String] { lock.withLock { signed } }; var seen: [String: BackendServersCredential] { lock.withLock { received } }
    func dial(server: BackendServersStoredServer, credential: BackendServersCredential, verifyHostKey: @escaping @Sendable (Data) throws -> Void) async throws -> any BackendServersConnection {
        lock.withLock { made += 1; received[server.id] = credential }; try verifyHostKey(Self.key); lock.withLock { signed.append(server.id) }; return client
    }
}
final class BackendServersConnectionTestClient: BackendServersConnection, @unchecked Sendable {
    let sftpHandle = BackendServersConnectionTestSFTP(), shellHandle = BackendServersConnectionTestShell(), followHandle = BackendServersConnectionTestFollow()
    private let lock = NSLock(); private var runs: [(String, Data?)] = [], closed = 0, followLine = ""
    private let closeEvents = BackendServersSSHEvents<Bool>()
    var commands: [(String, Data?)] { lock.withLock { runs } }; var closeCount: Int { lock.withLock { closed } }; var followCommand: String { lock.withLock { followLine } }
    func exec(command: String, stdin: Data?, timeoutMilliseconds: Int, maximumOutputBytes: Int) async throws -> BackendServersRunResult { lock.withLock { runs.append((command, stdin)) }; return .init(code: 0, stdout: "okay") }
    func follow(command: String) async throws -> any BackendServersFollow { lock.withLock { followLine = command }; return followHandle }
    func shell(size: BackendServersTerminalSize) async throws -> any BackendServersShell { shellHandle.resize(size); return shellHandle }
    func openSFTP() async throws -> any BackendServersSFTP { sftpHandle }
    func forward(host: String, port: Int) async throws -> any BackendServersDuplex { throw BackendServersForwardError(refusal: .unreachable, message: "connect failed") }
    func reverseForward(bindAddress: String, bindPort: Int) async throws -> any BackendServersReverseForward { throw CancellationError() }
    func onClose(_ listener: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe { closeEvents.listen { _ in listener() } }
    func close() { lock.withLock { closed += 1 } }
    func drop() { closeEvents.send(true) }
}
final class BackendServersConnectionTestShell: BackendServersShell, @unchecked Sendable {
    private let lock = NSLock(); private var dimensions = BackendServersTerminalSize(cols: 1, rows: 1), written: [String] = [], stopped = false
    private let closed = BackendServersSSHEvents<Bool>()
    var size: BackendServersTerminalSize { lock.withLock { dimensions } }; var writes: [String] { lock.withLock { written } }
    func onData(_ listener: @escaping @Sendable (String) -> Void) -> BackendServersUnsubscribe { {} }
    func onClose(_ listener: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe { closed.listen { _ in listener() } }
    func write(_ data: String) { lock.withLock { written.append(data) } }
    func resize(_ size: BackendServersTerminalSize) { lock.withLock { dimensions = size } }
    func close() { let first = lock.withLock { if stopped { return false }; stopped = true; return true }; if first { closed.send(true) } }
}
final class BackendServersConnectionTestFollow: BackendServersFollow, @unchecked Sendable {
    private let ended = BackendServersSSHEvents<BackendServersFollowEnd>(), lock = NSLock(); private var stopped = false
    func onBytes(_ listener: @escaping @Sendable (Data) -> Void) -> BackendServersUnsubscribe { {} }
    func onEnd(_ listener: @escaping @Sendable (BackendServersFollowEnd) -> Void) -> BackendServersUnsubscribe { ended.listen(listener) }
    func close() { let first = lock.withLock { if stopped { return false }; stopped = true; return true }; if first { ended.send(.init(code: nil, stderr: "stopped")) } }
}
final class BackendServersConnectionTestSFTP: BackendServersSFTP, @unchecked Sendable {
    var files: [String: Data] = [:], puts: [String] = [], renames: [(String, String)] = [], unlinked: [String] = [], made: [String] = []
    var closeCount = 0, failPut = false, denied: String?
    func realpath(_ path: String) async throws -> String { path == "." ? "/home/custom" : path }
    func list(_ path: String) async throws -> [BackendServersRemoteEntry] { [.init(name: ".", kind: "folder"), .init(name: "..", kind: "folder"), .init(name: "project with spaces", kind: "folder"), .init(name: "link", kind: "link")] }
    func size(_ path: String) async throws -> Int {
        if path == denied { throw BackendServersProblem.sftp(3, path: path) }
        if ["/", "/home/custom", "/picked"].contains(path) || made.contains(path) { return 0 }
        guard let bytes = files[path] else { throw BackendServersProblem.sftp(2, path: path) }; return bytes.count
    }
    func read(_ path: String, from: Int, length: Int) async throws -> Data { guard let bytes = files[path] else { throw BackendServersProblem.sftp(2, path: path) }; return Data(bytes.dropFirst(from).prefix(length)) }
    func mkdir(_ path: String) async throws { made.append(path) }
    func put(localPath: String, remotePath: String) async throws { puts.append(remotePath); files[remotePath] = Data([1]); if failPut { throw BackendServersProblem("lost", "write failed") } }
    func rename(_ from: String, to: String) async throws { renames.append((from, to)); files[to] = files.removeValue(forKey: from) }
    func unlink(_ path: String) async throws { unlinked.append(path); files[path] = nil }
    func close() { closeCount += 1 }
}
