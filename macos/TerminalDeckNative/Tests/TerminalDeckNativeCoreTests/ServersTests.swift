import Foundation
import Testing
@testable import TerminalDeckNativeCore

// Machines → Servers (lane G): the readers and sentences behind the native
// Servers screens, mirroring words.test.ts, group-notes, key-routes, AddServer,
// ServerHost, ServerFolderPicker and types.test.ts. Fixtures only.

private func json(_ text: String) -> CodingAIJSON { CodingAIJSON.parse(text) }

@Suite("Servers — what a look found")
struct ServersLookTests {
    let look = json(#"""
    {"cards": [
       {"id": "web", "kind": "site", "name": "example.com", "detail": "nginx", "running": true, "url": "https://example.com"},
       {"id": "db", "kind": "database", "name": "postgres", "running": false},
       {"id": "x", "kind": "weird", "name": "thing", "running": "yes"},
       {"id": "", "name": "no id"}
     ],
     "facts": {"os": {"known": "yes", "value": "Ubuntu 24.04", "measuredAt": 1}, "hostname": {"known": "cannot", "why": "No permission."},
               "user": {"known": "no"}, "disk": {"known": "yes", "value": {"totalKb": 1000, "freeKb": 250}},
               "memory": {"known": "yes", "value": {"totalKb": 200, "usedKb": 50}}, "load1": {"known": "yes", "value": 1.2},
               "cpus": {"known": "yes", "value": 2}, "uptime": {"known": "yes", "value": 7200}, "listeners": {"known": "yes", "value": [1, 2, 3]},
               "packages": {"known": "yes", "value": "apt"}, "init": {"known": "yes", "value": "systemd"}},
     "offered": {"web": ["open", "restart", ""]}, "absent": {"db": [{"actionId": "restart", "because": "No permission."}, {"actionId": ""}]},
     "cannot": [{"what": "Disk", "why": "Hidden."}, {"what": "x", "why": ""}], "measuredAt": 1000}
    """#)

    @Test func viewIsNarrowed() {
        let view = ServerView.parse(look)!
        #expect(view.cards.map(\.id) == ["web", "db", "x"])
        #expect(view.cards[2].kind == .other && view.cards[2].running == nil)
        #expect(view.offered["web"] == ["open", "restart"])
        #expect(view.absent["db"]?.count == 1)
        #expect(view.cannot.map(\.what) == ["Disk"])
        #expect(view.facts["hostname"] == .cannot("No permission."))
        #expect(view.facts["user"] == ServerFact.no)
        #expect(view.facts["packageManager"]?.value == .string("apt"))   // old spelling
        #expect(view.facts["listeners"]?.value == .number(3))            // a list counts
        #expect(ServerView.parse(.null) == nil)
    }

    @Test func readingsAndSentences() {
        let view = ServerView.parse(look)!
        #expect(ServerWords.readings(view.facts).map(\.value) == ["75% full", "25% in use", "Light", "2 hours"])
        var inContainer = view.facts
        inContainer.facts["init"] = .yes(.string("container-none"))
        #expect(ServerWords.readings(inContainer).isEmpty)
        #expect(ServerWords.overall(view.cards) == "postgres isn't running.")
        #expect(ServerWords.overall([]) == "There's nothing here we can check on.")
        #expect(ServerWords.overall(nil) == "")
        #expect(ServerWords.overall([ServerCardInfo(id: "a", kind: .app, name: "a", running: nil)]) == "We couldn't check anything on this server.")
        #expect(ServerWords.runningWord(nil) == "Can't tell")
        #expect(ServerWords.busyness(load: 1.5, cpus: 2) == "Steady")
        #expect(ServerWords.busyness(load: 1, cpus: 0) == "")
    }

    @Test func agesAndWhenTheyChange() {
        #expect(ServerWords.asOf(0, now: 30_000) == "just now")
        #expect(ServerWords.asOf(0, now: 90_000) == "2 minutes ago")
        #expect(ServerWords.asOf(0, now: 3_700_000) == "1 hour ago")
        #expect(ServerWords.asOf(0, now: 90_000_000) == "yesterday")
        #expect(ServerWords.nextAgeChange(0, now: 10_000) == 45_000)
        #expect(ServerWords.nextAgeChange(0, now: 90_000) == 150_000)
        #expect(ServerWords.howLong(30) == "less than a minute")
        #expect(ServerWords.howLong(86_400 * 3) == "3 days")
    }

    @Test func sharedReasonsAreSaidOnce() {
        let cards = [ServerCardInfo(id: "a", kind: .app, name: "a"), ServerCardInfo(id: "b", kind: .app, name: "b")]
        let absent: [String: [ServerAbsentAction]] = [
            "a": [.init(actionId: "restart", because: "Not yours."), .init(actionId: "logs", because: "No logs.")],
            "b": [.init(actionId: "restart", because: "Not yours.")],
        ]
        let reasons = ServerWords.groupReasons(cards, absent: absent)
        #expect(reasons.shared == ["Not yours."])
        #expect(reasons.own["a"]?.map(\.because) == ["No logs."])
        #expect(reasons.own["b"]?.isEmpty == true)
        #expect(ServerWords.groupReasons([cards[0]], absent: absent).shared.isEmpty)
    }

    @Test func refusalsAndOutcomes() {
        let refused = ServerRoomState.failed("s", refusal: json(#"{"ok": false, "sentence": "Host key changed.", "kind": "identity-changed", "identity": {"expected": "SHA256:a", "offered": "SHA256:b"}}"#))
        #expect(refused.link == .failed && refused.identityChanged && refused.identity?.offered == "SHA256:b")
        #expect(ServerRoomState.failed("s", refusal: .null).problem == "Nothing came back from that. Nothing may have happened.")
        let outcome = ServerActionOutcome.parse(json(#"{"done": "Restarted.", "wayBack": {"actionId": "stop", "label": "Stop it"}}"#))
        #expect(outcome.done == "Restarted." && outcome.wayBack?.label == "Stop it")
        #expect(ServerActionOutcome.parse(.null).done == "Done.")
        #expect(ServerActionPreview.parse(json(#"{"actionId": "restart", "label": "Restart", "klass": "reversible", "sentence": "Restarts it."}"#))?.klass == .reversible)
        #expect(ServerActionPreview.parse(json(#"{"actionId": "x", "label": "X", "klass": "maybe"}"#)) == nil)
        #expect(ServerWords.logLines(json(#"{"ok": true, "lines": ["a", 3, "b"]}"#)) == ["a", "", "b"])
        #expect(ServerGrant.parse(json(#"{"serverId": "s", "expiresAt": 5}"#))?.grantedAt == 0)
    }
}

@Suite("Servers — adding one, the host, folders")
struct ServersFlowTests {
    @Test func portAndDraft() {
        #expect(AddServerRules.readPort("").ok)
        #expect(AddServerRules.readPort(" 2222 ").port == 2222)
        #expect(AddServerRules.readPort("22a").sentence == "That is a number, like 2222. Leave it empty for the usual one.")
        #expect(AddServerRules.readPort("70000").sentence == "It has to be between 1 and 65535. Leave it empty for the usual one.")
        #expect(AddServerRules.wantsPassphrase(.badPassphrase, passphrase: ""))
        #expect(!AddServerRules.wantsPassphrase(nil, passphrase: ""))
        let draft = AddServerRules.draft(address: " box ", port: nil, username: "me", method: "key", password: "pw", key: "KEY",
                                         passphrase: "pp", locked: true, name: " ", remember: false)
        #expect(draft.jsonText == #"{"address":"box","key":"KEY","method":"key","passphrase":"pp","remember":false,"username":"me"}"#)
        let failed = AddServerRules.result(json(#"{"ok": false, "reason": "needs-passphrase", "message": "Locked."}"#))
        #expect(!failed.ok && failed.reason == .needsPassphrase && failed.message == "Locked.")
        #expect(AddServerRules.result(json(#"{"ok": true, "id": "s1"}"#)).id == "s1")
        #expect(AddServerRules.result(.null).message == "Nothing came back from that attempt. Try it again.")
    }

    @Test func keys() {
        let offers = AddServerRules.keyOffers(json(#"[{"path": "/k/id_ed25519", "name": "id_ed25519", "what": "An ed25519 key", "locked": true}, {"path": "", "name": "x"}]"#))
        #expect(offers.count == 1 && offers[0].says == "An ed25519 key · needs a password to open")
        let none = AddServerRules.keyRoutes(hasChooser: true, found: 0, chosen: false, pasting: false)
        #expect(!none.list && none.panel && none.paste && !none.offerPaste)
        let some = AddServerRules.keyRoutes(hasChooser: true, found: 2, chosen: false, pasting: false)
        #expect(some.list && !some.paste && some.offerPaste)
        #expect(AddServerRules.pasteBoxText(fromFile: true, typed: "x") == "")
        #expect(AddServerRules.keyText(json(#"{"ok": false}"#)).sentence == "That file could not be read. Choose it again.")
    }

    @Test func hostControls() {
        let offer = ServerHostOffer.parse(json(#"""
        {"host": {"command": "/usr/bin/td-host", "version": "0.17.0", "running": "yes", "address": "td://x"}, "room": {},
         "canInstall": true, "canLink": true, "linkedAs": null, "line": "Installed.", "mine": "0.18.7",
         "removes": {"keepData": "Keeps data.", "withData": "Deletes data."}, "state": {"serverId": "s", "step": "idle"}}
        """#))!
        let controls = ServerHostRules.controls(offer, busy: false)
        #expect(controls.here && !controls.install && controls.update == "0.18.7" && controls.link && controls.pair && controls.remove)
        #expect(ServerHostRules.controls(offer, busy: true) == ServerHostRules.Controls(here: true, install: false, update: nil, link: false, pair: false, remove: false, stop: true, why: nil, reach: nil, linkedAs: nil, away: false))
        #expect(ServerHostRules.updateAvailable(command: "x", version: "v1.2", mine: "1.2.0") == nil)
        #expect(ServerHostRules.updateAvailable(command: "", version: "0.1", mine: "1.0") == nil)
        #expect(ServerHostRules.updateAvailable(command: "x", version: "1.2.x", mine: "2.0") == nil)
        #expect(ServerHostOffer.parse(json(#"{"host": {}, "room": {}}"#)) == nil)
        #expect(ServerHostRules.sentence(json(#"{"message": "No."}"#)) == "No.")
    }

    @Test func relayAndGitHub() {
        let control = ServerHostControl.parse(json(#"{"running": true, "version": "0.18.7", "uptimeSeconds": 7200, "managed": "systemd"}"#))!
        #expect(control.detail == "up for 2 hours · it comes back on its own after a restart")
        #expect(control.say == "Running 0.18.7.")
        #expect(ServerHostControl.spell(30) == "1 minute")
        let signing = ServerGitHub.parse(json(#"{"pending": {"userCode": "AB-12", "verificationUri": "https://github.com/login/device"}, "appConfigured": true}"#))!
        #expect(signing.phase == .signingIn)
        #expect(ServerGitHub.parse(json(#"{"connected": true, "login": "me", "source": "gh"}"#))?.subtitle == "gh")
        #expect(ServerGitHub.parse(json(#"{"pending": {"userCode": ""}}"#))?.phase == .notConfigured)
        #expect(ServerGitHub.parse(json(#"{"appConfigured": true}"#))?.phase == .ready)
    }

    @Test func folders() {
        #expect(ServerFolders.line(path: nil, fallback: nil).shown == "Wherever this sign-in lands")
        #expect(ServerFolders.line(path: nil, fallback: "/srv").note == "Its default folder. Every session on it starts here.")
        #expect(ServerFolders.line(path: "/srv/app", fallback: "/srv").note == "Chosen for this session. Its default is /srv.")
        #expect(ServerFolders.inNameOrder([".git", "b", "A", "a"]) == ["A", "a", "b", ".git"])
        #expect(ServerFolders.childOf("/", "srv") == "/srv")
        #expect(ServerFolders.childOf("/srv", "..") == "/srv/..")
        let folder = ServerFolders.parse(json(#"{"ok": true, "path": "/srv", "entries": [{"name": "app", "kind": "folder"}, {"name": "l", "kind": "link"}, {"name": "f.txt"}, {"name": ""}]}"#))
        #expect(folder?.folders == ["app", "l"] && folder?.files == 1)
        #expect(ServerFolders.filesNotShown(2) == "2 files here are not shown — a session starts in a folder.")
        #expect(ServerFolders.storedFolder(json(#"{"path": "/srv"}"#)) == "/srv")
    }

    @Test func advancedLinesAndExtras() {
        #expect(ServerAdvancedText.credentialLine("key") == "A key, sealed by this computer and never shown on any screen.")
        #expect(ServerAdvancedText.credentialLine(nil) == "This build did not say.")
        #expect(ServerAdvancedText.factLine(nil, say: { _ in "" }, none: "x") == "We have not asked yet.")
        #expect(ServerAdvancedText.factLine(.cannot(""), say: { _ in "" }, none: "x") == "This sign-in could not find out.")
        #expect(ServerAdvancedText.listenersLine(.number(1)) == "1 thing")
        #expect(ServerAdvancedText.allowedFor(ServerGrant(serverId: "s", expiresAt: 3_600_000, grantedAt: 0), now: 0) == "Allowed for another 1 hour")
        let extras = CodingAIServer.parseExtras(json(#"[{"id": "a", "address": "h", "credential": "key", "hostKey": {"fingerprint": "SHA256:x"}, "drivesWindows": true}, {"id": "b", "credential": "odd"}]"#))
        #expect(extras["a"] == CodingAIServer.Extra(credential: "key", fingerprint: "SHA256:x", drivesWindows: true))
        #expect(extras["b"]?.credential == nil)
    }
}

@Suite("Hoot on other machines")
struct CopilotMachinesTests {
    @Test func rowsFollowTheLinks() {
        let rows = CopilotMachineRow.rows(json(#"""
        {"here": "Studio",
         "machines": [{"id": "pc", "name": "Office PC"}, {"id": "lap", "name": "Laptop"}, {"id": "nameless", "name": ""}, {"id": "srv", "name": "Box"}],
         "links": [{"id": "pc", "state": "online", "copilot": {"linked": true, "open": true, "grant": {"read": true, "act": false, "alter": false}}},
                   {"id": "lap", "state": "offline", "copilot": {"linked": true, "open": false, "grant": {"read": true, "act": true, "alter": true}}},
                   {"id": "nameless", "state": "online"},
                   {"id": "srv", "state": "online", "copilot": {"linked": true, "open": true, "grant": {"read": true}}}]}
        """#))
        #expect(rows.map(\.id) == ["", "pc", "lap", "srv"])
        #expect(rows[0] == CopilotMachineRow(id: "", name: "Studio", reach: .ready, open: true))
        #expect(rows[1].reach == .ready && rows[1].open)
        #expect(rows[2].reach == .unreachable)
        #expect(rows[3].reach == .refused && !rows[3].open)   // a grant missing booleans is no Hoot for us
        #expect(CopilotMachineRow.rows(.null).map(\.name) == ["This Mac"])
    }

    @Test func conversationFrames() {
        let first = RemoteCopilotModel.chat(json(#"{"messages": [{"id": "1", "role": "you", "text": "hi"}, {"id": "2", "role": "agent", "text": "hel"}, {"id": "", "text": "x"}]}"#))!
        var shown = RemoteCopilotModel.apply([], first)
        #expect(shown.map(\.id) == ["1", "2"] && shown[1].role == .agent)
        shown = RemoteCopilotModel.apply(shown, RemoteCopilotModel.chat(json(#"{"messages": [{"id": "2", "role": "agent", "text": "hello"}]}"#))!)
        #expect(shown.map(\.text) == ["hi", "hello"])
        shown = RemoteCopilotModel.apply(shown, RemoteCopilotModel.chat(json(#"{"reset": true, "messages": []}"#))!)
        #expect(shown.isEmpty)
        #expect(RemoteCopilotModel.chat(json("{}")) == nil)
        #expect(RemoteCopilotModel.report(json(#"{"desk": "running", "run": "r1", "profile": ""}"#)) == RemoteCopilotModel.Report(desk: .running, run: "r1", profile: nil))
        #expect(RemoteCopilotModel.report(json(#"{"desk": "asleep"}"#)) == nil)
        #expect(RemoteCopilotModel.outcome(.null) == (false, ""))
    }
}
