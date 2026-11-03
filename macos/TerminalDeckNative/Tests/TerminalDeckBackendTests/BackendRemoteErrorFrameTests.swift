import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// U58 (#58): one error from a linked machine fails only the request it belongs to.
@Suite("Remote error frames name their request", .serialized)
struct BackendRemoteErrorFrameTests {
    private actor Capture {
        var frames: [NativeRPCValue] = []
        func receive(_ text: String) throws { frames.append(try NativeRPCValue.parseJSON(Data(text.utf8))) }
    }

    @Test("the host's refusal of a request carries its rid; a stray refusal carries none") func hostStampsRid() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteErrorFrame-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let trust = BackendRemoteTrustStore(directory: directory)
        try await trust.open()
        let device = try await trust.redeem(try await trust.createPairingOffer().token, name: "Test phone", address: "test", publicKey: nil)
        try await trust.approve(device.device.id, kind: .mine)
        try await trust.setPhoneAccess(device.device.id, level: .full)
        let capture = Capture(), clock = INT2PhoneHostClock()
        let host = BackendRemoteHost(trust: trust, manager: BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in }), state: NativeStateStore(),
            home: directory.path, hostName: "Test", appVersion: "test", privateRoots: [],
            sleep: { try await clock.sleep($0) }, clock: { clock.now() })
        try await host.register(.init(capability: "settings", messageTypes: ["settings.read"], policy: .grantedDevice) { _, _ in
            throw NativeRPCError(code: "unavailable", message: "Settings cannot be read just now.")
        })
        try await host.start()
        let connection = try #require(await host.accept(.init(address: "test", send: { try await capture.receive($0) }, close: { _, _ in })))
        func send(_ type: String, _ fields: [NativeRPCValue.Field]) async throws {
            await host.receive(connection, text: String(decoding: try NativeRPCValue.object([.init("t", .string(type))] + fields).encodedJSON(), as: UTF8.self))
        }
        try await send("hello", [.init("protocol", .number(1)), .init("token", .string(device.credential)),
            .init("device", .object([.init("name", .string("Test phone")), .init("platform", .string("ios"))])),
            .init("capabilities", .array([.string("settings")]))])
        try await send("settings.read", [.init("rid", .string("read-1"))])
        try await send("input", [.init("id", .string("closed-session")), .init("data", .string("x"))])
        let errors = await capture.frames.filter { $0["t"].string == "error" }
        #expect(errors.count == 2)
        #expect(errors.first?["rid"].string == "read-1" && errors.first?["code"].string == "unavailable")
        #expect(errors.last?["rid"] == .missing)
        await host.stop(); await trust.close()
    }

    @Test("the guest fails only the waiting request an error names") func guestFailsOnlyTheNamedRequest() {
        let pending = ["read-1": "rid", "read-2": "rid", "tunnel-1": "id"]
        func error(_ fields: [NativeRPCValue.Field]) -> NativeRPCValue {
            .object([.init("t", .string("error")), .init("code", .string("unknown-session")), .init("message", .string("gone"))] + fields)
        }
        #expect(BackendRemoteGuest.requestNamed(by: error([]), in: pending) == nil)
        #expect(BackendRemoteGuest.requestNamed(by: error([.init("rid", .string("read-2"))]), in: pending) == "read-2")
        #expect(BackendRemoteGuest.requestNamed(by: error([.init("rid", .string("someone-else"))]), in: pending) == nil)
    }
}
