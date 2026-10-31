import CryptoKit
import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// 31 Oct: alerts for a phone whose app is closed (`push`). Registration shapes and access, what the relay is sent
/// (sealed for every phone, readable words only for an iPhone, a preview only when allowed), the phone's choices,
/// "on screen" suppression and dropped tokens. The relay is a recording seam.
final class PHONEPushTests: XCTestCase {
    private func parse(_ json: String) -> BackendRemoteClientMessage? {
        if case .message(let message) = BackendRemoteProtocol.parseClientMessage(json) { return message }
        return nil
    }

    private static let key = SymmetricKey(size: .bits256)
    private static var keyText: String { BackendRemoteTrustStorage.base64URL(key.withUnsafeBytes { Data($0) }) }
    private static let mailbox = String(repeating: "ab", count: 16)

    private final class Relay: @unchecked Sendable {
        let lock = NSLock()
        var bodies: [NativeRPCValue] = []
        var answer = #"{"ok":true,"apns":true,"fcm":false,"results":[{"mailbox":true,"apns":"sent","fcm":"off"}]}"#
        func post(_ url: URL, _ headers: [String: String], _ body: Data?) -> (Int, Data) {
            lock.lock(); defer { lock.unlock() }
            if url.path.hasSuffix("/status") { return (200, Data(#"{"ok":true,"apns":true,"fcm":false}"#.utf8)) }
            XCTAssertEqual(headers[BackendRelayPacketCodec.secretHeader], "c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0c2VjcmV0MTI")
            if let body, let value = try? NativeRPCValue.parseJSON(body, maximumBytes: 1 << 20) { bodies.append(value) }
            return (200, Data(answer.utf8))
        }
    }

    private func make(relay: Relay, hears: Bool = true) -> BackendPhonePush {
        BackendPhonePush(file: nil, host: .init(mayHear: { _, _ in hears }, relay: {
            ("HOSTID", Data("secretsecretsecretsecretsecret12".utf8), URL(string: "https://relay.example")!)
        }, post: { url, headers, body in relay.post(url, headers, body) }, macName: "Studio"))
    }

    private static func context(_ connection: UUID = UUID(), level: BackendINT2PhoneAccessLevel = .work) -> BackendRemoteHostContext {
        .init(connectionID: connection, deviceID: "phone-1", kind: .mine, address: "relay", peerPublicKey: nil, claimedCapabilities: [],
              reach: .init(kind: .mine, unrestricted: false, folders: ["/Projects/Phone"], accounts: nil, drivesWindows: false), phoneAccess: level)
    }

    private func register(_ push: BackendPhonePush, extra: String = "", connection: UUID = UUID()) async throws -> BackendRemoteServerMessage {
        let message = try XCTUnwrap(parse(#"{"t":"push.register","mailbox":"\#(Self.mailbox)","key":"\#(Self.keyText)","platform":"ios","apns":"\#(String(repeating: "0f", count: 32))","sandbox":true\#(extra)}"#))
        let answers = try await push.handle(message, context: Self.context(connection))
        return try XCTUnwrap(answers.first)
    }

    private func open(_ sealed: String) throws -> NativeRPCValue {
        var base = sealed.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base.count % 4 != 0 { base += "=" }
        let box = try AES.GCM.SealedBox(combined: try XCTUnwrap(Data(base64Encoded: base)))
        return try NativeRPCValue.parseJSON(try AES.GCM.open(box, using: Self.key), maximumBytes: 65_536)
    }

    private let notice = BackendPhonePush.Notice(kind: .needsYou, session: "chat-1", agent: "Claude", title: "Fix the login page",
                                                 folder: "/Projects/Phone", preview: "May I run npm test? token=ghp_abcdefghijklmnopqrstuvwxyz0123")

    func testShapesAndAccess() {
        XCTAssertNotNil(parse(#"{"t":"push.presence","onScreen":false}"#))
        XCTAssertNotNil(parse(#"{"t":"push.forget"}"#))
        XCTAssertNil(parse(#"{"t":"push.register","key":"\#(Self.keyText)"}"#), "a mailbox is required")
        XCTAssertNil(parse(#"{"t":"push.register","mailbox":"\#(Self.mailbox)","key":"\#(Self.keyText)","apns":"not hex"}"#))
        XCTAssertNil(parse(#"{"t":"push.register","mailbox":"\#(Self.mailbox)","key":"\#(Self.keyText)","platform":"windows"}"#))
        XCTAssertTrue(BackendRemoteProtocol.capabilities.contains(BackendPhonePush.capability), "or installFeatures refuses it")
        XCTAssertTrue(BackendRemoteServerMessage.Kind(rawValue: "push.state") != nil)
        for level in BackendINT2PhoneAccessLevel.allCases { XCTAssertTrue(level.permits("push.register") && level.permits("push.presence")) }
    }

    func testAnIPhoneGetsTitleOnlyAndASealedAlert() async throws {
        let relay = Relay(), push = make(relay: relay)
        let state = try await register(push)
        XCTAssertEqual(state.value["t"].string, "push.state")
        XCTAssertEqual(state.value["delivery"].string, "instant")
        let sent = await push.notify(notice)
        XCTAssertEqual(sent, 1)
        let message = try XCTUnwrap(relay.bodies.first?["messages"].elements?.first)
        XCTAssertEqual(message["kind"].string, "needs-you")
        XCTAssertEqual(message["alert"]["title"].string, "Claude needs you")
        XCTAssertEqual(message["alert"]["body"].string, "Open Terminal Deck to answer.")
        XCTAssertEqual(message["route"]["host"].string, "HOSTID")
        XCTAssertEqual(message["apns"]["sandbox"].bool, true)
        let text = message.compact
        XCTAssertFalse(text.contains("Fix the login page"), "the chat's name stays sealed")
        XCTAssertFalse(text.contains("npm test"), "no preview unless the phone allows it")
        let opened = try open(try XCTUnwrap(message["sealed"].string))
        XCTAssertEqual(opened["title"].string, "Fix the login page")
        XCTAssertEqual(opened["session"].string, "chat-1")
        XCTAssertEqual(opened["mac"].string, "Studio")
        XCTAssertTrue(opened["preview"] == .missing)
    }

    func testAPreviewIsShortAndBlanksSecrets() async throws {
        let relay = Relay(), push = make(relay: relay)
        _ = try await register(push, extra: #","preview":true"#)
        await push.notify(notice)
        let message = try XCTUnwrap(relay.bodies.first?["messages"].elements?.first)
        let body = try XCTUnwrap(message["alert"]["body"].string)
        XCTAssertTrue(body.hasPrefix("Fix the login page: May I run npm test?"))
        XCTAssertFalse(body.contains("ghp_"), "a token-shaped word never leaves the Mac")
        XCTAssertLessThanOrEqual(body.count, 180)
        XCTAssertFalse(try open(try XCTUnwrap(message["sealed"].string))["preview"].string?.contains("ghp_") ?? true)
    }

    func testThePhonesChoicesOnScreenAndAccessDecide() async throws {
        let relay = Relay(), push = make(relay: relay)
        let connection = UUID()
        _ = try await register(push, extra: #","finished":false,"onScreen":true"#, connection: connection)
        let none = await push.notify(notice)
        XCTAssertEqual(none, 0, "the app is on screen: it shows the news itself")
        _ = try await push.handle(try XCTUnwrap(parse(#"{"t":"push.presence","onScreen":false}"#)), context: Self.context(connection))
        var finished = notice; finished.kind = .finished
        let off = await push.notify(finished)
        XCTAssertEqual(off, 0, "finished alerts switched off on the phone")
        let one = await push.notify(notice)
        XCTAssertEqual(one, 1)
        let blocked = make(relay: Relay(), hears: false)
        _ = try await register(blocked)
        let refused = await blocked.notify(notice)
        XCTAssertEqual(refused, 0, "a phone that may not see the chat hears nothing")
        // The test alert reaches the named phone whatever it chose.
        let test = await push.notify(.init(kind: .needsYou, session: "test", agent: "Terminal Deck", title: "Terminal Deck test", folder: ""), only: "phone-1")
        XCTAssertEqual(test, 1)
    }

    func testADeadTokenIsDroppedAndTheMailboxStays() async throws {
        let relay = Relay(); relay.answer = #"{"ok":true,"apns":true,"fcm":false,"results":[{"mailbox":true,"apns":"gone","fcm":"off"}]}"#
        let push = make(relay: relay)
        _ = try await register(push)
        await push.notify(notice)
        let rows = await push.rows()
        XCTAssertEqual(rows.first?["delivery"].string, "mailbox")
        XCTAssertEqual(rows.first?["lastResult"].string, "kept")
        await push.notify(notice)
        XCTAssertTrue(relay.bodies.last?["messages"].elements?.first?["apns"] == .missing)
        XCTAssertEqual(relay.bodies.last?["messages"].elements?.first?["mailbox"].string, Self.mailbox)
    }

    func testHttpBase() {
        XCTAssertEqual(BackendPhonePush.httpBase("wss://relay.terminaldeck.dev")?.absoluteString, "https://relay.terminaldeck.dev")
        XCTAssertEqual(BackendPhonePush.httpBase("ws://127.0.0.1:8080/v1")?.absoluteString, "http://127.0.0.1:8080")
    }
}
