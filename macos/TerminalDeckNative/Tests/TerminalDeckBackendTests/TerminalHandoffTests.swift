import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// 28 Oct (Asad: "As soon as I click on the session in my phone's side panel, it automatically comes to my phone.
/// That click is the trigger. On the Mac, if I'm on another session and click that session, it comes to the Mac the
/// same way."): the session's size follows the device where it was chosen last; typing is not choosing; a device that
/// was showing the session when the other one took it shows "Open on <name>" with "Move back here"; the switch waits
/// for the program's redraw (quiet 120 ms, at most 600 ms) so nothing in between is ever shown.
final class TerminalHandoffTests: XCTestCase {
    private var segments: [(cols: Int, rows: Int, bytes: Data)] { TerminalGarbleFixture.segments }

    // MARK: The wait for the program's redraw

    func testTheSwitchWaitsForAQuietGapAndNeverPastTheCap() {
        let settle = TerminalSettle(start: 1_000)
        XCTAssertEqual(settle.next(now: 1_000, lastOutput: nil), 1_120, "nothing printed yet: 120 ms after the resize")
        XCTAssertNil(settle.next(now: 1_120, lastOutput: nil))
        XCTAssertEqual(settle.next(now: 1_000, lastOutput: 900), 1_120, "output from before the resize does not count")
        XCTAssertEqual(settle.next(now: 1_050, lastOutput: 1_040), 1_160, "the redraw came: 120 ms after its last byte")
        XCTAssertNil(settle.next(now: 1_160, lastOutput: 1_040))
        XCTAssertEqual(settle.next(now: 1_550, lastOutput: 1_540), 1_600, "an agent that never stops animating: the cap")
        XCTAssertNil(settle.next(now: 1_600, lastOutput: 1_599))
    }

    /// The Mac's real wait, on a real pty, for a program that repaints whenever its size changes (as Claude Code
    /// does): the switch is shown once the repaint is in, not before and not much after.
    func testHowLongASwitchTakesOnTheMac() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("handoff-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let script = folder.appendingPathComponent("repaint.pl")
        try #"""
        $| = 1;
        $SIG{WINCH} = sub { my $size = `stty size`; chomp $size; print "\e[2J\e[H" . "size $size\n"; };
        print "ready\n";
        sleep 1 while 1;
        """#.write(to: script, atomically: true, encoding: .utf8)
        let manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
        addTeardownBlock { manager.beginShutdown(); _ = await manager.drain(timeoutMilliseconds: 2_000) }
        let meta = try manager.create(.init(cwd: folder.path, provider: "shell"),
                                      spawn: .init(provider: "shell", command: "/usr/bin/perl", args: [script.path], path: "/usr/bin:/bin"))
        let id = meta.id
        try manager.resize(id, cols: 120, rows: 40)
        try await Self.wait { (manager.scrollbackText(id) ?? "").contains("ready") }
        let phone = BackendTerminalViewers.Claim(viewer: "phone", size: .init(cols: 45, rows: 30), name: "Asad's iPhone", platform: "ios")
        XCTAssertTrue(try manager.setViewerSizes(id, [phone], user: "phone"))
        _ = await manager.settle(id)
        try await Self.wait { (manager.scrollbackText(id) ?? "").contains("size 30 45") }

        let started = Date()
        XCTAssertTrue(try manager.macUsed(id, cols: 120, rows: 40))
        let waited = await manager.settle(id)
        let total = Date().timeIntervalSince(started) * 1000
        XCTAssertTrue((manager.scrollbackText(id) ?? "").contains("size 40 120"), "the repaint is in before the switch shows")
        XCTAssertGreaterThanOrEqual(waited, TerminalSettle.quiet)
        XCTAssertLessThan(waited, TerminalSettle.cap + 100)
        print(String(format: "SWITCH-TIME Mac takes it back: resize + repaint + quiet gap %.0f ms (total %.0f ms; then the screen is read and fades in over 180 ms)", waited, total))
    }

    // MARK: The Mac taking the session back

    /// While the phone had the session, the Mac's terminal kept its last frame (it drew nothing meant for the phone's
    /// screen). Taken back, it is reset and fed the session as it is once the program has repainted at the Mac's
    /// size: with the new session keeper its remount, with today's keeper the join built from its raw tail. Either
    /// way it is exactly the session's screen, colours included.
    func testTheMacTakingItBackIsExactWithEitherSessionKeeper() throws {
        let mac = segments[0], phone = segments[1], back = segments[3]
        XCTAssertEqual(mac.cols, 120); XCTAssertEqual(phone.cols, 45); XCTAssertEqual(back.cols, 120)
        // The session as its keeper's own terminal has it: the Mac's size, the phone's, the Mac's again (a repaint).
        let exact = BackendTerminalProbe(cols: 120, rows: 40)
        exact.feed(mac.bytes); exact.resize(cols: 45, rows: 60); exact.feed(phone.bytes); exact.resize(cols: 120, rows: 40); exact.feed(back.bytes)

        let newKeeper = BackendTerminalProbe(cols: 120, rows: 40); newKeeper.feed(mac.bytes)   // frozen at its last frame
        let remount = try BackendPTYManager.remountForTesting(cols: 120, rows: 40, chunks: [mac.bytes, phone.bytes, back.bytes],
                                                              resizes: [1: (45, 60), 2: (120, 40)])
        newKeeper.feed("\u{1b}c" + remount)
        XCTAssertEqual(newKeeper.rows, exact.rows, "new keeper: the remount")
        for row in 0..<40 { XCTAssertEqual(newKeeper.backgrounds(row: row), exact.backgrounds(row: row), "colours, row \(row)") }
        XCTAssertTrue(newKeeper.fullScreen); XCTAssertTrue(newKeeper.reportsMouse)

        let todaysKeeper = BackendTerminalProbe(cols: 120, rows: 40); todaysKeeper.feed(mac.bytes)
        var raw = Data(); raw.append(mac.bytes); raw.append(phone.bytes); raw.append(back.bytes)
        let screen = (0..<40).map { exact.terminal.getLine(row: $0)?.translateToString(trimRight: true) ?? "" }.joined(separator: "\n")
        let join = BackendTerminalJoin.build(replay: String(decoding: raw, as: UTF8.self), screen: screen,
                                             scrollbackText: String(decoding: exact.terminal.getBufferAsData(kind: .normal), as: UTF8.self))
        XCTAssertEqual(join.shape, .repaint, "the program's repaint for the Mac is the last full repaint")
        todaysKeeper.feed("\u{1b}c" + join.text)
        XCTAssertEqual(todaysKeeper.rows, exact.rows, "today's keeper: the join")
        for row in 0..<40 { XCTAssertEqual(todaysKeeper.backgrounds(row: row), exact.backgrounds(row: row), "colours, row \(row)") }
        XCTAssertTrue(todaysKeeper.fullScreen); XCTAssertTrue(todaysKeeper.reportsMouse)

        // What it replaces: the Mac's terminal drawing the phone's frames as they came (27 Oct) was garbled until
        // the repaint; frozen, it never shows them.
        let drawingAlong = BackendTerminalProbe(cols: 120, rows: 40); drawingAlong.feed(mac.bytes); drawingAlong.feed(phone.bytes)
        let beforeRepaint = BackendTerminalProbe(cols: 120, rows: 40)
        beforeRepaint.feed(mac.bytes); beforeRepaint.resize(cols: 45, rows: 60); beforeRepaint.feed(phone.bytes); beforeRepaint.resize(cols: 120, rows: 40)
        XCTAssertNotEqual(drawingAlong.rows, beforeRepaint.rows)
    }

    // MARK: The phone, end to end through the remote host

    /// A phone that follows the 28 Oct rule: opening the session takes it (and it is sent the program's repaint at
    /// its size); the Mac choosing it tells the phone, with the Mac's name for its panel; typing and turning the
    /// phone do not take it; "Move back here" takes it again; coming back after a dropped link does not take what
    /// the Mac chose since.
    func testThePhoneOpensTakesBackAndIsToldWhereTheSessionIs() async throws {
        let rig = try await HandoffRig.make()
        addTeardownBlock { await rig.finish() }
        let manager = rig.manager
        let meta = try manager.create(.init(cwd: "/tmp", provider: "shell"),
                                      spawn: .init(provider: "shell", command: "/bin/sh", args: [], path: "/usr/bin:/bin"))
        try manager.resize(meta.id, cols: 120, rows: 40)                                    // the Mac's terminal
        let id = meta.id
        func size(_ marker: String) async throws -> String {
            try manager.write(id, data: "echo \(marker) $(stty size)\n")
            for _ in 0..<400 {
                let text = manager.scrollbackText(id) ?? ""
                if let line = text.components(separatedBy: "\n").last(where: { $0.hasPrefix(marker + " ") }) {
                    return String(line.dropFirst(marker.count + 1)).trimmingCharacters(in: .whitespaces)
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            XCTFail("no answer for \(marker)"); return ""
        }
        let macFirst = try await size("A"); XCTAssertEqual(macFirst, "40 120")

        let phone = try await rig.connect(capabilities: ["terminal.handoff", "device.access"])
        let welcomes = await phone.wire.rows("welcome")
        let welcome = try XCTUnwrap(welcomes.first)
        XCTAssertTrue(welcome["capabilities"].elements?.contains(.string("terminal.handoff")) == true, "offered back")

        // Opening it on the phone takes it: its size, then the session as the program redrew it.
        try await rig.send(phone, "attach", [.init("id", .string(meta.id)), .init("cols", .number(45)), .init("rows", .number(30))])
        try await Self.wait { await phone.wire.rows("status").contains { $0["id"].string == id } }
        let opened = await phone.wire.types()
        XCTAssertEqual(Array(opened.drop { $0 != "attached" }.prefix(2)), ["attached", "size"])
        let sizes = await phone.wire.rows("size")
        XCTAssertEqual(sizes.last?["owner"], .string("you"))
        let phoneHas = try await size("B"); XCTAssertEqual(phoneHas, "30 45")
        XCTAssertEqual(manager.owner(id).name, "Fixture phone")

        // Chosen on the Mac: the phone hears at once who has it, by name.
        XCTAssertTrue(try manager.macUsed(id, cols: 120, rows: 40))
        try await Self.wait { await phone.wire.rows("size").last?["owner"] == .string("mac") }
        let told = await phone.wire.rows("size").last
        XCTAssertEqual(told?["name"], .string("Fixture Mac"))
        let macAgain = try await size("C"); XCTAssertEqual(macAgain, "40 120")

        // Typing and turning the phone are not choosing.
        try await rig.send(phone, "input", [.init("id", .string(id)), .init("data", .string(""))])
        try await rig.send(phone, "resize", [.init("id", .string(id)), .init("cols", .number(60)), .init("rows", .number(25))])
        let stillMac = try await size("D"); XCTAssertEqual(stillMac, "40 120")
        XCTAssertTrue(manager.owner(id).here)

        // "Move back here": taken again, and the session sent afresh once the program has redrawn.
        let attachedBefore = await phone.wire.rows("attached").count
        let started = Date()
        try await rig.send(phone, "take", [.init("id", .string(id)), .init("cols", .number(45)), .init("rows", .number(30))])
        let took = Date().timeIntervalSince(started) * 1000
        try await Self.wait { await phone.wire.rows("attached").count == attachedBefore + 1 }
        XCTAssertGreaterThanOrEqual(took, TerminalSettle.quiet - 1, "it waited for the program's redraw")
        XCTAssertLessThan(took, TerminalSettle.cap + 400)
        let after = await phone.wire.rows("size").last
        XCTAssertEqual(after?["owner"], .string("you"))
        let phoneBack = try await size("E"); XCTAssertEqual(phoneBack, "30 45")
        print(String(format: "SWITCH-TIME phone Move back here: %.0f ms until the session is sent afresh", took))

        // The Mac chooses it; the phone's link drops and it comes back to the session it had: it stays on the Mac.
        XCTAssertTrue(try manager.macUsed(id, cols: 120, rows: 40))
        try await rig.send(phone, "detach", [.init("id", .string(id))])
        try await rig.send(phone, "attach", [.init("id", .string(id)), .init("cols", .number(45)), .init("rows", .number(30)), .init("keep", .bool(true))])
        let kept = try await size("F"); XCTAssertEqual(kept, "40 120")
        let last = await phone.wire.rows("size").last
        XCTAssertEqual(last?["owner"], .string("mac"))
    }

    func testTakeIsReadLevelAndParsedLikeResize() throws {
        XCTAssertTrue(BackendINT2PhoneAccessLevel.look.permits("take"), "a phone that may look may choose where it looks")
        XCTAssertTrue(BackendRemoteProtocol.capabilities.contains("terminal.handoff"))
        guard case .message(let take) = BackendRemoteProtocol.parseClientMessage(#"{"t":"take","id":"s1","cols":45,"rows":30}"#) else {
            return XCTFail("take is a known message")
        }
        XCTAssertEqual(take["cols"], .number(45))
        guard case .refused = BackendRemoteProtocol.parseClientMessage(#"{"t":"take","id":"s1","cols":4,"rows":30}"#) else {
            return XCTFail("a take out of range is refused like a resize")
        }
        guard case .message(let attach) = BackendRemoteProtocol.parseClientMessage(#"{"t":"attach","id":"s1","cols":45,"rows":30,"keep":true}"#) else {
            return XCTFail("attach with keep")
        }
        XCTAssertEqual(attach["keep"], .bool(true))
        XCTAssertNoThrow(try BackendRemoteServerMessage(.terminalSize, fields: BackendRemoteHost.sizeFields(
            "s1", state: nil, viewer: "phone", hostName: "Asad's Mac mini")), "the size frame with a name is a valid frame")
    }

    static func wait(_ predicate: @escaping @Sendable () async -> Bool) async throws {
        for _ in 0..<400 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw NativeRPCError(code: "fixture-timeout", message: "It did not happen within ten seconds.")
    }
}

/// A remote host on a real pty manager, one approved phone of the owner's own at Full control, every session
/// visible to it.
private struct HandoffRig: Sendable {
    struct Peer: Sendable { let id: UUID; let wire: HandoffWire }
    let directory: URL
    let trust: BackendRemoteTrustStore
    let credential: String
    let manager: BackendPTYManager
    let host: BackendRemoteHost
    let lease: NativeRPCSubscription

    static func make() async throws -> HandoffRig {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TerminalHandoff-" + UUID().uuidString)
        let trust = BackendRemoteTrustStore(directory: directory.appendingPathComponent("remote"))
        try await trust.open()
        let offer = try await trust.createPairingOffer()
        let device = try await trust.redeem(offer.token, name: "Fixture phone", address: "fixture", publicKey: nil)
        try await trust.approve(device.device.id, kind: .mine)
        try await trust.setPhoneAccess(device.device.id, level: .full)
        let manager = BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in })
        let host = BackendRemoteHost(trust: trust, manager: manager, state: NativeStateStore(), home: directory.path,
                                     hostName: "Fixture Mac", appVersion: "test", privateRoots: [])
        let suppliers = BackendRemoteServeRegistration.Suppliers(requireReady: {}, create: nil, enrollment: nil,
            drivesWindows: { _ in false }, sessionVisible: { _, _ in true }, isHidden: { _ in false },
            accountShared: { _, _ in false }, anyAccount: { _ in false }, legacyCredential: { _, _ in },
            missingFeature: { _ in nil }, guestRefusal: { _ in nil })
        let hooks = BackendRemoteServeRegistration.Hooks(connectionsChanged: {}, rosterChanged: {},
            lastDeviceDisconnected: { _ in }, windowHolds: { _, _ in })
        let lease = try await host.installRemoteServe(ownerID: "terminal-handoff-test", features: [], suppliers: suppliers, hooks: hooks)
        try await host.start()
        return HandoffRig(directory: directory, trust: trust, credential: device.credential, manager: manager, host: host, lease: lease)
    }

    func connect(capabilities: [String]) async throws -> Peer {
        let wire = HandoffWire()
        guard let id = await host.accept(.init(address: "fixture", send: { try await wire.receive($0) }, close: { _, _ in await wire.close() })) else {
            throw NativeRPCError(code: "fixture", message: "The host refused the wire.")
        }
        let peer = Peer(id: id, wire: wire)
        try await send(peer, "hello", [.init("protocol", .number(1)), .init("token", .string(credential)),
            .init("device", .object([.init("name", .string("Fixture phone")), .init("platform", .string("ios"))])),
            .init("capabilities", .array(capabilities.map(NativeRPCValue.string)))])
        try await TerminalHandoffTests.wait { await !wire.rows("welcome").isEmpty }
        return peer
    }

    func send(_ peer: Peer, _ type: String, _ fields: [NativeRPCValue.Field] = []) async throws {
        let value = NativeRPCValue.object([.init("t", .string(type))] + fields)
        await host.receive(peer.id, text: String(decoding: try value.encodedJSON(), as: UTF8.self))
    }

    func finish() async {
        await host.stop()
        await lease.cancelAndWait()
        await trust.close()
        manager.beginShutdown(); _ = await manager.drain(timeoutMilliseconds: 2_000)
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor HandoffWire {
    private var frames: [NativeRPCValue] = []
    private(set) var closes = 0
    func receive(_ text: String) throws { frames.append(try NativeRPCValue.parseJSON(Data(text.utf8))) }
    func close() { closes += 1 }
    func rows(_ type: String) -> [NativeRPCValue] { frames.filter { $0["t"].string == type } }
    func types() -> [String] { frames.compactMap { $0["t"].string } }
}
