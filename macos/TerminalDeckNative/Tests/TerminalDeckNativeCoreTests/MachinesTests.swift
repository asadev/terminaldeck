import Foundation
import Testing
@testable import TerminalDeckNativeCore

/// "Machines you can reach" and the code entry, mirroring `MachineLinks.test.tsx`,
/// `CodeEntry.test.tsx` and the readers in `machines/types.ts`.
@Suite("Machines you can reach")
struct MachinesReachTests {
    @Test func readsTheViewAndFillsInAMissingLink() {
        let view = MachinesView(json: [
            "machines": [["id": "m1", "name": "Studio", "hostId": "h", "fingerprint": "ab cd", "platform": "win32", "pairedAt": 1, "drivesWindows": true], ["name": "no id"]] as [Any],
            "links": [["id": "m1", "state": "awaiting-approval", "reason": "", "sessions": [["id": "s1", "title": "Fix", "cwd": "C:\\work\\shop\\app", "status": "working"]],
                       "capabilities": ["localhost", "web"], "ports": [["port": 3000, "process": "node"], ["port": 70000], ["port": 5173, "guessed": true]],
                       "hostPlatform": "", "hostVersion": "0.18.7", "hostKind": "headless", "retryAt": NSNull()]] as [Any],
            "here": "My Mac", "blocked": "",
        ])
        #expect(view.machines.map(\.id) == ["m1"] && view.machines[0].drivesWindows)
        let link = view.link(for: "m1")
        #expect(link.phase == .awaitingApproval && link.reason == nil && link.ports.map(\.port) == [3000, 5173])
        #expect(view.blocked == nil && view.here == "My Mac")
        #expect(view.link(for: "gone").phase == .offline)
        #expect(MachinesView(json: "nonsense") == .empty)
        #expect(MachinesRules.noun(view.machines[0], link) == "PC")
        #expect(MachinesRules.versionLine(link) == "version 0.18.7 · server")
        #expect(MachinesRules.reasonLine(view.machines[0], link) == "Approve this Mac on Studio, under Remote. It will connect by itself once you have.")
        #expect(MachinesRules.shortPath("C:\\work\\shop\\app") == "…/shop/app" && MachinesRules.shortPath("/a/b") == "/a/b")
        #expect(MachinesRules.portLabel(link.ports[0]) == "3000 · node" && MachinesRules.portLabel(link.ports[1]) == "5173 · unknown process")
        #expect(MachinesRules.tabId(machineId: "m1", sessionId: "s1") == "machine m1 s1")
        #expect(MachineLinkPhase.online.label == "Connected" && MachineLinkPhase.error.label == "Cannot connect")
    }

    @Test func theWindowsTickIsMutedOnlyWhereThatBuildCannotAsk() {
        let machine = PairedMachine(id: "m", name: "PC", drivesWindows: true)
        #expect(MachinesRules.windowsMuted(machine, MachineLink(id: "m", phase: .online)))
        #expect(!MachinesRules.windowsMuted(machine, MachineLink(id: "m", phase: .online, capabilities: ["windows"])))
        #expect(!MachinesRules.windowsMuted(machine, MachineLink(id: "m", phase: .offline)))
    }

    @Test func pairingAnswersAreRead() {
        #expect(MachinesRules.pairFailure(["ok": true]) == nil)
        #expect(MachinesRules.pairFailure(["ok": false, "reason": "x", "message": "Wrong code."]) == "Wrong code.")
        #expect(MachinesRules.pairFailure(["ok": false]) == "That did not work, and this machine did not say why.")
        #expect(MachinesRules.pairFailure(nil) == "This machine gave no answer.")
    }
}

@Suite("Code entry")
struct CodeEntryTests {
    @Test func takesDigitsOnly() {
        #expect(CodeEntryRules.symbol("4") == "4" && CodeEntryRules.symbol("0") == "0")
        for bad in ["O", "l", " ", "-"] as [Character] { #expect(CodeEntryRules.symbol(bad) == nil) }
        #expect(CodeEntryRules.normalise("482-913") == "482913" && CodeEntryRules.normalise("48291") == nil && CodeEntryRules.normalise("48a913") == nil)
    }

    @Test func fillsTheBoxTypedIntoAndMovesOn() {
        #expect(CodeEntryRules.typed(into: "", at: 0, raw: "4") == ("4", 1))
        #expect(CodeEntryRules.typed(into: "48", at: 2, raw: "2") == ("482", 3))
        let later = CodeEntryRules.typed(into: "", at: 3, raw: "5")
        #expect(later.digits == "   5" && CodeEntryRules.digit(later.digits, at: 0) == "" && CodeEntryRules.digit(later.digits, at: 3) == "5")
        #expect(CodeEntryRules.normalise(later.digits) == nil)
        #expect(CodeEntryRules.typed(into: "482913", at: 0, raw: "7") == ("782913", 1))
    }

    @Test func spreadsAPasteAndNeverHoldsMoreThanACode() {
        #expect(CodeEntryRules.typed(into: "", at: 0, raw: "482 913").digits == "482913")
        #expect(CodeEntryRules.typed(into: "", at: 0, raw: "482-913").digits == "482913")
        let long = CodeEntryRules.typed(into: "", at: 3, raw: "123456789")
        #expect(long.digits.count == 6 && long.focus == 5)
        #expect(CodeEntryRules.typed(into: "482", at: 3, raw: "x") == ("482", 3))
        #expect(CodeEntryRules.typed(into: "482", at: 3, raw: "") == ("482", 3))
        #expect(CodeEntryRules.added(by: "45", previous: "4") == "5" && CodeEntryRules.added(by: "54", previous: "4") == "5" && CodeEntryRules.added(by: "7", previous: "4") == "7")
    }
}
