import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// PHONE (8 Oct 2026). Asad: "as soon as I enter the code on my phone it takes me back to the
/// login page for the server", and the Mac logged nothing. The phone never reached the Mac: the
/// rendezvous offer the Mac shows carried its key as unpadded base64url, and the iPhone app reads
/// it with `Data(base64Encoded:)`, which refuses that spelling every time. The lookup came back
/// empty, the pairing sheet had already closed, and its "No machine is showing that code" notice
/// was left on the closed sheet, so the person saw only the login page.
///
/// `Rendezvous.parseOffer` and `RendezvousLookup` below are the iPhone app's own code
/// (`BackendRendezvous.generated.swift` is generated from the phone app's `Rendezvous.swift`,
/// unchanged since TestFlight 0.20.0), so these tests read the offer exactly as his phone does.
@MainActor
final class PHONEPairingRoundTripTests: XCTestCase {

    private static func randomBytes(_ count: Int) -> Data { Data((0..<count).map { _ in UInt8.random(in: 0...255) }) }

    /// The offer this Mac puts on the rendezvous slot must be one the phone (and another Mac) can read,
    /// for any key: about three keys in four contain a `+` or `/`, and every unpadded one failed.
    func testThePairingOfferThisMacShowsIsReadByThePhoneApp() throws {
        for _ in 0..<256 {
            let key = Self.randomBytes(32), hostID = BackendRelayPacketCodec.hostID(for: Self.randomBytes(32))
            let offer = BackendRemoteHostService.pairingOffer(relayURL: "wss://relay.terminaldeck.dev", hostID: hostID,
                                                              publicKey: key, hostName: "Studio Mac")
            let parsed = try XCTUnwrap(Rendezvous.parseOffer(offer.compact), "the phone could not read \(offer.compact)")
            XCTAssertEqual(parsed.hostKey, key)
            XCTAssertEqual(parsed.hostId, hostID)
            XCTAssertEqual(parsed.relayURL.absoluteString, "wss://relay.terminaldeck.dev")
            // Another Mac pairing with this one reads the key the way BackendMachineCoordinator.parseOffer does.
            let encoded = try XCTUnwrap(offer["publicKey"].string)
            XCTAssertEqual(BackendRemoteTrustStorage.decodeURL(encoded) ?? BackendRemoteTrustStorage.base64(encoded), key)
        }
    }

    /// The whole phone pairing over the real relay: the Mac shows a code, the phone's own lookup finds
    /// the Mac, the phone dials the Mac sealed and says hello with the code, and the Mac answers
    /// `welcome` with a credential. Throwaway identities and a temporary trust folder only; nothing of
    /// a real Mac or phone is read. Opt-in, because it opens sockets to the public relay.
    func testLivePhonePairsWithAMacThroughTheRelay() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["TD_PHONE_LIVE"] == "1" else { throw XCTSkip("Live relay round trip: set TD_PHONE_LIVE=1") }
        let relay = environment["TD_PHONE_RELAY"] ?? BackendRelayPacketCodec.defaultRelayURL
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PHONE-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let trust = BackendRemoteTrustStore(directory: directory)
        try await trust.open()
        let host = BackendRemoteHost(trust: trust, manager: BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in }),
                                     state: NativeStateStore(), home: directory.path, hostName: "PHONE test Mac",
                                     appVersion: "test", privateRoots: [directory.path])
        let service = BackendRemoteHostService(endpoint: host, ownPorts: BackendDevOwnPorts(), relayURL: relay,
                                               webRoot: nil, tailnet: nil, hostName: "PHONE test Mac")
        _ = try await service.start()
        var online = false
        for _ in 0..<150 where !online {
            online = await service.status().relay?.connected == true
            if !online { try await Task.sleep(for: .milliseconds(100)) }
        }
        XCTAssertTrue(online, "the test Mac never connected to \(relay)")

        // The Mac's screen: a six-digit code, findable at its rendezvous slot.
        let shown = try await service.showPairingCode()
        XCTAssertTrue(shown.findable, "the rendezvous beacon did not come up")

        // The phone: its own lookup, exactly as DeckModel.pairAsync runs it.
        let found = await RendezvousLookup().find(code: shown.code.token, relay: try XCTUnwrap(URL(string: relay)))
        let offer = try XCTUnwrap(found, "the phone's lookup found no machine: this is the 'back to the login page' bug")

        // The phone dials the machine the offer names and says hello with the code, as LiveTransport does.
        final class Wire { var frames: [NativeRPCValue] = []; var closed: CarrierClose? }
        let wire = Wire()
        let carrier = RelayCarrier(url: offer.endpoint.socketURL, hostKey: offer.hostKey, deviceKeys: StaticKeyPair.generate())
        let hello = NativeRPCValue.object([.init("t", .string("hello")), .init("protocol", .number(1)),
            .init("token", .string(shown.code.token)),
            .init("device", .object([.init("name", .string("PHONE test phone")), .init("platform", .string("ios"))])),
            .init("capabilities", .array([.string("device.access"), .string("hoot.events")]))]).compact
        carrier.onEvent = { [weak carrier] event in
            switch event {
            case .ready: carrier?.send(hello)
            case let .text(text): if let value = try? NativeRPCValue.parseJSON(Data(text.utf8)) { wire.frames.append(value) }
            case let .closed(close): wire.closed = close
            }
        }
        carrier.open()
        for _ in 0..<150 where wire.closed == nil && !wire.frames.contains(where: { $0["t"].string == "welcome" }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        carrier.close()
        let welcome = try XCTUnwrap(wire.frames.first { $0["t"].string == "welcome" }, "no welcome; frames \(wire.frames), close \(String(describing: wire.closed))")
        XCTAssertFalse((welcome["token"].string ?? "").isEmpty, "the welcome carried no credential")
        let paired = await trust.listDevices().map(\.name)
        XCTAssertEqual(paired, ["PHONE test phone"])

        await service.stop()
        await trust.close()
    }

    /// The Mac half of the simulator proof (`macos/round7/phone-sim.sh`): a throwaway Mac shows codes
    /// (written to TD_PHONE_SIM_CODE_FILE for the iPhone UI test to type), and once the phone has paired
    /// it approves it, the way the owner clicks Approve, so the phone can go on past "waiting for approval".
    func testLiveHoldACodeForTheSimulator() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let codeFile = environment["TD_PHONE_SIM_CODE_FILE"], !codeFile.isEmpty else {
            throw XCTSkip("Simulator proof: run macos/round7/phone-sim.sh")
        }
        let relay = environment["TD_PHONE_RELAY"] ?? BackendRelayPacketCodec.defaultRelayURL
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PHONE-sim-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let trust = BackendRemoteTrustStore(directory: directory)
        try await trust.open()
        let host = BackendRemoteHost(trust: trust, manager: BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in }),
                                     state: NativeStateStore(), home: directory.path, hostName: "PHONE sim Mac",
                                     appVersion: "test", privateRoots: [directory.path])
        let service = BackendRemoteHostService(endpoint: host, ownPorts: BackendDevOwnPorts(), relayURL: relay,
                                               webRoot: nil, tailnet: nil, hostName: "PHONE sim Mac")
        _ = try await service.start()
        var paired: BackendRemoteDevice?
        for _ in 0..<5 where paired == nil {
            let shown = try await service.showPairingCode()
            XCTAssertTrue(shown.findable)
            try shown.code.token.write(toFile: codeFile, atomically: true, encoding: .utf8)
            for _ in 0..<550 where paired == nil {
                paired = await trust.listDevices().first
                if paired == nil { try await Task.sleep(for: .milliseconds(100)) }
            }
        }
        try? FileManager.default.removeItem(atPath: codeFile)
        let device = try XCTUnwrap(paired, "no phone paired with the codes this Mac showed")
        try await Task.sleep(for: .seconds(8))
        try await trust.approve(device.id, kind: .mine)
        try await trust.setPhoneAccess(device.id, level: .full)
        await host.phoneAccessChanged(device.id)
        var connected = false
        for _ in 0..<900 where !connected {
            connected = !(await host.connections().isEmpty)
            if !connected { try await Task.sleep(for: .milliseconds(100)) }
        }
        XCTAssertTrue(connected, "the approved phone never reconnected")
        try await Task.sleep(for: .seconds(10))
        await service.stop()
        await trust.close()
    }
}
