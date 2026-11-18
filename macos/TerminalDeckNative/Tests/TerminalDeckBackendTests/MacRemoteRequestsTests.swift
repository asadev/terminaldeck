import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// The receiving Mac's real channels and sealed guest, against a loopback peer. No installed app, account or session.
final class MacRemoteRequestsTests: XCTestCase {
    private actor Host {
        var options: NativeRPCValue = .object([
            .init("model", .string("codex:gpt-test")), .init("effort", .string("high")),
            .init("models", .array([.object([.init("id", .string("codex:gpt-test")), .init("name", .string("Test model")), .init("provider", .string("Codex"))])])),
            .init("efforts", .array([.string("low"), .string("high")]))])
        func reply(_ request: NativeRPCValue) -> [NativeRPCValue] {
            let tag = request["t"].string ?? "", id = request["id"], rid = request["rid"]
            func frame(_ tag: String, _ fields: [NativeRPCValue.Field]) -> NativeRPCValue { .object([.init("t", .string(tag))] + fields) }
            switch tag {
            case "attach": return [frame("attached", [.init("id", id)]), frame("output", [.init("id", id), .init("data", .string("live peer screen\r\n"))]),
                                   frame("status", [.init("id", id), .init("status", .string("idle"))])]
            case "chats.watch": return [frame("chats.events", [.init("id", id), .init("conversationId", .string("conv")), .init("reset", .bool(true)), .init("busy", .bool(false)), .init("events", .array([
                                       HootChatEvent(conversationID: "conv", turnID: "turn", sequence: 1, provider: .codex,
                                           record: .init(.message, id: "reply", value: .object([.init("text", .string("Remote chat readback"))])), at: 1).wireValue]))])]
            case "chats.options": return [frame("chats.options", [.init("id", id), .init("options", options)])]
            case "chats.set":
                if request["effort"].string == "low" {
                    return [frame("error", [.init("rid", rid), .init("code", .string("unauthorized")), .init("message", .string("This device needs Full control."))])]
                }
                for key in ["model", "effort", "permissionMode"] where request[key] != .missing { options = options.setting(key, request[key]) }
                return [frame("chats.options", [.init("id", id), .init("options", options)])]
            case "controls.read":
                return [frame("controls.reading", [.init("rid", rid), .init("id", id), .init("reading", BackendMachineChannels.chatControls(options))])]
            case "controls.apply":
                return [frame("controls.applied", [.init("rid", rid), .init("id", id), .init("ok", .bool(true)), .init("message", .string("Changed")),
                    .init("reading", .object([.init("value", request["value"]), .init("label", request["value"])]))])]
            case "account.read":
                let account = NativeRPCValue.object([.init("id", .string("work")), .init("name", .string("Work")), .init("provider", .string("codex"))])
                return [frame("account.state", [.init("rid", rid), .init("id", id), .init("current", account), .init("accounts", .array([account]))])]
            case "account.switch": return [frame("account.switched", [.init("rid", rid), .init("id", id), .init("ok", .bool(true)), .init("message", .string("Changed on peer")), .init("session", .string("p2"))])]
            case "usage.read":
                return [frame("usage.reading", [.init("rid", rid), .init("id", id), .init("want", request["want"]), .init("answer", .object([
                    .init("reading", .object([.init("state", .string("reported")), .init("percent", .number(37)), .init("provider", .string("codex"))]))]))])]
            default: return []
            }
        }
    }
    private actor Received {
        var output = ""
        var resets = 0
        func add(_ text: String) { output += text }
        func frame(_ value: NativeRPCValue) { if value["t"].string == "attached" { resets += 1 } }
    }
    private struct Rig {
        let coordinator: BackendMachineCoordinator, registry: NativeChannelRegistry
        let peer: ReachGuestTests.FakeRelay, id: String, received: Received, tools: BackendDeckToolsMachinesWatch
        func invoke(_ channel: String, _ args: [NativeRPCValue]) async throws -> NativeRPCValue {
            try await registry.invoke(channel, context: .init(caller: .nativeApp, ownerID: "mac-remote-test"), arguments: [.string(id)] + args)
        }
    }
    private func rig(delayOptions: Bool = false) async throws -> Rig {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mac-remote-requests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let identity = BackendSealedIdentity.generate(), host = Host(), received = Received()
        let peer = ReachGuestTests.FakeRelay(allowed: identity.publicKey, response: { request in
            if delayOptions, request["t"].string == "chats.options" { try? await Task.sleep(for: .milliseconds(20)) }
            return await host.reply(request)
        })
        peer.welcomeText = ReachGuestTests.FakeRelay.welcome.replacingOccurrences(of: #"["chats","create"]"#, with: #"["chats","create","account","controls","usage"]"#)
        let port = try await peer.start(), url = "ws://127.0.0.1:\(port)"
        let registry = NativeChannelRegistry(), store = BackendMachineStore(directory: directory)
        let coordinator = BackendMachineCoordinator(store: store, registry: registry, localName: "Fixture Mac", relayURL: url,
            uploadAuthorize: { path, _ in path }, ownPorts: BackendDevOwnPorts())
        try await coordinator.open()
        let saved = try await store.remember(name: "Fixture MacBook", secrets: .init(hostID: ReachGuestTests.hostId, hostPublicKey: peer.host.publicKey,
            relayURL: url, credential: "fixture-only", guestIdentity: identity), platform: "darwin")
        let tools = BackendDeckToolsMachinesWatch()
        try await tools.start(registry: registry)
        _ = try await BackendMachineChannels.register(registry: registry, coordinator: coordinator, localHost: nil,
            authorizeCall: { channel, _, args in await tools.invoked(channel, args) })
        let subscription = try await registry.subscribe("machines:output", ownerID: "mac-remote-test") { event in
            if let text = event.arguments.first?["data"].string { await received.add(text) }
            if event.arguments.first?["reset"].bool == true { await received.frame(.object([.init("t", .string("attached"))])) }
        }
        addTeardownBlock {
            await subscription.cancelAndWait()
            await tools.dispose()
            await coordinator.stop(); await registry.shutdown(); peer.stop()
            try? FileManager.default.removeItem(at: directory)
        }
        try await coordinator.connect(saved.id)
        let link = try await coordinator.link(saved.id)
        for _ in 0..<200 {
            if await link.state().phase == .online { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let phase = await link.state().phase
        XCTAssertEqual(phase, .online)
        return Rig(coordinator: coordinator, registry: registry, peer: peer, id: saved.id, received: received, tools: tools)
    }

    func testLiveTerminalUsesAttachInputResizeAndReplaysAtTheLatestSizeAfterReconnect() async throws {
        let rig = try await rig()
        let attached = try await rig.invoke("machines:attach", [.string("p1"), .number(100), .number(30)])
        XCTAssertEqual(attached, .bool(true))
        let paste = "first\r" + String(repeating: "🙂", count: 20_000) + "last\r"
        _ = try await rig.invoke("machines:input", [.string("p1"), .string(paste)])
        _ = try await rig.invoke("machines:resize", [.string("p1"), .number(132), .number(42)])
        for _ in 0..<200 where rig.peer.frames.last?["t"].string != "resize" { try await Task.sleep(for: .milliseconds(10)) }
        let input = rig.peer.frames.filter { $0["t"].string == "input" }.compactMap { $0["data"].string }
        XCTAssertEqual(input.joined(), paste)
        XCTAssertTrue(input.count > 1 && input.allSatisfy { $0.utf8.count <= 16_384 })
        let output = await rig.received.output
        XCTAssertTrue(output.contains("live peer screen"))
        let link = try await rig.coordinator.link(rig.id)
        await link.disconnect(); await link.connect()
        for _ in 0..<300 where rig.peer.frames.filter({ $0["t"].string == "attach" }).count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        let replay = try XCTUnwrap(rig.peer.frames.last { $0["t"].string == "attach" })
        XCTAssertEqual(replay["cols"].number, 132); XCTAssertEqual(replay["rows"].number, 42)
        for _ in 0..<200 { if await rig.received.resets == 2 { break }; try await Task.sleep(for: .milliseconds(10)) }
        let resets = await rig.received.resets
        XCTAssertEqual(resets, 2, "Each attached receipt resets the viewer before the host's replay")
    }

    func testChatChoicesAndMachineToolsUsePhoneOptionsAndCorrelateRefusalsWithoutDroppingTheLink() async throws {
        let rig = try await rig()
        let options = try await rig.invoke("machines:chats", [.string("options"), .string("c9")])
        XCTAssertEqual(options["model"].string, "codex:gpt-test")
        let read = try await rig.invoke("machines:controls:read", [.string("c9")])
        XCTAssertEqual(read["model"]["label"].string, "Test model")
        let changed = try await rig.invoke("machines:controls:apply", [.string("c9"), .string("effort"), .string("high")])
        XCTAssertEqual(changed["ok"].bool, true)
        XCTAssertEqual(changed["reading"]["value"].string, "high")
        do {
            _ = try await rig.invoke("machines:chats", [.string("set"), .string("c9"), .object([.init("effort", .string("low"))])])
            XCTFail("The host's refusal was lost")
        } catch { XCTAssertEqual((error as? NativeRPCError)?.code, "unauthorized") }
        let link = try await rig.coordinator.link(rig.id)
        let phase = await link.state().phase
        XCTAssertEqual(phase, .online)
        XCTAssertTrue(rig.peer.frames.contains { $0["t"].string == "chats.set" && $0["effort"].string == "high" })
        XCTAssertFalse(rig.peer.frames.contains { $0["t"].string == "controls.apply" && $0["id"].string == "c9" })
    }

    func testConcurrentHeaderAndToolOptionsReadsBothReceiveTheHostsAnswer() async throws {
        let rig = try await rig(delayOptions: true)
        async let ui = rig.invoke("machines:chats", [.string("options"), .string("c9")])
        async let tool = rig.invoke("machines:controls:read", [.string("c9")])
        let (options, controls) = try await (ui, tool)
        XCTAssertEqual(options["model"].string, "codex:gpt-test")
        XCTAssertEqual(controls["model"]["value"].string, "codex:gpt-test")
    }

    func testMachineWatchReadsChatsThroughPhoneEventsWithoutAttachingAPTY() async throws {
        let rig = try await rig(), watch = rig.tools
        _ = try await rig.invoke("machines:attach", [.string("c9"), .number(120), .number(30)])
        var screen = await watch.screen(rig.id, "c9")
        for _ in 0..<100 where screen["text"].string?.contains("Remote chat readback") != true {
            try await Task.sleep(for: .milliseconds(10)); screen = await watch.screen(rig.id, "c9")
        }
        XCTAssertTrue(screen["text"].string?.contains("Remote chat readback") == true)
        _ = try await rig.invoke("machines:chats", [.string("options"), .string("c9")])
        let afterOptions = await watch.screen(rig.id, "c9")
        XCTAssertEqual(afterOptions["text"], screen["text"], "An options response must not replace the chat's transcript")
        XCTAssertTrue(rig.peer.frames.contains { $0["t"].string == "chats.watch" && $0["id"].string == "c9" })
        XCTAssertFalse(rig.peer.frames.contains { $0["t"].string == "attach" && $0["id"].string == "c9" })
        _ = try await rig.invoke("machines:detach", [.string("c9")])
        await watch.dispose()
    }

    func testMachineToolsReplaceTheirShadowScreenOnReconnectReplayToo() async {
        let watch = BackendDeckToolsMachinesWatch()
        await watch.invoked("machines:attach", [.string("m"), .string("s"), .number(80), .number(24)])
        func frame(_ text: String, reset: Bool = false) -> NativeRPCValue {
            .object([.init("machineId", .string("m")), .init("sessionId", .string("s")), .init("data", .string(text)), .init("reset", .bool(reset))])
        }
        await watch.pushed("machines:output", frame("old picture\r\n"))
        await watch.pushed("machines:output", frame("", reset: true))
        await watch.pushed("machines:output", frame("replacement picture\r\n"))
        let screen = await watch.screen("m", "s")
        XCTAssertTrue(screen["text"].string?.contains("replacement picture") == true)
        XCTAssertFalse(screen["text"].string?.contains("old picture") == true)
        await watch.pushed("machines:output", frame("").setting("problem", .string("Input was refused")))
        let refused = await watch.screen("m", "s")
        XCTAssertEqual(refused["text"], screen["text"])
        XCTAssertEqual(refused["problem"].string, "Input was refused")
        await watch.dispose()
    }

    func testErrorRequestIDWinsOverAnotherOperationsCorrelationField() {
        let pending = ["chat-1": "id", "read-1": "rid"]
        let error = NativeRPCValue.object([.init("rid", .string("read-1")), .init("id", .string("chat-1"))])
        XCTAssertEqual(BackendRemoteGuest.requestNamed(by: error, in: pending), "read-1")
        XCTAssertNil(BackendRemoteGuest.requestNamed(by: error.setting("rid", .string("unknown")), in: pending))
    }

    func testTerminalHeaderRequestsAccountModelEffortAndContextFromThePeer() async throws {
        let rig = try await rig()
        let account = try await rig.invoke("machines:account:read", [.string("p1")])
        XCTAssertEqual(account["current"]["name"].string, "Work")
        let switched = try await rig.invoke("machines:account:switch", [.string("p1"), .string("work")])
        XCTAssertEqual(switched["session"].string, "p2")
        for (control, value) in [("model", "opus"), ("effort", "high")] {
            let result = try await rig.invoke("machines:controls:apply", [.string("p1"), .string(control), .string(value)])
            XCTAssertEqual(result["reading"]["value"].string, value)
        }
        let context = try await rig.invoke("machines:usage:read", [.string("p1"), .string("context"), .bool(false)])
        XCTAssertEqual(context["percent"].number, 37)
        XCTAssertTrue(rig.peer.frames.filter { ["account.read", "account.switch", "controls.apply", "usage.read"].contains($0["t"].string ?? "") }.allSatisfy { $0["id"].string == "p1" && $0["rid"].string != nil })
    }
}
