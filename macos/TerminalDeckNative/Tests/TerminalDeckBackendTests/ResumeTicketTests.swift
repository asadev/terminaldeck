import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// 13 Nov (phone speed, 1a/1d): the resume hello sealed into the handshake's first message, and the tickets behind it.
/// Old/new combinations: an old phone (plain 80-byte message, no `resume.v1`) on this Mac; a new phone on this Mac;
/// a new phone on an old Mac is the phones' own tests (they never send early without a ticket, which only this Mac
/// issues, and drop a ticket after any failed try).
@Suite("Resume tickets", .serialized)
struct ResumeTicketTests {
    private actor Capture {
        var frames: [NativeRPCValue] = []
        func receive(_ text: String) throws { frames.append(try NativeRPCValue.parseJSON(Data(text.utf8))) }
        func of(_ type: String) -> [NativeRPCValue] { frames.filter { $0["t"].string == type } }
    }

    // MARK: Sealed channel

    @Test func earlyPayloadRidesTheFirstMessageAndBothEndsAgree() throws {
        let mac = StaticKeyPair.generate(), phone = StaticKeyPair.generate()
        var phoneBinding = Data()
        let started = try SealedHandshake.start(deviceStatic: phone, responderStaticPublic: mac.publicKey,
                                                early: { binding in phoneBinding = binding; return Data("early hello".utf8) })
        #expect(started.message.count == Sealed.noiseMessageBytes + Sealed.tagBytes + 11)
        let answered = try SealedHandshake.respondEarly(host: mac, message: started.message, known: [phone.publicKey], ephemeral: .generate())
        #expect(answered.early == Data("early hello".utf8))
        #expect(answered.earlyBinding == phoneBinding)
        let transport = try SealedHandshake.finish(pending: started.pending, reply: answered.reply)
        #expect(transport.channelBinding == answered.transport.channelBinding)
        #expect(try answered.transport.receive(transport.send(Data("after".utf8))) == Data("after".utf8))
        #expect(try transport.receive(answered.transport.send(Data("back".utf8))) == Data("back".utf8))
    }

    @Test func plainFirstMessageIsUnchanged() throws {
        let mac = StaticKeyPair.generate(), phone = StaticKeyPair.generate()
        let started = try SealedHandshake.start(deviceStatic: phone, responderStaticPublic: mac.publicKey)
        #expect(started.message.count == Sealed.noiseMessageBytes)
        let answered = try SealedHandshake.respondEarly(host: mac, message: started.message, known: [phone.publicKey], ephemeral: .generate())
        #expect(answered.early == nil && answered.earlyBinding == nil)
        _ = try SealedHandshake.finish(pending: started.pending, reply: answered.reply)
    }

    @Test func earlyPayloadIsRefusedWhenTamperedOrFromAPairingKey() throws {
        let mac = StaticKeyPair.generate(), phone = StaticKeyPair.generate()
        var started = try SealedHandshake.start(deviceStatic: phone, responderStaticPublic: mac.publicKey, early: { _ in Data("x".utf8) })
        // A pairing (unknown key permitted) gets no early payload handed up, though the transcript still matches.
        let pairing = try SealedHandshake.respondEarly(host: mac, message: started.message, known: [], permitUnknownPeer: true, ephemeral: .generate())
        #expect(pairing.early == nil)
        _ = try SealedHandshake.finish(pending: started.pending, reply: pairing.reply)
        started = try SealedHandshake.start(deviceStatic: phone, responderStaticPublic: mac.publicKey, early: { _ in Data("x".utf8) })
        var bent = started.message
        bent[bent.count - 1] ^= 1
        #expect(throws: (any Error).self) { try SealedHandshake.respondEarly(host: mac, message: bent, known: [phone.publicKey], ephemeral: .generate()) }
        // Too short to hold a sealed payload, or larger than the cap: a length failure.
        #expect(throws: SealedError.length) { try SealedHandshake.respondEarly(host: mac, message: started.message.prefix(90), known: [phone.publicKey], ephemeral: .generate()) }
        #expect(throws: SealedError.length) {
            try SealedHandshake.start(deviceStatic: phone, responderStaticPublic: mac.publicKey, early: { _ in Data(count: Sealed.mostEarlyBytes + 1) })
        }
    }

    /// The same vector the iPhone and Android tests check (HMAC-SHA256 over `td.resume.v1|<id>|` + binding).
    @Test func proofVectorMatchesThePhones() {
        #expect(BackendRemoteResume.proof(secret: Data(repeating: 1, count: 32), id: "abc", binding: Data(repeating: 2, count: 32))
                == "AvyoLs2HikxxQV5lNKuqw9fZ8918fKCspHHEmeTwUo8=")
    }

    // MARK: Host

    private struct Rig {
        let directory: URL, trust: BackendRemoteTrustStore, host: BackendRemoteHost, capture: Capture
        let deviceID: String, credential: String, key: Data
        func connect(binding: Data?) async throws -> UUID {
            var wire = BackendRemoteHostWire(address: "relay:test", peerPublicKey: key, send: { [capture] in try await capture.receive($0) }, close: { _, _ in })
            wire.channelBinding = Data(repeating: 7, count: 32)
            wire.earlyBinding = binding
            return try #require(await host.accept(wire))
        }
        func hello(_ id: UUID, token: String, claims: [String], resume: (String, String)? = nil) async throws {
            var fields: [NativeRPCValue.Field] = [.init("t", .string("hello")), .init("protocol", .number(1)), .init("token", .string(token)),
                .init("device", .object([.init("name", .string("Test phone")), .init("platform", .string("ios"))])),
                .init("capabilities", .array(claims.map(NativeRPCValue.string)))]
            if let resume { fields.append(.init("resume", .object([.init("id", .string(resume.0)), .init("proof", .string(resume.1))]))) }
            await host.receive(id, text: String(decoding: try NativeRPCValue.object(fields).encodedJSON(), as: UTF8.self))
        }
    }

    private func rig() async throws -> Rig {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Resume-" + UUID().uuidString)
        let trust = BackendRemoteTrustStore(directory: directory)
        try await trust.open()
        let key = StaticKeyPair.generate().publicKey
        let offer = try await trust.createPairingOffer()
        let paired = try await trust.redeem(offer.token, name: "Test phone", address: "test", publicKey: key, platform: "ios")
        _ = try await trust.approve(paired.device.id, kind: .mine)
        try await trust.setPhoneAccess(paired.device.id, level: .full)
        let capture = Capture()
        let host = BackendRemoteHost(trust: trust, manager: BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in }), state: NativeStateStore(),
                                     home: directory.path, hostName: "Test", appVersion: "test", privateRoots: [])
        try await host.start()
        return Rig(directory: directory, trust: trust, host: host, capture: capture, deviceID: paired.device.id, credential: paired.credential, key: key)
    }

    @Test func oldPhoneOnThisMacGetsNoTicketAndConnectsAsBefore() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.directory) }
        let id = try await r.connect(binding: nil)
        try await r.hello(id, token: r.credential, claims: ["device.access", "link.dc2"])
        #expect(await r.capture.of("welcome").count == 1)
        #expect(await r.capture.of("resume.ticket").isEmpty)
        #expect(await r.trust.resumeTicketCount == 0)
        await r.host.stop()
    }

    @Test func newPhoneResumesOnceWithAProofBoundToItsHandshake() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.directory) }
        let claims = ["device.access", "link.dc2", BackendRemoteResume.capability]
        let first = try await r.connect(binding: nil)
        try await r.hello(first, token: r.credential, claims: claims)
        let issued = try #require(await r.capture.of("resume.ticket").first)
        let ticket = try #require(issued["id"].string), secret = try #require(issued["key"].string.flatMap { Data(base64Encoded: $0) })
        #expect(issued["ttl"].number == BackendRemoteResume.lifetimeMs / 1000)

        // A proof for another handshake's transcript is refused, and spends the ticket.
        let bindingA = Data(repeating: 1, count: 32), bindingB = Data(repeating: 2, count: 32)
        let wrong = try await r.connect(binding: bindingA)
        try await r.hello(wrong, token: "resume", claims: claims, resume: (ticket, BackendRemoteResume.proof(secret: secret, id: ticket, binding: bindingB)))
        #expect(await r.capture.of("resume.no").count == 1)
        // The full hello on the same connection still works (a refused resume costs nothing over the old way).
        try await r.hello(wrong, token: r.credential, claims: claims)
        #expect(await r.capture.of("welcome").count == 2)

        let next = try #require(await r.capture.of("resume.ticket").last)
        let ticket2 = try #require(next["id"].string), secret2 = try #require(next["key"].string.flatMap { Data(base64Encoded: $0) })
        #expect(ticket2 != ticket)
        let fast = try await r.connect(binding: bindingA)
        try await r.hello(fast, token: "resume", claims: claims, resume: (ticket2, BackendRemoteResume.proof(secret: secret2, id: ticket2, binding: bindingA)))
        #expect(await r.capture.of("welcome").count == 3)
        #expect(await r.host.connections().contains { $0.id == fast })

        // Replayed (the relay resending the same first message): spent, refused.
        let replay = try await r.connect(binding: bindingA)
        try await r.hello(replay, token: "resume", claims: claims, resume: (ticket2, BackendRemoteResume.proof(secret: secret2, id: ticket2, binding: bindingA)))
        #expect(await r.capture.of("resume.no").count == 2)
        #expect(await r.capture.of("welcome").count == 3)
        // Not as the sealed first message (no early binding): refused even with a fresh ticket.
        let late = try #require(await r.capture.of("resume.ticket").last)
        let ticket3 = try #require(late["id"].string), secret3 = try #require(late["key"].string.flatMap { Data(base64Encoded: $0) })
        let plain = try await r.connect(binding: nil)
        try await r.hello(plain, token: "resume", claims: claims, resume: (ticket3, BackendRemoteResume.proof(secret: secret3, id: ticket3, binding: bindingA)))
        #expect(await r.capture.of("resume.no").count == 3)
        await r.host.stop()
    }

    @Test func aRevokedDeviceOrAnotherKeyCannotResume() async throws {
        let r = try await rig()
        defer { try? FileManager.default.removeItem(at: r.directory) }
        let other = StaticKeyPair.generate().publicKey
        await #expect(throws: (any Error).self) { _ = try await r.trust.issueResume(deviceID: r.deviceID, key: other) }
        let a = try await r.trust.issueResume(deviceID: r.deviceID, key: r.key)
        let binding = Data(repeating: 3, count: 32)
        #expect(await r.trust.redeemResume(id: a.id, proof: BackendRemoteResume.proof(secret: a.secret, id: a.id, binding: binding), binding: binding, key: other) == nil)
        let b = try await r.trust.issueResume(deviceID: r.deviceID, key: r.key)
        _ = try await r.trust.revoke(r.deviceID)
        #expect(await r.trust.redeemResume(id: b.id, proof: BackendRemoteResume.proof(secret: b.secret, id: b.id, binding: binding), binding: binding, key: r.key) == nil)
        await r.host.stop()
    }
}
