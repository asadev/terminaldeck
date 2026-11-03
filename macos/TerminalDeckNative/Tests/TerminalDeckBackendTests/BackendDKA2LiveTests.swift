import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// DKA2 opt-in live proof, READ ONLY. Runs only with TD_DKA2_LIVE=terminaldeck-server
/// (the demo box; every other name is refused) and TD_DKA2_HELPER naming the built
/// helper. It signs in exactly as the app does for a server added from SSH settings:
/// the real BackendServersSSH dialer with the person's own ~/.ssh/config and key
/// files (ssh reads them; this code never does), then reads Docker over the real
/// dial-stdio transport. Nothing on the server is created, changed or removed.
final class BackendDKA2LiveTests: XCTestCase {
    func testSSHSettingsServerReadsDockerAndLookOnlyRefusesChanges() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let alias = environment["TD_DKA2_LIVE"] else { throw XCTSkip("Live DKA2 check is opt-in.") }
        guard alias == "terminaldeck-server" else { XCTFail("Only the demo server may be used for this live check."); return }
        let helper = URL(fileURLWithPath: try XCTUnwrap(environment["TD_DKA2_HELPER"], "TD_DKA2_HELPER"))
        let root = BackendServersS4RealTemp.directory().appendingPathComponent("dka2-live-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = BackendServersStoragePolicy(mayRead: true, mayWrite: true)
        let store = BackendServersStore(dataRoot: root, policy: policy)
        let cipher = BackendBrowserPasswordsCipher(available: { false }, decrypt: { String(decoding: $0, as: UTF8.self) }, encrypt: { text, _ in Data(text.utf8) })
        // ssh's control socket path must stay under 104 bytes, so the scratch root is short.
        let scratch = URL(fileURLWithPath: "/private/tmp/dka2l-" + UUID().uuidString.prefix(6), isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let ssh = BackendServersSSH(scratchRoot: scratch,
            policy: .init(mayConnect: true, helperExecutable: helper, helperDispatchInstalled: FileManager.default.isExecutableFile(atPath: helper.path)),
            sshHome: FileManager.default.homeDirectoryForCurrentUser, agentSocket: BackendServersSSH.personAgentSocket())
        let credentials = BackendServersCredentials(dataRoot: root, cipher: cipher, policy: policy, keyValidator: ssh.keyValidator())
        let connections = BackendServersConnections(store: store, credentials: credentials, dialer: ssh)
        let resolved = try await BackendDockerMCPServerSSHConfig().resolve(alias: alias, home: FileManager.default.homeDirectoryForCurrentUser)
        let row = try store.add(.init(name: alias, address: resolved.hostname, port: resolved.port, username: resolved.user), sshAlias: alias, lookOnly: true)

        let started = Date()
        let lease = try await connections.acquireLease(row.id)
        let pinned = try XCTUnwrap(try store.get(row.id)?.hostKey?.fingerprint, "the host key is pinned on first use")
        let client = BackendDockerClient(transport: BackendDockerSSHTransport(openDialStdio: { command in
            guard command == BackendDockerSSHTransport.command else { throw NativeRPCError(code: "access-denied", message: "fixed command only") }
            return try await connections.dockerDialStdio(row.id)
        }))
        let status = try await client.status()
        let containers = try await client.listContainers(all: true)
        let images = try await client.listImages()
        let volumes = try await client.listVolumes()
        let networks = try await client.listNetworks()

        // Look only, through the real coordinator: a change is refused before approval or I/O.
        let room = BackendServersCoordinator(store: store, connections: connections,
            grants: .init(assistantName: "Hoot", knows: { (try? store.get($0)) != nil }), journal: BackendServersMemoryJournal(),
            storageDirectory: root, authorize: { _, _ in }, download: nil)
        let window = BackendServersCaller(kind: .nativeUI, attended: true, context: .init(caller: .nativeApp, ownerID: "dka2-live"))
        var refused = false
        do { try await room.check(window, .init(operation: "servers.control", serverId: row.id, tier: .alter)) }
        catch let error as NativeRPCError { refused = error.message.contains("Look only") }
        try await room.check(window, .init(operation: "servers:look", serverId: row.id, tier: .read))
        XCTAssertTrue(refused)

        await connections.release(lease)
        await connections.closeAll()
        let record: NativeRPCValue = .object([
            .init("at", .string(ISO8601DateFormatter().string(from: started))), .init("alias", .string(alias)),
            .init("signIn", .string("ssh-config (own ~/.ssh/config and key files; nothing copied)")),
            .init("hostKeyPinned", .string(pinned)), .init("dockerVersion", .string(status.version)),
            .init("containers", .array(containers.map { .string($0.name) })), .init("images", .number(Double(images.count))),
            .init("volumes", .number(Double(volumes.count))), .init("networks", .array(networks.map { .string($0.name) })),
            .init("lookOnlyRefusedChange", .bool(refused)), .init("serverMutations", .number(0)),
            .init("seconds", .number((Date().timeIntervalSince(started) * 10).rounded() / 10))])
        print("DKA2-LIVE " + String(decoding: try record.encodedJSON(), as: UTF8.self))
        XCTAssertFalse(status.version.isEmpty)
    }
}

/// Regression (DKA2): FileHandle.read(upToCount:) waited for a full 8 KB on a
/// pipe, so ssh's short "Entering interactive session." line from a master that
/// keeps running was never delivered and every sign-in timed out.
final class BackendDKA2ProcessReadyTests: XCTestCase {
    func testReadyMarkerOnStderrIsSeenWhileTheProcessKeepsRunning() async throws {
        let child = BackendServersSSHProcess(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf 'debug1: one\\r\\ndebug1: Entering interactive session.\\r\\n' >&2; sleep 20"], environment: ["PATH": "/usr/bin:/bin"])
        defer { child.close() }
        try child.start()
        let started = Date()
        try await child.ready(marker: "Entering interactive session.", timeoutMilliseconds: 5_000)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }
}
