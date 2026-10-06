import Foundation
import Testing
@testable import TerminalDeckNativeCore

// Lane T — a session's bar: its title and folder, its controls' words and presence,
// and its account chips (mirrors SessionTitle, FolderChip, SessionControls, AccountChip,
// MachineAccountChip and ServerAccountChip tests).

@Suite("Session bar")
struct SessionChromeTests {
    @Test func typedNamesAreCleanedAndShortened() {
        #expect(SessionTitleRules.typed("   ") == nil)
        #expect(SessionTitleRules.typed("  fix   the\tbuild ") == "fix the build")
        #expect(SessionTitleRules.typed("\u{1b}[1mBold\u{1b}[0m name") == "Bold name")
        #expect(SessionTitleRules.typed("3f2504e0-4f89-41d3-9a0c-0305e82c3301: the task") == "the task")
        let long = String(repeating: "word ", count: 20)
        let cut = SessionTitleRules.typed(long)!
        #expect(cut.count <= 40 && cut.hasSuffix("…"))
        #expect(SessionTitleRules.truncate("abcdefghij", max: 5) == "abcd…")
        #expect(SessionTitleRules.truncate("short", max: 40) == "short")
    }

    @Test func foldersAreNamedByTheirLastPart() {
        #expect(SessionFolder.label("/Users/a/web/") == "web")
        #expect(SessionFolder.label("C:\\code\\api") == "api")
        #expect(SessionFolder.shown("/x/copilot", assistant: true) == "Hoot’s folder")
        #expect(SessionFolder.shown("/x/copilot") == "copilot")
        #expect(SessionFolder.help("/x").hasPrefix("/x\nA session keeps this folder"))
    }

    @Test func controlWordsAreThePagesWords() {
        #expect(TerminalControlCatalog.contentsSentence(withConnectors: false) == "Model, effort and fast mode")
        #expect(TerminalControlCatalog.contentsSentence(withConnectors: true) == "Model, effort, fast mode and connectors")
        #expect(TerminalControlCatalog.summaryLabel(model: "Opus 5", effort: "High", withConnectors: false)
                == "Model, effort and fast mode — model Opus 5, effort High")
        #expect(TerminalControlCatalog.value(nil, control: "permission") == "Not reported")
        #expect(TerminalControlCatalog.value(nil, control: "model") == "Unknown")
        #expect(TerminalControlCatalog.foreignAgentNote("codex")?.contains("Codex has its own") == true)
        #expect(TerminalControlCatalog.foreignAgentNote("claude") == nil)
        #expect(TerminalControlCatalog.options("model").last?.id == "claude-sonnet-4-6")
        #expect(TerminalControlCatalog.options("model").first { $0.group != nil }?.id == "claude-opus-4-8")
        #expect(TerminalControlCatalog.chipHelp("effort", reading: TerminalControlReading(value: "high", label: "High", source: "settings"),
                                                busy: false, blocked: nil) == "Effort: High — from Claude settings")
    }

    @Test func presenceSettlesLikeThePage() {
        #expect(SessionPresence.fromSession(provider: "claude", exited: false) == true)
        #expect(SessionPresence.fromSession(provider: "shell", exited: false) == nil)
        #expect(SessionPresence.fromSession(provider: "claude", exited: true) == false)
        #expect(SessionPresence.settle(previous: true, reading: false, seenAgent: true) == nil)
        #expect(SessionPresence.settle(previous: nil, reading: false, seenAgent: true) == false)
        #expect(SessionPresence.settle(previous: nil, reading: false, seenAgent: false) == false)
        #expect(SessionPresence.runningProvider("shell", agentRunning: true) == nil)
        #expect(SessionPresence.runningProvider("shell", agentRunning: false) == "shell")
    }

    @Test func theRememberedEffortIsTypedOnce() {
        #expect(SessionEffortMemory.preferred(stored: nil) == "xhigh")
        #expect(SessionEffortMemory.preferred(stored: "auto") == nil)
        #expect(SessionEffortMemory.preferred(stored: "nonsense") == "xhigh")
        #expect(SessionEffortMemory.preferred(stored: "low") == "low")
        let unread = TerminalControls(model: .unread, effort: .unread, live: true, agentRunning: true, canType: true, gateReason: nil)
        #expect(SessionEffortMemory.shouldApply(want: "xhigh", local: true, provider: "claude", readings: unread, busy: false, alreadyDefaulted: false))
        #expect(!SessionEffortMemory.shouldApply(want: "xhigh", local: true, provider: "claude", readings: unread, busy: false, alreadyDefaulted: true))
        #expect(!SessionEffortMemory.shouldApply(want: "xhigh", local: true, provider: "codex", readings: unread, busy: false, alreadyDefaulted: false))
        let read = unread.with("effort", TerminalControlReading(value: "high", label: "High"))
        #expect(!SessionEffortMemory.shouldApply(want: "xhigh", local: true, provider: "claude", readings: read, busy: false, alreadyDefaulted: false))
    }

    @Test func mcpRowsSayWhyOrWhat() {
        let rows = McpRow.list([["id": "a", "name": "github", "scope": "user", "transport": "stdio"],
                                ["id": "b", "name": "db", "enabled": false, "disabledReason": "Needs a token."], ["name": "x"]])
        #expect(rows?.count == 2)
        #expect(rows?[0].detail == "user · stdio")
        #expect(rows?[1].detail == "Needs a token." && rows?[1].enabled == false)
        #expect(McpRow.list("no") == nil)
    }
}

@Suite("Account chips")
struct AccountChipTests {
    private func account(_ id: String, _ name: String, provider: String = "claude", system: Bool = false, used: Double? = nil) -> CodingAIAccount {
        CodingAIAccount(id: id, name: name, provider: provider, system: system, lastUsedAt: used)
    }

    @Test func oneRowPerLogin() {
        let signedIn = CodingAISignIn(state: .signedIn, account: "a@x.com")
        let rows = AccountChipRules.oneRowPerLogin(
            [account("1", "Work", used: 1), account("2", "Other", used: 5), account("3", "Gen", system: true), account("4", "Home")],
            signIn: ["1": signedIn, "2": signedIn], prefer: nil)
        // One row for the shared login (the latest used), then the named one; the unnamed install last.
        #expect(rows.map(\.id) == ["2", "4", "3"])
        let preferred = AccountChipRules.oneRowPerLogin([account("1", "W"), account("2", "O")], signIn: ["1": signedIn, "2": signedIn], prefer: "1")
        #expect(preferred.map(\.id) == ["1"])
    }

    @Test func theFoldersAccount() {
        let snapshot = CodingAIAccountsSnapshot(accounts: [account("a", "A"), account("s", "S", system: true), account("p", "P")],
                                                defaultId: nil, projectDefaults: ["/web": "p"])
        #expect(AccountChipRules.accountForFolder(snapshot, projectPath: "/web")?.id == "p")
        #expect(AccountChipRules.accountForFolder(snapshot, projectPath: "/other")?.id == "s")
        #expect(AccountChipRules.accountForFolder(.empty, projectPath: nil) == nil)
    }

    @Test func identityLadder() {
        #expect(AccountChipRules.identity(nil, nil).label == "Account")
        let verified = AccountChipRules.identity(("1", "Work", false), CodingAISignIn(state: .signedIn, account: "a@x.com"))
        #expect(verified.label == "a@x.com" && verified.verified)
        #expect(AccountChipRules.identity(("1", "Work", false), nil).label == "Work")
        #expect(AccountChipRules.identity(("system", "Default", true), CodingAISignIn(state: .signedOut)).label == "Not signed in")
        #expect(AccountChipRules.stateSummary(CodingAISignIn(state: .signedIn, plan: "Max")).label == "Signed in · Max")
        #expect(AccountChipRules.stateSummary(.checking).label == "Checking…")
    }

    @Test func whatTheChipIs() {
        #expect(AccountChipRules.mode(hasSession: true, agentRunning: true) == .account)
        #expect(AccountChipRules.mode(hasSession: true, agentRunning: false) == .run)
        #expect(AccountChipRules.mode(hasSession: true, agentRunning: nil) == .none)
        #expect(AccountChipRules.runCommand("claude")?.command == "claude\r")
        #expect(AccountChipRules.runCommand("shell") == nil)
        #expect(AccountChipRules.fixedNote(hasSession: true, showAccount: true, switching: false, sessionAgent: nil, sessionProvider: "shell") == AccountChipRules.fixedShell)
        #expect(AccountChipRules.fixedNote(hasSession: true, showAccount: true, switching: true, sessionAgent: "claude", sessionProvider: "claude") == nil)
    }

    @Test func sessionAccountsAndArmedSwitches() {
        #expect(SessionAccountView.decode(["kind": "known", "provider": "claude", "configDir": "/c", "email": " "])
                == .known(provider: "claude", configDir: "/c", profileId: nil, profileName: nil, email: nil))
        #expect(SessionAccountView.decode(["kind": "withheld", "reason": "Not yours."]) == .withheld("Not yours."))
        #expect(SessionAccountView.decode(nil) == .withheld("This session’s account could not be read, so none is named."))
        let armed = ArmedSwitch.list([["sessionId": "s", "profileId": "p", "accountName": "Work", "note": "n"]])
        #expect(armed.first?.help == "Switching to Work when you send your next message.")
    }

    @Test func machineAccounts() {
        let state = MachineAccount.state(["current": ["id": "a", "name": "Main", "provider": "claude"],
                                          "accounts": [["id": "a", "name": "Main"], ["id": "", "name": "x"]]])
        #expect(state?.current?.name == "Main" && state?.accounts.count == 1)
        #expect(state?.current?.signInOrNotReported == MachineAccount.notReported)
        #expect(MachineAccount.switchAnswer(nil).message == "That machine did not answer.")
        #expect(MachineAccount.switchAnswer(["ok": true, "session": "s2"]).session == "s2")
    }

    @Test func serverLogins() {
        let none = ServerSignIn.decode(["known": "yes", "agents": 0, "logins": []])!
        #expect(none.words("box").line == "No coding agent here")
        #expect(none.menuState("box") == "No coding agent is installed on box.")
        let some = ServerSignIn.decode(["known": "yes", "agents": 1, "logins": [["agentId": "claude", "account": "a@x.com"]]])!
        #expect(some.words("box").line == "Claude Code signs in as a@x.com")
        #expect(some.menuState("box") == nil)
        #expect(ServerSignIn.decode(["known": "cannot"]) == .cannot("This server did not say."))
        #expect(ServerSignIn.decode(["known": "cannot", "why": "Asleep."])!.words("").line == "Coding logins unknown")
    }
}

@Suite struct SessionSameAsPageTests {
    @Test func featureSwitchesReadThePageStore() {
        #expect(SessionFeatures.decode(nil) == .defaults)
        #expect(SessionFeatures.decode("not json") == .defaults)
        #expect(SessionFeatures.decode(#"{"usage":"off"}"#) == SessionFeatures(usageOn: false, mcpOn: true))
        #expect(SessionFeatures.decode(#"{"mcp":"uninstalled","usage":"on"}"#) == SessionFeatures(usageOn: true, mcpOn: false))
        // An unreadable value is the default, as `mergeFeatureState` keeps it.
        #expect(SessionFeatures.decode(#"{"mcp":"maybe"}"#) == .defaults)
    }

    @Test func switchNoteComesFromTheTabsState() throws {
        let json = #"{"tabs":[],"canNewTerminal":true,"canNewBrowser":false,"accountSwitch":{"sessionId":"s1","state":"done","text":"Switched to Work"}}"#
        let state = try JSONDecoder().decode(TabsState.self, from: Data(json.utf8))
        let note = try #require(AccountSwitchNote.shown(state.accountSwitch, for: "s1"))
        #expect(note.text == "Switched to Work")
        #expect(note.lightsTheName)
        #expect(AccountSwitchNote.shown(state.accountSwitch, for: "s2") == nil)
        let working = AccountSwitchNote(sessionId: "s1", state: .working, text: "Switching to Work…")
        #expect(!working.lightsTheName)
        let none = try JSONDecoder().decode(TabsState.self, from: Data(#"{"tabs":[],"accountSwitch":null}"#.utf8))
        #expect(none.accountSwitch == nil)
        let odd = try JSONDecoder().decode(TabsState.self, from: Data(#"{"tabs":[],"accountSwitch":{"state":"done"}}"#.utf8))
        #expect(odd.accountSwitch == nil)
    }
}
