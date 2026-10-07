import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// Native equivalent of reach.ssh.test.ts. The final integration runner owns
/// the disposable SSH server and helper, because this implementation lane may
/// not build helpers, launch daemons, generate keys or probe installed tools.
/// This suite refuses a live/non-loopback fixture and is visibly disabled until
/// its explicit isolated fixture file is supplied; it does not fake SSH.
@Suite("Native server pages through real isolated SSH",
       .disabled("tests-port uses fake SSH streams and listener bindings; product SSH/process/socket execution is reserved for the combined runtime gate."))
struct BackendServersReachSSHTests {
    @Test func realSSHServesThePageDrains288KiBAndSharesOneTunnel() async throws {
        let fixture = try Fixture.read(), app = try fixture.application()
        defer { try? FileManager.default.removeItem(at: app.root) }
        async let first = app.reach.reach(app.id, port: fixture.sitePort)
        async let second = app.reach.reach(app.id, port: fixture.sitePort)
        let (one, two) = await (first, second)
        #expect(one["ok"].bool == true && one == two)
        let url = try #require(one["url"].string.flatMap(URL.init(string:)))
        let (bytes, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(bytes == Data(repeating: UInt8(ascii: "q"), count: 288 * 1024))
        #expect(one["port"].number == Double(fixture.sitePort))
        #expect(try app.store.get(app.id)?.hostKey?.fingerprint == fixture.hostFingerprint)
        #expect(await app.reach.openPorts(app.id) == [fixture.sitePort])
        _ = await app.reach.closeReach(app.id, port: fixture.sitePort)
        await app.reach.stop(); await app.pool.closeAll()
    }
    @Test func wrongPinSendsNoSignInAndDoesNotReplaceTheIdentity() async throws {
        let fixture = try Fixture.read(), app = try fixture.application()
        defer { try? FileManager.default.removeItem(at: app.root) }
        _ = try app.store.rememberHostKey(app.id, algorithm: "ssh-ed25519", fingerprint: "SHA256:deliberately-not-the-fixture-key")
        do { try await app.pool.acquire(app.id); Issue.record("Accepted wrong native SSH identity") }
        catch let issue as BackendServersProblem { #expect(issue.kind == "identity-changed" && issue.offered == fixture.hostFingerprint) }
        #expect(try app.store.get(app.id)?.hostKey?.fingerprint == "SHA256:deliberately-not-the-fixture-key")
        #expect(try app.store.get(app.id)?.lastConnectedAt == nil)
        await app.reach.stop(); await app.pool.closeAll()
    }
    @Test func actualSSHExecStdinAndBinarySFTPUseTheSameMaster() async throws {
        let fixture = try Fixture.read(), app = try fixture.application()
        defer { try? FileManager.default.removeItem(at: app.root) }
        try await app.pool.acquire(app.id)
        let result = try await app.pool.runScript(app.id, script: "printf '%s' 'é native stdin'\n")
        #expect(result.code == 0 && result.stdout == "é native stdin" && !result.truncated)
        let local = app.root.appendingPathComponent("synthetic.bin"), bytes = Data([0, 255, 2, 128, 10])
        try bytes.write(to: local)
        let uploaded = try await app.pool.putFile(app.id, localPath: local.path, name: "synthetic \(UUID().uuidString).bin", folder: fixture.remoteScratch)
        #expect(uploaded.hasPrefix(fixture.remoteScratch + "/"))
        let slice = try await app.pool.readFileRange(app.id, path: uploaded, from: 0, length: bytes.count)
        #expect(slice.bytes == bytes && slice.size == bytes.count)
        _ = try await app.pool.withConnection(app.id) { client in let sftp = try await client.openSFTP(); defer { sftp.close() }; try await sftp.unlink(uploaded); return true }
        await app.pool.release(app.id); await app.reach.stop(); await app.pool.closeAll()
    }
    @Test func actualKeyParserUsesPrivateHelperIPCForTheSyntheticLockedKey() async throws {
        let fixture = try Fixture.read(), ssh = BackendServersSSH(scratchRoot: fixture.localRoot.appendingPathComponent("parser"), policy: .init(mayConnect: false, helperExecutable: fixture.helper, helperDispatchInstalled: true))
        #expect(try await ssh.keyValidator().validate(fixture.keyText, fixture.opener) == nil)
        if fixture.opener != nil { #expect(try await ssh.keyValidator().validate(fixture.keyText, "deliberately-wrong") == "That passphrase does not open the key.") }
    }
    private struct Fixture: Decodable {
        let kind: String, address: String, sshPort: Int, username: String, keyText: String, opener: String?, hostFingerprint: String, sitePort: Int, remoteScratch: String, helperPath: String, localRootPath: String
        var helper: URL { URL(fileURLWithPath: helperPath) }; var localRoot: URL { URL(fileURLWithPath: localRootPath, isDirectory: true) }
        static func read() throws -> Self {
            let path = try #require(ProcessInfo.processInfo.environment["TERMINALDECK_SERVERS_TEST_FIXTURE"])
            let fixture = try JSONDecoder().decode(Self.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
            let root = fixture.localRoot.resolvingSymlinksInPath().path
            guard fixture.kind == "isolated-ssh-fixture", ["127.0.0.1", "::1"].contains(fixture.address),
                  (1024...65535).contains(fixture.sshPort), (1024...65535).contains(fixture.sitePort),
                  (root.hasPrefix(temporary + "/") || root.hasPrefix("/private/tmp/")), fixture.remoteScratch.hasPrefix("/"),
                  fixture.hostFingerprint.hasPrefix("SHA256:"), FileManager.default.isExecutableFile(atPath: fixture.helperPath) else {
                throw NativeRPCError.invalidArguments("The SSH test requires a disposable loopback server, synthetic key, signed native helper, and explicit temporary roots.")
            }
            return fixture
        }
        func application() throws -> Application {
            let root = localRoot.appendingPathComponent("c-" + UUID().uuidString.prefix(8)), store = BackendServersStore(dataRoot: root.appendingPathComponent("data"), policy: .init(mayRead: true, mayWrite: true))
            let ssh = BackendServersSSH(scratchRoot: root.appendingPathComponent("ssh"), policy: .init(mayConnect: true, helperExecutable: helper, helperDispatchInstalled: true))
            let cipher = BackendBrowserPasswordsCipher(available: { false }, decrypt: { _ in throw CancellationError() }, encrypt: { _, _ in throw CancellationError() })
            let credentials = BackendServersCredentials(dataRoot: root.appendingPathComponent("data"), cipher: cipher, policy: .init(mayRead: true, mayWrite: true), keyValidator: ssh.keyValidator())
            let server = try store.add(.init(name: "isolated fixture", address: address, port: sshPort, username: username))
            credentials.holdForSession(server.id, credential: .key(privateKey: keyText, passphrase: opener))
            let pool = BackendServersConnections(store: store, credentials: credentials, dialer: ssh)
            let reach = BackendServersReach(connections: pool, ownPorts: .init(), servers: { try store.list() }, facts: { id in BackendServersFacts(serverId: id, measuredAt: 1) }, tunnelsDropped: { _ in })
            return .init(root: root, id: server.id, store: store, pool: pool, reach: reach)
        }
    }
    private struct Application: Sendable { let root: URL, id: String, store: BackendServersStore, pool: BackendServersConnections, reach: BackendServersReach }
}
