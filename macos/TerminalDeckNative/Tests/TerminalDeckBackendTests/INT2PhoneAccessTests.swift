import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

@Suite("INT2 host-issued phone access", .serialized)
struct INT2PhoneAccessTests {
    private actor Capture {
        var frames: [NativeRPCValue] = []
        var calls = 0
        func receive(_ text: String) throws { frames.append(try NativeRPCValue.parseJSON(Data(text.utf8))) }
        func called() { calls += 1 }
    }
    private func fixture() async throws -> (URL, BackendRemoteTrustStore, BackendRemoteCredential) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("INT2Phone-" + UUID().uuidString)
        let trust = BackendRemoteTrustStore(directory: directory)
        try await trust.open()
        let offer = try await trust.createPairingOffer()
        let device = try await trust.redeem(offer.token, name: "Test phone", address: "test", publicKey: nil)
        return (directory, trust, device)
    }
    @Test func pairingAndApprovalNeverCreateAccess() async throws {
        let (directory, trust, device) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(await trust.phoneAccess(device.device.id) == nil)
        try await trust.approve(device.device.id, kind: .mine)
        #expect(await trust.phoneAccess(device.device.id) == nil)
        do { try await trust.requirePhoneAccess(device.device.id, message: "list"); Issue.record("Unset grant was accepted") } catch {}
        do { try await trust.setPhoneAccess("unknown", level: .full); Issue.record("Unknown device received Full") } catch {}
        await trust.close()
    }
    @Test func persistedGrantRevocationAndUnknownValueFailClosed() async throws {
        let (directory, trust, device) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await trust.approve(device.device.id, kind: .mine)
        try await trust.setPhoneAccess(device.device.id, level: .work)
        await trust.close(); try await trust.open()
        #expect(await trust.phoneAccess(device.device.id) == .work)
        try await trust.setPhoneAccess(device.device.id, level: nil)
        await trust.close(); try await trust.open()
        #expect(await trust.phoneAccess(device.device.id) == nil)
        await trust.close()
        try NativeRPCValue.object([.init("version", .number(1)), .init("devices", .object([
            .init(device.device.id, .string("administrator"))]))]).encodedJSON().write(to: directory.appendingPathComponent("remote-access.json"))
        try await trust.open()
        #expect(await trust.phoneAccess(device.device.id) == nil)
        try await trust.setPhoneAccess(device.device.id, level: .full)
        try await trust.revoke(device.device.id)
        #expect(await trust.phoneAccess(device.device.id) == nil)
        do { try await trust.requirePhoneAccess(device.device.id, message: "input"); Issue.record("Revoked device could write") } catch {}
        await trust.close()
    }
    @Test func fullKeepsExistingFolderAccountSessionAndWindowFences() async throws {
        let (directory, trust, device) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = device.device.id
        try await trust.approve(id, kind: .guest)
        try await trust.setFolderGrants(id, folders: [directory.appendingPathComponent("allowed").path])
        try await trust.setAccountGrants(id, all: false, accounts: ["allowed-account"])
        try await trust.setSessionGrants(id, all: false, sessions: ["allowed-session"])
        try await trust.setWindowGrant(id, drives: false)
        try await trust.setPhoneAccess(id, level: .full)
        #expect(await trust.canReachFolder(id, folder: directory.appendingPathComponent("allowed/subfolder").path))
        #expect(await !trust.canReachFolder(id, folder: directory.appendingPathComponent("other").path))
        #expect(await trust.accountAllowed(id, account: "allowed-account"))
        #expect(await !trust.accountAllowed(id, account: "other-account"))
        #expect(await trust.sessionShared(id, session: "allowed-session"))
        #expect(await !trust.sessionShared(id, session: "other-session"))
        #expect(await !trust.drivesWindows(id))
        await trust.close()
    }
    @Test func expiredQuestionCannotBeAnsweredWhileDeliveryIsStillAwaiting() async throws {
        let now = BackendDeckCoreSecurityTestBox<Double>(1_000)
        let asked = BackendDeckCoreTestPortSecuritySignal(), release = BackendDeckCoreTestPortSecuritySignal()
        let broker = BackendDeckCoreSecurityConsentBroker(timeoutMilliseconds: 60_000, now: { now.get() }, ask: { _ in
            asked.signal(); await release.wait(1); return true
        })
        let request = Task { await broker.request(tool: "hoot.cli", tier: .alter, summary: "Fixture confirmation",
            arguments: .object([]), origin: "device:test-phone") }
        await asked.wait(1)
        let question = try #require(await broker.list().first)
        now.edit { $0 = question.expiresAt + 1 }
        #expect(await !broker.mayAnswer(id: question.id, by: "device:test-phone"))
        #expect(await !broker.respond(id: question.id, approved: true, by: "device:test-phone"))
        release.signal()
        let outcome = await request.value
        #expect(!outcome.granted && outcome.reason == .timeout)
        #expect(await !broker.respond(id: question.id, approved: true, by: "device:test-phone"))
        await broker.stop()
    }
    @Test func hostEnforcesLevelsAndPushesWithdrawal() async throws {
        let (directory, trust, device) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await trust.approve(device.device.id, kind: .mine)
        let capture = Capture(), manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
        let host = BackendRemoteHost(trust: trust, manager: manager, state: NativeStateStore(),
            home: directory.path, hostName: "Test", appVersion: "test", privateRoots: [])
        try await host.register(.init(capability: "settings", messageTypes: ["settings.read", "settings.apply"], policy: .grantedDevice) { _, _ in
            await capture.called(); return []
        })
        try await host.start()
        var connection = try #require(await host.accept(.init(address: "test", send: { try await capture.receive($0) }, close: { _, _ in })))
        func send(_ type: String, _ fields: [NativeRPCValue.Field] = []) async throws {
            let value = NativeRPCValue.object([.init("t", .string(type))] + fields)
            await host.receive(connection, text: String(decoding: try value.encodedJSON(), as: UTF8.self))
        }
        try await send("hello", [.init("protocol", .number(1)), .init("token", .string(device.credential)),
            .init("device", .object([.init("name", .string("Test phone")), .init("platform", .string("ios"))])),
            .init("capabilities", .array([.string("device.access"), .string("settings")]))])
        try await send("settings.read", [.init("rid", .string("test-read"))])
        #expect(await capture.calls == 0)
        try await trust.setPhoneAccess(device.device.id, level: .look); await host.phoneAccessChanged(device.device.id)
        try await send("settings.read", [.init("rid", .string("test-read"))])
        #expect(await capture.calls == 1)
        try await send("device.access.set", [.init("level", .string("full"))])
        #expect(await trust.phoneAccess(device.device.id) == .look)
        #expect(await host.connections().isEmpty)
        connection = try #require(await host.accept(.init(address: "test", send: { try await capture.receive($0) }, close: { _, _ in })))
        try await send("hello", [.init("protocol", .number(1)), .init("token", .string(device.credential)),
            .init("device", .object([.init("name", .string("Test phone")), .init("platform", .string("ios"))])),
            .init("capabilities", .array([.string("device.access"), .string("settings")]))])
        try await send("settings.apply", [.init("rid", .string("test-write")), .init("key", .string("agents.defaultProvider")), .init("value", .string("codex"))])
        #expect(await capture.calls == 1)
        try await trust.setPhoneAccess(device.device.id, level: .work)
        try await send("settings.apply", [.init("rid", .string("test-write")), .init("key", .string("agents.defaultProvider")), .init("value", .string("codex"))])
        #expect(await capture.calls == 1)
        try await trust.setPhoneAccess(device.device.id, level: .full)
        try await send("settings.apply", [.init("rid", .string("test-write")), .init("key", .string("agents.defaultProvider")), .init("value", .string("codex"))])
        #expect(await capture.calls == 2)
        try await trust.setPhoneAccess(device.device.id, level: nil); await host.phoneAccessChanged(device.device.id)
        try await send("settings.read", [.init("rid", .string("test-read"))])
        #expect(await capture.calls == 2)
        let frames = await capture.frames
        #expect(frames.contains { $0["t"].string == "device.access" && $0["level"] == .null })
        await host.stop()
    }
}
