import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// 14 Nov phone link, the root on the Mac's side: answers first, never more than the channel takes, and a busy
/// terminal never builds a backlog (`BackendRemoteLinkOutbox`). A fake data channel that drains at a set rate.
@Suite("Link outbox", .serialized)
struct BackendRemoteLinkOutboxTests {
    /// A data channel that takes everything at once and sends it at `rate` bytes a second (nil: at once).
    final class FakeChannel: @unchecked Sendable {
        let rate: Double?
        private let lock = NSLock()
        private var buffered: Double = 0
        private var last = Date()
        private(set) var handed: [(text: String, at: Double, ahead: Double)] = []
        init(rate: Double?) { self.rate = rate }
        static func now() -> Double { Date().timeIntervalSince1970 * 1_000 }
        private func drain() {
            let t = Date()
            if let rate { buffered = max(0, buffered - rate * t.timeIntervalSince(last)) } else { buffered = 0 }
            last = t
        }
        /// While held, the channel reports itself full (nothing more is handed to it).
        var hold = false
        func queued() -> UInt64 { lock.withLock { drain(); return hold ? 10_000_000 : UInt64(buffered) } }
        func send(_ data: Data) -> Bool {
            lock.withLock {
                drain()
                handed.append((String(decoding: data, as: UTF8.self), Self.now(), buffered))
                buffered += Double(data.count)
            }
            return true
        }
        /// When a handed frame reaches the phone: handed at, plus what was ahead of it in the channel at that rate.
        func arrival(of index: Int) -> Double {
            lock.withLock {
                let entry = handed[index]
                return entry.at + (rate.map { (entry.ahead + Double(entry.text.utf8.count)) / $0 * 1_000 } ?? 0)
            }
        }
        var texts: [String] { lock.withLock { handed.map(\.text) } }
    }
    final class Resyncs: @unchecked Sendable {
        private let lock = NSLock()
        private var sessions: [String] = []
        func add(_ session: String) { lock.withLock { sessions.append(session) } }
        var all: [String] { lock.withLock { sessions } }
    }

    static func output(_ session: String, _ data: String) -> String {
        String(decoding: (try? NativeRPCValue.object([.init("t", .string("output")), .init("id", .string(session)),
                                                      .init("data", .string(data))]).encodedJSON()) ?? Data(), as: UTF8.self)
    }
    final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var said: [String] = []
        func add(_ text: String) { lock.withLock { said.append(text) } }
        var all: [String] { lock.withLock { said } }
    }
    static func box(_ channel: FakeChannel, resyncs: Resyncs, events: Events = Events(),
                    onResync: (@Sendable (BackendRemoteLinkOutbox, String) -> Void)? = nil) -> BackendRemoteLinkOutbox {
        final class Holder: @unchecked Sendable { var box: BackendRemoteLinkOutbox? }
        let holder = Holder()
        let box = BackendRemoteLinkOutbox(send: { channel.send($0) }, queued: { channel.queued() }, now: { FakeChannel.now() },
                                          failed: { why in events.add("failed: " + why) }, resync: { session in
            resyncs.add(session)
            if let box = holder.box { onResync?(box, session) }
        }, listsLost: { events.add("lists lost") })
        holder.box = box
        return box
    }

    @Test("the classes: the heartbeat answer and answers by rid first; output, pictures, lists and rid-less refusals in order")
    func classes() {
        #expect(BackendRemoteLinkOutbox.classOf(#"{"t":"pong"}"#) == .answer)
        #expect(BackendRemoteLinkOutbox.classOf(#"{"t":"panel.rows","panel":"tasks","rid":"p-1"}"#) == .answer)
        #expect(BackendRemoteLinkOutbox.classOf(#"{"t":"error","code":"unavailable","rid":"r-1"}"#) == .answer)
        #expect(BackendRemoteLinkOutbox.classOf(#"{"t":"error","code":"unavailable"}"#) == .stream)
        #expect(BackendRemoteLinkOutbox.classOf(Self.output("s1", #"{"rid":"x"}"#)) == .stream, "output that prints a rid is still output")
        #expect(BackendRemoteLinkOutbox.classOf(#"{"t":"panel.rows","panel":"agents"}"#) == .stream, "an unasked list")
        #expect(BackendRemoteLinkOutbox.classOf(#"{"t":"status","id":"s1","status":"working"}"#) == .stream)
    }

    /// 14 Nov 18:20Z, 0220zd on his phone over a real TURN link: answers arrived (pong, Activity), the session's screen
    /// (`attached`, its replay, its `status`: stream class) never did. The real channel's reading of its own queue
    /// stayed between the stream's mark (16 KB) and the answers' (64 KB). Stand-in: a channel that sends everything it
    /// is handed but always READS 40 KB waiting. Before the fix the screen waited for ever; now it leaves within about a
    /// second, the episode is logged once, and the screen's delivery is logged.
    @Test(.timeLimit(.minutes(1))) func aChannelWhoseReadingNeverFallsStillGetsTheScreen() async throws {
        let channel = FakeChannel(rate: nil)
        final class Stuck: @unchecked Sendable { let reading: UInt64 = 40 * 1024 }
        let stuck = Stuck()
        let notes = Events()
        let box = BackendRemoteLinkOutbox(send: { channel.send($0) }, queued: { stuck.reading }, now: { FakeChannel.now() },
                                          failed: { _ in }, resync: { _ in }, log: { notes.add($0) }, label: { "Test phone" })
        let start = FakeChannel.now()
        box.put(#"{"t":"attached","id":"92fe8634-aaaa"}"#)
        box.put(#"{"t":"output","id":"92fe8634-aaaa","data":"the screen","replay":true}"#)
        box.put(#"{"t":"status","id":"92fe8634-aaaa","status":"working"}"#)
        var screenAt: Double?
        for n in 0..<40 {
            box.put(#"{"t":"panel.rows","panel":"tasks","path":"/p","rows":[],"rid":"r-\#(n)"}"#) // answers keep flowing
            if channel.texts.contains(#"{"t":"status","id":"92fe8634-aaaa","status":"working"}"#) { screenAt = FakeChannel.now(); break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let took = try #require(screenAt, "the screen never left: the stream class was starved") - start
        #expect(took < 1_600, "the screen left \(Int(took)) ms after it was put")
        let texts = channel.texts.filter { !$0.contains("panel.rows") }
        #expect(texts == [#"{"t":"attached","id":"92fe8634-aaaa"}"#, #"{"t":"output","id":"92fe8634-aaaa","data":"the screen","replay":true}"#,
                          #"{"t":"status","id":"92fe8634-aaaa","status":"working"}"#], "in order")
        #expect(notes.all.filter { $0.contains("sent anyway") }.count == 1, "\(notes.all)")
        #expect(notes.all.contains { $0.hasPrefix("open: screen 92fe8634 left for Test phone in ") }, "\(notes.all)")
        box.stop()
    }

    @Test("a rid deep inside a list, a page or a welcome is not an answer; only a top-level rid is")
    func aDeepRidIsStream() {
        #expect(BackendRemoteLinkOutbox.classOf(#"{"t":"sessions","sessions":[{"id":"s1","rid":"r-1"}]}"#) == .stream)
        #expect(BackendRemoteLinkOutbox.classOf(#"{"t":"welcome","sessions":[{"id":"s1","rid":"r-1"}]}"#) == .stream)
        #expect(BackendRemoteLinkOutbox.classOf(#"{"t":"chats.events","id":"c1","events":[{"value":{"input":{"rid":"x"}}}]}"#) == .stream)
        #expect(BackendRemoteLinkOutbox.classOf(#"{"t":"created","session":{"id":"s1","rid":"r-1"},"rid":"r-1"}"#) == .answer)
    }

    @Test("a newer sessions list never lands before an older one: the waiting older one is dropped")
    func aNewerSessionsListReplacesTheWaitingOne() {
        let channel = FakeChannel(rate: nil)
        let box = Self.box(channel, resyncs: Resyncs())
        channel.hold = true
        box.put(#"{"t":"sessions","sessions":[{"id":"old"}]}"#)
        box.put(#"{"t":"status","id":"s1","status":"working"}"#)
        box.put(#"{"t":"sessions","sessions":[{"id":"old"},{"id":"new"}]}"#)
        box.put(#"{"t":"folders","folders":["/a"]}"#)
        box.put(#"{"t":"folders","folders":["/a","/b"]}"#)
        channel.hold = false
        box.pump()
        #expect(channel.texts == [#"{"t":"status","id":"s1","status":"working"}"#,
                                  #"{"t":"sessions","sessions":[{"id":"old"},{"id":"new"}]}"#,
                                  #"{"t":"folders","folders":["/a","/b"]}"#])
    }

    @Test("an unasked list never lands after a fresher answer for the same panel, path and view")
    func anUnaskedListNeverOverwritesAnAnswer() {
        let channel = FakeChannel(rate: nil)
        let box = Self.box(channel, resyncs: Resyncs())
        channel.hold = true
        box.put(#"{"t":"panel.rows","panel":"tasks","path":"/p","rows":[{"id":"stale"}]}"#)
        box.put(#"{"t":"panel.rows","panel":"tasks","path":"/other","rows":[{"id":"kept"}]}"#)
        box.put(#"{"t":"panel.rows","panel":"tasks","path":"/p","rows":[{"id":"fresh"}],"rid":"p-1"}"#)
        channel.hold = false
        box.pump()
        #expect(channel.texts == [#"{"t":"panel.rows","panel":"tasks","path":"/p","rows":[{"id":"fresh"}],"rid":"p-1"}"#,
                                  #"{"t":"panel.rows","panel":"tasks","path":"/other","rows":[{"id":"kept"}]}"#])
    }

    final class FakeLink: BackendLinkConnection, @unchecked Sendable {
        var inChannel: UInt64 = 0
        func offer() async throws -> String { "" }
        func accept(answer: String) async throws {}
        func add(candidate: String, mid: String?, index: Int32) {}
        func send(_ data: Data, lane: BackendLinkLane) -> Bool { true }
        func close() {}
        func queued(_ lane: BackendLinkLane) -> UInt64 { lane == .control ? inChannel : 0 }
    }

    @Test("pushMayGo holds an unasked list back while the outbox itself is full")
    func pushMayGoCountsTheOutbox() async throws {
        let fake = FakeLink()
        fake.inChannel = 20 * 1024 // over the outbox's low mark, under the push limit: the channel alone said "go"
        let path = BackendRemoteLinkPath(relay: { _ in })
        path.set(.link(clientOnly: true))
        path.attach(fake, failure: nil)
        try await path.write(BackendRemoteLinkPath.movedText)
        try await path.write(Self.output("s1", String(repeating: "q", count: 40_000)))
        #expect(path.outboxWaitingBytes > 40_000)
        var state = BackendRemoteLinkState(path: path)
        state.token = UUID(); state.connection = fake; state.open = true; state.openedAt = 0
        #expect(!BackendRemoteHost.pushMayGo(link: state, now: 60_000), "40 KB waiting in the outbox holds the list back")
        path.attach(nil, failure: nil)
    }

    final class RecordingLink: BackendLinkConnection, @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [String] = []
        var inChannel: UInt64 = 10_000_000 // a link far behind: the outbox would hold and drop
        func offer() async throws -> String { "" }
        func accept(answer: String) async throws {}
        func add(candidate: String, mid: String?, index: Int32) {}
        func send(_ data: Data, lane: BackendLinkLane) -> Bool { lock.withLock { sent.append(String(decoding: data, as: UTF8.self)) }; return true }
        func close() {}
        func queued(_ lane: BackendLinkLane) -> UInt64 { lane == .control ? inChannel : 0 }
        var texts: [String] { lock.withLock { sent } }
    }

    /// The hidden off switch (`TDLinkOutboxOff`): off, a burst and an echo go straight onto the channel in plain order
    /// with nothing dropped (as 0220ze); on, the same link holds them in the outbox.
    @Test func theOffSwitchSendsThePlainWay() async throws {
        let burst = (0..<80).map { Self.output("s1", String(repeating: "z", count: 4_000) + "\($0)") } // 320 KB: over the backlog limit
        let frames = burst + [Self.output("s1", "echo"), #"{"t":"pong"}"#]
        for off in [true, false] {
            let link = RecordingLink()
            let path = BackendRemoteLinkPath(relay: { _ in }, outboxOff: { off })
            path.set(.link(clientOnly: true))
            path.attach(link, failure: nil)
            try await path.write(BackendRemoteLinkPath.movedText)
            for frame in frames { try await path.write(frame) }
            if off {
                #expect(link.texts == frames, "off: every frame, in order, nothing held or dropped")
                #expect(path.outboxWaitingBytes == 0)
            } else {
                #expect(link.texts.count < frames.count, "on: a link far behind is not handed the burst")
            }
            path.attach(nil, failure: nil)
        }
    }

    @Test("more than 2 MB waiting ends the link, once, with its reason")
    func theCapEndsTheLink() {
        let channel = FakeChannel(rate: nil)
        let events = Events()
        let box = Self.box(channel, resyncs: Resyncs(), events: events)
        channel.hold = true
        let page = #"{"t":"hoot.events","conversationId":"c","events":[],"pad":""# + String(repeating: "p", count: 64 * 1024) + #""}"#
        var taken = 0
        while box.put(page) { taken += 1; if taken > 100 { break } }
        #expect(taken == BackendRemoteLinkOutbox.mostWaitingBytes / page.utf8.count, "every frame up to the cap was taken")
        #expect(events.all == ["failed: " + BackendRemoteLinkOutbox.tooMuchWaited])
        #expect(box.waitingBytes == 0 && !box.put(#"{"t":"pong"}"#), "nothing more goes on that link")
    }

    @Test("an unasked list thrown away with its link is reported lost, and the host sends it again")
    func aThrownAwayListIsSentAgain() {
        let channel = FakeChannel(rate: nil)
        let events = Events()
        let box = Self.box(channel, resyncs: Resyncs(), events: events)
        channel.hold = true
        box.put(#"{"t":"panel.rows","panel":"agents","path":"","rows":[]}"#)
        box.stop()
        #expect(events.all == ["lists lost"], "the host then forgets it sent it (BackendRemoteHost.forgetPushedLists)")
        // (PhoneStartAsksTests.unchangedAgentListIsNotSentAgain: after forgetPushedLists the same list goes again.)
    }

    @Test("on a slow link no chat page or replay frame is above 64 KB")
    func slowLinkFramesStayUnderTheBound() async throws {
        // Replays and live output are already cut at 32 KB of JSON per frame (BackendRemoteProtocol.chunkOutput).
        let screen = String(repeating: "line of a busy terminal \u{1b}[0m\n", count: 40_000)
        for frame in try BackendRemoteHost.historyFrames("s1", screen) {
            #expect(try BackendRemoteProtocol.serialize(frame).utf8.count <= 64 * 1024)
        }
        // A chat page with the slow budget: the newest events that fit 64 KB (the phone pages back for the rest).
        let events = (1...200).map { n in
            HootChatEvent(conversationID: "conv-1", turnID: "turn-1", sequence: n, provider: .codex,
                          record: .text(.message, id: "m\(n)", String(repeating: "word ", count: 400)), at: 1).wireValue
        }
        let snapshot = NativeRPCValue.object([.init("conversationId", .string("conv-1")), .init("events", .array(events))])
        let chats = BackendPhoneChats(engine: .init(read: { _ in snapshot }, isChat: { _ in true }, say: { _, _ in }, interrupt: { _ in },
            answer: { _, _, _ in }, start: { _ in throw NativeRPCError(code: "unused", message: "unused") }),
            host: .init(send: { _, _ in }, stillSees: { _, _ in true }, admitStarted: { _, _ in }), beat: .zero)
        let slow = try await chats.conversation("chat-1", budget: BackendRemoteHost.slowPageBytes)
        #expect(try BackendRemoteProtocol.serialize(slow).utf8.count <= BackendRemoteHost.slowPageBytes)
        #expect((slow.value["events"].elements?.count ?? 0) >= 1 && (slow.value["first"].number ?? 0) > 0, "newest kept; older ones paged")
        // Every chat page is already at most MAX_MESSAGE_BYTES (64 KB) on any link, so the slow budget changes nothing.
        let usual = try await chats.conversation("chat-1")
        #expect(try BackendRemoteProtocol.serialize(usual).utf8.count <= 64 * 1024)
        #expect(usual.value["events"] == slow.value["events"], "a fast link keeps today's page")
    }

    /// A slow link (20 KB a second) and a session writing 1 MB, for a minute: the heartbeat answer is handed to the channel
    /// within 100 ms of being sent, every time (what is already in the channel ahead of it is at most `answerMark`); his input's echo reaches the phone within a second once the burst's backlog is gone (3 s while it waits); the waiting output is
    /// replaced by the session afresh and nothing here ever holds more than the backlog limit.
    @Test(.timeLimit(.minutes(2))) func slowLinkKeepsAnswersFastAndTheBacklogBounded() async throws {
        let channel = FakeChannel(rate: 20_000)
        let resyncs = Resyncs()
        // The host's answer to a resync: `attached`, a small screen, the status (BackendRemoteHost.resyncSession).
        let box = Self.box(channel, resyncs: resyncs) { box, session in
            box.put(#"{"t":"attached","id":"\#(session)"}"#)
            box.put(#"{"t":"output","id":"\#(session)","data":"screen","replay":true}"#)
            box.put(#"{"t":"status","id":"\#(session)","status":"working"}"#)
        }
        let chunk = String(repeating: "x", count: 4_000)
        let started = FakeChannel.now()
        var written = 0, pings = 0, most = 0
        var echoes: [String] = [], pongPuts: [Double] = [], echoPuts: [Double] = []
        var burstEnded: Double?
        while FakeChannel.now() - started < 60_000 {
            // The session: 1 MB in its first seconds, then a steady trickle.
            if written < 1_000_000 { box.put(Self.output("s1", chunk)); written += chunk.count }
            else { box.put(Self.output("s1", "tick")); burstEnded = burstEnded ?? FakeChannel.now() }
            let elapsed = Int(FakeChannel.now() - started)
            if elapsed / 1_000 > pings { pings += 1; pongPuts.append(FakeChannel.now()); box.put(#"{"t":"pong"}"#) }
            if elapsed / 5_000 > echoes.count { let echo = "echo-\(echoes.count)"; echoes.append(echo); echoPuts.append(FakeChannel.now()); box.put(Self.output("s1", echo)) }
            most = max(most, box.waitingBytes)
            try await Task.sleep(for: .milliseconds(written < 1_000_000 ? 4 : 50))
        }
        try await Task.sleep(for: .milliseconds(200))
        let texts = channel.texts
        // Every pong went to the channel within 100 ms (the time from `put` is bounded by the poll and the low mark).
        let pongs = channel.handed.enumerated().filter { $0.element.text == #"{"t":"pong"}"# }
        #expect(pongs.count == pongPuts.count)
        for (n, pong) in pongs.enumerated() where n < pongPuts.count {
            #expect(pong.element.at - pongPuts[n] < 100, "pong \(n) left \(Int(pong.element.at - pongPuts[n])) ms after it was sent")
            #expect(pong.element.ahead <= Double(BackendRemoteLinkOutbox.answerMark), "and waited behind at most the answer mark")
        }
        // Every echo reached the phone in time: none was lost behind a stale backlog.
        // An echo is the same session's output as the burst, so it never overtakes the burst's own earlier output (the
        // terminal's order). While the burst still waits, the design's bound on this link is: at most
        // `mostSessionBacklogMs` (2 s) in the outbox (older output is dropped and the screen sent afresh, the echo with
        // it), one poll (0.1 s), then at most `lowMark` (16 KB) ahead of it in the channel: 16 KB / 20 KB/s = 0.8 s;
        // 2 + 0.1 + 0.8 = 2.9 s, so 3 s. Once that backlog is gone (2 s after the burst, plus a second for the channel),
        // an echo reaches the phone within a second. (15 Nov: on a slower run, most likely with the burst still pouring then, echo-0..2
        // came in 2.5, 1.9 and 1.4 s, inside the bound; the later ones in under 0.1 s.)
        let calm = (burstEnded ?? .infinity) + BackendRemoteLinkOutbox.mostSessionBacklogMs + 1_000
        for (n, echo) in echoes.enumerated() {
            // The exact frame, never a substring ("echo-1" is inside "echo-10": a dropped echo-1 was timed by echo-10).
            guard let index = texts.firstIndex(of: Self.output("s1", echo)) else { continue } // dropped: inside a fresh screen
            let limit: Double = echoPuts[n] >= calm ? 1_000 : 3_000
            #expect(channel.arrival(of: index) - echoPuts[n] < limit, "\(echo) reached the phone within \(Int(limit)) ms")
        }
        #expect(!resyncs.all.isEmpty, "the backlog was replaced by the session afresh")
        #expect(most <= BackendRemoteLinkOutbox.mostSessionBacklogBytes + 64 * 1024, "the outbox stayed bounded: \(most)")
        #expect(texts.contains(#"{"t":"attached","id":"s1"}"#))
        box.stop()
    }

    /// A fast link: nothing skipped, nothing reordered, the bytes exactly as handed in.
    @Test func fastLinkSendsEveryByteInOrder() async throws {
        let channel = FakeChannel(rate: nil)
        let resyncs = Resyncs()
        let box = Self.box(channel, resyncs: resyncs)
        var sent: [String] = []
        for n in 0..<300 {
            let frames = [Self.output("s1", String(repeating: "y", count: 3_500) + "\(n)"),
                          n % 10 == 0 ? #"{"t":"pong"}"# : #"{"t":"status","id":"s1","status":"working"}"#,
                          #"{"t":"panel.rows","panel":"tasks","rid":"p-\#(n)"}"#]
            for frame in frames { box.put(frame); sent.append(frame) }
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(channel.texts == sent, "identical to today's bytes, in today's order")
        #expect(resyncs.all.isEmpty && box.waitingBytes == 0)
    }

    /// A newer picture of the same browser window replaces an older one still waiting; other windows keep theirs.
    @Test func aNewerBrowserPictureReplacesAWaitingOne() async throws {
        let channel = FakeChannel(rate: 1_000)
        let box = Self.box(channel, resyncs: Resyncs())
        box.put(Self.output("s1", String(repeating: "z", count: 40_000))) // fills the channel past the low mark
        box.put(#"{"t":"browser.frame","id":"w1","jpeg":"old"}"#)
        box.put(#"{"t":"browser.frame","id":"w2","jpeg":"other"}"#)
        box.put(#"{"t":"browser.frame","id":"w1","jpeg":"new"}"#)
        #expect(box.waitingBytes > 0)
        #expect(!channel.texts.contains { $0.contains("old") })
        box.stop()
    }
}
