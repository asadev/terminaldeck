import AppKit
import SwiftUI
import Testing
import TerminalDeckNativeCore
import TerminalDeckBackend
@testable import TerminalDeckNative

/// Live use from another Mac (15 Nov, live-use-plan.md steps 2-3): the "Runs on <machine>" page is the live session by
/// itself when that machine is on and lists it (a terminal opens as its live tab, a chat is drawn live with a box), and
/// the Cloud copy, read only, when it is off. One row per session in the side panel. No account, link or window is
/// touched: rows, links and chat frames are made up here.
@Suite("Live use from another Mac — the Runs on page")
@MainActor
struct CloudLiveUseUITests {
    static let ref = "0123456789abcdef0123456789abcdef"

    static func row(_ sessionId: String, kind: String = "session", on: Bool = true, closed: Bool = false, name: String = "Fix the login page") throws -> BackendCloudSessionsRead.Row {
        var raw: [String: Any] = ["ref": "r-" + sessionId, "sessionId": sessionId, "name": name, "lastUsedAt": 1_800_000_000_000, "ai": "claude",
                                  "kind": kind, "status": "idle", "machine": ref, "machineName": "Mac mini", "machineOn": on, "self": false, "readable": true]
        if closed { raw["closedAt"] = 1_800_000_000_000 }
        return try JSONDecoder().decode(BackendCloudSessionsRead.Row.self, from: JSONSerialization.data(withJSONObject: raw))
    }
    static func links(online: Bool = true, exited: Bool = false) -> MachinesSnapshot {
        let rows: [[String: Any]] = [["id": "p1", "title": "Claude", "cwd": "/w", "provider": "claude", "status": exited ? "exited" : "idle", "tab": "tab-1"],
                                     ["id": "c9", "title": "Plan", "cwd": "/w", "provider": "claude", "status": "idle", "chat": true, "tab": "tab-9"]]
        return MachinesSnapshot.decode(["machines": [["id": "reach-m1", "name": "Mac mini", "reach": true]],
                                        "links": [["id": "reach-m1", "state": online ? "online" : "connecting", "machine": ref, "sessions": rows]]])!
    }
    static func event(_ sequence: Int, _ kind: HootChatKind, _ text: String, id: String = "", turn: String = "t1") -> HootChatEvent {
        HootChatEvent(conversationID: "conv", turnID: turn, sequence: sequence, provider: .claude,
                      record: .init(kind, id: id, value: .object([.init("text", .string(text))])), at: 1_800_000_000_000 + Double(sequence))
    }
    static func frame(_ events: [HootChatEvent], busy: Bool, reset: Bool = true) -> [String: Any] {
        ["machineId": "reach-m1", "frame": ["t": "chats.events", "id": "c9", "conversationId": "conv", "reset": reset, "busy": busy,
                                            "events": events.map { $0.wireValue.foundation }]]
    }

    @Test func thePageIsLiveOnlyWhileThatMachineIsOnAndListsTheSession() throws {
        #expect(NativeCloudLiveChoice.choose(row: try Self.row("tab-1"), links: Self.links()) == .terminal(tabId: "machine reach-m1 p1"))
        #expect(NativeCloudLiveChoice.choose(row: try Self.row("tab-9", kind: "chat"), links: Self.links()) == .chat(machineId: "reach-m1", chatId: "c9"))
        #expect(NativeCloudLiveChoice.choose(row: try Self.row("tab-1", on: false), links: Self.links()) == .terminal(tabId: "machine reach-m1 p1"))
        #expect(NativeCloudLiveChoice.choose(row: try Self.row("tab-1", closed: true), links: Self.links()) == .cloud)
        #expect(NativeCloudLiveChoice.choose(row: try Self.row("tab-1"), links: Self.links(online: false)) == .cloud)
        #expect(NativeCloudLiveChoice.choose(row: try Self.row("tab-1"), links: Self.links(exited: true)) == .cloud)
        #expect(NativeCloudLiveChoice.choose(row: try Self.row("unknown"), links: Self.links()) == .cloud)
        #expect(NativeCloudLiveChoice.choose(row: nil, links: Self.links()) == .cloud)
    }

    @Test func oneRowPerSession() throws {
        let others = [try Self.row("tab-1"), try Self.row("tab-9", kind: "chat"), try Self.row("elsewhere")]
        // Its live tab is open here: the Cloud row is not listed a second time.
        let shown = NativeCloudLiveChoice.shownOthers(others, ownIDs: ["machine reach-m1 p1"], links: Self.links())
        #expect(shown.map(\.sessionId) == ["tab-9", "elsewhere"])
        #expect(NativeCloudLiveChoice.shownOthers(others, ownIDs: [], links: Self.links()).count == 3)
    }

    @Test func theLiveChatReadsAsItAnswersAndAnswersWhatItAsks() async {
        let live = NativeMachineChatLive()
        var sent: [[String?]] = []
        live.send = { args in sent.append(args.map { $0.map { "\($0)" } }) }
        live.readOptions = { _ in .object([]) }
        await live.open(machineId: "reach-m1", chatId: "c9")
        live.receive(Self.frame([Self.event(1, .user, "Add a test for the login page"), Self.event(2, .textDelta, "Writing ", id: "m1"),
                                 Self.event(3, .textDelta, "the test now.", id: "m1"),
                                 Self.event(4, .approval, "Run swift test?", id: "req-7")], busy: true))
        #expect(live.shown.map { $0.value["text"].string } == ["Add a test for the login page", "Writing the test now."])
        #expect(live.busy && live.waiting?.record.messageID == "req-7")
        // The local chat's question card takes the request itself (its id named, as the card answers with it).
        #expect(live.pending.map(NativeMachineChatLive.requestID) == ["req-7"])
        await live.answer("req-7", allowed: true)
        live.receive(Self.frame([Self.event(5, .approvalResolved, "", id: "req-7")], busy: true, reset: false))
        #expect(live.waiting == nil && live.pending.isEmpty && live.events.count == 5)
        await live.say("Thanks")
        await live.stop()
        // Another chat's frame is not this one's.
        live.receive(["machineId": "reach-m1", "frame": ["id": "other", "events": [], "reset": true, "busy": false]])
        #expect(live.events.count == 5)
        #expect(sent.count == 4)
        #expect(sent[0] == ["reach-m1", "watch", "c9"])
        #expect(sent[1] == ["reach-m1", "answer", "c9", "req-7", "true"])
        #expect(Array(sent[2].prefix(4)) == ["reach-m1", "say", "c9", "Thanks"])
        #expect(sent[2].count == 6 && sent[2][5].flatMap(UUID.init(uuidString:)) != nil)
        #expect(sent[3] == ["reach-m1", "interrupt", "c9"])
    }

    /// Pictures (written to `macos/night/codex/mac-live-use-evidence/`, light and dark): the page of a chat session on
    /// the Mac mini while it is on (live: its answer as it is written; what it asks in the local chat's own question
    /// card right above the box; the app's own composer with its arrow as Stop, no model/effort/permission menus), and
    /// while it is off (the Cloud copy, read only, no box).
    @Test func picturesOfTheRunsOnPageLiveAndReadOnly() async throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let output = package.deletingLastPathComponent().appendingPathComponent("night/codex/mac-live-use-evidence")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let history = [Self.event(1, .user, "Add a test for the login page"),
                       Self.event(2, .message, "I added `LoginPageTests` with three cases: a good password, a wrong one, and an empty field.", id: "m0"),
                       Self.event(3, .user, "Now run it", turn: "t2"), Self.event(4, .textDelta, "Running the tests in the login folder", id: "m1", turn: "t2"),
                       HootChatEvent(conversationID: "conv", turnID: "t2", sequence: 5, provider: .claude, record: .init(.approval, id: "req-7", value: .object([
                           .init("requestId", .string("req-7")), .init("subtype", .string("can_use_tool")), .init("name", .string("Bash")),
                           .init("input", .object([.init("command", .string("swift test --filter LoginPageTests"))]))])), at: 1_800_000_000_005)]
        let filled = NativeMachineChatLive()
        filled.send = { _ in }
        filled.readOptions = { _ in .object([]) }
        // Only names the chat (its watch goes to the no-op above); the frame below fills it.
        await filled.open(machineId: "reach-m1", chatId: "c9")
        filled.receive(Self.frame(history, busy: true))
        let reader = NativeCloudChatReader()
        reader.apply(newest: .init(gen: 1, total: 4, first: 0, count: 4, events: Array(history.prefix(4))))
        let size = NSSize(width: 900, height: 620)
        for dark in [false, true] {
            let shots: [(String, NativeCloudLivePreview)] = [
                ("live", .init(row: try Self.row("tab-9", kind: "chat"), links: Self.links(), reader: reader, live: filled)),
                ("read-only", .init(row: try Self.row("tab-9", kind: "chat", on: false), links: Self.links(online: false), reader: reader, live: nil)),
            ]
            for (name, preview) in shots {
                // The box's glass cannot be drawn into a picture; its solid stand-in is (as the island's box draws it).
                let host = NSHostingView(rootView: NativeCloudChatPage(ref: "r-tab-9", preview: preview).environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.agkitOffscreenSolid, true)
                    .frame(width: size.width, height: size.height).background(DeckTokens.page))
                host.sizingOptions = []
                host.frame = NSRect(origin: .zero, size: size)
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                host.layoutSubtreeIfNeeded()
                let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: image)
                let png = try #require(image.representation(using: .png, properties: [:]))
                try png.write(to: output.appendingPathComponent("runs-on-\(name)-\(dark ? "dark" : "light").png"))
                #expect(image.pixelsWide >= Int(size.width))
            }
        }
        #expect(filled.shown.count == 4 && filled.pending.count == 1)
        filled.close()
    }
}
