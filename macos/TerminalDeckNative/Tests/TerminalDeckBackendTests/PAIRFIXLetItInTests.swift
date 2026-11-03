import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// PAIRFIX (10 Oct 2026). Asad, recording the App Review demo: "pairing is not working now".
/// The phone redeemed the code and waited, but the Devices page's "Let it in" called
/// `remote:device:approve-access`, a channel nothing registered, so it failed every time; the
/// sheet's "Not now" then refused the phone for good. These tests drive the real channel the
/// sheet calls, over the real trust store and host.
@MainActor
final class PAIRFIXLetItInTests: XCTestCase {
    private struct Rig {
        let scratch: URL
        let root: BackendCompositionRoot
        let authority: BackendCompositionAuthority
        let trust: BackendRemoteTrustStore
        let host: BackendRemoteHost
        let service: BackendRemoteHostService
        let hootLease: NativeRPCSubscription?
    }

    private func rig(relay: String? = nil, hoot: Bool = false) async throws -> Rig {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("PAIRFIX-" + UUID().uuidString + ".noindex")
        let data = scratch.appendingPathComponent("data")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let store = try NativeStateStore(file: data.appendingPathComponent("state.json"), ownership: .memory)
        let root = try BackendCompositionRoot(dataRoot: data, state: store, environment: [:], home: scratch.path)
        let state = await BackendCompositionState.make(store: store, settings: root.settings, dataRoot: data,
            registry: root.registry, copilotRoot: { _ in scratch.appendingPathComponent("hoot").path })
        let configuration = try BackendAccountConfiguration(dataDirectory: data, homeDirectory: scratch,
            appName: "PAIRFIX Fixture", appID: "terminaldeck", helperExecutable: scratch.appendingPathComponent("never-run"),
            inheritedEnvironment: root.preparedSessions.environment)
        let authority = try BackendCompositionAuthority(prepared: root.preparedSessions, state: state, configuration: configuration,
            coreContexts: BackendDeckCoreToolContextAuthority(),
            gate: .init(authorize: { _, _, _, _, _, _ in throw NativeRPCError(code: "approval-required", message: "Fixture approval refused") },
                        record: { _, _, _, _ in }), hidden: .init())
        let trust = BackendRemoteTrustStore(directory: data.appendingPathComponent("remote"))
        try await trust.open()
        let host = BackendRemoteHost(trust: trust, manager: BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in }),
                                     state: NativeStateStore(), home: scratch.path, hostName: "PAIRFIX Mac",
                                     appVersion: "test", privateRoots: [scratch.path])
        var hootLease: NativeRPCSubscription?
        if hoot {
            // Hoot as the phone sees it: the real phone bridge over a Hoot owner with no agent process.
            let chat = try BackendHootChatStore(file: scratch.appendingPathComponent("hoot-history.json"))
            let runtime = BackendCopilotSessionRuntime(dependencies: .init(userData: scratch.path,
                driver: BackendCopilotSessionUnavailableDriver(), records: BackendCopilotSessionUnavailableRecords(), chat: chat))
            let bridge = BackendINT2HootPhone(trust: trust, endpoint: host, consent: BackendDeckCoreSecurityConsentBroker(ask: { _ in false }),
                runtime: { runtime }, log: { _ in [] }, setInteractive: { _ in })
            hootLease = try await host.installFeatures(ownerID: "pairfix.phone-hoot", features: [await bridge.feature()],
                                               connectionClosed: { await bridge.disconnected($0) })
        }
        let service = BackendRemoteHostService(endpoint: host, ownPorts: BackendDevOwnPorts(), relayURL: relay,
                                               webRoot: nil, tailnet: nil, hostName: "PAIRFIX Mac")
        _ = try await BackendCompositionRemoteChannels.register(registry: root.registry, ownerID: "pairfix-remote", authority: authority,
            service: service, settings: state, dropConnection: { _ in false })
        return .init(scratch: scratch, root: root, authority: authority, trust: trust, host: host, service: service, hootLease: hootLease)
    }

    private func pendingPhone(_ r: Rig, name: String) async throws -> String {
        let offer = try await r.trust.createPairingOffer()
        let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
        let issued = try await r.trust.redeem(offer.token, name: name, address: "relay", publicKey: key)
        XCTAssertEqual(issued.device.status, "pending")
        return issued.device.id
    }

    private func letIn(_ r: Rig, _ id: String, _ access: String) async throws -> NativeRPCValue {
        try await r.root.registry.invoke("remote:device:approve-access", context: try r.authority.localContext(),
                                         arguments: [.string(id), .string(access)])
    }

    func testLetItInApprovesTheWaitingPhoneWithTheChosenAccess() async throws {
        let r = try await rig(); defer { try? FileManager.default.removeItem(at: r.scratch) }
        let id = try await pendingPhone(r, name: "iPhone")
        let rows = try await letIn(r, id, "full")
        let row = try XCTUnwrap(rows.elements?.first { $0["id"].string == id }, "the reply has no row for the phone")
        XCTAssertEqual(row["status"].string, "approved")
        XCTAssertEqual(row["access"].string, "full")
        // The sheet's own check, exactly as RemoteSectionModel.letIn reads the reply.
        XCTAssertEqual(RemoteRead.stateAfter(rows.foundation, id: id), .approved)
        let approved = await r.trust.isApproved(id); XCTAssertTrue(approved)
        let level = await r.trust.phoneAccess(id); XCTAssertEqual(level, .full)
        // Hoot is shared only with the owner's own devices: Let it in makes it one.
        let linked = await BackendCopilotRemoteAccess(trust: r.trust).linked(id); XCTAssertTrue(linked)
    }

    func testPairingSheetCanApproveWorkWithoutGivingFullControl() async throws {
        let r = try await rig(); defer { try? FileManager.default.removeItem(at: r.scratch) }
        let id = try await pendingPhone(r, name: "Test browser")
        let rows = try await letIn(r, id, "work")
        XCTAssertEqual(rows.elements?.first { $0["id"].string == id }?["access"].string, "work")
        let level = await r.trust.phoneAccess(id)
        XCTAssertEqual(level, .work)
        XCTAssertTrue(level?.permits("create") == true)
        XCTAssertFalse(level?.permits("hoot.answer") == true)
        await r.trust.close()
    }

    func testHootOnlyLetsThePhoneTalkToHootAndNothingElse() async throws {
        let r = try await rig(); defer { try? FileManager.default.removeItem(at: r.scratch) }
        let id = try await pendingPhone(r, name: "iPhone")
        let rows = try await letIn(r, id, "hoot")
        XCTAssertEqual(rows.elements?.first { $0["id"].string == id }?["access"].string, "hoot")
        let maybe = await r.trust.phoneAccess(id)
        let level = try XCTUnwrap(maybe)
        for allowed in ["hello", "hoot.hello", "hoot.attach", "hoot.say", "hoot.start", "hoot.stop"] {
            XCTAssertTrue(level.permits(allowed), allowed)
        }
        for refused in ["list", "attach", "input", "create", "files.read", "git.status", "panel.read", "hoot.answer", "hoot.file.read", "devices.list"] {
            XCTAssertFalse(level.permits(refused), refused)
        }
        // Phones up to 0.20.0 know look/work/full only; they are told "work" so Hoot shows.
        XCTAssertEqual(level.wireLevel, "work")
    }

    func testABadAccessChangesNothing() async throws {
        let r = try await rig(); defer { try? FileManager.default.removeItem(at: r.scratch) }
        let id = try await pendingPhone(r, name: "iPhone")
        for bad in ["owner", "admin", ""] {
            do { _ = try await letIn(r, id, bad); XCTFail("\(bad) let the phone in") } catch {}
        }
        let approved = await r.trust.isApproved(id); XCTAssertFalse(approved)
        let pending = await r.trust.listDevices().first { $0.id == id }?.status; XCTAssertEqual(pending, "pending")
    }

    func testARefusedPhoneCannotBeLetIn() async throws {
        let r = try await rig(); defer { try? FileManager.default.removeItem(at: r.scratch) }
        let id = try await pendingPhone(r, name: "iPhone")
        _ = try await r.trust.revoke(id)
        do { _ = try await letIn(r, id, "full"); XCTFail("a refused phone was let in") } catch {}
        let approved = await r.trust.isApproved(id); XCTAssertFalse(approved)
    }

    func testRenameKeepsTheDevice() async throws {
        let r = try await rig(); defer { try? FileManager.default.removeItem(at: r.scratch) }
        let id = try await pendingPhone(r, name: "iPhone")
        _ = try await letIn(r, id, "full")
        _ = try await r.root.registry.invoke("remote:device:rename", context: try r.authority.localContext(),
                                             arguments: [.string(id), .string("Asad's iPhone")])
        let device = await r.trust.listDevices().first { $0.id == id }
        XCTAssertEqual(device?.name, "Asad's iPhone"); XCTAssertEqual(device?.status, "approved")
    }

    /// What the submitted phone is told once let in: its sessions, Hoot offered and linked.
    func testTheLetInPhonesWelcomeOffersHoot() async throws {
        for (access, sessions) in [("full", true), ("hoot", false)] {
            let r = try await rig(hoot: true); defer { try? FileManager.default.removeItem(at: r.scratch) }
            let offer = try await r.trust.createPairingOffer()
            let key = Data((0..<32).map { _ in UInt8.random(in: 0...255) })
            let issued = try await r.trust.redeem(offer.token, name: "iPhone", address: "relay", publicKey: key)
            _ = try await letIn(r, issued.device.id, access)
            let frames = BackendDeckCoreSecurityTestBox<[NativeRPCValue]>([])
            let wire = BackendRemoteHostWire(address: "relay", peerPublicKey: key, send: { text in
                if let value = try? NativeRPCValue.parseJSON(Data(text.utf8)) { frames.edit { $0.append(value) } }
            }, close: { _, _ in })
            try await r.host.start()
            let accepted = await r.host.accept(wire)
            let id = try XCTUnwrap(accepted)
            let hello = NativeRPCValue.object([.init("t", .string("hello")), .init("protocol", .number(1)), .init("token", .string(issued.credential)),
                .init("device", .object([.init("name", .string("iPhone")), .init("platform", .string("ios"))])),
                .init("capabilities", .array(["github", "devices", "settings", "watch", "device.access", "hoot.events"].map(NativeRPCValue.string)))]).compact
            await r.host.receive(id, text: hello)
            for _ in 0..<50 where !frames.get().contains(where: { $0["t"].string == "welcome" }) { try await Task.sleep(for: .milliseconds(50)) }
            let welcome = try XCTUnwrap(frames.get().first { $0["t"].string == "welcome" }, "\(access): no welcome; frames \(frames.get())")
            let capabilities = welcome["capabilities"].elements?.compactMap(\.string) ?? []
            XCTAssertTrue(capabilities.contains("hoot"), "\(access): Hoot not offered; capabilities \(capabilities)")
            XCTAssertEqual(welcome["hoot"]["linked"].bool, true, "\(access): Hoot not linked; welcome \(welcome)")
            XCTAssertEqual(welcome["hoot"]["grant"]["act"].bool, true, "\(access): cannot talk to Hoot")
            if !sessions { XCTAssertFalse(capabilities.contains("create"), "Hoot only was offered new sessions") }
            for _ in 0..<20 where !frames.get().contains(where: { $0["t"].string == "device.access" }) { try await Task.sleep(for: .milliseconds(50)) }
            let told = frames.get().first { $0["t"].string == "device.access" }?["level"].string
            XCTAssertEqual(told, access == "hoot" ? "work" : access)
        }
    }

    /// The Mac half of the simulator proof (`macos/design-2026-10-10/built.noindex/PAIRFIX/pair-sim.sh`):
    /// a throwaway Mac on the live relay with Hoot served shows codes into TD_PAIRFIX_CODE_FILE; once
    /// the submitted iPhone app has paired, it is let in through the same channel the sheet's
    /// "Let it in" calls, with Full control, and must come back connected.
    func testLiveLetItInForTheSimulator() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let codeFile = environment["TD_PAIRFIX_CODE_FILE"], !codeFile.isEmpty else {
            throw XCTSkip("Simulator proof: run pair-sim.sh")
        }
        let relay = environment["TD_PHONE_RELAY"] ?? BackendRelayPacketCodec.defaultRelayURL
        let r = try await rig(relay: relay, hoot: true); defer { try? FileManager.default.removeItem(at: r.scratch) }
        _ = try await r.service.start()
        var paired: BackendRemoteDevice?
        for _ in 0..<5 where paired == nil {
            let shown = try await r.service.showPairingCode()
            XCTAssertTrue(shown.findable)
            try shown.code.token.write(toFile: codeFile, atomically: true, encoding: .utf8)
            for _ in 0..<550 where paired == nil {
                paired = await r.trust.listDevices().first
                if paired == nil { try await Task.sleep(for: .milliseconds(100)) }
            }
        }
        try? FileManager.default.removeItem(atPath: codeFile)
        let device = try XCTUnwrap(paired, "no phone paired with the codes this Mac showed")
        XCTAssertEqual(device.status, "pending")
        try await Task.sleep(for: .seconds(6))
        let rows = try await letIn(r, device.id, "full")
        XCTAssertEqual(rows.elements?.first { $0["id"].string == device.id }?["access"].string, "full")
        var connected = false
        for _ in 0..<900 where !connected {
            connected = !(await r.host.connections().isEmpty)
            if !connected { try await Task.sleep(for: .milliseconds(100)) }
        }
        XCTAssertTrue(connected, "the approved phone never reconnected")
        try "connected".write(toFile: codeFile + ".connected", atomically: true, encoding: .utf8)
        try await Task.sleep(for: .seconds(40))
        await r.service.stop()
        await r.trust.close()
    }
}
