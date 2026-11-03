import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Local web pairing", .serialized)
struct WEBLocalPairingTests {
    private actor Capture {
        var frames: [NativeRPCValue] = []
        func receive(_ text: String) throws { frames.append(try NativeRPCValue.parseJSON(Data(text.utf8))) }
    }
    private func withTrust(_ run: (BackendRemoteTrustStore, URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WEBPair-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let trust = BackendRemoteTrustStore(directory: directory)
        try await trust.open()
        do { try await run(trust, directory); await trust.close() }
        catch { await trust.close(); throw error }
    }
    private func hello(_ token: String) -> String {
        NativeRPCValue.object([.init("t", .string("hello")), .init("protocol", .number(1)), .init("token", .string(token)),
            .init("device", .object([.init("name", .string("Test browser")), .init("platform", .string("web"))])),
            .init("capabilities", .array([.string("device.access")]))]).compact
    }

    @Test func offersAreRandomSingleUseExpireAndCancelIndependentlyOfPhoneCodes() throws {
        var offers = BackendRemoteLocalWebPairing()
        let first = try offers.create(now: 0), second = try offers.create(now: 0)
        #expect(first.token.utf8.count == 43)
        let distinct = first.token != second.token
        #expect(distinct)
        let outcomes = [offers.consume(String(repeating: "x", count: 43), now: 1),
            offers.consume(first.token, now: 2), offers.consume(first.token, now: 3), offers.consume(second.token, now: 60_000)]
        #expect(outcomes == [false, true, false, false])
        let third = try offers.create(now: 60_001)
        offers.cancel()
        let cancelled = offers.consume(third.token, now: 60_002)
        #expect(!cancelled)
    }

    @Test func localApprovalUsesOrdinaryPersistentTrustAndRespectsRevoke() async throws {
        try await withTrust { trust, _ in
            let phone = try await trust.createPairingOffer()
            let offer = try await trust.createLocalWebOffer()
            let issued = try await trust.redeemLocalWeb(offer.token, name: "Safari")
            let id = issued.device.id
            #expect(issued.device.approved && issued.device.platform == "web")
            #expect(await trust.kindOf(id) == .mine)
            #expect(await trust.phoneAccess(id) == .full)
            let verifiedID = try await trust.verify(issued.credential, address: "localhost", peerKey: nil).id
            #expect(verifiedID == id)
            let pairedPhone = try await trust.redeem(phone.token, name: "Phone", address: "relay", publicKey: nil)
            #expect(!pairedPhone.device.approved)
            do { _ = try await trust.redeemLocalWeb(offer.token, name: "Replay"); Issue.record("Bootstrap was reusable") } catch {}
            try await trust.setPhoneAccess(id, level: .look)
            #expect(await trust.phoneAccess(id) == .look)
            do { try await trust.requirePhoneAccess(id, message: "create"); Issue.record("Look allowed a mutation") } catch {}
            _ = try await trust.revoke(id)
            do { _ = try await trust.verify(issued.credential, address: "localhost", peerKey: nil); Issue.record("Revoked browser authenticated") } catch {}
        }
    }

    @Test func bootstrapRequiresListenerProvenLocalOriginAndReconnectUsesOrdinaryHello() async throws {
        try await withTrust { trust, directory in
            let capture = Capture(), clock = INT2PhoneHostClock()
            let host = BackendRemoteHost(trust: trust, manager: BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in }),
                state: NativeStateStore(), home: directory.path, hostName: "Test", appVersion: "test", privateRoots: [],
                sleep: { try await clock.sleep($0) }, clock: { clock.now() })
            try await host.start()
            do {
                let offer = try await trust.createLocalWebOffer()
                let remote = try #require(await host.accept(.init(address: "relay", send: { try await capture.receive($0) }, close: { _, _ in })))
                await host.receive(remote, text: hello(offer.token))
                #expect(await trust.listDevices().isEmpty)
                let local = try #require(await host.accept(.init(address: "127.0.0.1", localWebBootstrap: true,
                    send: { try await capture.receive($0) }, close: { _, _ in })))
                await host.receive(local, text: hello(offer.token))
                let frame = try #require(await capture.frames.first { $0["t"].string == "welcome" })
                let credential = try #require(frame["token"].string)
                let browser = try #require(await host.accept(.init(address: "127.0.0.1", send: { try await capture.receive($0) }, close: { _, _ in })))
                await host.receive(browser, text: hello(credential))
                #expect(await host.connections().count == 1)
                let id = try #require(frame["deviceId"].string)
                try await trust.setPhoneAccess(id, level: .hoot)
                await host.phoneAccessChanged(id)
                let access = try #require(await capture.frames.last { $0["t"].string == "device.access" })
                #expect(access["level"].string == "work")
                #expect(access["effectiveLevel"].string == "hoot")
                await host.stop()
            } catch { await host.stop(); throw error }
        }
    }
}
