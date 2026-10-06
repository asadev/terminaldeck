import Foundation
import Testing
@testable import TerminalDeckNativeCore

/// The native Session updates page and its one-time ask, mirroring
/// `HooksPanel.test.tsx` and `HooksOffer.test.tsx`.
@Suite("Hooks rules")
struct HooksRulesTests {
    func status(_ state: HookInstallState, foreign: Int = 0, owners: [String] = []) -> HookProviderStatus {
        HookProviderStatus(id: "claude", label: "Claude Code", file: "~/.claude/settings.json", state: state,
                           foreignHooks: foreign, foreignOwners: owners)
    }

    @Test func offersARepairWhenTheAddressIsStaleAndNoWriteToAnUnreadableFile() {
        #expect(HooksRules.primaryAction(.stale) == ("Fix it", true))
        #expect(HooksRules.primaryAction(.partial) == ("Fix it", true))
        #expect(HooksRules.primaryAction(.complete) == ("Set up again", true))
        #expect(HooksRules.primaryAction(.none) == ("Turn on", true))
        #expect(HooksRules.primaryAction(.error) == ("Turn on", false))
    }

    @Test func onlyOffersRemovalWhenSomethingOfOursIsThere() {
        #expect(HooksRules.canRemove(status(.complete)) && HooksRules.canRemove(status(.stale)) && HooksRules.canRemove(status(.partial)))
        #expect(!HooksRules.canRemove(status(.none)) && !HooksRules.canRemove(status(.error)))
    }

    @Test func namesTheOtherToolAndPromisesNotToTouchIt() {
        #expect(HooksRules.foreignNote(status(.complete, foreign: 2, owners: ["vibeyard", "", "staysfixed"]))
                == "2 hooks here belong to Vibeyard and Staysfixed. They are never modified or removed.")
        #expect(HooksRules.foreignNote(status(.complete, foreign: 1)) == "1 hook here belongs to another tool. It is never modified or removed.")
        #expect(HooksRules.foreignNote(status(.complete)) == nil)
        #expect(HooksRules.foreignNote(status(.complete, foreign: 3, owners: [""])) == "3 hooks here belong to another tool. They are never modified or removed.")
    }

    @Test func theEndpointLineSaysWhatAStoppedEndpointCosts() {
        #expect(HooksRules.endpointLine(HookServerInfo(address: "http://127.0.0.1:4000", running: true)) == "Listening on http://127.0.0.1:4000.")
        #expect(HooksRules.endpointLine(HookServerInfo(running: false)) == "The local endpoint is not running, so hooks have nowhere to report to.")
        #expect(HooksRules.endpointLine(HookServerInfo(json: ["running": false, "error": "port in use"]))
                == "The local endpoint is not running, so hooks have nowhere to report to: port in use")
        #expect(!HooksRules.endpointLine(nil).contains("undefined"))
    }

    @Test func keepsTheRemovalPromiseAndTheBackupForTheConfirm() {
        #expect(HooksRules.removalPromise(file: "a.json", backupPath: nil) == "Only our own entries are removed from a.json. Everything else stays.")
        #expect(HooksRules.removalPromise(file: "a.json", backupPath: "/b.json").hasSuffix(" The original is still at /b.json."))
        #expect(HooksRules.stateLabel(.stale) == "Out of date" && HooksRules.consequence(.none) == "Its tabs cannot tell whether it is working or waiting for you.")
        #expect(HooksRules.subtitle() == "One switch per assistant. Which assistants you have, and who each is signed in as, is in Settings → Coding AI.")
    }

    @Test func readsTheEnginesStatuses() {
        let rows = HookProviderStatus.list([
            ["id": "claude", "label": "Claude Code", "file": "f", "fileExists": true, "state": "stale", "installedEvents": ["Stop"],
             "staleEvents": [], "missingEvents": [], "foreignHooks": 3, "foreignOwners": [], "backupPath": NSNull(), "message": ""],
            ["label": "no id"],
        ] as [Any])
        #expect(rows.count == 1 && rows[0].state == .stale && rows[0].foreignHooks == 3 && rows[0].backupPath == nil)
    }
}

@Suite("Hooks offer")
struct HooksOfferTests {
    @Test func readsAVerdictWithProvidersAndFollowUps() {
        let offer = HooksOfferState(json: ["show": true, "eligible": [["id": "claude", "label": "Claude Code", "file": "a"], ["id": "", "label": "x", "file": "y"]] as [Any],
                                           "followUps": ["Restart Codex."]])
        #expect(offer.providers.map(\.id) == ["claude"] && offer.followUps == ["Restart Codex."])
        #expect(HooksOfferState(json: ["show": false, "eligible": [["id": "a", "label": "b", "file": "c"]] as [Any]]).providers.isEmpty)
        #expect(HooksOfferState(json: "nonsense").providers.isEmpty)
        #expect(HooksOfferState(json: ["show": true, "eligible": [] as [Any]]).followUps.isEmpty)
    }

    @Test func speaksSingularToOneAssistantAndNamesThisApp() {
        #expect(HooksOffer.headline(1) == "Let tabs say what your assistant is doing")
        #expect(HooksOffer.headline(2) == "Let tabs say what your assistants are doing")
        #expect(HooksOffer.detail(1) == "One press adds Terminal Deck's session hooks to your assistant's own settings file, so a tab can show working, waiting for you, or done — nothing else in the file is touched.")
        #expect(HooksOffer.writesTitle([HooksOfferProvider(id: "a", label: "A", file: "x.json"), HooksOfferProvider(id: "b", label: "B", file: "y.toml")]) == "Writes x.json and y.toml")
    }

    @Test func keepsEachRefusalAndCallsUnreadableAFailure() {
        #expect(HooksOffer.failures([["ok": true]] as [Any]).isEmpty)
        #expect(HooksOffer.failures([["ok": false, "message": " Not allowed. "], ["ok": false]] as [Any])
                == ["Not allowed.", "One install did not go through — the Session updates page in the sidebar has the state."])
        #expect(HooksOffer.failures(nil).count == 1)
    }
}
