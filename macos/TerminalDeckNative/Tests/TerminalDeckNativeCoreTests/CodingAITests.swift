import Foundation
import Testing
@testable import TerminalDeckNativeCore

// Settings → Coding AI, native. Fixtures are the engine's own answers, as
// JSONSerialization hands them over; nothing here signs anything in or out.

private func json(_ text: String) -> CodingAIJSON { CodingAIJSON.parse(text) }

private let snapshotFixture = json(#"""
{
  "profiles": [
    {"id": "system", "name": "Default", "provider": "claude", "configDir": "/Users/me/.claude", "system": true, "color": "--accent", "lastUsedAt": 10},
    {"id": "system:codex", "name": "Default (Codex CLI)", "provider": "codex", "configDir": "/Users/me/.codex", "system": true, "color": "--status-completed"},
    {"id": "system:gemini", "name": "Default (Gemini CLI)", "provider": "gemini", "configDir": "/Users/me/.gemini", "system": true, "color": "--status-waiting"},
    {"id": "p-work", "name": "work@example.com", "provider": "claude", "configDir": "/Users/me/td/p-work", "system": false, "color": "var(--x)"},
    {"id": "p-odd", "name": "Odd", "provider": "nonsense", "configDir": "/x", "system": 1},
    {"id": "", "name": "no id"},
    {"name": "missing id"}
  ],
  "defaultProfileId": null,
  "projectDefaults": {"/Users/me/app": "p-work", "/bad": 3},
  "inherited": [{"provider": "claude", "env": "CLAUDE_CONFIG_DIR", "dir": "/Users/me/.claude-other"}, {"provider": "codex", "env": "CODEX_HOME"}],
  "machine": "Studio",
  "vault": {"p-work": {"keptBy": "app", "signedIn": true}, "system": {"keptBy": "agent", "signedIn": null}, "system:codex": {"keptBy": "bogus"}}
}
"""#)

private func signedIn(_ account: String?, plan: String? = nil) -> CodingAISignIn {
    CodingAISignIn(state: .signedIn, account: account, plan: plan, detail: "ok")
}

private let signedOut = CodingAISignIn(state: .signedOut, detail: "Not logged in")

@Suite("Coding AI — reading the engine")
struct CodingAIReadingTests {
    @Test func booleansAreStrict() {
        let value = json(#"{"a": true, "b": 1, "c": "true", "d": false}"#)
        #expect(value["a"].isTrue)
        #expect(!value["b"].isTrue)
        #expect(value["b"].number == 1)
        #expect(!value["c"].isTrue)
        #expect(value["d"].bool == false)
        #expect(value["missing"] == .null)
        // A Swift Bool from the bridge is still a boolean.
        #expect(CodingAIJSON(true) == .bool(true))
        #expect(CodingAIJSON(1) == .number(1))
    }

    @Test func snapshotIsNarrowedFieldByField() {
        let snapshot = CodingAIAccountsParse.snapshot(snapshotFixture)
        #expect(snapshot.accounts.map(\.id) == ["system", "system:codex", "system:gemini", "p-work", "p-odd"])
        let work = snapshot.accounts[3]
        #expect(work.color == "--accent")               // `var(--x)` is not a token
        #expect(work.keptBy == .app)
        #expect(work.keptSignedIn == true)
        let odd = snapshot.accounts[4]
        #expect(odd.provider == nil)                    // unknown agent claims none
        #expect(odd.system == false)                    // `1` is not `true`
        #expect(snapshot.accounts[0].keptBy == .agent)
        #expect(snapshot.accounts[0].keptSignedIn == nil)
        #expect(snapshot.accounts[1].keptBy == nil)      // bogus value dropped
        #expect(snapshot.defaultId == nil)
        #expect(snapshot.projectDefaults == ["/Users/me/app": "p-work"])
        #expect(snapshot.inherited.count == 1)
        #expect(snapshot.machine == "Studio")
        #expect(CodingAIAccountsParse.snapshot(.null) == .empty)
    }

    @Test func signInNeverBecomesSignedOutByAccident() {
        let odd = CodingAIAccountsParse.signIn(json(#"{"state": "weird", "account": ""}"#))
        #expect(odd.state == .unknown)
        #expect(odd.account == nil)
        #expect(odd.detail == "This account’s sign-in state could not be read.")
        let good = CodingAIAccountsParse.signIn(json(#"{"state": "signed-in", "account": "me@x.com", "plan": "max", "detail": "Logged in", "command": "claude auth status"}"#))
        #expect(good == CodingAISignIn(state: .signedIn, account: "me@x.com", plan: "max", detail: "Logged in", command: "claude auth status"))
    }

    @Test func historyNeverClaimsSharedFromAnUnknownLink() {
        #expect(CodingAIAccountsParse.history(json(#"{"share": "x"}"#)) == nil)
        let odd = CodingAIAccountsParse.history(json(#"{"state": {"link": "teleported", "ownProjects": -3.7}}"#))
        #expect(odd?.link == .unmanaged)
        #expect(odd?.ownProjects == 0)
        let shared = CodingAIAccountsParse.history(json(#"{"state": {"link": "shared", "root": "/r", "ownProjects": 2.9}, "remove": "  ", "share": "s"}"#))
        #expect(shared?.link == .shared)
        #expect(shared?.ownProjects == 2)
        #expect(shared?.remove == nil)
        #expect(shared?.share == "s")
    }
}

@Suite("Coding AI — the per-agent account model")
struct CodingAIAccountModelTests {
    let accounts = CodingAIAccountsParse.snapshot(snapshotFixture).accounts

    @Test func loginLabelLadder() {
        let system = accounts[0]
        #expect(CodingAIAccountLabels.profileLoginLabel(system, nil) == "Your own Claude Code install")
        #expect(CodingAIAccountLabels.profileLoginLabel(system, signedIn("me@x.com")) == "me@x.com")
        // An expired login still reports its email; it must not name the row.
        #expect(CodingAIAccountLabels.profileLoginLabel(system, CodingAISignIn(state: .signedOut, account: "old@x.com")) == "Your own Claude Code install")
        #expect(CodingAIAccountLabels.profileLoginLabel(accounts[3], nil) == "work@example.com")
        #expect(CodingAIAccountLabels.profileLoginLabel(system, nil, namesTheAgent: false) == "Your own install")
    }

    @Test func rowLabelSaysWhenTheAgentWillNotName() {
        let codex = accounts[1]
        #expect(CodingAIAccountLabels.rowLabel(codex, signedIn(nil, plan: "ChatGPT")) == CodingAIAccountLabels.unnamedLogin)
        #expect(CodingAIAccountLabels.stateLine(signedIn(nil, plan: "ChatGPT")) == "Signed in using ChatGPT")
        #expect(CodingAIAccountLabels.stateLine(signedIn("a@b", plan: "max")) == "Signed in")
        #expect(CodingAIAccountLabels.stateLine(nil) == "Checking with the agent…")
        #expect(CodingAIAccountLabels.stateLine(signedOut) == "Not signed in")
        #expect(CodingAIAccountLabels.rowLabel(codex, signedOut) == "Your own Codex CLI install")
    }

    @Test func runsPutTheUnansweredFirstAndGroupInCatalogueOrder() {
        let extra = CodingAIAccount(id: "p-x", name: "x", provider: nil)
        let all = accounts + [extra]
        let runs = CodingAIAccountRuns.runs(all, signIn: [
            "system": signedIn("me@x.com"),
            "system:codex": signedOut,
            "p-work": signedIn("work@example.com"),
            "system:gemini": CodingAISignIn(state: .unsupported),
        ])
        #expect(runs.map(\.kind) == [.notAnswered, .signedIn, .notSignedIn])
        #expect(runs.map(\.title) == [nil, "Signed in", "Not signed in or not installed"])
        #expect(runs[0].groups.map(\.label) == ["Other agents"])           // p-odd and p-x, both unnamed agents
        #expect(runs[0].groups[0].accounts.map(\.id) == ["p-odd", "p-x"])  // stable inside a group
        #expect(runs[1].groups.map(\.label) == ["Claude Code"])
        #expect(runs[1].groups[0].accounts.map(\.id) == ["system", "p-work"])
        #expect(runs[2].groups.map(\.label) == ["Codex CLI", "Gemini CLI"])
    }

    @Test func aSecondCopyOfALoginIsNamedAndTheInstallIsTheOriginal() {
        let copies = CodingAILogins.duplicates([accounts[3], accounts[0]], signIn: [
            "system": signedIn("Me@X.com "),
            "p-work": signedIn("me@x.com"),
        ])
        #expect(copies["p-work"]?.id == "system")
        #expect(copies["system"] == nil)
    }

    @Test func oneLoginOneAccount() {
        let signIn: [String: CodingAISignIn] = ["p-work": signedIn("a@b.com")]
        // Signed in as a@b, though added as work@: only what it is signed in as counts.
        #expect(CodingAILogins.holding(accounts, signIn: signIn, provider: "claude", address: "work@example.com") == nil)
        #expect(CodingAILogins.holding(accounts, signIn: signIn, provider: "claude", address: " A@B.com")?.id == "p-work")
        // Same address, other agent: not the same account.
        #expect(CodingAILogins.holding(accounts, signIn: signIn, provider: "codex", address: "a@b.com") == nil)
        // Not signed in yet: the name it was added under is caught — and offered to finish.
        #expect(CodingAILogins.holding(accounts, signIn: [:], provider: "claude", address: "WORK@example.com")?.id == "p-work")
        var waiting = accounts
        waiting[3].keptSignedIn = nil
        #expect(CodingAILogins.awaiting(waiting, signIn: [:], provider: "claude", address: "work@example.com")?.id == "p-work")
        #expect(CodingAILogins.awaiting(waiting, signIn: signIn, provider: "claude", address: "a@b.com") == nil)
        // Kept signed in by the app: finished, not awaiting.
        #expect(CodingAILogins.awaiting(accounts, signIn: [:], provider: "claude", address: "work@example.com") == nil)
        #expect(CodingAILogins.holding(accounts, signIn: [:], provider: "claude", address: "   ") == nil)
    }

    @Test func renameValidation() {
        #expect(CodingAILogins.normalizeName("  Work  ", current: "Home") == "Work")
        #expect(CodingAILogins.normalizeName("   ", current: "Home") == nil)
        #expect(CodingAILogins.normalizeName(" Home ", current: "Home") == nil)
        #expect(CodingAILogins.normalizeName(String(repeating: "a", count: 80), current: "x")?.count == 60)
    }

    @Test func removePromisesWhatActuallyHappens() {
        #expect(CodingAIAccountText.removeConfirm(accounts[3]).contains("The login this app keeps for it is deleted"))
        #expect(CodingAIAccountText.removeConfirm(accounts[0]).contains("its login stays in your keychain"))
    }

    @Test func noteCarriesFolderHistoryKeptAndInherited() {
        let snapshot = CodingAIAccountsParse.snapshot(snapshotFixture)
        let history = CodingAIHistory(link: .separate, target: nil, root: "/r", ownProjects: 1, share: nil, unshare: nil, remove: nil)
        let note = CodingAIAccountText.accountNote(snapshot.accounts[0], history: history, inherited: snapshot.inherited)
        #expect(note.hasPrefix("Its own folder is /Users/me/.claude. Keeps its own conversations — 1 folder of them"))
        #expect(note.contains("Claude Code's own install here is /Users/me/.claude-other"))
        #expect(CodingAIAccountText.accountNote(snapshot.accounts[3], history: nil).hasSuffix("This app keeps its login, encrypted, so switching to it needs no sign-in."))
    }

    @Test func sessionsLine() {
        #expect(CodingAIAccountText.sessionsLine(nil) == nil)
        #expect(CodingAIAccountText.sessionsLine(["  "]) == "Running in a session")
        #expect(CodingAIAccountText.sessionsLine(["A very long session title that goes on"]) == "Running in A very long session title t…")
        #expect(CodingAIAccountText.sessionsLine(["abcdefghijklmnopqrstuvwxyz and more"]) == "Running in abcdefghijklmnopqrstuvwxyz…")
        #expect(CodingAIAccountText.sessionsLine(["a", "a", "b", "c"]) == "Running in 4 sessions — a, b and others")
    }

    @Test func rowOffersOnlyWhatCanAct() {
        var snapshot = CodingAIAccountsParse.snapshot(snapshotFixture)
        snapshot.accounts.removeLast() // p-odd
        let rows = CodingAIProviders.rows(detected: json(#"{"claude": true, "codex": true, "gemini": true, "shell": true}"#), fromMain: [])
        let signIn: [String: CodingAISignIn] = [
            "system": signedIn("me@x.com"),
            "system:codex": signedOut,
            "system:gemini": signedIn(nil),
            "p-work": .checking,
        ]
        func row(_ index: Int, sessions: Bool = true) -> CodingAIAccountRowModel {
            CodingAIAccountRowModel.make(account: snapshot.accounts[index], snapshot: snapshot, signIn: signIn, history: [:],
                                         providerRows: rows, sessionTitles: nil, canStartSessions: sessions, canSignOut: true)
        }
        let claude = row(0)
        #expect(claude.offersSignOut && !claude.offersSignIn)
        #expect(claude.defaultBadge)                         // the one default, among several
        #expect(claude.ownInstallBadge)
        #expect(!claude.offersRenameRemove && !claude.offersUseByDefault && !claude.hasMenu)
        let codex = row(1)
        #expect(codex.offersSignIn && !codex.offersSignOut)
        #expect(codex.offersUseByDefault && codex.hasMenu)
        #expect(!row(1, sessions: false).offersSignIn)       // nothing can open a session
        let gemini = row(2)
        #expect(!gemini.offersSignOut)                       // no logout command: the reason instead
        #expect(gemini.signOutNote?.hasPrefix("Gemini CLI has no logout command") == true)
        #expect(!gemini.offersUseByDefault)                  // one login per machine: no choice to make
        let work = row(3)
        #expect(work.offersSignIn)                           // still checking: signing in is the next thing to try
        #expect(work.offersRenameRemove)
        #expect(work.keptBadge)
        #expect(work.removeConfirm.hasPrefix("Remove “work@example.com”?"))
    }

    @Test func anAgentThatWillNotStartGetsASentenceNotAButton() {
        let snapshot = CodingAIAccountsParse.snapshot(snapshotFixture)
        let rows = CodingAIProviders.rows(detected: json(#"{"claude": true, "codex": false, "gemini": true}"#), fromMain: [])
        let model = CodingAIAccountRowModel.make(account: snapshot.accounts[1], snapshot: snapshot, signIn: ["system:codex": signedOut],
                                                 history: [:], providerRows: rows, sessionTitles: ["Fix login"],
                                                 canStartSessions: true, canSignOut: true)
        #expect(!model.offersSignIn)
        #expect(model.problem == CodingAIAgentProblem(text: "Codex CLI will not start on this machine, so signing in cannot open a session yet.",
                                                      install: "npm install -g @openai/codex"))
        #expect(model.sessions == "Running in Fix login")
    }
}

@Suite("Coding AI — agents, menu and pickers")
struct CodingAIAgentsTests {
    @Test func providerRowsFailOpenAndKeepGeminiToOneLogin() {
        let unknown = CodingAIProviders.rows(detected: .null, fromMain: [])
        #expect(unknown.map(\.id) == ["claude", "codex", "gemini"])
        #expect(unknown.allSatisfy { $0.available })
        #expect(unknown.map(\.canAdd) == [true, true, false])
        #expect(unknown[2].tag == "One login only")
        #expect(unknown[2].note?.hasPrefix("Gemini keeps one login per machine") == true)

        let said = CodingAIAccountProviderView.parse(json(#"{"providers": [{"id": "codex", "supported": false, "reason": "Not today."}, {"id": "gemini", "supported": 1}]}"#))
        let rows = CodingAIProviders.rows(detected: json(#"{"claude": true, "codex": true, "gemini": false}"#), fromMain: said)
        #expect(rows[1].canAdd == false && rows[1].note == "Not today.")
        #expect(rows[2].available == false && rows[2].tag == "Not installed")
        #expect(CodingAIProviders.chosen(rows, selected: "codex")?.id == "claude")
        #expect(CodingAIProviders.chosen(rows, selected: nil)?.id == "claude")
        #expect(CodingAIProviders.agentCanStart(rows, "gemini") == false)
        #expect(CodingAIProviders.agentCanStart(rows, nil) && CodingAIProviders.canHaveMore(rows, "custom:x"))
        // An empty detector answer is a broken detector, not "nothing installed".
        #expect(CodingAIProviders.installed(json("{}")) == nil)
    }

    @Test func prerequisitesAndWhatIsPresent() {
        let prereq = CodingAIPrerequisites.parse(json(#"""
        {"tools": [
          {"id": "claude", "label": "Claude Code", "state": "ready", "version": "2.1.0"},
          {"id": "codex", "state": "installed-not-authed", "note": "Runs from ~/.codex"},
          {"id": "gemini", "state": "missing"},
          {"id": "git", "state": "ready"},
          {"label": "no id"}
        ], "canRunSessions": true, "needsLogin": false}
        """#))
        #expect(prereq?.tools.count == 4)
        #expect(prereq?.agentsPresent.map(\.id) == ["claude", "codex"])
        #expect(prereq?.tools[1].versionLabel == CodingAITool.noVersion)
        #expect(prereq?.tools[2].versionLabel == nil)
        #expect(CodingAIPrerequisites.parse(json(#"{"canRunSessions": true}"#)) == nil)

        let options = CodingAIDefaultTool.options(prereq)
        #expect(options.map(\.title) == ["Claude Code", "Codex CLI — sign-in needed", "Gemini CLI — not installed", "Plain shell"])
        #expect(options.map(\.disabled) == [false, false, true, false])
        #expect(CodingAIDefaultTool.options(nil).allSatisfy { !$0.disabled && $0.suffix == nil })
    }

    @Test func addAccountsRowsHaveExactlyOneAct() {
        let prereq = CodingAIPrerequisites(tools: [
            CodingAITool(id: "claude", label: "Claude Code", state: .ready),
            CodingAITool(id: "gemini", label: "Gemini CLI", state: .ready),
        ])
        let accounts = CodingAIAccountsParse.snapshot(snapshotFixture).accounts
        let providerRows = CodingAIProviders.rows(detected: json(#"{"claude": true, "codex": false, "gemini": true}"#), fromMain: [])

        // Nothing signed in yet: Claude's install can be signed in; Codex is not here.
        var facts = CodingAIAddAccounts.facts(prerequisites: prereq, providerRows: providerRows, accounts: accounts, signIn: [:])
        // Somebody who already added a Claude account adds accounts.
        #expect(facts.hasAccounts == ["claude"])
        var rows = CodingAIAddAccounts.rows(facts, canAdd: true, canSignIn: true)
        #expect(rows.map(\.action) == [.addAccount, .install, .signIn])
        #expect(rows.map(\.run) == [.notSignedIn, .notSignedIn, .notSignedIn])

        // Signed in: Gemini keeps one login, so its row names it and offers nothing.
        facts = CodingAIAddAccounts.facts(prerequisites: prereq, providerRows: providerRows, accounts: accounts,
                                          signIn: ["system": signedIn("me@x.com"), "system:gemini": signedIn(nil)])
        rows = CodingAIAddAccounts.rows(facts, canAdd: true, canSignIn: true)
        #expect(rows[0].action == .addAccount && rows[0].run == .signedIn && rows[0].logins == ["me@x.com"])
        #expect(rows[2].action == .none && rows[2].run == .signedIn && rows[2].logins.isEmpty)

        // No way to open a session: no Sign in on any row.
        var bare = facts
        bare.hasAccounts = []
        bare.signedIn = []
        #expect(CodingAIAddAccounts.rows(bare, canAdd: false, canSignIn: false).map(\.action) == [.none, .install, .none])
        #expect(CodingAIAddAccountsRow(id: "x", label: "x", url: nil, installed: false, run: .notSignedIn, logins: [], action: .install).actionTitle == "Install")
    }

    @Test func primaryAccountOffersNothingThatChangesNothing() {
        let accounts = CodingAIAccountsParse.snapshot(snapshotFixture).accounts
        let rows = CodingAIProviders.rows(detected: .null, fromMain: [])
        let choices = CodingAIPrimaryAccount.choices(accounts, providerRows: rows)
        #expect(choices.map(\.id) == ["system", "system:codex", "p-work", "p-odd"])
        #expect(CodingAIPrimaryAccount.selected(defaultId: nil) == "system")
        #expect(CodingAIPrimaryAccount.selected(defaultId: "p-work") == "p-work")
    }

    @Test func defaultToolValueAndTheValuesHandedBack() {
        let settings = json(#"{"version": 2, "values": {"general.defaultProvider": "gemini", "advanced.restoreSessions": false, "appearance.density": "compact", "notifications.onNeedsInput": true, "general.notifyOnAttention": false}}"#)
        #expect(CodingAIDefaultTool.current(settings: settings, preferences: .null) == "gemini")
        #expect(CodingAIDefaultTool.current(settings: settings, preferences: json(#"{"defaultProvider": "codex"}"#)) == "codex")
        #expect(CodingAIDefaultTool.current(settings: .null, preferences: json(#"{"defaultProvider": "nope"}"#)) == "claude")

        let values = CodingAISettingsValues.merged(
            settings: settings,
            preferences: json(#"{"defaultProvider": "codex", "theme": "light", "restoreSessions": true, "notifyOnComplete": false}"#))
        #expect(values["agents.defaultProvider"] == .string("codex"))
        #expect(values["general.defaultProvider"] == nil)
        #expect(values["general.restoreSessions"] == .bool(true))
        #expect(values["appearance.theme"] == .string("light"))
        #expect(values["appearance.density"] == .string("compact"))
        // The current name wins over the old one.
        #expect(values["notifications.onNeedsInput"] == .bool(true))
        let message = CodingAISettingsValues.changedMessage(values)
        #expect(message["type"] == .string("changed"))
        #expect(message["values"]["agents.defaultProvider"] == .string("codex"))
    }

    @Test func staleAgentsAndWhatWasPutAway() {
        let stale = CodingAIStaleAgent.parse(json(#"[{"command": "claude", "version": "1.0.3", "stale": true, "advice": "Run `npm i -g x` then retry."}, {"command": "codex", "stale": false}, {"stale": true}]"#))
        #expect(stale.count == 1)
        #expect(stale[0].dismissalId == "agent-cli:claude@1.0.3")
        #expect(stale[0].advicePieces.map(\.code) == [false, true, false])
        #expect(stale[0].advicePieces.map(\.text) == ["Run ", "npm i -g x", " then retry."])

        var put = CodingAIDismissed.parse(#"{"*machine*": ["a", 3, ""], "/p": ["b"], "__proto__": ["c"]}"#)
        #expect(put.map == ["*machine*": ["a"], "/p": ["b"]])
        put = put.dismissing(stale[0].dismissalId)
        #expect(put.isDismissed("agent-cli:claude@1.0.3"))
        #expect(CodingAIDismissed.parse(put.serialized) == put)
        #expect(put.restoringAll().map == ["/p": ["b"]])
        #expect(CodingAIDismissed.parse("not json").map.isEmpty)
        #expect(CodingAIDismissed.hiddenLine(1) == "1 update hidden.")
        #expect(CodingAIStaleAgent.fixResult(json(#"{"ok": true, "message": "Upgraded."}"#))! == (true, "Upgraded."))
        #expect(CodingAIStaleAgent.fixResult(json(#"{"ok": true}"#)) == nil)
    }

    @Test func setupNotice() {
        #expect(CodingAISetupNotice.warning(json(#"{"tools": [], "canRunSessions": true}"#)) == nil)
        #expect(CodingAISetupNotice.warning(json(#"{"tools": [], "canRunSessions": false, "needsLogin": true}"#))?.hasPrefix("An agent CLI is installed but none of them is signed in") == true)
        #expect(CodingAISetupNotice.warning(json(#"{"tools": [], "canRunSessions": false}"#)) == "No agent CLI was found, so a new session can only run a plain shell.")
        #expect(!CodingAISetupNotice.readable(json(#"{"canRunSessions": false}"#)))
    }
}

@Suite("Coding AI — machines, devices and servers")
struct CodingAIMachinesTests {
    @Test func onlyOnlineDevicesGetASeatAndThisMacIsNamed() {
        let view = CodingAIMachinesView.parse(json(#"""
        {"here": "Studio",
         "machines": [{"id": "pc", "name": "Office PC"}, {"id": "lap", "name": "Laptop"}, {"name": "no id"}],
         "links": [{"id": "pc", "state": "online", "sessions": [{"id": "s1", "title": "build"}, {"title": "no id"}]},
                   {"id": "lap", "state": "offline", "sessions": []}]}
        """#))
        #expect(view.devices.map(\.id) == ["pc"])
        #expect(view.devices[0].sessions == [CodingAIRemoteSession(id: "s1", title: "build")])
        #expect(CodingAIScopes.seats(here: view.here, devices: view.devices).map(\.label) == ["Studio", "Servers", "Office PC"])
        #expect(CodingAIScopes.seats(here: "  ", devices: []).first?.label == "This Mac")
        #expect(CodingAIScope.device("lap").after(devices: view.devices) == .thisMachine)
        #expect(CodingAIScope.device("pc").after(devices: view.devices) == .device("pc"))
        #expect(CodingAIScope.servers.after(devices: []) == .servers)
    }

    @Test func machineLoginsKeepCouldNotAskApartFromNone() {
        #expect(CodingAIMachineLogins.parse(.null).answered == false)
        let empty = CodingAIMachineLogins.parse(json("[]"))
        #expect(empty.answered && empty.accounts.isEmpty)
        let read = CodingAIMachineLogins.parse(json(#"""
        [{"id": "system", "name": "Default", "provider": "claude", "system": true, "signIn": {"state": "signed-in", "account": "pc@x.com"}},
         {"id": "system:gemini", "name": "Default (Gemini CLI)", "provider": "gemini", "system": true, "signIn": {"state": "signed-in"}},
         {"id": "old", "name": "Old", "provider": "codex"}]
        """#))
        #expect(read.accounts.map(\.label) == ["pc@x.com", "Your own Gemini CLI install", "Old"])
        #expect(read.accounts[2].signIn == nil)
        #expect(read.accounts[2].stateLine == CodingAIMachineAccount.notReported.detail)
        let claude = CodingAIMachineLogins.offers(read.accounts[0], machineAnswered: true)
        #expect(claude.signIn && claude.signOut && claude.signOutNote == nil)
        let gemini = CodingAIMachineLogins.offers(read.accounts[1], machineAnswered: true)
        #expect(!gemini.signOut && gemini.signOutNote != nil)
        #expect(CodingAIMachineLogins.offers(read.accounts[0], machineAnswered: false) == (false, false, nil))
        #expect(CodingAIMachineLogins.outcome(.null) == (false, "That machine did not answer.", nil))
        let through = CodingAIMachineLogins.parseThroughSession(json(#"{"current": {"id": "old", "name": "Old"}, "accounts": [{"id": "old", "name": "Old"}]}"#))
        #expect(through?.current?.id == "old" && through?.accounts.count == 1)
    }

    @Test func openSessionsByAccount() {
        let titles = CodingAISessions.titlesByAccount(json(#"""
        [{"id": "1", "title": "api", "profileId": "p-work", "exitCode": null},
         {"id": "2", "title": "done", "profileId": "p-work", "exitCode": 0},
         {"id": "3", "title": "web", "profileId": "p-work"},
         {"id": "4", "title": "none"}]
        """#))
        #expect(titles == ["p-work": ["api", "web"]])
    }

    @Test func serversListAndWhereTheyAre() {
        let servers = CodingAIServer.parseList(json(#"""
        [{"id": "a", "name": "Box", "address": "10.0.0.2", "username": "root"},
         {"id": "b", "address": "fe80::1", "port": 2222, "username": ""},
         {"id": "c", "name": "Same", "address": "h", "port": 22, "username": "me"},
         {"id": "d", "name": "no address"}]
        """#))
        #expect(servers.map(\.whereLine) == ["root at 10.0.0.2", "[fe80::1]:2222", "me at h"])
        #expect(servers[1].name == "fe80::1")
        #expect(CodingAIDeadline.overdue("reading your servers", seconds: 8) == "reading your servers did not answer within 8 seconds.")
    }

    @Test func lookingAtAServer() {
        #expect(CodingAIServerLook.parse(json(#"{"ok": false, "sentence": "Host key changed."}"#), serverName: "Box") == .failed("Host key changed."))
        #expect(CodingAIServerLook.parse(json(#"{"ok": true, "view": {"facts": {}}}"#), serverName: "Box") == .notAsked)
        #expect(CodingAIServerLook.parse(json(#"{"ok": true, "view": {"facts": {"agents": {"known": "cannot", "why": "No shell."}}}}"#), serverName: "Box") == .cannot("No shell."))
        let look = CodingAIServerLook.parse(json(#"""
        {"ok": true, "view": {"facts": {"agents": {"known": "yes", "value": [
          {"id": "claude", "path": "/usr/bin/claude", "version": "2.0", "signedIn": "yes", "account": "srv@x.com"},
          {"id": "codex", "path": "/usr/bin/codex", "version": "", "signedIn": "maybe"},
          {"id": "gemini", "version": "1"}
        ]}}}}
        """#), serverName: "Box")
        guard case .agents(let found) = look else {
            Issue.record("expected agents")
            return
        }
        #expect(found.map(\.id) == ["claude", "codex"])  // gemini had no path
        let runs = CodingAIServerAgents.runs(found)
        #expect(runs.map(\.kind) == [.signedIn, .notSignedIn, .notAnswered])
        #expect(runs[0].agents[0].line == "Signed in as srv@x.com")
        #expect(runs[1].agents.map(\.line) == ["Not installed"])
        #expect(runs[2].agents.map(\.line) == ["Installed, and would not start"])
    }

    @Test func settingAnAgentUpOnAServer() {
        let rows = CodingAISetupRow.parseOffer(json(#"""
        {"ok": true, "rows": [
          {"agentId": "claude", "label": "Claude Code", "installed": {"id": "claude", "path": "/c", "version": "2.0", "signedIn": "yes"},
           "canInstall": true, "consequence": "Installs.", "signOutConsequence": "Signs out.", "whyNoSignOut": null,
           "state": {"serverId": "s", "agentId": "claude", "step": "idle", "weInstalled": true}},
          {"agentId": "gemini", "label": "Gemini CLI", "installed": {"id": "gemini", "path": "/g", "version": "0.3", "signedIn": "yes"},
           "canInstall": true, "whyNoSignOut": "No logout command.",
           "state": {"serverId": "s", "agentId": "gemini", "step": "idle"}},
          {"agentId": "codex", "label": "Codex CLI", "installed": null, "canInstall": false, "why": "No npm here.",
           "state": {"serverId": "s", "agentId": "codex", "step": "installing", "line": "Installing…", "byHand": false}},
          {"agentId": "shell", "state": {"serverId": "s", "agentId": "shell"}}
        ]}
        """#))
        #expect(rows?.map(\.agentId) == ["claude", "gemini", "codex"])
        guard let rows else { return }
        #expect(rows[0].line(rows[0].state) == "Claude Code 2.0, signed in.")
        #expect(rows[2].line(rows[2].state) == "Installing…")
        #expect(rows[2].line(CodingAISetupState(serverId: "s", agentId: "codex", step: .idle, line: "x", detail: "", byHand: false, code: "", weInstalled: false)) == "Codex CLI isn’t set up on this server yet.")

        let claude = rows[0].offers(rows[0].state, idle: true, canSignOut: true)
        #expect(claude.signOut && claude.remove && !claude.signIn && !claude.setUp)
        let gemini = rows[1].offers(rows[1].state, idle: true, canSignOut: true)
        #expect(!gemini.signOut && gemini.whyNoSignOut == "No logout command.")
        let codex = rows[2].offers(rows[2].state, idle: true, canSignOut: true)
        #expect(!codex.setUp && codex.why == "No npm here.")
        // While something runs, nothing else offers a button.
        #expect(rows[0].offers(rows[0].state, idle: false, canSignOut: true) == CodingAISetupRow.Offers())
        #expect(CodingAISetupRow.parseOffer(json(#"{"ok": false, "rows": []}"#)) == nil)
        #expect(CodingAISetupReply.sentence(json(#"{"ok": false}"#)) == "That did not work.")
        #expect(CodingAISetupReply.shellId(json(#"{"ok": true, "shellId": "sh1"}"#)) == "sh1")
        #expect(CodingAISetupReply.shellId(json(#"{"ok": false, "shellId": "sh1"}"#)) == nil)
    }
}

@Suite("Coding AI — what is said to the pages")
struct CodingAIPageScriptTests {
    @Test func startSessionCarriesTheAccountsOwnAgent() {
        let message = CodingAIPageScripts.startSessionMessage(profileId: "p-1", provider: "codex")
        #expect(message.jsonText == #"{"profileId":"p-1","provider":"codex","type":"start-session"}"#)
        #expect(CodingAIPageScripts.startSessionMessage(profileId: "p-1", provider: nil)["provider"] == .null)
    }

    @Test func relayScriptEncodesTheMessageAsAString() {
        let script = CodingAIPageScripts.relay(.object(["type": .string("start-session"), "profileId": .string("a\"b</script>\u{2028}")]))
        #expect(script.contains(#"new BroadcastChannel("terminaldeck:native-settings")"#))
        #expect(script.contains("JSON.parse(\""))
        #expect(!script.contains("</script>"))
        #expect(!script.contains("\u{2028}"))
    }

    @Test func addAccountRequestFromTheAccountChip() {
        #expect(CodingAISettingsRequest.parse(json(#"{"type": "open-settings", "url": "/?settings=1&section=agents", "section": "agents", "action": "add-account"}"#)) == CodingAISettingsRequest(provider: nil))
        #expect(CodingAISettingsRequest.parse(json(#"{"type": "open-settings", "action": "add-account", "provider": "codex"}"#))?.provider == "codex")
        #expect(CodingAISettingsRequest.parse(json(#"{"type": "open-settings", "action": "add-account", "provider": "nope"}"#))?.provider == nil)
        #expect(CodingAISettingsRequest.parse(json(#"{"type": "open-settings", "section": "agents"}"#)) == nil)
        #expect(CodingAISettingsRequest.parse(json(#"{"type": "open-window", "action": "add-account"}"#)) == nil)
    }

    @Test func storageScripts() {
        #expect(CodingAIPageScripts.readStorage("readiness.dismissed.v1").contains(#"getItem("readiness.dismissed.v1")"#))
        #expect(CodingAIPageScripts.announceAccountsChanged.contains(#"new CustomEvent("deck:accounts-changed")"#))
    }
}
