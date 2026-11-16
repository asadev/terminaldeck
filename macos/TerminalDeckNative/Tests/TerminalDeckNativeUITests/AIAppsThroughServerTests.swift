import AppKit
import SwiftUI
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Asad, 15 Nov (items 51, 60): ONE address through our own server, the key in Authorization: Bearer, a calm page.
/// The server only forwards; this Mac's same key door decides every key. Made-up keys only (temporary folders).
@MainActor
final class AIAppsThroughServerTests: XCTestCase {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AIAppsThroughServer-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    private func control() throws -> BackendDeckCoreSecurityControl {
        let tool = try BackendMCPTool(id: "projects.list", wireName: "projects_list", description: "projects",
                                      inputSchema: .object([.init("type", .string("object")), .init("properties", .object([]))]), tier: .read)
        let policy = BackendDeckCoreSecurityToolPolicy(tool: tool, summary: { _, _ in "List projects" },
                                                       run: { _, _ in .init(value: .object([.init("count", .number(1))])) })
        return try .init(log: .init(directory: temporary()), consent: .init(ask: { _ in false }), policies: [policy])
    }
    private func ping() throws -> Data {
        try NativeRPCValue.object([.init("jsonrpc", .string("2.0")), .init("id", .number(1)), .init("method", .string("ping"))]).encodedJSON()
    }
    private struct Door { let keys: BackendDeckCoreSecurityAccessKeys; let door: BackendDeckCoreSecurityAccessKeyDoor
        let board: BackendCompositionRelaySwitchboard; let serving: BackendRelayMCPServing; let key: String
        let server: BackendDeckCoreSecurityServer }
    private func door(level: String = "full") async throws -> Door {
        let keys = BackendDeckCoreSecurityAccessKeys(directory: try temporary())
        let made = try await keys.create(.object([.init("name", .string("Made-up app")), .init("level", .string(level))]))
        let door = BackendDeckCoreSecurityAccessKeyDoor(keys: keys); await door.activate()
        addTeardownBlock { await door.stop() }
        let server = BackendDeckCoreSecurityServer(control: try control(), keys: door, ownPorts: .init())
        let serving = BackendRelayMCPServing()
        let board = BackendCompositionRelaySwitchboard(serving: serving)
        serving.setProvider { [board] in await board.isServing() }
        try await board.install(server)
        return Door(keys: keys, door: door, board: board, serving: serving, key: try XCTUnwrap(made["key"].string), server: server)
    }
    private func head(_ authorization: String?, pathKey: String? = nil) -> BackendRelayPacketCodec.MCPRequestHead {
        .init(pathKey: pathKey, authorization: authorization, protocolVersion: "2025-06-18", userAgent: "made-up-app/1")
    }

    // MARK: The forwarded request goes through the same key door

    func testForwardedRequestGoesThroughTheSameKeyCheck() async throws {
        let d = try await door()
        _ = try await d.keys.setInternet(.bool(true))
        let good = await d.board.answer(head("Bearer " + d.key), body: try ping())
        XCTAssertEqual(good.status, 200)
        XCTAssertFalse(good.refused)
        // The key was let in by the door itself, through its internet road.
        let used = await d.keys.list().first
        XCTAssertEqual(used?["lastVia"].string, "internet")
        // The old link form (key in the path) is the same door.
        let pathForm = await d.board.answer(head(nil, pathKey: d.key), body: try ping())
        XCTAssertEqual(pathForm.status, 200)
        // A wrong key: the same 404 the relay shows for nothing at all, marked refused for the relay's count only.
        let wrong = await d.board.answer(head("Bearer ak_made-up-wrong-key-000000000000000000000"), body: try ping())
        XCTAssertEqual(wrong.status, 404)
        XCTAssertTrue(wrong.refused)
        XCTAssertEqual(String(decoding: wrong.body, as: UTF8.self), BackendRelayPacketCodec.mcpNotFoundBody)
        XCTAssertFalse(String(decoding: wrong.body, as: UTF8.self).contains("refused"))
        // A revoked key is refused at once.
        let listed = await d.keys.list().first?["id"].string
        let id = try XCTUnwrap(listed)
        _ = try await d.keys.revoke(id: id)
        let revoked = await d.board.answer(head("Bearer " + d.key), body: try ping())
        XCTAssertEqual(revoked.status, 404)
        XCTAssertTrue(revoked.refused)
    }

    // MARK: Switch off = not registered

    func testSwitchOffMeansNotRegisteredAndNothingCounted() async throws {
        let d = try await door()
        let internetAtStart = await d.keys.internet()
        XCTAssertFalse(internetAtStart, "a new person starts with the switch OFF")
        let servingAtStart = await d.serving.serving()
        XCTAssertFalse(servingAtStart)
        let boardAtStart = await d.board.isServing()
        XCTAssertFalse(boardAtStart)
        // Even if an old relay still forwards: refused by this Mac, and not counted as a wrong key.
        let off = await d.board.answer(head("Bearer " + d.key), body: try ping())
        XCTAssertEqual(off.status, 404)
        XCTAssertFalse(off.refused)
        _ = try await d.keys.setInternet(.bool(true))
        let servingOn = await d.serving.serving()
        XCTAssertTrue(servingOn)
        _ = try await d.keys.setInternet(.bool(false))
        let servingOff = await d.serving.serving()
        XCTAssertFalse(servingOff)
        // A switchboard with no core server installed never serves.
        let emptyBoard = await BackendCompositionRelaySwitchboard(serving: BackendRelayMCPServing()).isServing()
        XCTAssertFalse(emptyBoard)
        // What the relay is told: [1] serving, [0] not now.
        XCTAssertEqual(BackendRemoteRelayClient.reachServing, Data([1]))
        XCTAssertEqual(BackendRemoteRelayClient.reachNotServing, Data([0]))
    }

    func testReplyHeadCarriesRefusedOnlyWhenTrue() throws {
        let plain = try BackendRelayPacketCodec.encodeMCPReply(flags: 3, head: .init(status: 200, contentType: "application/json"), chunk: Data("{}".utf8))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("refused"), "older relays and replies stay byte-identical")
        let marked = try BackendRelayPacketCodec.encodeMCPReply(flags: 3, head: .init(status: 404, contentType: "application/json", refused: true), chunk: Data())
        XCTAssertEqual(BackendRelayPacketCodec.decodeMCPReply(marked)?.head?.refused, true)
        XCTAssertEqual(BackendRelayPacketCodec.decodeMCPReply(plain)?.head?.refused, false)
    }

    // MARK: The page

    func testPageShowsTheServerAddressAndNamesSameKeysApart() throws {
        let state = try XCTUnwrap(AIAppsPictures.state(internetOn: true))
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        // DESIGN-FIXES A-1: a key's row carries its NAME only; the date and time it was made sit at the right, once.
        let made = Dictionary(uniqueKeysWithValues: state.keys.map { ($0.id, AiAppsLines.madeAt($0.createdAt, timeZone: utc)) })
        XCTAssertEqual(made["k1"], "12 Nov, 08:00")
        XCTAssertEqual(made["k3"], "12 Nov, 09:30")
        XCTAssertEqual(made["k6"], "14 Nov, 06:00")
        XCTAssertEqual(AiAppsLines.mayDo(state.keys.first { $0.id == "k7" }!), "Work")
        XCTAssertEqual(state.keys.count, 7, "no key is deleted or merged")
        // The ONE address is the server's; the local one lives only in the info popover.
        XCTAssertEqual(state.internetBase, "https://relay.terminaldeck.dev/mcp/" + AIAppsPictures.hostId)
        XCTAssertEqual(BackendDeckCoreEventsAIApps.internetBase(relayUrl: "wss://relay.terminaldeck.dev", hostId: AIAppsPictures.hostId), state.internetBase)
        XCTAssertTrue(AiAppsLines.addressInfo(localURL: state.localURL).contains("http://127.0.0.1:47011/mcp"))
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let page = try String(contentsOf: package.appendingPathComponent("Sources/TerminalDeckNative/NativeAiAppsSettings.swift"), encoding: .utf8)
        let groups = try XCTUnwrap(page.components(separatedBy: "struct AiAppsPageGroups").last?.components(separatedBy: "private struct AiNewKeySheet").first)
        XCTAssertTrue(groups.contains("subtitle: state.internetBase"))
        XCTAssertTrue(groups.contains("DeckSettingsLinkRow(title: key.name,"), "no key row carries a date in its name")
        XCTAssertTrue(groups.contains("value: AiAppsLines.madeAt(key.createdAt)"))
        XCTAssertFalse(groups.contains("keyTitles"))
        // DESIGN-FIXES A-2: the address row only while the switch is on.
        XCTAssertTrue(groups.contains("if state.internetOn {\n                DeckSettingsRow(\"Connection address\""))
        XCTAssertFalse(groups.contains("subtitle: state.localURL"))
        XCTAssertTrue(groups.contains("\"Let AI apps use this Mac\""))
        XCTAssertTrue(groups.contains("DeckSettingsGroup(\"Keys\")"))
        XCTAssertTrue(page.contains("DeckSettingsScaffold(title: \"AI apps\")"))
        XCTAssertFalse(page.contains("Outside AI apps"))
    }
}

/// Light and dark pictures of the AI apps page, drawn offscreen into night/codex/ai-apps-evidence (never in a window).
@MainActor
final class AIAppsPictures: XCTestCase {
    static let hostId = "A2B3C4D5E6F7G8H9JKMNPQRSTV"

    static func state(internetOn: Bool, connected: Bool = true) -> AiAppsState? {
        func key(_ id: String, _ name: String, _ level: String, _ at: Double) -> [String: Any] {
            ["id": id, "name": name, "level": level, "createdAt": at, "askFirst": false, "tasks": true, "notify": ["mode": "wait"]]
        }
        let raw: [String: Any] = [
            "keys": [key("k7", "Claude", "work", 1_794_640_000_000), key("k6", "iLoop CRM", "full", 1_794_636_000_000),
                     key("k5", "iLoop CRM", "full", 1_794_553_220_000), key("k4", "iLoop CRM", "full", 1_794_553_200_000),
                     key("k3", "iLoop CRM", "full", 1_794_475_800_000), key("k2", "iLoop CRM", "full", 1_794_470_700_000),
                     key("k1", "iLoop CRM", "full", 1_794_470_400_000)],
            "internet": ["on": internetOn, "base": "https://relay.terminaldeck.dev/mcp/" + hostId, "relayHost": "relay.terminaldeck.dev", "connected": connected],
            "local": ["url": "http://127.0.0.1:47011/mcp"],
            "folders": [String](), "delivery": [String: Any](), "subscriptions": [String: Any](),
        ]
        return AiAppsState.from(CodingAIJSON(raw))
    }

    func testPicturesBothThemes() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let output = package.deletingLastPathComponent().appendingPathComponent("night/codex/ai-apps-evidence")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, on) in [("on", true), ("off", false)] {
            let model = AiAppsSettingsModel()
            model.state = Self.state(internetOn: on)
            let page = DeckSettingsScaffold(title: "AI apps") { AiAppsPageGroups(state: model.state!, model: model) }
            for dark in [false, true] { try render(page, "ai-apps-\(name)", dark, output) }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("ai-apps-on-dark.png").path))
    }

    private func render<V: View>(_ view: V, _ name: String, _ dark: Bool, _ output: URL, size: CGSize = CGSize(width: 1025, height: 760)) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: size.width, height: size.height).background(DeckTokens.page))
        host.sizingOptions = []
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: output.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
    }
}

// MARK: review-fixes 1: the switch alone makes the address work (an AI-apps-only link while remote access is off)

private actor FakeAIAppsLink: BackendRemoteServeHostServiceRelaying {
    private(set) var running = false
    private(set) var starts = 0, stops = 0
    func start() { running = true; starts += 1 }
    func stop() { running = false; stops += 1 }
    func state() -> BackendRemoteRelayState {
        .init(url: "wss://relay.example.test", hostID: "fakehostid", publicKey: "", fingerprint: "", connected: running, channels: 0, reason: nil, retryAt: nil)
    }
}
private final class Wanted: @unchecked Sendable {
    private let lock = NSLock(); private var on = false
    var value: Bool { get { lock.withLock { on } } set { lock.withLock { on = newValue } } }
}

extension AIAppsThroughServerTests {
    private func hostService(_ directory: URL, fullDialled: @escaping @Sendable () -> Void) async throws -> BackendRemoteHostService {
        let trust = BackendRemoteTrustStore(directory: directory)
        try await trust.open()
        let host = BackendRemoteHost(trust: trust, manager: BackendPTYManager(inheritedEnvironment: [:], onEvent: { _ in }),
                                     state: NativeStateStore(), home: directory.path, hostName: "AI apps test Mac",
                                     appVersion: "test", privateRoots: [directory.path])
        return BackendRemoteHostService(endpoint: host, ownPorts: BackendDevOwnPorts(), relayURL: "ws://127.0.0.1:9/relay",
            webRoot: nil, tailnet: nil, hostName: "AI apps test Mac",
            mcp: { _, _ in .init(status: 404, contentType: nil, body: Data()) },
            afterEndpointStart: { throw NativeRPCError(code: "test", message: "stop here") },
            makeRelay: { _, _, _, _, _ in fullDialled(); return FakeAIAppsLink() })
    }

    func testTheSwitchStartsAnAIAppsOnlyLinkAndRemoteAccessReplacesIt() async throws {
        let directory = try temporary()
        let wanted = Wanted()
        let links = LinkBox()
        let service = try await hostService(directory, fullDialled: { links.full() })
        await service.keepAIAppsLink(wanted: { wanted.value }, make: { _, _, _ in let link = FakeAIAppsLink(); links.add(link); return link })
        XCTAssertTrue(links.all.isEmpty, "switch off: no link")
        let noneYet = await service.aiAppsRelayState()
        XCTAssertNil(noneYet)
        // Switch on: the AI-apps-only link comes up by itself, and the page's address is read from it.
        wanted.value = true
        await service.refreshAIAppsLink()
        let first = try XCTUnwrap(links.all.first)
        let up = await first.running
        XCTAssertTrue(up)
        let facts = await service.aiAppsRelayState()
        XCTAssertEqual(facts?.hostID, "fakehostid")
        // Remote access starting stops it BEFORE the full link dials (one socket per room); its failure brings it back.
        _ = try? await service.start()
        XCTAssertEqual(links.fullDials, 1)
        let firstStops = await first.stops
        XCTAssertEqual(firstStops, 1)
        XCTAssertEqual(links.all.count, 2, "remote access did not start, so AI apps got their own link again")
        // Switch off: the link goes.
        wanted.value = false
        await service.refreshAIAppsLink()
        let second = try XCTUnwrap(links.all.last)
        let secondUp = await second.running
        XCTAssertFalse(secondUp)
        let after = await service.aiAppsRelayState()
        XCTAssertNil(after)
    }

    func testTheAIAppsOnlyLinkCarriesNoDeviceAndNoPairing() throws {
        // The AI-apps-only client has no host, no trust store and no pairing offer: it is built from the identity and the
        // MCP handler alone, so nothing a phone or browser sends can reach a host through it.
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/TerminalDeckBackend/BackendRemoteRelayClient.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("aiAppsOnly mcp: @escaping MCPHandler) throws {\n        self.url = try Self.target(url); self.identity = identity; self.mcp = mcp; trust = nil; host = nil; beaconOffer = nil"))
        XCTAssertTrue(source.contains("guard host != nil || beaconOffer != nil else { try? await envelope(.close"))
    }
}

private final class LinkBox: @unchecked Sendable {
    private let lock = NSLock(); private var links: [FakeAIAppsLink] = []; private var dials = 0
    func add(_ link: FakeAIAppsLink) { lock.withLock { links.append(link) } }
    func full() { lock.withLock { dials += 1 } }
    var all: [FakeAIAppsLink] { lock.withLock { links } }
    var fullDials: Int { lock.withLock { dials } }
}

// MARK: review-fixes 6 and 7: "serving" is never stale or assumed; only a key that matched nothing is marked

private final class Said: @unchecked Sendable {
    private let lock = NSLock(); private var values: [Bool] = []
    func add(_ on: Bool) { lock.withLock { values.append(on) } }
    var all: [Bool] { lock.withLock { values } }
}

extension AIAppsThroughServerTests {
    func testOffOnOffQuicklyEndsNotNow() async throws {
        let teller = BackendRelayServingTeller(), wanted = Wanted(), said = Said()
        let gate = AsyncStream<Void>.makeStream()
        // The first send ("not now") is slow; while it is under way the switch goes on and off again, with a tell each time.
        let first = Task {
            await teller.tell(read: { wanted.value }, live: { true }, send: { on in
                said.add(on)
                if said.all.count == 1 { for await _ in gate.stream { break } }
            })
        }
        while said.all.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        wanted.value = true
        await teller.tell(read: { wanted.value }, live: { true }, send: { said.add($0) })
        wanted.value = false
        await teller.tell(read: { wanted.value }, live: { true }, send: { said.add($0) })
        gate.continuation.yield(); gate.continuation.finish()
        await first.value
        XCTAssertEqual(said.all.last, false, "the relay ends on the switch's latest value")
        let last = await teller.said
        XCTAssertEqual(last, false)
        // On, then a quick off while "serving" is being sent: "not now" is said after it.
        let quick = BackendRelayServingTeller(), sent = Said()
        wanted.value = true
        await quick.tell(read: { wanted.value }, live: { true }, send: { on in sent.add(on); if on { wanted.value = false } })
        XCTAssertEqual(sent.all, [true, false])
        // A connection that is gone says nothing.
        let gone = BackendRelayServingTeller(), none = Said()
        await gone.tell(read: { true }, live: { false }, send: { none.add($0) })
        XCTAssertTrue(none.all.isEmpty)
    }

    func testNothingIsServingBeforeTheSwitchIsRead() async {
        let unread = await BackendRelayMCPServing().serving()
        XCTAssertFalse(unread, "no provider yet: \"not now\"")
        let wiring = try? String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/TerminalDeckNative/NativeCompositionProductionRemote.swift"), encoding: .utf8)
        let source = wiring ?? ""
        let provider = source.range(of: "BackendRelayMCPServing.shared.setProvider")
        let host = source.range(of: "remoteHost = try await root.remoteHostService(")
        XCTAssertNotNil(provider); XCTAssertNotNil(host)
        if let provider, let host { XCTAssertLessThan(provider.lowerBound, host.lowerBound, "the provider is set before any relay client exists") }
    }

    func testACancelledGoodKeyRequestCarriesNoMark() async throws {
        let d = try await door()
        _ = try await d.keys.setInternet(.bool(true))
        let cancelled = BackendMCPCancellation(); cancelled.cancel()
        let answer = await d.server.answerRelayMarked(authorization: "Bearer " + d.key, pathKey: nil, userAgent: "made-up-app/1",
                                                      protocolVersion: "2025-06-18", body: try ping(), cancellation: cancelled)
        XCTAssertEqual(answer.response.status, 404)
        XCTAssertFalse(answer.refused, "a good key is not a wrong key, even when its request did not run")
        // A key that matches nothing is still marked.
        let wrong = await d.server.answerRelayMarked(authorization: "Bearer ak_made-up-wrong-key-000000000000000000000", pathKey: nil,
                                                     userAgent: nil, protocolVersion: nil, body: try ping(), cancellation: .init())
        XCTAssertTrue(wrong.refused)
    }
}
