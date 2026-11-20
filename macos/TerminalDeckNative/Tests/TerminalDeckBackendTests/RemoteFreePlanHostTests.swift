import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Asad, 19 Nov 2026 (PAYMENTS-DESIGN.md "19 Nov changes"): a free account's devices get this computer's sessions only.
/// The relay cannot see inside the sealed link, so the host refuses the paid kinds itself. Over the real host and a
/// paired device of the person's own: paid kinds get the one refusal, session kinds and every other page are served,
/// and with the paywall off (or a paid account) nothing changes.
@Suite("Free plan: a free account's devices get this computer's sessions only", .serialized)
struct RemoteFreePlanHostTests {
    private actor Wire {
        var frames: [NativeRPCValue] = []
        var closed: (Int, String)?
        func close(_ code: Int, _ reason: String) { closed = (code, reason) }
        func receive(_ text: String) throws { frames.append(try NativeRPCValue.parseJSON(Data(text.utf8))) }
        func rows(_ type: String) -> [NativeRPCValue] { frames.filter { $0["t"].string == type } }
        func error(_ rid: String) -> NativeRPCValue? { rows("error").first { $0["rid"].string == rid } }
    }
    private actor Calls {
        var kinds: [String] = []
        func note(_ kind: String) { kinds.append(kind) }
    }
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var free = true
        func set(_ value: Bool) { lock.withLock { free = value } }
        func get() -> Bool { lock.withLock { free } }
    }

    @Test func theListMatchesTheDecision() {
        typealias F = BackendRemoteFreePlan
        // Refused: browser windows, simulator / device / this computer's screens, files, a session driving this
        // computer's browser windows, Tasks and the Simulators page.
        for kind in ["ports", "tunnel.open", "tunnel.close", "net.open", "net.data", "net.ack", "net.close",
                     "browser.windows", "browser.window.open", "browser.window.act", "browser.watch", "browser.input",
                     "browser.surfaces", "browser.handover.take", "browser.profiles", "browser.profile.use",
                     "sims.list", "sims.watch", "sims.input", "sims.touch", "sims.record", "sims.key", "sims.shot",
                     "sims.annotate", "sims.unlock", "sims.power", "files.list", "files.read", "window.call"] {
            #expect(F.isPaid(kind, panel: nil), "\(kind)")
        }
        for panel in ["tasks", "connected-tasks", "simulators"] {
            #expect(F.isPaid("panel.read", panel: panel), "\(panel)")
            #expect(F.isPaid("panel.act", panel: panel), "\(panel)")
        }
        // Served: sessions (list, view, type, continue, start, close, rename), chats, Projects, Hoot, Activity, ...
        for kind in ["list", "attach", "detach", "take", "input", "resize", "create", "close", "rename", "session.send",
                     "chats.list", "chats.send", "chats.choices", "hoot.hello", "hoot.say", "hoot.files", "activity.watch",
                     "pictures", "picture", "push.register", "folders.browse", "upload.begin", "sessions.mine",
                     "window.holds", "window.result", "routines", "git.status", "usage.read", "account.read"] {
            #expect(!F.isPaid(kind, panel: nil), "\(kind)")
        }
        for panel in ["projects", "agents", "artifacts", "goals", "memory", "receiver"] {
            #expect(!F.isPaid("panel.read", panel: panel), "\(panel)")
        }
        let frame = try? F.refusal()
        #expect(frame?.value["code"] == .string("unauthorized"))
        #expect(frame?.value["reason"] == .string("subscription_required"))
        #expect(frame?.value["message"] == .string("Part of Terminal Deck Cloud"))
        // Every client already knows the code; a newer one reads the reason.
        #expect(BackendRemoteProtocol.errorCodes.contains(F.code))
    }

    @Test func aFreeAccountsDeviceGetsSessionsAndPagesButNoPaidKind() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FREEPLAN-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let trust = BackendRemoteTrustStore(directory: dir.appendingPathComponent("remote"))
        try await trust.open()
        let offer = try await trust.createPairingOffer()
        let device = try await trust.redeem(offer.token, name: "Phone", address: "fixture", publicKey: nil)
        _ = try await trust.approve(device.device.id, kind: .mine)
        try await trust.setPhoneAccess(device.device.id, level: .full)
        let clock = INT2PhoneHostClock()
        let host = BackendRemoteHost(trust: trust, manager: BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in }), state: NativeStateStore(),
            home: dir.path, hostName: "Fixture", appVersion: "test", privateRoots: [], sleep: { try await clock.sleep($0) }, clock: { clock.now() })
        let gate = Gate()
        await host.setFreePlanCheck { gate.get() }
        let calls = Calls()
        try await host.register(BackendRemoteHostFeature(capability: "files", messageTypes: BackendPhoneFiles.messages, policy: .ownerOnly) { message, _ in
            await calls.note(message.type); return []
        })
        try await host.register(BackendRemoteHostFeature(capability: "panels", messageTypes: ["panel.read", "panel.act"], policy: .grantedDevice) { message, _ in
            await calls.note("panel:" + (message["panel"].string ?? "")); return []
        })
        try await host.start()
        defer { Task { await host.stop(); await trust.close() } }

        let wire = Wire()
        let timer = clock.scheduled.value() + 1
        let id = try #require(await host.accept(.init(address: "fixture", send: { try await wire.receive($0) }, close: { await wire.close($0, $1) })))
        await clock.scheduled.wait(timer)
        let hello = NativeRPCValue.object([.init("t", .string("hello")), .init("protocol", .number(1)), .init("token", .string(device.credential)),
            .init("device", .object([.init("name", .string("Phone")), .init("platform", .string("ios"))])), .init("capabilities", .array([]))])
        await host.receive(id, text: String(decoding: try hello.encodedJSON(), as: UTF8.self))
        try await waitFor { await wire.rows("welcome").count == 1 }

        // Free account, paywall on: each paid kind gets the one refusal, with its rid; nothing behind it is asked.
        let path = dir.path
        let paid = ["f1": #"{"t":"files.list","path":"\#(path)","rid":"f1"}"#, "b1": #"{"t":"browser.windows","rid":"b1"}"#,
                    "s1": #"{"t":"sims.list","rid":"s1"}"#, "t1": #"{"t":"panel.read","panel":"tasks","rid":"t1"}"#]
        for (_, text) in paid { await host.receive(id, text: text) }
        for rid in paid.keys {
            try await waitFor { await wire.error(rid) != nil }
            let refusal = try #require(await wire.error(rid))
            #expect(refusal["code"].string == "unauthorized", "\(rid)")
            #expect(refusal["reason"].string == "subscription_required", "\(rid)")
            #expect(refusal["message"].string == "Part of Terminal Deck Cloud", "\(rid)")
        }
        // Sessions and every other page are served as before.
        let sessionsBefore = await wire.rows("sessions").count
        await host.receive(id, text: #"{"t":"list"}"#)
        await host.receive(id, text: #"{"t":"panel.read","panel":"projects","rid":"p1"}"#)
        try await waitFor { await wire.rows("sessions").count > sessionsBefore }
        try await waitFor { await calls.kinds.contains("panel:projects") }
        #expect(await wire.error("p1") == nil)
        #expect(await calls.kinds == ["panel:projects"], "no paid kind reached its handler")

        // Paywall off or a paid account: the same request is served as today.
        gate.set(false)
        await host.receive(id, text: #"{"t":"files.list","path":"\#(path)","rid":"f2"}"#)
        await host.receive(id, text: #"{"t":"panel.read","panel":"tasks","rid":"t2"}"#)
        try await waitFor { let kinds = await calls.kinds; return kinds.contains("files.list") && kinds.contains("panel:tasks") }
        #expect(await wire.error("f2") == nil)
        #expect(await wire.error("t2") == nil)

        // The plan becomes free (a lapse): the connection that was served paid kinds ends whole (its streams with it);
        // the device stays approved and reconnects.
        gate.set(true)
        #expect(await host.freePlanBegan() == 1)
        try await waitFor { await wire.closed != nil }
        #expect(await wire.closed?.0 == 1001)
        #expect(await wire.closed?.1 == "Part of Terminal Deck Cloud")
        #expect(await trust.isApproved(device.device.id))
        #expect(await host.freePlanBegan() == 0, "nothing left to close")
    }

    private func waitFor(_ predicate: @escaping @Sendable () async -> Bool) async throws {
        for _ in 0..<300 { if await predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw NativeRPCError(code: "fixture-timeout", message: "The host did not answer.")
    }
}
