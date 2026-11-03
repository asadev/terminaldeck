import Foundation
import Testing
@testable import TerminalDeckNativeCore

// Lane T — sessions wherever they run: tab ids, machine links, how a session ends.

private func json(_ text: String) -> Any {
    try! JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
}

@Suite("Session targets")
struct SessionTargetTests {
    @Test func tabIdsNameWhereTheSessionRuns() {
        let uuid = "3F2504E0-4F89-41D3-9A0C-0305E82C3301"
        #expect(SessionTarget(tabId: uuid) == .local(uuid))
        #expect(SessionTarget(tabId: "machine m1 s-2") == .machine(machineId: "m1", sessionId: "s-2"))
        // The session id is the whole remainder, spaces and all.
        #expect(SessionTarget(tabId: "machine m1 a b") == .machine(machineId: "m1", sessionId: "a b"))
        #expect(SessionTarget(tabId: "server srv k1") == .server(serverId: "srv", shellKey: "k1"))
        #expect(SessionTarget(tabId: "machine m1") == nil)
        #expect(SessionTarget(tabId: "machine  s") == nil)
        #expect(SessionTarget(tabId: "machine m1 ") == nil)
        #expect(SessionTarget(tabId: "held:abc") == nil)
        #expect(SessionTarget(tabId: "browser:1:2") == nil)
    }

    @Test func roundTripsToTheSameTabId() {
        for id in ["machine m1 s1", "server a b c", "3f2504e0-4f89-41d3-9a0c-0305e82c3301"] {
            #expect(SessionTarget(tabId: id)?.tabId == id)
        }
        #expect(SessionTarget(tabId: "machine m1 s1")?.machineId == "m1")
        #expect(SessionTarget(tabId: "server a b")?.machineId == nil)
    }
}

@Suite("Machine links")
struct MachineLinkTests {
    private let view = json(#"""
    {"machines":[{"id":"m1","name":"Office PC","hostId":"h"},{"id":"m2"}],
     "links":[{"id":"m1","state":"online","reason":null,"retryAt":null,
               "sessions":[{"id":"s1","title":"api","cwd":"/home/a/api","provider":"claude","status":"working","exitCode":null},
                           {"id":"s2","title":"","cwd":"/","provider":"shell","status":"exited","exitCode":1}]},
              {"id":"m2","state":"error","reason":"Timed out.","retryAt":1759700000000,"sessions":[]},
              {"id":"m3","state":"sideways","sessions":[]}]}
    """#)

    @Test func decodesNamesLinksAndSessions() throws {
        let snapshot = try #require(MachinesSnapshot.decode(view))
        #expect(snapshot.names["m1"] == "Office PC")
        #expect(snapshot.names["m2"] == "m2")
        let link = try #require(snapshot.links["m1"])
        #expect(link.state == .online)
        #expect(link.session("s1")?.provider == "claude")
        #expect(link.session("s2")?.exitCode == 1)
        #expect(snapshot.links["m2"]?.retryAt == 1_759_700_000_000)
        #expect(snapshot.links["m3"]?.state == .offline)
        #expect(MachinesSnapshot.decode("nope") == nil)
    }

    @Test func aMachineSessionEndsAsTheLinkSays() throws {
        let snapshot = try #require(MachinesSnapshot.decode(view))
        let m1 = snapshot.links["m1"]
        #expect(SessionEnd.ofMachineSession(machine: "Office PC", link: m1, session: m1?.session("s1")) == nil)
        #expect(SessionEnd.ofMachineSession(machine: "Office PC", link: m1, session: m1?.session("s2")) == .exited(code: 1))
        #expect(SessionEnd.ofMachineSession(machine: "Office PC", link: nil, session: nil) == .machineStopped(machine: "Office PC"))
        let away = SessionEnd.ofMachineSession(machine: "m2", link: snapshot.links["m2"], session: nil)
        #expect(away == .machineAway(machine: "m2", why: "Timed out.", retryAt: 1_759_700_000_000))
        let dialling = MachineLinkFacts(id: "x", state: .connecting, reason: nil, retryAt: nil, sessions: [])
        #expect(SessionEnd.ofMachineSession(machine: "X", link: dialling, session: nil) == .machineDialling(machine: "X"))
        let refused = MachineLinkFacts(id: "x", state: .awaitingApproval, reason: nil, retryAt: nil, sessions: [])
        #expect(SessionEnd.ofMachineSession(machine: "X", link: refused, session: nil) == .machineUnapproved(machine: "X"))
        #expect(SessionEnd.ofLocal(exitCode: nil) == nil)
        #expect(SessionEnd.ofLocal(exitCode: 0) == .exited(code: 0))
    }
}

@Suite("Session end notices")
struct SessionEndNoticeTests {
    @Test func everyEndSaysWhatHappenedAndOffersOnePress() {
        let exited = SessionEnd.exited(code: 2).notice
        #expect(exited.title == "This session has ended")
        #expect(exited.detail.hasPrefix("The program running here exited with status 2."))
        #expect(exited.action?.label == "Start another session here")
        #expect(!exited.alive)
        #expect(SessionEnd.exited(code: nil).notice.detail.hasPrefix("The program running here finished."))

        let gone = SessionEnd.shellGone(server: "box").notice
        #expect(gone.title == "This terminal has ended")
        #expect(gone.action?.label == "Open another terminal on box")

        let stopped = SessionEnd.machineStopped(machine: "PC").notice
        #expect(stopped.title == "Disconnected from PC")
        #expect(stopped.action == .init(id: .connect, label: "Connect to PC"))
        #expect(stopped.alive)

        #expect(SessionEnd.machineDialling(machine: "PC").notice.action == nil)
        #expect(SessionEnd.machineUnapproved(machine: "PC").notice.title == "PC has not let this computer in")
        #expect(SessionEnd.neverOpened(why: "No shell.").notice.action?.label == "Try again")
    }

    @Test func aMachineBeingRedialledCountsDownAndOffersNoButton() {
        let away = SessionEnd.machineAway(machine: "PC", why: nil, retryAt: 10_000).notice
        #expect(away.action == nil)
        #expect(away.detail.hasSuffix("It is being dialled again."))
        #expect(away.countdown(nowMs: 6_000) == "in 4s")
        #expect(away.countdown(nowMs: 12_000) == "now")
        #expect(away.detail(nowMs: 6_000).hasSuffix(" Next try in 4s."))
        let idle = SessionEnd.machineAway(machine: "PC", why: "Asleep.", retryAt: nil).notice
        #expect(idle.action == .init(id: .redial, label: "Try it now"))
        #expect(idle.detail.hasPrefix("Asleep. The session is still running over there"))
        #expect(idle.countdown(nowMs: 0) == nil)
    }
}

@Suite("Transfers to another machine")
struct TerminalTransferTests {
    @Test func linesSayTheNameAndTheNumber() {
        #expect(TerminalTransfer.line(name: "a.png", size: 200, sent: 50, phase: "sending", message: "") == "a.png — 25%")
        #expect(TerminalTransfer.line(name: "a.png", size: 0, sent: 0, phase: "sending", message: "") == "a.png")
        #expect(TerminalTransfer.line(name: "a.png", size: 10, sent: 10, phase: "finishing", message: "") == "a.png — finishing")
        #expect(TerminalTransfer.line(name: "a.png", size: 10, sent: 10, phase: "landed", message: "") == "")
        #expect(TerminalTransfer.line(name: "a.png", size: 10, sent: 3, phase: "failed", message: "Disk full.") == "Disk full.")
    }

    @Test func pastesOverAMegabyteDoNotCross() {
        #expect(!TerminalTransfer.overPasteCap(String(repeating: "a", count: 1024 * 1024)))
        #expect(TerminalTransfer.overPasteCap(String(repeating: "a", count: 1024 * 1024 + 1)))
        // Counted in UTF-8 bytes: 300,000 emoji are 1.2 MB.
        #expect(TerminalTransfer.overPasteCap(String(repeating: "🙂", count: 300_000)))
        #expect(TerminalTransfer.pasteTooBig == "That paste is too big to send — the limit is 1.0 MB.")
    }
}

@Suite("Server shells")
struct ServerShellTests {
    @Test func outputBeforeTheShellIdIsHeldAndFiltered() {
        var frames = ShellFrames(cap: 10)
        #expect(frames.arrived(shellId: "a", data: "one ") == "")
        #expect(frames.arrived(shellId: "b", data: "other") == "")
        #expect(frames.arrived(shellId: "a", data: "two") == "")
        #expect(frames.settled("a") == "one two")
        #expect(frames.arrived(shellId: "a", data: "live") == "live")
        #expect(frames.arrived(shellId: "b", data: "not mine") == "")
        var refused = ShellFrames()
        _ = refused.arrived(shellId: "a", data: "x")
        #expect(refused.settled(nil) == "")
    }

    @Test func aServerTabCarriesWhatItsPaneOpens() throws {
        let json = #"{"tabs":[{"id":"server s1 k1","title":"box","kind":"session","server":{"serverId":"s1","serverName":"box","shellKey":"k1","startIn":"/srv","run":"claude","shellId":null}},{"id":"x","kind":"session"}],"canNewTerminal":true,"canNewBrowser":true}"#
        let state = try JSONDecoder().decode(TabsState.self, from: Data(json.utf8))
        let server = try #require(state.tabs.first?.server)
        #expect(server == ServerTabInfo(serverId: "s1", serverName: "box", shellKey: "k1", startIn: "/srv", run: "claude", shellId: nil))
        #expect(state.tabs.last?.server == nil)
        #expect(state.tabs.first?.with(active: true).server == server)
    }
}
