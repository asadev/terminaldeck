import CoreVideo
import Darwin
import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Mac reach private transport and boot boundary", .serialized)
struct MacReachBackendTests {
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mac-reach-" + UUID().uuidString)
        var source: URL { root.appendingPathComponent("user/remote") }
        var target: URL { root.appendingPathComponent("system/remote") }
        init() throws {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let key = BackendSealedIdentity.generate()
            try save(.object([.init("hostSecret", .string(Data(repeating: 7, count: 32).base64EncodedString())),
                .init("privateKey", .string(key.privateKey.base64EncodedString())), .init("publicKey", .string(key.publicKey.base64EncodedString()))]), "relay-identity.json")
            try roster()
        }
        func save(_ value: NativeRPCValue, _ name: String) throws {
            let path = source.appendingPathComponent(name)
            try value.encodedJSON().write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        }
        func roster(revoked: Bool = false, level: String = "full", kind: String = "mine") throws {
            try save(.object([.init("devices", .array([.object([.init("id", .string("phone")), .init("approved", .bool(true)),
                .init("revoked", .bool(revoked)), .init("platform", .string("ios"))])]))]), "remote-auth.json")
            try save(.object([.init("devices", .object([.init("phone", .object([.init("kind", .string(kind))]))]))]), "remote-device-kinds.json")
            try save(.object([.init("devices", .object([.init("phone", .string(level))]))]), "remote-access.json")
        }
        func stage() throws -> BackendMacReachTrust.Counts { try BackendMacReachTrust.stage(from: source, owner: getuid(), to: target) }
        func close() { try? FileManager.default.removeItem(at: root) }
    }
    @Test func bootUsesTheExistingIdentityWithoutRotatingIt() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        #expect(try fixture.stage().controllers == 1)
        let before = try NativeRPCValue.parseJSON(Data(contentsOf: fixture.source.appendingPathComponent("relay-identity.json")))
        let after = try NativeRPCValue.parseJSON(Data(contentsOf: fixture.target.appendingPathComponent("relay-identity.json")))
        let preserved = ["hostSecret", "privateKey", "publicKey"].allSatisfy { before[$0].string == after[$0].string }
        #expect(preserved)
    }
    @Test func aRevocationCannotBeRestoredByAnOlderCopy() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        #expect(try fixture.stage().controllers == 1)
        try fixture.roster(revoked: true)
        #expect(try fixture.stage().controllers == 0)
        let raw = try NativeRPCValue.parseJSON(Data(contentsOf: fixture.target.appendingPathComponent("remote-auth.json")))
        #expect(raw["devices"].elements?.isEmpty == true)
    }
    @Test func workAccessCannotControlSignIn() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        try fixture.roster(level: "work")
        let counts = try fixture.stage()
        #expect(counts.controllers == 0 && counts.phones == 1)
        try fixture.roster(level: "full", kind: "guest")
        #expect(try fixture.stage().controllers == 0)
    }
    @Test func symlinkAndDifferentOwnerCannotSupplyBootTrust() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        #expect(throws: (any Error).self) { try BackendMacReachTrust.stage(from: fixture.source, owner: getuid() + 1, to: fixture.target) }
        let identity = fixture.source.appendingPathComponent("relay-identity.json")
        let saved = fixture.source.appendingPathComponent("fixture-identity.json")
        try FileManager.default.moveItem(at: identity, to: saved)
        try FileManager.default.createSymbolicLink(at: identity, withDestinationURL: saved)
        #expect(throws: (any Error).self) { try fixture.stage() }
    }
    @Test func malformedIdentityNeverCreatesAnotherMacIdentity() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        try fixture.save(.object([]), "relay-identity.json")
        #expect(throws: (any Error).self) { try fixture.stage() }
        #expect(!FileManager.default.fileExists(atPath: fixture.target.appendingPathComponent("relay-identity.json").path))
    }
    @Test func latestOffAndUnreadablePreferencesFailClosed() throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let path = fixture.source.deletingLastPathComponent().appendingPathComponent("settings.json")
        try NativeRPCValue.object([.init("values", .object([.init("remote.macScreenAllowed", .bool(false)),
            .init("remote.keepAwakeOnPower", .bool(false))]))]).encodedJSON().write(to: path)
        let off = BackendMacReachTrust.screenAllowed(trustDirectory: fixture.source, owner: getuid())
        #expect(!off)
        try Data("{broken".utf8).write(to: path)
        let broken = BackendMacReachTrust.screenAllowed(trustDirectory: fixture.source, owner: getuid())
        #expect(!broken)
    }
    @Test func boundedRawPixelsRoundTripWithoutAFile() throws {
        var buffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 4, 2, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        let original = try #require(buffer)
        CVPixelBufferLockBaseAddress(original, [])
        memset(CVPixelBufferGetBaseAddress(original), 43, CVPixelBufferGetBytesPerRow(original) * 2)
        CVPixelBufferUnlockBaseAddress(original, [])
        let encoded = try BackendMacReachPixels.encode(original, capturedAt: 1234)
        let decoded = try BackendMacReachPixels.decode(encoded)
        #expect(decoded.capturedAt == 1234)
        #expect(CVPixelBufferGetWidth(decoded.buffer) == 4 && CVPixelBufferGetHeight(decoded.buffer) == 2)
        CVPixelBufferLockBaseAddress(decoded.buffer, .readOnly)
        #expect(CVPixelBufferGetBaseAddress(decoded.buffer)?.load(as: UInt8.self) == 43)
        CVPixelBufferUnlockBaseAddress(decoded.buffer, .readOnly)
    }
    @Test func anOverflowingFrameHeaderIsRejected() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: ["width": 4, "height": 2, "stride": Int.max,
            "time": 1.0, "pixels": Data()], format: .binary, options: 0)
        #expect(throws: (any Error).self) { try BackendMacReachPixels.decode(data) }
    }
    @Test func sharedInputStillUsesTheOrdinaryValidatedVocabulary() throws {
        let inputs: [BackendPhoneDeviceInput] = [.tap(x: 0.2, y: 0.4, holdMilliseconds: nil), .type("fixture"), .key("return"),
            .shortcut("c", modifiers: ["command"]), .pointerTo(x: 0.3, y: 0.5, held: true), .click(button: "left", phase: nil),
            .keyCode(36, down: false, modifiers: []), .wheel(dx: 0, dy: 0.2)]
        for input in inputs {
            let decoded = try BackendMacReachInput.decode(BackendMacReachInput.wire(input, display: "mac:main"))
            // The existing Mac decoder represents an unmodified named key as shortcut(key, []), with the same events.
            let expected: BackendPhoneDeviceInput
            if case .key(let name) = input { expected = .shortcut(name, modifiers: []) } else { expected = input }
            #expect(decoded == expected)
        }
    }
    @Test func passwordIsAMacOnlyBoundedTransientMessage() {
        func parse(_ id: String, count: Int) -> BackendRemoteClientParse {
            BackendRemoteProtocol.parseClientMessage(.object([.init("t", .string("sims.unlock")), .init("rid", .string("fixture")),
                .init("id", .string(id)), .init("password", .string(String(repeating: "x", count: count)))]))
        }
        if case .message(let message) = parse("mac:main", count: 12) { #expect(message.type == "sims.unlock") }
        else { Issue.record("A bounded Mac sign-in message was refused") }
        if case .refused = parse("ios:fixture", count: 12) {} else { Issue.record("A phone is not a Mac sign-in screen") }
        if case .refused = parse("mac:main", count: 2_001) {} else { Issue.record("An oversized password was accepted") }
    }
    private actor Counter {
        var calls = 0
        var frames: [NativeRPCValue] = []
        func called() { calls += 1 }
        func frame(_ text: String) throws { frames.append(try NativeRPCValue.parseJSON(Data(text.utf8))) }
    }
    @Test func bootEndpointRefusesEvenAnApprovedFullOwnersSessionCreation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reach-endpoint-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let trust = BackendRemoteTrustStore(directory: root)
        try await trust.open()
        let offer = try await trust.createPairingOffer()
        let device = try await trust.redeem(offer.token, name: "Fixture phone", address: "fixture", publicKey: nil)
        try await trust.approve(device.device.id, kind: .mine)
        try await trust.setPhoneAccess(device.device.id, level: .full)
        let counter = Counter()
        let host = BackendRemoteHost(trust: trust, manager: BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in }),
            state: NativeStateStore(), home: root.path, hostName: "Fixture", appVersion: "test", privateRoots: [],
            operations: .init(create: { _, _ in await counter.called(); throw NativeRPCError(code: "unavailable", message: "Fixture") }), screenOnly: true)
        try await host.start()
        let id = try #require(await host.accept(.init(address: "fixture", send: { try await counter.frame($0) }, close: { _, _ in })))
        let hello = NativeRPCValue.object([.init("t", .string("hello")), .init("protocol", .number(1)), .init("token", .string(device.credential)),
            .init("device", .object([.init("name", .string("Fixture")), .init("platform", .string("ios"))])), .init("capabilities", .array([.string("device.access")]))])
        await host.receive(id, text: String(decoding: try hello.encodedJSON(), as: UTF8.self))
        let create = NativeRPCValue.object([.init("t", .string("create")), .init("rid", .string("new")), .init("cwd", .string(root.path)),
            .init("cols", .number(80)), .init("rows", .number(24))])
        await host.receive(id, text: String(decoding: try create.encodedJSON(), as: UTF8.self))
        #expect(await counter.calls == 0)
        let frames = await counter.frames
        #expect(frames.contains { $0["t"].string == "welcome" })
        #expect(frames.contains { $0["t"].string == "error" && $0["message"].string == "Before sign-in, this Mac serves only its sign-in screen." })
        await host.stop(); await trust.close()
    }
}
