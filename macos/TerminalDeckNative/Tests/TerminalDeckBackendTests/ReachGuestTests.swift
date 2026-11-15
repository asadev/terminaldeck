import Foundation
import CryptoKit
import Network
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// Live use from another Mac (15 Nov, live-use-plan.md steps 2-3): this Mac reaches his other machines by sign-in, as
/// his phones do. Its own reach key (registered once per device id), the account's machines (only signed ones are
/// dialled), the relay token on the join, the `reach:<deviceId>` hello, the `machine` header and the rows' `tab`;
/// a fake service and a fake relay on this machine's loopback (it plays the other Mac's side of the sealed channel).
@Suite("Live use from another Mac: his other machines, reached by sign-in")
struct ReachGuestTests {
    static let macId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
    static let miniId = "11111111-2222-4333-8444-555555555555"
    static let pcId = "22222222-3333-4444-8555-666666666666"
    static let hostId = "ABCDEFGHJKLMNPQRSTUVWXYZ23"
    static let ref = "0123456789abcdef0123456789abcdef"

    final class Clock: @unchecked Sendable {
        private let lock = NSLock(); private var ms: Double = 1_800_000_000_000
        var now: Double { lock.withLock { ms } }
        func advance(_ by: Double) { lock.withLock { ms += by } }
    }

    final class FakeService: BackendReachGuestService, @unchecked Sendable {
        private let lock = NSLock()
        private var _deviceId: String? = ReachGuestTests.macId
        private var _registered: [(String, String)] = []
        private var _machines: [BackendReachMachine] = []
        private var _tokens = 0
        var scope = "reach"
        /// The service's refusal code for the next registrations (nil: accepted).
        var refuse: String?
        let clock: Clock
        init(clock: Clock) { self.clock = clock }
        func set(deviceId: String?) { lock.withLock { _deviceId = deviceId } }
        func set(machines: [BackendReachMachine]) { lock.withLock { _machines = machines } }
        var registered: [(String, String)] { lock.withLock { _registered } }
        var tokens: Int { lock.withLock { _tokens } }
        func machineDeviceId() async -> String? { lock.withLock { _deviceId } }
        func registerReachKey(deviceId: String, publicKey: String) async throws {
            if let refuse { throw CloudFailure.remote(.init(code: refuse, message: refuse, retryable: false, requestId: "")) }
            lock.withLock { _registered.append((deviceId, publicKey)) }
        }
        func reachMachines() async throws -> [BackendReachMachine] { lock.withLock { _machines } }
        func relayToken() async throws -> BackendReachRelayToken {
            let scope = self.scope
            return lock.withLock { _tokens += 1; return .init(token: "h.p.\(_tokens)", expiresAtMs: clock.now + 900_000, scope: scope) }
        }
    }

    /// One `/v1/reach/machines` row, signed by the machine's own P-256 key as the service keeps it.
    static func row(_ id: String, sign: P256.Signing.PrivateKey, host: BackendSealedIdentity, name: String = "Mac mini",
                    platform: String = "macos", online: Bool = true, isSelf: Bool = false, signedAt: Int64 = 1_800_000_000_000) throws -> NativeRPCValue {
        let hostKey = BackendReachWire.base64url(host.publicKey)
        let record = BackendReachPresenceRecord(deviceId: id, hostId: hostId, hostKey: hostKey, name: name, platform: platform, policy: .accountOnly)
        let sig = try sign.signature(for: Data(BackendReachWire.presenceMessage(record, signedAt: signedAt).utf8)).rawRepresentation
        let point = sign.publicKey.x963Representation
        return .object([.init("deviceId", .string(id)), .init("hostId", .string(hostId)), .init("hostKey", .string(hostKey)), .init("name", .string(name)),
            .init("displayName", .string(name)), .init("platform", .string(platform)), .init("policy", .string("A")), .init("signedAt", .number(Double(signedAt))),
            .init("sig", .string(BackendReachWire.base64url(sig))), .init("online", .bool(online)), .init("self", .bool(isSelf)),
            .init("signPublicJwk", .object([.init("kty", .string("EC")), .init("crv", .string("P-256")),
                .init("x", .string(BackendReachWire.base64url(point[1..<33]))), .init("y", .string(BackendReachWire.base64url(point[33..<65])))]))])
    }
    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reach-guest-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    @Test("The account's machines are read; only a record signed by the machine's own key is ever dialled")
    func machineList() throws {
        let sign = P256.Signing.PrivateKey(), host = BackendSealedIdentity.generate()
        var tampered = try Self.row(Self.pcId, sign: sign, host: host, name: "Office PC")
        tampered = tampered.setting("name", .string("Someone else"))
        let list = BackendReachMachine.list(.object([.init("machines", .array([
            try Self.row(Self.miniId, sign: sign, host: host), tampered,
            .object([.init("deviceId", .string("not-a-device")), .init("hostId", .string(Self.hostId))]),
        ]))]))
        #expect(list.map(\.deviceId) == [Self.miniId, Self.pcId])
        #expect(list[0].presenceValid && list[0].hostKey == host.publicKey && list[0].shownName == "Mac mini")
        #expect(!list[1].presenceValid)
        #expect(BackendReachMachine.bare("Studio.local") == "Studio")
    }

    @Test("Dialled: on, not this Mac, a computer, signed; a page's machine name narrows it, else every machine on")
    func reachableAndChoice() async throws {
        let clock = Clock(), service = FakeService(clock: clock), sign = P256.Signing.PrivateKey(), host = BackendSealedIdentity.generate()
        var bad = try Self.row("33333333-4444-4555-8666-777777777777", sign: sign, host: host, name: "Bad")
        bad = bad.setting("hostKey", .string(BackendReachWire.base64url(BackendSealedIdentity.generate().publicKey)))
        service.set(machines: BackendReachMachine.list(.object([.init("machines", .array([
            try Self.row(Self.miniId, sign: sign, host: host, name: "Mac mini"),
            try Self.row(Self.pcId, sign: sign, host: host, name: "Office PC", platform: "windows"),
            try Self.row(Self.macId, sign: sign, host: host, name: "MacBook", isSelf: true),
            try Self.row("44444444-5555-4666-8777-888888888888", sign: sign, host: host, name: "Off", online: false),
            try Self.row("55555555-6666-4777-8888-999999999999", sign: sign, host: host, name: "Phone", platform: "ios"), bad,
        ]))])))
        let guest = BackendReachGuest(service: service, directory: try Self.folder(), relayURL: "wss://relay.example.test", now: { clock.now })
        let reachable = try await guest.reachable()
        #expect(reachable.map(\.shownName) == ["Mac mini", "Office PC"])
        #expect(BackendMachineCoordinator.reachChoice(reachable, name: "Mac mini.local", deviceIds: nil).map(\.deviceId) == [Self.miniId])
        #expect(BackendMachineCoordinator.reachChoice(reachable, name: "Renamed in the Cloud", deviceIds: nil).count == 2)
        #expect(BackendMachineCoordinator.reachChoice(reachable, name: nil, deviceIds: [Self.pcId]).map(\.deviceId) == [Self.pcId])
    }

    @Test("Its reach key is registered once per device id, kept across restarts, and a new device id gets a new key")
    func keyOncePerDevice() async throws {
        let clock = Clock(), service = FakeService(clock: clock), folder = try Self.folder()
        let first = BackendReachGuest(service: service, directory: folder, relayURL: "wss://relay.example.test", now: { clock.now })
        let a = try await first.prepare(), again = try await first.prepare()
        #expect(a.deviceId == Self.macId && a.identity.publicKey == again.identity.publicKey)
        #expect(service.registered.count == 1 && service.registered[0].1 == BackendReachWire.base64url(a.identity.publicKey))
        // The app started again: the same key, no second registration.
        let restarted = BackendReachGuest(service: service, directory: folder, relayURL: "wss://relay.example.test", now: { clock.now })
        #expect(try await restarted.prepare().identity.publicKey == a.identity.publicKey && service.registered.count == 1)
        // This Mac came back as a new device of the account: a new key goes with it.
        service.set(deviceId: Self.pcId)
        let renewed = try await restarted.prepare()
        #expect(renewed.identity.publicKey != a.identity.publicKey && service.registered.count == 2 && service.registered[1].0 == Self.pcId)
        // Signed out: nothing to dial with.
        service.set(deviceId: nil)
        await #expect(throws: BackendReachFailure.self) { _ = try await restarted.prepare() }
        // The key file is owner-only.
        let mode = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("reach-guest-key.json").path)[.posixPermissions] as? Int
        #expect(mode.map { $0 & 0o077 } == 0)
    }

    @Test("An unreadable key file and a service that keeps the old key: refused, and said in one plain line, not only a log")
    func keyRefusedIsSaid() async throws {
        let clock = Clock(), service = FakeService(clock: clock), folder = try Self.folder()
        let guest = BackendReachGuest(service: service, directory: folder, relayURL: "wss://relay.example.test", now: { clock.now })
        _ = try await guest.prepare()
        // The key file is damaged; a new key is made for the same device id and the service refuses it.
        try Data("not json".utf8).write(to: folder.appendingPathComponent("reach-guest-key.json"))
        service.refuse = "reach_key_set"
        let fresh = BackendReachGuest(service: service, directory: folder, relayURL: "wss://relay.example.test", now: { clock.now })
        await #expect(throws: BackendReachFailure.refused(.keyChanged)) { _ = try await fresh.prepare() }
        #expect(await fresh.keyRefused)
        #expect(BackendReachGuest.keyRefusedLine == "This Mac could not connect to your other Macs. Sign out and in again to fix it.")
        // Any other failure is not that line (a network error is tried again next time).
        service.refuse = "unavailable"
        let other = BackendReachGuest(service: service, directory: try Self.folder(), relayURL: "wss://relay.example.test", now: { clock.now })
        await #expect(throws: CloudFailure.self) { _ = try await other.prepare() }
        #expect(await other.keyRefused == false)
        // Signed in again (forget): the line goes.
        await fresh.forget()
        #expect(await fresh.keyRefused == false)
    }

    @Test("The relay token is reused until 2 minutes are left; a reach-host token (not approved yet) never joins")
    func token() async throws {
        let clock = Clock(), service = FakeService(clock: clock)
        let guest = BackendReachGuest(service: service, directory: try Self.folder(), relayURL: "wss://relay.example.test", now: { clock.now })
        #expect(try await guest.relayToken() == "h.p.1")
        clock.advance(700_000)
        #expect(try await guest.relayToken() == "h.p.1" && service.tokens == 1)
        clock.advance(100_000)
        #expect(try await guest.relayToken() == "h.p.2")
        let held = FakeService(clock: clock); held.scope = "reach-host"
        let refused = BackendReachGuest(service: held, directory: try Self.folder(), relayURL: "wss://relay.example.test", now: { clock.now })
        await #expect(throws: BackendReachFailure.refused(.notApproved)) { _ = try await refused.relayToken() }
        #expect(BackendRemoteGuestChannel.reachProtocols("h.p.1") == ["td-reach", "td-token.h.p.1"])
    }

    @Test("The service calls are signed device requests: the key's own signature, the machines route")
    func http() async throws {
        let key = P256.Signing.PrivateKey()
        let http = BackendReachAccountTests.FakeHTTP { request in
            request.url.path == "/v1/reach/machines" ? .init(status: 200, body: Data(#"{"account":"acct-A","machines":[]}"#.utf8)) : .init(status: 201, body: Data("{}".utf8))
        }
        let service = BackendReachAccountHTTPService(base: URL(string: "https://td-cloud-test.example.test/v1")!, http: http, account: .init(
            subject: { "acct-A" }, accessToken: { _ in "access-1" }, deviceId: { Self.macId },
            sign: { bytes, _ in try key.signature(for: bytes).rawRepresentation }), now: { 1_800_000_000_000 })
        let reach = BackendReachWire.base64url(BackendSealedIdentity.generate().publicKey)
        try await service.registerReachKey(deviceId: Self.macId, publicKey: reach)
        #expect(try await service.reachMachines().isEmpty)
        let sent = http.all
        #expect(sent.map { $0.method + " " + $0.url.path } == ["POST /v1/devices/reach-key", "GET /v1/reach/machines"])
        let body = try NativeRPCValue.parseJSON(sent[0].body)
        #expect(body["deviceId"].string == Self.macId && body["reachPublicKey"].string == reach)
        let sig = try #require(body["sig"].string.flatMap { BackendReachWire.unbase64url($0, length: 64) })
        #expect(key.publicKey.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: sig),
                                               for: Data(BackendReachWire.reachKeyMessage(deviceId: Self.macId, key: reach).utf8)))
        // Another device id than this Mac's is never registered.
        await #expect(throws: BackendReachFailure.self) { try await service.registerReachKey(deviceId: Self.pcId, publicKey: reach) }
    }

    @Test("A live row keeps its tab and chat mark; the header's machine ref is read only when well formed")
    func rowsAndHeader() {
        let row = NativeRPCValue.object([.init("id", .string("p1")), .init("title", .string("Claude")), .init("cwd", .string("/x")),
            .init("provider", .string("claude")), .init("status", .string("idle")), .init("tab", .string("tab-1")), .init("chat", .bool(true))])
        let kept = BackendRemoteProtocol.remoteSession(row)
        #expect(kept?["tab"].string == "tab-1" && kept?["chat"].bool == true)
        #expect(BackendRemoteProtocol.remoteSession(row.setting("tab", .string("bad\ntab")).setting("chat", .bool(false)))?["tab"] == .missing)
        #expect(BackendRemoteGuest.machineHeader(.object([.init("machine", .string(Self.ref))])) == Self.ref)
        #expect(BackendRemoteGuest.machineHeader(.object([.init("machine", .string("not-a-ref"))])) == nil)
    }

    @Test("Chat operations become the phones' chats.* frames; anything else is refused")
    func chatFrames() {
        #expect(BackendMachineChannels.chatFrame("watch", chat: "c1", .missing, .missing)?.0 == "chats.watch")
        let say = BackendMachineChannels.chatFrame("say", chat: "c1", .string("hello"), .missing)
        #expect(say?.0 == "chats.say" && say?.1.first { $0.key == "text" }?.value.string == "hello" && say?.1.contains { $0.key == "clientMessageId" } == true)
        let answer = BackendMachineChannels.chatFrame("answer", chat: "c1", .string("req-1"), .bool(true))
        #expect(answer?.0 == "chats.answer" && answer?.1.first { $0.key == "approved" }?.value.bool == true)
        #expect(BackendMachineChannels.chatFrame("say", chat: "c1", .string(""), .missing) == nil)
        #expect(BackendMachineChannels.chatFrame("answer", chat: "c1", .string("req-1"), .missing) == nil)
        #expect(BackendMachineChannels.chatFrame("new", chat: "c1", .missing, .missing) == nil)
        for op in ["watch", "say", "interrupt", "answer"] {
            guard let (type, fields) = BackendMachineChannels.chatFrame(op, chat: "c1", .string("x"), .bool(false)) else { Issue.record("no frame for \(op)"); continue }
            let frame = NativeRPCValue.object([.init("t", .string(type))] + fields)
            guard case .message = BackendRemoteProtocol.parseClientMessage(frame) else { Issue.record("not a client message: \(type)"); continue }
        }
    }

    /// The other Mac's side of the relay: accepts the join, answers the Noise IK handshake only for the registered key,
    /// reads the hello and sends its welcome (with the `machine` header and a row's `tab`).
    final class FakeRelay: @unchecked Sendable {
        let host = BackendSealedIdentity.generate()
        let allowed: Data
        let queue = DispatchQueue(label: "reach-guest-tests.fake-relay")
        private let lock = NSLock()
        private var _protocols: [String] = []
        private var _hello: NativeRPCValue?
        /// One sealed channel per connection (a redial is a new handshake, never fed to the last one's transport).
        private var transports: [ObjectIdentifier: BackendSealedTransport] = [:]
        private var listener: NWListener?
        init(allowed: Data) { self.allowed = allowed }
        var protocols: [String] { lock.withLock { _protocols } }
        var hello: NativeRPCValue? { lock.withLock { _hello } }
        /// As the session host sends it: `token` is always there (null for a device that already holds its access).
        static let welcome = #"{"t":"welcome","protocol":1,"deviceId":"d1","deviceName":"MacBook","token":null,"capabilities":["chats","create"],"#
            + #""hostPlatform":"darwin","machine":"0123456789abcdef0123456789abcdef","sessions":[{"id":"p1","title":"Claude","cwd":"/work","#
            + #""provider":"claude","status":"idle","exitCode":null,"tab":"tab-1"},{"id":"c9","title":"Plan","cwd":"/work","provider":"claude","#
            + #""status":"idle","exitCode":null,"chat":true}]}"#

        func start() async throws -> Int {
            let ws = NWProtocolWebSocket.Options()
            ws.autoReplyPing = true
            ws.setClientRequestHandler(queue) { [weak self] subprotocols, _ in
                // The relay trims each offered protocol (reach.ts reachToken: split(',').map(trim)); Network does not.
                let offered = subprotocols.map { $0.trimmingCharacters(in: .whitespaces) }
                self?.lock.withLock { self?._protocols = offered }
                return NWProtocolWebSocket.Response(status: .accept, subprotocol: offered.first)
            }
            let parameters = NWParameters.tcp
            parameters.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            let listener = try NWListener(using: parameters), ready = BackendServersSSHOnce<Int>()
            self.listener = listener
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.start(queue: self.queue)
                self.read(connection)
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if let port = listener.port { ready.finish(.success(Int(port.rawValue))) }
                case .failed(let error): ready.finish(.failure(error))
                default: break
                }
            }
            listener.start(queue: queue)
            return try await ready.value()
        }
        func stop() { listener?.cancel() }
        private func read(_ connection: NWConnection) {
            connection.receiveMessage { [weak self] data, _, _, error in
                guard let self, error == nil, let data else { return }
                Task { await self.handle(data, connection); self.read(connection) }
            }
        }
        private func handle(_ data: Data, _ connection: NWConnection) async {
            let key = ObjectIdentifier(connection)
            if let transport = lock.withLock({ transports[key] }) {
                guard let clear = try? await transport.receive(data), let value = try? NativeRPCValue.parseJSON(clear) else { return }
                lock.withLock { _hello = value }
                if let sealed = try? await transport.send(Data(Self.welcome.utf8)) { send(sealed, connection) }
                return
            }
            guard let answer = try? BackendSealedHost.respondRelayFrame(identity: host, frame: data, approvedKeys: [allowed]) else { connection.cancel(); return }
            lock.withLock { transports[key] = answer.transport }
            send(answer.reply, connection)
        }
        private func send(_ data: Data, _ connection: NWConnection) {
            let context = NWConnection.ContentContext(identifier: "data", metadata: [NWProtocolWebSocket.Metadata(opcode: .binary)])
            connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
        }
    }

    @Test("Joined by sign-in: the token on the join, the registered key in the handshake, `reach:<id>` in the hello; the link is online with the machine's ref and the rows' tab")
    func joinsByToken() async throws {
        let clock = Clock(), service = FakeService(clock: clock), folder = try Self.folder()
        let probe = BackendReachGuest(service: service, directory: folder, relayURL: "ws://127.0.0.1:1", now: { Date().timeIntervalSince1970 * 1000 })
        let key = try await probe.prepare().identity
        let relay = FakeRelay(allowed: key.publicKey)
        let port = try await relay.start()
        defer { relay.stop() }
        let reach = BackendReachGuest(service: service, directory: folder, relayURL: "ws://127.0.0.1:\(port)", now: { Date().timeIntervalSince1970 * 1000 })
        let sign = P256.Signing.PrivateKey()
        let machine = try #require(BackendReachMachine.list(.object([.init("machines", .array([try Self.row(Self.miniId, sign: sign, host: relay.host)]))])).first)
        let secrets = try await reach.secrets(machine)
        #expect(secrets.credential == "reach:" + Self.macId && secrets.hostID == Self.hostId && secrets.guestIdentity.publicKey == key.publicKey)
        let link = BackendRemoteGuest(id: BackendReachGuest.linkID(Self.miniId), secrets: secrets, localName: "MacBook",
                                      onState: { _ in }, onOutput: { _, _, _ in }, onWelcome: { _ in },
                                      relayToken: { try await reach.relayToken() })
        await link.connect()
        var state = await link.state()
        for _ in 0..<100 where state.phase != .online { try await Task.sleep(for: .milliseconds(50)); state = await link.state() }
        await link.disconnect()
        #expect(state.phase == .online)
        #expect(state.machine == Self.ref && state.value["machine"].string == Self.ref)
        #expect(state.sessions.first { $0["id"].string == "p1" }?["tab"].string == "tab-1")
        #expect(state.sessions.first { $0["id"].string == "c9" }?["chat"].bool == true)
        #expect(relay.protocols == ["td-reach", "td-token.h.p.1"])
        #expect(relay.hello?["token"].string == "reach:" + Self.macId && relay.hello?["device"]["platform"].string == "darwin")
        #expect(BackendReachGuest.isReachLink(link.id) && service.registered.count == 1)
    }
}
