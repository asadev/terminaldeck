import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// connect-fix (17 Nov 2026, Asad: "sometimes it's taking ten, sometimes it's not even loading at all"): the chat model
/// list no longer holds a phone's other requests, the direct link's signalling skips the queue, only the relay's own
/// refusal unties the Mac from the account, and a start waits briefly for the account token before its first dial.
@Suite("Connect fix: queue lanes and the relay's account token", .serialized)
struct ConnectFixTests {
    private actor Capture {
        var frames: [NativeRPCValue] = []
        func receive(_ text: String) throws { frames.append(try NativeRPCValue.parseJSON(Data(text.utf8))) }
        var types: [String] { frames.compactMap { $0["t"].string } }
    }
    /// A door the test opens: whatever waits on it stays inside until `open`, or gives up after 5 s.
    private actor Door {
        private var isOpen = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        func open() { isOpen = true; waiting.forEach { $0.resume() }; waiting = [] }
        func pass() async {
            if isOpen { return }
            let task = Task { try? await Task.sleep(for: .seconds(5)); self.open() }
            await withCheckedContinuation { waiting.append($0) }
            task.cancel()
        }
    }
    private struct Fixture {
        let host: BackendRemoteHost, trust: BackendRemoteTrustStore, capture: Capture, connection: UUID, directory: URL
        func frame(_ type: String, _ fields: [NativeRPCValue.Field]) throws -> String {
            String(decoding: try NativeRPCValue.object([.init("t", .string(type))] + fields).encodedJSON(), as: UTF8.self)
        }
        func finish() async { await host.stop(); await trust.close(); try? FileManager.default.removeItem(at: directory) }
    }

    private func fixture(choices: @escaping @Sendable (BackendRemoteClientMessage) async throws -> [BackendRemoteServerMessage],
                         settings: @escaping @Sendable (BackendRemoteClientMessage) async throws -> [BackendRemoteServerMessage]) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ConnectFix-" + UUID().uuidString)
        let trust = BackendRemoteTrustStore(directory: directory)
        try await trust.open()
        let device = try await trust.redeem(try await trust.createPairingOffer().token, name: "Test phone", address: "test", publicKey: nil)
        try await trust.approve(device.device.id, kind: .mine)
        try await trust.setPhoneAccess(device.device.id, level: .full)
        let capture = Capture(), clock = INT2PhoneHostClock()
        let host = BackendRemoteHost(trust: trust, manager: BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in }), state: NativeStateStore(),
            home: directory.path, hostName: "Test", appVersion: "test", privateRoots: [],
            sleep: { try await clock.sleep($0) }, clock: { clock.now() })
        try await host.register(.init(capability: "chats", messageTypes: ["chats.choices"], policy: .grantedDevice) { message, _ in try await choices(message) })
        try await host.register(.init(capability: "settings", messageTypes: ["settings.apply"], policy: .grantedDevice) { message, _ in try await settings(message) })
        try await host.start()
        let connection = try #require(await host.accept(.init(address: "test", send: { try await capture.receive($0) }, close: { _, _ in })))
        let fixture = Fixture(host: host, trust: trust, capture: capture, connection: connection, directory: directory)
        await host.receive(connection, text: try fixture.frame("hello", [.init("protocol", .number(1)), .init("token", .string(device.credential)),
            .init("device", .object([.init("name", .string("Test phone")), .init("platform", .string("ios"))])), .init("capabilities", .array([]))]))
        return fixture
    }
    private static func applied(_ message: BackendRemoteClientMessage) throws -> [BackendRemoteServerMessage] {
        [try BackendRemoteServerMessage(.settingsApplied, fields: [.init("rid", .string(message["rid"].string ?? "")), .init("ok", .bool(true)),
            .init("message", .string("")), .init("setting", .object([]))])]
    }
    private static let write: [NativeRPCValue.Field] = [.init("rid", .string("w1")), .init("key", .string("general.restoreSessions")), .init("value", .string("on"))]

    @Test("a slow chat model list no longer holds the requests after it")
    func choicesRunOnTheSide() async throws {
        let door = Door()
        let fixture = try await fixture(choices: { message in
            await door.pass()
            return [try BackendRemoteServerMessage(.chatsChoices, fields: [.init("rid", .string(message["rid"].string ?? "")),
                .init("providers", .array([])), .init("accounts", .array([])), .init("agents", .array([]))])]
        }, settings: { message in try Self.applied(message) })
        let choices = try #require(await fixture.host.take(fixture.connection, text: try fixture.frame("chats.choices", [.init("rid", .string("c1"))])))
        #expect(choices.alongside, "the reader opens the next frame at once")
        let write = try #require(await fixture.host.take(fixture.connection, text: try fixture.frame("settings.apply", Self.write)))
        await write.answered.value
        #expect(await fixture.capture.types.contains("settings.applied"), "the write was answered while the model list was still running")
        #expect(!(await fixture.capture.types.contains("chats.choices")))
        await door.open()
        await choices.answered.value
        let replies = await fixture.capture.frames.filter { ["settings.applied", "chats.choices"].contains($0["t"].string ?? "") }
        #expect(replies.map { $0["t"].string } == ["settings.applied", "chats.choices"])
        #expect(replies.last?["rid"].string == "c1", "the model list answers its own request id")
        #expect(BackendRemoteHost.sideLane == ["chats.choices"])
        await fixture.finish()
    }

    @Test("a model list still waits for a write sent before it")
    func choicesWaitForAnEarlierWrite() async throws {
        let door = Door()
        let fixture = try await fixture(choices: { message in
            [try BackendRemoteServerMessage(.chatsChoices, fields: [.init("rid", .string(message["rid"].string ?? "")),
                .init("providers", .array([])), .init("accounts", .array([])), .init("agents", .array([]))])]
        }, settings: { message in await door.pass(); return try Self.applied(message) })
        let write = try #require(await fixture.host.take(fixture.connection, text: try fixture.frame("settings.apply", Self.write)))
        let choices = try #require(await fixture.host.take(fixture.connection, text: try fixture.frame("chats.choices", [.init("rid", .string("c1"))])))
        try await Task.sleep(for: .milliseconds(100))
        #expect(await fixture.capture.types.filter { $0 == "chats.choices" }.isEmpty)
        await door.open()
        await write.answered.value; await choices.answered.value
        let replies = await fixture.capture.types.filter { ["settings.applied", "chats.choices"].contains($0) }
        #expect(replies == ["settings.applied", "chats.choices"])
        await fixture.finish()
    }

    @Test("the direct link's signalling is not held behind a slow request")
    func linkPeerSkipsTheQueue() async throws {
        let door = Door()
        let fixture = try await fixture(choices: { _ in [] }, settings: { message in await door.pass(); return try Self.applied(message) })
        let write = try #require(await fixture.host.take(fixture.connection, text: try fixture.frame("settings.apply", Self.write)))
        let started = Date()
        let peer = try #require(await fixture.host.take(fixture.connection, text: try fixture.frame("link.peer", [.init("op", .string("end"))])))
        #expect(peer.alongside)
        await peer.answered.value
        #expect(Date().timeIntervalSince(started) < 2, "link.peer was handled while the write was still running")
        #expect(!(await fixture.capture.types.contains("settings.applied")))
        await door.open()
        await write.answered.value
        #expect(BackendRemoteHost.linkLane == ["link.peer"])
        await fixture.finish()
    }

    @Test("only the relay's own refusal (its 403) unties the Mac; a network failure keeps the token")
    func onlyARealRefusalUnties() {
        #expect(BackendRemoteRelayClient.relayRefusedToken(httpStatus: 403))
        for status in [nil, 0, 101, 200, 500, 502, 503, 429] as [Int?] {
            #expect(!BackendRemoteRelayClient.relayRefusedToken(httpStatus: status), "\(String(describing: status))")
        }
    }

    @Test("a drop names the WebSocket close code and the relay's short reason beside the socket error")
    func dropsCarryTheCloseCode() {
        let reset = "The relay's connection was reset (TCP reset, NSPOSIXErrorDomain 54)."
        #expect(BackendRemoteRelayClient.withCloseCode(reset, code: 0, reason: nil) == reset, "no close frame: unchanged")
        #expect(BackendRemoteRelayClient.withCloseCode(reset, code: 1006, reason: nil) == reset + " (close code 1006)")
        #expect(BackendRemoteRelayClient.withCloseCode(reset, code: 1001, reason: Data("going away".utf8)) == reset + " (close code 1001: going away)")
        let closed = BackendRemoteRelayClient.closeReason(code: 1000, reason: nil)
        #expect(BackendRemoteRelayClient.withCloseCode(closed, code: 1000, reason: nil) == closed, "said once")
    }

    @Test("a start without the account token waits about 2 s before its first dial")
    func startWaitsForTheToken() async throws {
        guard BackendReachRelayLink.shared.token == nil else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ConnectFixStart-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let trust = BackendRemoteTrustStore(directory: directory)
        try await trust.open()
        let host = BackendRemoteHost(trust: trust, manager: BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in }),
                                     state: NativeStateStore(), home: directory.path, hostName: "Connect-fix test Mac",
                                     appVersion: "test", privateRoots: [directory.path])
        let identity = BackendRemoteHostIdentity(hostSecret: Data(repeating: 7, count: 32), keys: .generate())
        let client = try BackendRemoteRelayClient(url: "ws://127.0.0.1:9/relay", identity: identity, trust: trust, host: host)
        #expect(BackendRemoteRelayClient.firstDialTokenWaitMs == 2_000)
        await client.start()
        #expect(await client.waitingForToken(), "no dial before the token or the wait ends")
        try await Task.sleep(for: .milliseconds(2_400))
        #expect(!(await client.waitingForToken()), "the wait ended and the client dialed")
        await client.stop()
        #expect(!(await client.waitingForToken()))
        await trust.close()
    }
}
