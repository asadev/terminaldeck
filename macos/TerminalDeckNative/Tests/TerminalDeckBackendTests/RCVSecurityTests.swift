import XCTest
import CryptoKit
import Foundation
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// A dispatcher that records what it was asked to do.
actor RCVFakeDispatch: BackendRCVDispatching {
    struct Created: Equatable { let assignee: String, title: String, instructions: String, project: String }
    var created: [Created] = []
    var continued: [(String, String)] = []
    var typed: [(String, String)] = []
    var sent: [URLRequest] = []
    var comments: [(String, Int, String)] = []
    var failCreate = false, failContinue = false, replyStatus = 200
    func setFailCreate(_ value: Bool) { failCreate = value }
    func setFailContinue(_ value: Bool) { failContinue = value }
    func createTask(assignee: String, title: String, instructions: String, project: String) async throws -> String {
        if failCreate { throw NativeRPCError.invalidArguments("No such agent.") }
        created.append(.init(assignee: assignee, title: title, instructions: instructions, project: project))
        return "local:task-\(created.count)"
    }
    func continueTask(_ taskID: String, text: String) async throws {
        if failContinue { throw NativeRPCError.invalidArguments("No agent is waiting on this task.") }
        continued.append((taskID, text))
    }
    func typeIntoSession(_ sessionID: String, text: String) async throws { typed.append((sessionID, text)) }
    func taskOutcome(_ taskID: String) async -> String? { "Working" }
    func agents() async -> [RCVChoice] { [.init(id: "builder", name: "Builder")] }
    func sessions() async -> [RCVChoice] { [.init(id: "s1", name: "Claude in td")] }
    func githubComment(repository: String, number: Int, body: String) async throws { comments.append((repository, number, body)) }
    func send(_ request: URLRequest) async throws -> Int { sent.append(request); return replyStatus }
}

/// Frames the service sends back to the relay.
actor RCVFrames {
    var frames: [(UInt8, Data, Data)] = []
    func add(_ type: UInt8, _ channel: Data, _ payload: Data) { frames.append((type, channel, payload)) }
    func acks() -> [UInt8] { frames.filter { $0.0 == BackendRCVWire.ack }.map { $0.2.first ?? 0 } }
}

final class RCVClock: @unchecked Sendable {
    private let lock = NSLock(); private var value: Double
    init(_ start: Double = 1_800_000_000_000) { value = start }
    func now() -> Double { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ ms: Double) { lock.lock(); value += ms; lock.unlock() }
}

enum RCVTestKit {
    static func service(clock: RCVClock = RCVClock(), dispatch: RCVFakeDispatch = RCVFakeDispatch()) async throws -> (BackendRCVService, RCVFakeDispatch, RCVFrames) {
        let store = BackendRCVStore(persistence: nil, cipher: nil)
        let service = BackendRCVService(store: store, dispatch: dispatch, relayBase: { "https://relay.example" }, now: { clock.now() })
        try await service.start()
        let frames = RCVFrames()
        await service.relayOpened { type, channel, payload in await frames.add(type, channel, payload) }
        return (service, dispatch, frames)
    }

    static func publicKey(_ service: BackendRCVService) async throws -> Curve25519.KeyAgreement.PublicKey {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: try await service.storeForTests().read().receiverKey).publicKey
    }

    /// What the relay would send for one delivery.
    static func deliver(_ service: BackendRCVService, source: String, opened: BackendRCVWire.Opened, id: Data = Data((0..<16).map { _ in UInt8.random(in: 0...255) }),
                        receivedAt: Int64 = 1_800_000_000_000) async throws -> Data {
        let key = try await publicKey(service)
        let sealed = try BackendRCVWire.seal(try BackendRCVWire.plain(opened), to: key, aad: BackendRCVWire.aad(sourceID: source, deliveryID: id, receivedAt: receivedAt))
        let head = try JSONSerialization.data(withJSONObject: ["v": 1, "sourceId": source, "receivedAt": receivedAt])
        var payload = Data([UInt8(head.count >> 8), UInt8(head.count & 0xff)]); payload.append(head); payload.append(sealed)
        await service.relayFrame(type: BackendRCVWire.deliver, channel: id, payload: payload)
        return id
    }

    static func githubSignature(_ body: Data, secret: String) -> String {
        "sha256=" + HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: Data(secret.utf8))).map { String(format: "%02x", $0) }.joined()
    }
}

extension BackendRCVService {
    func storeForTests() -> BackendRCVStore { store }
}

final class RCVSecurityTests: XCTestCase {
    // MARK: Sealing, shared with relay/src/receiver.test.ts

    func testOpensTheRelaysFixedVector() throws {
        var raw = Data([0xa8]); raw.append(Data(repeating: 0xab, count: 30)); raw.append(0x6b)
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
        XCTAssertEqual(key.publicKey.rawRepresentation.base64EncodedString(), "43EthRoOXXm4McXjSrIrQaGYFx3iCbi4+sojoRxiSFk=")
        let sealed = Data(base64Encoded: "YMB8fiXuuaE4bGh+x/v6JqIwI4gB/bqTGxmC5rHvv2dIgoObvJcBG2qNQnBb3Bo97xUhup7a25YuFWsL4SeYY7Oaw3Kw2k/ouEizu0+r9zI=")!
        let aad = Data("AAAAAAAAAAAAAAAAAAAAAAAAAA.00112233445566778899aabbccddeeff.1800000000000".utf8)
        XCTAssertEqual(String(decoding: try BackendRCVWire.open(sealed, key: key, aad: aad), as: UTF8.self), #"{"hello":"receiver"}"#)
    }

    func testSealedDeliveriesRefuseTamperingOtherKeysAndOtherDeliveries() throws {
        let key = Curve25519.KeyAgreement.PrivateKey()
        let aad = Data("a.b.1".utf8)
        var sealed = try BackendRCVWire.seal(Data("secret words".utf8), to: key.publicKey, aad: aad)
        XCTAssertEqual(try BackendRCVWire.open(sealed, key: key, aad: aad), Data("secret words".utf8))
        XCTAssertFalse(String(decoding: sealed, as: UTF8.self).contains("secret words"))
        XCTAssertThrowsError(try BackendRCVWire.open(sealed, key: key, aad: Data("a.b.2".utf8)))
        XCTAssertThrowsError(try BackendRCVWire.open(sealed, key: Curve25519.KeyAgreement.PrivateKey(), aad: aad))
        sealed[50] ^= 1
        XCTAssertThrowsError(try BackendRCVWire.open(sealed, key: key, aad: aad))
        XCTAssertThrowsError(try BackendRCVWire.open(Data(count: 20), key: key, aad: aad))
    }

    func testDeliveryFramesMustBeExactlyRight() {
        XCTAssertNil(BackendRCVWire.decodeDeliver(channel: Data(count: 16), payload: Data([0, 1])))
        XCTAssertNil(BackendRCVWire.decodeDeliver(channel: Data(count: 15), payload: Data(count: 100)))
        let head = try! JSONSerialization.data(withJSONObject: ["v": 1, "sourceId": "not-an-id", "receivedAt": 1])
        var payload = Data([0, UInt8(head.count)]); payload.append(head); payload.append(Data(count: 80))
        XCTAssertNil(BackendRCVWire.decodeDeliver(channel: Data(count: 16), payload: payload))
    }

    // MARK: Signature and secret checks (the Mac's end-to-end check)

    func source(_ auth: RCVAuth) -> RCVSource {
        RCVSource(id: BackendRCVWire.mintSourceID(), name: "Test", preset: "webhook", auth: auth, mapping: RCVPresets.generic.mapping)
    }

    func testGitHubStyleSignature() {
        let github = source(RCVPresets.github.auth)
        let body = Data(#"{"zen":"Keep it logically awesome."}"#.utf8)
        let good = BackendRCVWire.Opened(headers: ["X-Hub-Signature-256": RCVTestKit.githubSignature(body, secret: "s3cret")], body: body)
        XCTAssertNil(BackendRCVAuth.verify(good, source: github, secret: "s3cret", now: 0))
        XCTAssertEqual(BackendRCVAuth.verify(good, source: github, secret: "other", now: 0), .signature)
        XCTAssertEqual(BackendRCVAuth.verify(.init(headers: good.headers, body: Data("{}".utf8)), source: github, secret: "s3cret", now: 0), .signature)
        XCTAssertEqual(BackendRCVAuth.verify(.init(headers: [:], body: body), source: github, secret: "s3cret", now: 0), .signature)
        let noPrefix = String(good.headers["x-hub-signature-256"]!.dropFirst("sha256=".count))
        XCTAssertEqual(BackendRCVAuth.verify(.init(headers: ["x-hub-signature-256": noPrefix], body: body), source: github, secret: "s3cret", now: 0), .signature)
        // An empty secret never verifies anything.
        let emptyKeyed = "sha256=" + HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: Data())).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(BackendRCVAuth.verify(.init(headers: ["x-hub-signature-256": emptyKeyed], body: body), source: github, secret: "", now: 0), .signature)
    }

    func testSentrySignatureAndRotatedSignatures() {
        let sentry = source(RCVPresets.sentry.auth)
        let body = Data(#"{"action":"created","data":{"issue":{"title":"TypeError"}}}"#.utf8)
        let hex = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: Data("client-secret".utf8))).map { String(format: "%02x", $0) }.joined()
        XCTAssertNil(BackendRCVAuth.verify(.init(headers: ["sentry-hook-signature": hex], body: body), source: sentry, secret: "client-secret", now: 0))
        XCTAssertNil(BackendRCVAuth.verify(.init(headers: ["sentry-hook-signature": "deadbeef, \(hex)"], body: body), source: sentry, secret: "client-secret", now: 0))
    }

    func testOtherAlgorithmsEncodingsAndSignedTimestamps() {
        let body = Data("{}".utf8)
        var auth = RCVAuth(scheme: .hmac, hmac: .init(header: "x-sig", algorithm: .sha512, encoding: .base64, prefix: "v1="))
        let b64 = HMAC<SHA512>.authenticationCode(for: body, using: SymmetricKey(data: Data("k".utf8)))
        XCTAssertNil(BackendRCVAuth.verify(.init(headers: ["x-sig": "v1=" + Data(b64).base64EncodedString()], body: body), source: source(auth), secret: "k", now: 0))

        auth = RCVAuth(scheme: .hmac, hmac: .init(header: "x-sig", algorithm: .sha256, encoding: .hex, prefix: "v0=", signedPayload: "v0:{timestamp}:{body}",
                                                  timestampHeader: "x-ts", toleranceSeconds: 300))
        let now = 1_800_000_000_000.0
        func signed(_ ts: String) -> BackendRCVWire.Opened {
            let mac = HMAC<SHA256>.authenticationCode(for: Data("v0:\(ts):{}".utf8), using: SymmetricKey(data: Data("k".utf8))).map { String(format: "%02x", $0) }.joined()
            return .init(headers: ["x-sig": "v0=" + mac, "x-ts": ts], body: body)
        }
        XCTAssertNil(BackendRCVAuth.verify(signed("1800000000"), source: source(auth), secret: "k", now: now))
        XCTAssertEqual(BackendRCVAuth.verify(signed("1799999000"), source: source(auth), secret: "k", now: now), .stale, "a 1000-second-old signature is a possible replay")
        XCTAssertEqual(BackendRCVAuth.verify(.init(headers: ["x-sig": "v0=00"], body: body), source: source(auth), secret: "k", now: now), .stale)
    }

    func testTokensBasicAndAddressLists() {
        let token = source(.init(scheme: .token, tokenHeader: "x-api-token"))
        let secret = BackendRCVWire.mintSecret()
        XCTAssertNil(BackendRCVAuth.verify(.init(headers: [:], pathToken: secret, body: Data()), source: token, secret: secret, now: 0))
        XCTAssertNil(BackendRCVAuth.verify(.init(headers: ["Authorization": "Bearer \(secret)"], body: Data()), source: token, secret: secret, now: 0))
        XCTAssertNil(BackendRCVAuth.verify(.init(headers: ["x-api-token": secret], body: Data()), source: token, secret: secret, now: 0))
        XCTAssertEqual(BackendRCVAuth.verify(.init(headers: ["x-receiver-secret": secret], body: Data()), source: token, secret: secret, now: 0), .credential)
        XCTAssertEqual(BackendRCVAuth.verify(.init(headers: [:], pathToken: BackendRCVWire.mintSecret(), body: Data()), source: token, secret: secret, now: 0), .credential)
        XCTAssertEqual(BackendRCVAuth.verify(.init(headers: [:], body: Data()), source: token, secret: secret, now: 0), .credential)

        let basic = source(.init(scheme: .basic, basicUser: "monitor"))
        let header = "Basic " + Data("monitor:\(secret)".utf8).base64EncodedString()
        XCTAssertNil(BackendRCVAuth.verify(.init(headers: ["authorization": header], body: Data()), source: basic, secret: secret, now: 0))
        XCTAssertEqual(BackendRCVAuth.verify(.init(headers: ["authorization": "Basic " + Data("monitor:x".utf8).base64EncodedString()], body: Data()), source: basic, secret: secret, now: 0), .credential)

        let listed = source(.init(scheme: .none, ipAllow: ["203.0.113.0/24", "2001:db8::/32"]))
        XCTAssertNil(BackendRCVAuth.verify(.init(headers: [:], clientIP: "203.0.113.77", body: Data()), source: listed, secret: "", now: 0))
        XCTAssertNil(BackendRCVAuth.verify(.init(headers: [:], clientIP: "2001:db8:1::5", body: Data()), source: listed, secret: "", now: 0))
        XCTAssertEqual(BackendRCVAuth.verify(.init(headers: [:], clientIP: "203.0.114.1", body: Data()), source: listed, secret: "", now: 0), .address)
        XCTAssertEqual(BackendRCVAuth.verify(.init(headers: [:], body: Data()), source: listed, secret: "", now: 0), .address)
        XCTAssertTrue(BackendRCVAuth.allows("10.0.0.0/8", "10.200.3.4"))
        XCTAssertFalse(BackendRCVAuth.allows("10.0.0.0/8", "11.0.0.1"))
        XCTAssertTrue(BackendRCVAuth.allows("192.0.2.1", "::ffff:192.0.2.1"))
    }

    func testTheRelayIsToldHashesNeverSecrets() throws {
        let secret = BackendRCVWire.mintSecret()
        var token = source(.init(scheme: .token)), basic = source(.init(scheme: .basic, basicUser: "u")), hmac = source(RCVPresets.github.auth)
        token.enabled = true; basic.enabled = true; hmac.enabled = false
        let payload = try BackendRCVWire.syncPayload(sealKey: Curve25519.KeyAgreement.PrivateKey().publicKey,
            sources: [token, basic, hmac].map { BackendRCVWire.declaration($0, secret: secret) })
        let text = String(decoding: payload, as: UTF8.self)
        XCTAssertFalse(text.contains(secret))
        XCTAssertTrue(text.contains(BackendRCVWire.sha256Hex(secret)))
        XCTAssertTrue(text.contains(BackendRCVWire.sha256Hex("u:" + secret)))
        XCTAssertTrue(text.contains("x-hub-signature-256"))
        XCTAssertEqual(BackendRCVWire.declaration(hmac, secret: secret).secretHash, nil)
        XCTAssertTrue(BackendRCVWire.isSourceID(BackendRCVWire.mintSourceID()))
        XCTAssertEqual(BackendRCVWire.mintSecret().count, 43)
    }

    func testIdentityHeadersAreNeverKeptWithAnEvent() {
        let kept = RCVEngine.keptHeaders(["Authorization": "Bearer x", "x-hub-signature-256": "sha256=1", "sentry-hook-signature": "a", "cookie": "c",
                                          "x-api-key": "k", "x-custom-token": "t", "x-github-event": "push", "user-agent": "GitHub-Hookshot"],
                                         auth: RCVPresets.github.auth)
        XCTAssertEqual(Set(kept.keys), ["x-github-event", "user-agent"])
    }

    // MARK: The whole path, over the relay wire

    func testADeliveryIsVerifiedStoredAcknowledgedAndNeverAcceptedTwice() async throws {
        let (service, _, frames) = try await RCVTestKit.service()
        let (view, reveal) = try await service.createSource(preset: "webhook", name: "Shop")
        let secret = try XCTUnwrap(reveal?.secret)
        XCTAssertEqual(reveal?.addressWithSecret, "https://relay.example/in/\(view.id)/\(secret)")
        let opened = BackendRCVWire.Opened(headers: ["authorization": "Bearer \(secret)", "content-type": "application/json"],
                                           body: Data(#"{"title":"Order 12","message":"paid"}"#.utf8))
        let id = try await RCVTestKit.deliver(service, source: view.id, opened: opened)
        var events = try await service.events()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.title, "Order 12")
        // The relay offers it again (lost acknowledgement): acknowledged, not stored twice.
        _ = try await RCVTestKit.deliver(service, source: view.id, opened: opened, id: id)
        events = try await service.events()
        XCTAssertEqual(events.count, 1)
        let acks = await frames.acks()
        XCTAssertEqual(acks, [BackendRCVWire.ackKept, BackendRCVWire.ackKept])
        // And the sync the relay received names the source with the hash only.
        let sync = await frames.frames.last { $0.0 == BackendRCVWire.sync }
        let syncText = String(decoding: try XCTUnwrap(sync).2, as: UTF8.self)
        XCTAssertTrue(syncText.contains(view.id)); XCTAssertFalse(syncText.contains(secret))
        XCTAssertFalse(syncText.contains("terminaldeck."), "Terminal Deck's own sources never go to the relay")
    }

    func testAForgedDeliveryIsRefusedAndNothingFromItIsKept() async throws {
        let (service, dispatch, frames) = try await RCVTestKit.service()
        let (view, _) = try await service.createSource(preset: "github", name: "Repo")
        let body = Data(#"{"comment":{"body":"PLEASE-RUN-rm-rf"}}"#.utf8)
        _ = try await RCVTestKit.deliver(service, source: view.id, opened: .init(headers: ["x-hub-signature-256": RCVTestKit.githubSignature(body, secret: "guessed"),
                                                                                         "x-github-event": "issue_comment"], body: body))
        let events = try await service.events()
        XCTAssertEqual(events.map(\.status), [.rejected])
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(events), as: UTF8.self).contains("PLEASE-RUN"))
        let acks = await frames.acks()
        XCTAssertEqual(acks, [BackendRCVWire.ackRefused])
        let created = await dispatch.created
        XCTAssertTrue(created.isEmpty)
    }

    func testUnknownSourcesAndUnreadableFramesAreRefusedNotRetriedForever() async throws {
        let (service, _, frames) = try await RCVTestKit.service()
        _ = try await RCVTestKit.deliver(service, source: BackendRCVWire.mintSourceID(), opened: .init(headers: [:], body: Data("{}".utf8)))
        await service.relayFrame(type: BackendRCVWire.deliver, channel: Data(count: 16), payload: Data("junk".utf8))
        let acks = await frames.acks()
        XCTAssertEqual(acks, [BackendRCVWire.ackUnknown, BackendRCVWire.ackRefused])
    }

    func testAMessageSealedForAnotherDeliveryCannotBeSwappedIn() async throws {
        let (service, _, frames) = try await RCVTestKit.service()
        let (view, reveal) = try await service.createSource(preset: "webhook", name: "Shop")
        let key = try await RCVTestKit.publicKey(service)
        let plain = try BackendRCVWire.plain(.init(headers: ["authorization": "Bearer \(reveal!.secret)"], body: Data("{}".utf8)))
        let sealed = try BackendRCVWire.seal(plain, to: key, aad: BackendRCVWire.aad(sourceID: view.id, deliveryID: Data(count: 16), receivedAt: 1))
        let head = try JSONSerialization.data(withJSONObject: ["v": 1, "sourceId": view.id, "receivedAt": 2])
        var payload = Data([0, UInt8(head.count)]); payload.append(head); payload.append(sealed)
        await service.relayFrame(type: BackendRCVWire.deliver, channel: Data(count: 16), payload: payload)
        let acks = await frames.acks()
        XCTAssertEqual(acks, [BackendRCVWire.ackRefused])
        let statuses = try await service.events().map(\.status)
        XCTAssertEqual(statuses, [.rejected])
    }

    func testSecretsNeverAppearInWhatThePageOrToolsRead() async throws {
        let (service, _, _) = try await RCVTestKit.service()
        let (view, reveal) = try await service.createSource(preset: "whapi", name: "Group")
        _ = try await service.setReplyCredential(view.id, value: "whapi-api-token-XYZ")
        let overview = String(decoding: try JSONEncoder().encode(try await service.overview()), as: UTF8.self)
        XCTAssertFalse(overview.contains(reveal!.secret))
        XCTAssertFalse(overview.contains("whapi-api-token-XYZ"))
        let listed = try await service.sources()
        XCTAssertTrue(listed.first { $0.id == view.id }!.hasReplyCredential)
        // Replacing the secret makes the old one useless.
        let next = try await service.rotateSecret(view.id)
        XCTAssertNotEqual(next.secret, reveal!.secret)
        _ = try await RCVTestKit.deliver(service, source: view.id, opened: .init(headers: [:], pathToken: reveal!.secret, body: Data("{}".utf8)))
        let statuses = try await service.events().map(\.status)
        XCTAssertEqual(statuses, [.rejected])
    }

    // MARK: Replies

    func testReplyRequestsKeepTheOwnersHostAndEscapeEverythingFromTheMessage() throws {
        var event = RCVEvent(sourceId: "S", receivedAt: 0, kind: "message", fields: ["chat": "evil.example/steal?x=", "id": "1\"}"])
        event.text = "hi"
        let channel = RCVReplyChannel(via: .http, method: "POST", url: "https://api.example/chats/{{fields.chat}}/messages",
                                      headers: [.init("Authorization", "Bearer {{secret.reply}}"), .init("Content-Type", "application/json")],
                                      body: "{\"to\":\"{{fields.id}}\",\"body\":\"{{reply}}\"}")
        let request = try BackendRCVReplySender.request(for: channel, event: event, text: "line \"one\"\n{{secret.reply}}", credential: "TOKEN")
        XCTAssertEqual(request.url?.host, "api.example")
        XCTAssertFalse(request.url!.absoluteString.contains("evil.example/"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer TOKEN")
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: String]
        XCTAssertEqual(body["to"], "1\"}")
        XCTAssertEqual(body["body"], "line \"one\"\n{{secret.reply}}", "the agent's text is inserted once and never expanded")

        var templatedHost = RCVSource(id: "S", name: "x", preset: "webhook", auth: .init(scheme: .none), mapping: .init())
        templatedHost.reply = .init(url: "https://{{fields.chat}}/x")
        XCTAssertThrowsError(try RCVEngine.validate(templatedHost))
        templatedHost.reply = .init(url: "http://plain.example/x")
        XCTAssertThrowsError(try RCVEngine.validate(templatedHost))
        let header = RCVReplyChannel(url: "https://api.example/x", headers: [.init("X-To", "{{fields.chat}}")])
        var crlf = event; crlf.fields["chat"] = "a\r\nX-Evil: 1"
        XCTAssertThrowsError(try BackendRCVReplySender.request(for: header, event: crlf, text: "t", credential: nil))
    }

    func testRepliesAreBoundedAndTheirEchoIsNotRoutedBack() async throws {
        let (service, dispatch, _) = try await RCVTestKit.service()
        let (view, reveal) = try await service.createSource(preset: "whapi", name: "Group")
        _ = try await service.setReplyCredential(view.id, value: "api")
        _ = try await service.saveRule(RCVRule(name: "All", sourceIds: [view.id], target: .init(kind: .hoot)), byOwner: true)
        func message(_ id: String, _ text: String, fromMe: Bool = false) -> Data {
            Data(#"{"messages":[{"id":"\#(id)","from_me":\#(fromMe),"chat_id":"123@g.us","from":"971","from_name":"Asad","type":"text","text":{"body":"\#(text)"}}]}"#.utf8)
        }
        _ = try await RCVTestKit.deliver(service, source: view.id, opened: .init(headers: [:], pathToken: reveal!.secret, body: message("m1", "status please")))
        let event = try await service.events().first!
        XCTAssertEqual(event.status, .delivered)
        _ = try await service.reply(event.id, text: "All green.", by: "builder", autoApproved: false)
        let sent = await dispatch.sent
        XCTAssertEqual(sent.first?.url?.absoluteString, "https://gate.whapi.cloud/messages/text")
        XCTAssertEqual(sent.first?.value(forHTTPHeaderField: "Authorization"), "Bearer api")
        // Our own reply comes back twice: once flagged from_me, once (another gateway) without the flag.
        _ = try await RCVTestKit.deliver(service, source: view.id, opened: .init(headers: [:], pathToken: reveal!.secret, body: message("m2", "All green.", fromMe: true)))
        _ = try await RCVTestKit.deliver(service, source: view.id, opened: .init(headers: [:], pathToken: reveal!.secret, body: message("m3", "all green.")))
        let statuses = try await service.events().prefix(2).map(\.status)
        XCTAssertEqual(statuses, [.ignored, .ignored])
        let created = await dispatch.created
        XCTAssertEqual(created.count, 1, "only the real message reached Hoot")
        for n in 0..<(BackendRCVService.maxRepliesPerEvent - 1) { _ = try await service.reply(event.id, text: "r\(n)", by: "builder", autoApproved: false) }
        do { _ = try await service.reply(event.id, text: "one too many", by: "builder", autoApproved: false); XCTFail("expected a limit") } catch {}
    }

    func testOnlyTheOwnerCanTurnOnRepliesWithoutAsking() async throws {
        let (service, _, _) = try await RCVTestKit.service()
        var rule = RCVRule(name: "Auto", target: .init(kind: .hoot), autoApproveReplies: true)
        do { _ = try await service.saveRule(rule, byOwner: false); XCTFail("a tool turned on auto-approve") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "owner-only") }
        rule = try await service.saveRule(rule, byOwner: true)
        rule.name = "Still auto"
        _ = try await service.saveRule(rule, byOwner: false) // keeping it on is allowed
        rule.autoApproveReplies = false
        _ = try await service.saveRule(rule, byOwner: false) // turning it off is allowed
        rule.autoApproveReplies = true
        do { _ = try await service.saveRule(rule, byOwner: false); XCTFail("a tool turned it back on") } catch {}
    }

    func testTheOwnerCanUseTheSendersOwnSecretForSentry() async throws {
        let (service, _, frames) = try await RCVTestKit.service()
        let (view, _) = try await service.createSource(preset: "sentry", name: "Sentry")
        _ = try await service.setSecret(view.id, value: "sentry-client-secret-0001")
        let body = Data(#"{"action":"created","data":{"issue":{"title":"E","level":"error","project":{"slug":"web"}}}}"#.utf8)
        let hex = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: Data("sentry-client-secret-0001".utf8))).map { String(format: "%02x", $0) }.joined()
        _ = try await RCVTestKit.deliver(service, source: view.id, opened: .init(headers: ["sentry-hook-signature": hex, "sentry-hook-resource": "issue"], body: body))
        let event = try await service.events().first!
        XCTAssertEqual(event.status, .unrouted)
        XCTAssertEqual(event.fields["project"], "web")
        let acks = await frames.acks()
        XCTAssertEqual(acks, [BackendRCVWire.ackKept])
        let (token, _) = try await service.createSource(preset: "webhook", name: "Hook")
        do { _ = try await service.setSecret(token.id, value: "has spaces and is short"); XCTFail("a token that cannot travel in an address") } catch {}
        do { _ = try await service.setSecret(view.id, value: "line\nbreak-secret"); XCTFail("a secret with a line break") } catch {}
        XCTAssertEqual(BackendRCVWire.httpBase("wss://relay.terminaldeck.dev"), "https://relay.terminaldeck.dev")
        XCTAssertEqual(BackendRCVWire.httpBase("ws://127.0.0.1:8080/v1/host"), "http://127.0.0.1:8080")
        XCTAssertNil(BackendRCVWire.httpBase(nil))
    }

    func testSessionTypingRemovesEveryControlCharacter() {
        let typed = BackendRCVProductionDispatch.printable("ls\u{1b}[201~\r\nrm -rf /\u{3}\u{7f}\u{9b}x")
        XCTAssertFalse(typed.unicodeScalars.contains { $0.value < 0x20 && $0 != "\n" })
        XCTAssertFalse(typed.contains("\u{1b}"))
        XCTAssertTrue(typed.contains("rm -rf /"))
    }
}
