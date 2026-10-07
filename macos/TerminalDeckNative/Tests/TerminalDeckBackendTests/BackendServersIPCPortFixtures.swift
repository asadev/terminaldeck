import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

// Source fixtures only: no real SSH, sockets, processes, timers or sleeps.
struct BackendServersIPCPortFixture: Sendable {
    let root: URL, store: BackendServersStore, credentials: BackendServersCredentials
    let client: BackendServersIPCPortClient, dialer: BackendServersIPCPortDialer, pool: BackendServersConnections
    let room: BackendServersCoordinator, shells: BackendServersShells, ipc: BackendServersIPC
    let audit: BackendServersIPCPortAudit, drives: BackendServersWindowDrives, reaches: BackendServersWindowReachPool
    let clock: BackendServersIPCPortClock
    let caller = BackendServersCaller(kind: .nativeUI, attended: true, context: .init(caller: .nativeApp, ownerID: "port-window"))
    init(secure: Bool = false, legacy: Bool = false, enabled: Bool = false,
         raw: String = BackendServersIPCPortClient.facts,
         help: String = "--mcp-config <file> --settings <file>", curl: String = "/usr/bin/curl",
         failure: (any Error & Sendable)? = nil, shellUnavailable: Bool = false, uploadUnavailable: Bool = false,
         uploadFailure: BackendServersProblem? = nil, channels: Int = 1, standing: (name: String, online: Bool)? = nil,
         fileJournal: Bool = false) throws {
        let root = BackendServersS4RealTemp.directory().appendingPathComponent("servers-ipc-port-" + UUID().uuidString), clock = BackendServersIPCPortClock(), audit = BackendServersIPCPortAudit()
        let store = BackendServersStore(dataRoot: root, policy: .init(mayRead: true, mayWrite: true), makeID: { "new-1" })
        if legacy {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data(#"{"version":1,"servers":[{"id":"s1","name":"Office PC","address":"100.69.56.25","port":2222,"username":"asad","credential":"password","hostKey":null,"addedAt":1,"lastConnectedAt":null}]}"#.utf8).write(to: root.appendingPathComponent("servers.json"))
        } else {
            // Write via real source store so every list field is actually persisted.
            let original = BackendServersStore(dataRoot: root, policy: .init(mayRead: true, mayWrite: true), makeID: { "s1" })
            _ = try original.add(.init(name: "demo", address: "example.test", username: "root"))
            _ = try original.setDrivesWindows("s1", allowed: enabled)
        }
        let cipher = BackendBrowserPasswordsCipher(available: { secure }, decrypt: { String(decoding: $0, as: UTF8.self) }, encrypt: { text, _ in Data(text.utf8) })
        let credentials = BackendServersCredentials(dataRoot: root, cipher: cipher, policy: .init(mayRead: true, mayWrite: true), keyValidator: .init { _, _ in "This key is locked or unreadable." })
        credentials.holdForSession("s1", credential: .password("fixture-only"))
        let agentRaw = raw == BackendServersIPCPortClient.facts && (enabled || legacy) ? raw.replacingOccurrences(of: "#agents ok\n", with: "#agents ok\nclaude\t/usr/bin/claude\t2.0.0\tyes\tme@example.test\n") : raw
        let client = BackendServersIPCPortClient(raw: agentRaw, help: help, curl: curl, failure: failure, shellUnavailable: shellUnavailable, uploadUnavailable: uploadUnavailable, uploadFailure: uploadFailure, channels: channels, repoSurvey: fileJournal)
        let dialer = BackendServersIPCPortDialer(client), pool = BackendServersConnections(store: store, credentials: credentials, dialer: dialer)
        let journal: any BackendServersWayBackJournal = fileJournal ? BackendServersFileJournal(storageDirectory: root, policy: .init(mayRead: true, mayWrite: true)) : BackendServersMemoryJournal()
        let room = BackendServersCoordinator(store: store, connections: pool, grants: .init(assistantName: "Hoot", now: { clock.now }, knows: { (try? store.get($0)) != nil }), journal: journal, storageDirectory: root, authorize: { _, request in await audit.authorize(request) }, download: nil, now: { clock.now })
        let reaches = BackendServersWindowReachPool(connections: pool, endpoint: { kind in kind == .control ? .port(5599) : .socketPath("/fixture/hook.sock") })
        let drives = BackendServersWindowDrives(.init(allowed: { (try? store.drivesWindows($0)) == true }, claudeOn: { id in (try await room.measured(id)).agents.value?.first { $0.id == .claude } }, run: { try await pool.run($0, argv: $1) }, runScript: { try await pool.runScript($0, script: $1) }, reach: { await reaches.reach($0, kind: $1) }, letGo: { await reaches.letGo($0, kind: $1) }, mint: { allowed in
            await audit.mint(allowed)
            return .init(configFor: { "{\"url\":\"" + $0 + "\"}" }, started: { shell, server in await audit.started(shell, server) }, drop: { await audit.dropped() })
        }, hookEndpoint: { "deadbeef" }, remoteContext: { name, opens in .init(pages: ["INDEX.md": "# \(name) \(opens)"], mapFor: { "read " + $0 + "/INDEX.md" }) }))
        let shells = BackendServersShells(room: room, connections: pool, store: store, hooks: .init(arm: { await drives.arm($0, shellId: $1).wireValue }, disarm: { await drives.disarm($0) }, cancelSetup: { await audit.cancelSetup($0) }, whyNot: { await drives.whyNot($0) }, belonging: { await drives.belonging($0)?.wireValue }, publish: { _, channel, value in await audit.publish(channel, value) }, report: { _ in }, controls: nil), now: { clock.now })
        let ipc = BackendServersIPC(room: room, shells: shells, store: store, credentials: credentials, keys: .init(keyRoot: root.appendingPathComponent("keys")), setups: .init(.init(runScript: { try await pool.runScript($0, script: $1) })), hosts: .init(.init(runScript: { try await pool.runScript($0, script: $1) }, hostPackage: { nil })), hooks: .init(resolve: { BackendServersCaller(kind: .nativeUI, attended: true, context: $0) }, pickKey: nil, uploadFile: { _, _, _ in }, uploadDirectory: { _, _ in "Terminal Deck" }, appVersion: { "0.10.3" }, linkStanding: { _ in standing }, redial: { await audit.redial($0) }, revokeWindows: { await drives.revoke($0) }, forgetReach: { _ in }))
        self.root = root; self.store = store; self.credentials = credentials; self.client = client; self.dialer = dialer; self.pool = pool; self.room = room; self.shells = shells; self.ipc = ipc; self.audit = audit; self.drives = drives; self.reaches = reaches; self.clock = clock
    }
    func call(_ channel: String, _ args: NativeRPCValue...) async throws -> NativeRPCValue { try await ipc.invoke(channel, arguments: args, context: caller.context) }
    func stop() async { await ipc.stop(); await drives.stop(); await reaches.stop() }
    func cleanup() { credentials.close(); try? FileManager.default.removeItem(at: root) }
}
final class BackendServersIPCPortClock: @unchecked Sendable {
    private let lock = NSLock(); private var at: Double = 1_000
    var now: Double { lock.withLock { at } }; func advance(_ by: Double) { lock.withLock { at += by } }
}
actor BackendServersIPCPortAudit {
    private var checks: [BackendServersAuthorization] = [], redials: [String] = [], allowed: [@Sendable () async -> Bool] = []
    private var bound: [(String, String)] = [], cancelled: [String] = [], dropCount = 0
    private let output: AsyncStream<(String, NativeRPCValue)>, emit: AsyncStream<(String, NativeRPCValue)>.Continuation
    private let dials: AsyncStream<String>, emitDial: AsyncStream<String>.Continuation
    init() { let p = AsyncStream<(String, NativeRPCValue)>.makeStream(); output = p.stream; emit = p.continuation; let d = AsyncStream<String>.makeStream(); dials = d.stream; emitDial = d.continuation }
    func authorize(_ r: BackendServersAuthorization) { checks.append(r) }
    func tiers() -> [BackendMCPTier] { checks.filter { $0.operation == "servers.control" }.map(\.tier) }
    func clearChecks() { checks = [] }
    func mint(_ gate: @escaping @Sendable () async -> Bool) { allowed.append(gate) }
    func grantsAllowed() async -> [Bool] { var values: [Bool] = []; for gate in allowed { values.append(await gate()) }; return values }
    func started(_ shell: String, _ server: String) { bound.append((shell, server)) }; func dropped() { dropCount += 1 }
    func cancelSetup(_ server: String) { cancelled.append(server) }
    func publish(_ channel: String, _ value: NativeRPCValue) { emit.yield((channel, value)) }
    func nextOutput() async -> (String, NativeRPCValue)? { var iterator = output.makeAsyncIterator(); return await iterator.next() }
    func redial(_ host: String) { redials.append(host); emitDial.yield(host) }
    func nextRedial() async -> String? { var iterator = dials.makeAsyncIterator(); return await iterator.next() }
    func redialled() -> [String] { redials }
}
final class BackendServersIPCPortDialer: BackendServersSSHDialer, @unchecked Sendable {
    private let client: BackendServersIPCPortClient, lock = NSLock(); private var countValue = 0
    init(_ client: BackendServersIPCPortClient) { self.client = client }
    var count: Int { lock.withLock { countValue } }
    func dial(server: BackendServersStoredServer, credential: BackendServersCredential, verifyHostKey: @escaping @Sendable (Data) throws -> Void) async throws -> any BackendServersConnection {
        lock.withLock { countValue += 1 }; if let failure = client.dialFailure { throw failure }; try verifyHostKey(BackendServersConnectionTestDialer.key); return client
    }
}
final class BackendServersIPCPortClient: BackendServersConnection, @unchecked Sendable {
    static let facts = "schema=1\nos=Ubuntu 24.04.4 LTS\nroot=yes\ninit=systemd\ncontainers=\n#services ok\nmine.service\tactive\trunning\tMine\n#adminunits ok\nmine.service\n#agents ok\n#end ok\n"
    let sftp = BackendServersConnectionTestSFTP(), shellHandle = BackendServersIPCPortShell()
    private let lock = NSLock(), raw: String, help: String, curl: String, shellUnavailable: Bool, uploadUnavailable: Bool, uploadFailure: BackendServersProblem?, channels: Int
    private let failure: (any Error & Sendable)?
    private let repoSurvey: Bool; var dialFailure: BackendServersProblem?
    private var commandsValue: [String] = [], scriptsValue: [String] = [], probesValue = 0, forwardsValue: [BackendServersWindowTestLease] = []
    init(raw: String, help: String, curl: String, failure: (any Error & Sendable)?, shellUnavailable: Bool, uploadUnavailable: Bool, uploadFailure: BackendServersProblem?, channels: Int, repoSurvey: Bool) { self.raw = raw; self.help = help; self.curl = curl; self.failure = failure; self.shellUnavailable = shellUnavailable; self.uploadUnavailable = uploadUnavailable; self.uploadFailure = uploadFailure; self.channels = channels; self.repoSurvey = repoSurvey }
    var commands: [String] { lock.withLock { commandsValue } }; var scripts: [String] { lock.withLock { scriptsValue } }; var probes: Int { lock.withLock { probesValue } }; var forwards: [BackendServersWindowTestLease] { lock.withLock { forwardsValue } }
    func exec(command: String, stdin: Data?, timeoutMilliseconds: Int, maximumOutputBytes: Int) async throws -> BackendServersRunResult {
        if let stdin { let script = String(decoding: stdin, as: UTF8.self); lock.withLock { scriptsValue.append(script) }
            if script == BackendServersProbe.script { lock.withLock { probesValue += 1 }; if let failure { throw failure }; return .init(code: 0, stdout: raw) }
            if script.contains("command -v ss") { return .init(code: 0, stdout: "loopback\n") }
            if script.contains("mktemp -d") { return .init(code: 0, stdout: "TD_SCOUTED\n/tmp/td-drive-abc123\n/bin/bash\n\(curl)\n\n/usr/bin/xdg-open\n\n") }
            if script.contains("--- status ---") { return .init(code: 0, stdout: "command\t/home/asad/.local/bin/terminaldeck\nversion\t0.9.1\nos\tLinux\narch\tx86_64\nnode\tv22.23.2\nnpm\t/usr/bin/npm\ntar\tyes\nhash\tsha256sum\nfetch\tcurl\nhome_free_kb\t32439968\nstate_dir\t/home/asad/.local/share/terminaldeck\n--- status ---\nTerminal Deck host 0.9.1 — running, idle\n\nRelay\n  connected      wss://relay.terminaldeck.dev\n  host id        KZ2J9AWGK8BWGQUEZDYKW5RS22\n  fingerprint    NW76-TCC7-DKFD-AGVD-MBGK-W28U\n  channels       \(channels)\n") }
            return .init(code: 0, stdout: repoSurvey ? "##compose-available\nno\n##repos\nmine.service\t/opt/mine\n" : "##compose-available\nno\n")
        }
        lock.withLock { commandsValue.append(command) }
        return .init(code: 0, stdout: command.contains("journalctl") ? "line one\nline two\n" : command.contains("--help") ? help : command.contains("rev-parse") ? String(repeating: "d", count: 40) + "\n" : "")
    }
    func shell(size: BackendServersTerminalSize) async throws -> any BackendServersShell { if shellUnavailable { throw NativeRPCError(code: "unavailable", message: "This copy of the app can’t open a terminal on a server.") }; shellHandle.resize(size); return shellHandle }
    func openSFTP() async throws -> any BackendServersSFTP { if let uploadFailure { throw uploadFailure }; if uploadUnavailable { throw NativeRPCError(code: "unavailable", message: "This app cannot put a file on this server.") }; return sftp }
    func reverseForward(bindAddress: String, bindPort: Int) async throws -> any BackendServersReverseForward { lock.withLock { let lease = BackendServersWindowTestLease(port: 40404 + forwardsValue.count); forwardsValue.append(lease); return lease } }
    func follow(command: String) async throws -> any BackendServersFollow { throw NativeRPCError(code: "unavailable", message: "Fixture has no follow") }
    func forward(host: String, port: Int) async throws -> any BackendServersDuplex { throw NativeRPCError(code: "unavailable", message: "Fixture has no TCP") }
    func onClose(_ listener: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe { {} }; func close() {}
}
final class BackendServersIPCPortShell: BackendServersShell, @unchecked Sendable {
    private let lock = NSLock(), data = BackendServersSSHEvents<String>(), end = BackendServersSSHEvents<Bool>()
    private var closed = 0, writesValue: [String] = [], sizesValue: [BackendServersTerminalSize] = []
    var closeCount: Int { lock.withLock { closed } }; var writes: [String] { lock.withLock { writesValue } }; var sizes: [BackendServersTerminalSize] { lock.withLock { sizesValue } }
    func onData(_ listener: @escaping @Sendable (String) -> Void) -> BackendServersUnsubscribe { data.listen(listener) }
    func onClose(_ listener: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe { end.listen { _ in listener() } }
    func emit(_ text: String) { data.send(text) }; func write(_ text: String) { lock.withLock { writesValue.append(text) } }; func resize(_ size: BackendServersTerminalSize) { lock.withLock { sizesValue.append(size) } }
    func close() { lock.withLock { closed += 1 }; end.send(true) }
}
