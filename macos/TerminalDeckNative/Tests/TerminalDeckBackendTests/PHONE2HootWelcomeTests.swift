import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// PHONE2 (9 Oct 2026). Asad, with his iPhone connected with full control: "i dont see hoot in my phone".
/// The phone draws its Hoot tab only when the `welcome` carries the `hoot` link object; the native
/// host never wrote it. These pin who gets it: the owner's own approved phone, where Hoot is served.
@Suite("PHONE2 Hoot in the phone's welcome", .serialized)
struct PHONE2HootWelcomeTests {
    private actor Capture {
        var frames: [NativeRPCValue] = []
        func receive(_ text: String) throws { frames.append(try NativeRPCValue.parseJSON(Data(text.utf8))) }
    }

    private func welcome(kind: BackendRemoteDeviceKind, access: BackendINT2PhoneAccessLevel?, hootServed: Bool) async throws -> NativeRPCValue {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PHONE2-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let trust = BackendRemoteTrustStore(directory: directory)
        try await trust.open()
        let offer = try await trust.createPairingOffer()
        let paired = try await trust.redeem(offer.token, name: "Asad's iPhone", address: "test", publicKey: nil)
        try await trust.approve(paired.device.id, kind: kind)
        if let access { try await trust.setPhoneAccess(paired.device.id, level: access) }
        let capture = Capture()
        // These assertions cover welcome projection. Debug token hashing can exceed the
        // production hello window under concurrent tests; keep its cancellable timer separate.
        let host = BackendRemoteHost(trust: trust, manager: BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in }),
                                     state: NativeStateStore(), home: directory.path, hostName: "Test", appVersion: "test", privateRoots: [],
                                     sleep: { _ in try await Task.sleep(for: .seconds(60)) })
        if hootServed {
            try await host.register(.init(capability: "hoot", messageTypes: ["hoot.hello"], policy: .ownerOnly) { _, _ in [] })
        }
        try await host.start()
        let connection = try #require(await host.accept(.init(address: "test", send: { try await capture.receive($0) }, close: { _, _ in })))
        let hello = NativeRPCValue.object([.init("t", .string("hello")), .init("protocol", .number(1)),
            .init("token", .string(paired.credential)),
            .init("device", .object([.init("name", .string("Asad's iPhone")), .init("platform", .string("ios"))])),
            .init("capabilities", .array([.string("device.access"), .string("hoot.events")]))])
        await host.receive(connection, text: String(decoding: try hello.encodedJSON(), as: UTF8.self))
        let frame = try #require(await capture.frames.first { $0["t"].string == "welcome" })
        await host.stop()
        await trust.close()
        return frame
    }

    @Test func theOwnersPhoneWithFullControlIsToldHootIsThere() async throws {
        let frame = try await welcome(kind: .mine, access: .full, hootServed: true)
        let link = frame["hoot"]
        #expect(link["linked"].bool == true)
        #expect(link["open"].bool == false)
        #expect(link["grant"]["read"].bool == true && link["grant"]["act"].bool == true && link["grant"]["alter"].bool == true)
    }

    @Test func aLookOnlyPhoneSeesHootButCannotAct() async throws {
        let link = try await welcome(kind: .mine, access: .look, hootServed: true)["hoot"]
        #expect(link["linked"].bool == true)
        #expect(link["grant"]["read"].bool == true && link["grant"]["act"].bool == false && link["grant"]["alter"].bool == false)
    }

    @Test func aGuestOrAMacWithoutHootSaysNothing() async throws {
        #expect(try await welcome(kind: .guest, access: .full, hootServed: true)["hoot"] == .missing)
        #expect(try await welcome(kind: .mine, access: .full, hootServed: false)["hoot"] == .missing)
    }
}
