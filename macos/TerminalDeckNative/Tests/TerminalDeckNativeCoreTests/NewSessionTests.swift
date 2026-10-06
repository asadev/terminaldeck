import Foundation
import Testing
@testable import TerminalDeckNativeCore

// Mirrors NewSessionDialog.test.ts and session-start.test.ts.

private func json(_ text: String) -> CodingAIJSON { CodingAIJSON.parse(text) }

private let providers = [
    NewSessionStartProvider(id: "claude", label: "Claude Code", available: true, canResume: true, supportsProfiles: true),
    NewSessionStartProvider(id: "codex", label: "Codex CLI", available: true, canResume: true, supportsProfiles: true),
    NewSessionStartProvider(id: "gemini", label: "Gemini CLI", available: false, canResume: false, supportsProfiles: false),
    NewSessionStartProvider(id: "shell", label: "Shell", available: true, canResume: false, supportsProfiles: false),
]
private let profiles = [NewSessionStartProfile(id: "sys", name: "System", system: true), NewSessionStartProfile(id: "work", name: "Work")]

private func resolve(path: String? = "/w/app", provider: String? = nil, profile: String? = nil, resume: Bool? = false,
                     memory: NewSessionMemory = NewSessionMemory(), defaultProvider: String? = nil,
                     defaultProfile: String? = nil, providerList: [NewSessionStartProvider] = providers,
                     profileList: [NewSessionStartProfile] = profiles) -> NewSessionResolution {
    NewSessionStart.resolve(providers: providerList, profiles: profileList, memory: memory, defaultProvider: defaultProvider,
                            defaultProfileId: defaultProfile, projectPath: path, provider: provider, profileId: profile, resume: resume)
}

@Suite("New session: recent projects")
struct NewSessionProjectTests {
    @Test func parsesSortsAndDeDuplicates() {
        let list = NewSessionProjects.parse(json(#"[{"path":"/a/one","lastOpenedAt":1},{"path":"/b/two","lastOpenedAt":5},{"path":"/c/three"},{"path":""},{"x":1},{"path":"/a/one","lastOpenedAt":9}]"#))
        #expect(list.map(\.path) == ["/b/two", "/a/one", "/c/three"], "newest first; missing timestamp is oldest; one row per folder")
        #expect(list[0].name == "two")
        #expect(NewSessionProjects.parse(json(#"{"not":"a list"}"#)).isEmpty)
    }

    @Test func aBrowsedFolderGoesToTheTop() {
        let list = [NewSessionProject(path: "/a"), NewSessionProject(path: "/b")]
        #expect(NewSessionProjects.with(list, "/c").map(\.path) == ["/c", "/a", "/b"])
        #expect(NewSessionProjects.with(list, "/b").map(\.path) == ["/b", "/a"], "moved up, not duplicated")
    }

    @Test func filterAndShortlist() {
        let list = (1...10).map { NewSessionProject(path: "/work/proj\($0)") } + [NewSessionProject(path: "/elsewhere/Notes")]
        #expect(NewSessionProjects.match(list, " NOTES ").map(\.name) == ["Notes"])
        #expect(NewSessionProjects.match(list, "work").count == 10, "by where they live")
        #expect(NewSessionProjects.match(list, "").count == 11)
        #expect(NewSessionProjects.match(list, "zzz").isEmpty)
        let few = NewSessionProjects.shortlist(Array(list.prefix(8)), filter: "")
        #expect(!few.filtering && few.shown.count == 8 && few.hidden == 0, "no filter while the whole list is on screen")
        let many = NewSessionProjects.shortlist(list, filter: "")
        #expect(many.filtering && many.shown.count == 8 && many.hidden == 3)
        #expect(NewSessionProjects.shortlist(list, filter: "notes").shown.map(\.name) == ["Notes"], "searches the whole list")
        #expect(NewSessionProjects.shortlist(list, filter: "zzz").hidden == 0)
    }

    @Test func liveSessionsMatchTheSameFolderSpeltDifferently() {
        let context = NewSessionContext(liveSessions: ["/w/app/": 2])
        #expect(context.sessions(in: "/w/app") == 2)
        #expect(context.sessions(in: "/w/other") == 0)
    }

    @Test func theContextFromThePage() {
        let body: [String: Any] = ["type": "new-session", "seq": 4, "projectPath": "/p", "machineId": NSNull(),
                                   "machines": [["id": "m1", "name": "Office PC", "folders": ["/srv"]]],
                                   "hereName": "", "servers": [["id": "s1", "name": "Box"]],
                                   "liveSessions": ["/p": 3], "memory": "{}"]
        let context = NewSessionContext.parse(body)
        #expect(context?.seq == 4 && context?.projectPath == "/p" && context?.machineId == nil)
        #expect(context?.machines.first?.folders == ["/srv"] && context?.servers.first?.name == "Box")
        #expect(context?.hereName == "This Mac")
        #expect(NewSessionContext.parse(["type": "tabs"]) == nil)
    }
}

@Suite("New session: agents")
struct NewSessionAgentTests {
    @Test func rowsCarryAvailabilityResumeAndLabels() {
        let rows = NewSessionProviders.rows(detected: json(#"{"claude":true,"codex":false,"gemini":true}"#), added: [])
        #expect(rows.map(\.id) == ["claude", "codex", "gemini", "shell"])
        #expect(rows[1].available == false && rows[1].reason == "Terminal Deck could not start `codex` on this machine.")
        #expect(rows[1].hint == rows[1].reason)
        #expect(rows[3].available, "the shell is always there")
        #expect(rows[0].canResume && !rows[2].canResume)
        #expect(rows.allSatisfy { !$0.label.isEmpty })
        let unread = NewSessionProviders.rows(detected: json("{}"), added: [])
        #expect(unread.allSatisfy { $0.available }, "a detector that said nothing fails open")
    }

    @Test func isolatableAgentsMatchTheProfilesRule() {
        let start = NewSessionStartProvider.from(NewSessionProviders.rows(detected: .null, added: []))
        #expect(start.map(\.supportsProfiles) == [true, true, false, false])
        #expect(NewSessionProviders.isolationNotice("custom:x") == NewSessionProviders.customLoginsNote)
        #expect(NewSessionProviders.isolationNotice("claude") == nil)
        #expect(NewSessionProviders.isolationNotice(nil) == nil)
    }

    @Test func addedAgentsJoinTheList() {
        let added = NewSessionCustomAgent.parse(json(#"[{"id":"custom:aider","label":" Aider ","command":"aider","resumeArgs":["--restore"]},{"id":"aider","label":"x","command":"y"},{"id":"custom:z","label":"","command":"z"}]"#))
        #expect(added.map(\.id) == ["custom:aider"])
        let rows = NewSessionProviders.rows(detected: json(#"{"claude":true,"custom:aider":true}"#), added: added)
        #expect(rows.last?.label == "Aider" && rows.last?.available == true && rows.last?.canResume == true)
        #expect(rows.last?.description == "Runs `aider` in the project folder.")
        #expect(rows.last?.isCustom == true)
    }

    @Test func addOutcomes() {
        #expect(NewSessionAddAgent.outcome(json(#"{"ok":true,"agent":{"id":"custom:aider"}}"#)) == .added("custom:aider"))
        #expect(NewSessionAddAgent.outcome(json(#"{"ok":false,"problems":{"command":"Not found","bogus":"x"}}"#)) == .problems(["command": "Not found"]))
        #expect(NewSessionAddAgent.outcome(json(#"{"ok":false,"problems":{}}"#)) == .problems(NewSessionAddAgent.refused))
        #expect(NewSessionAddAgent.outcome(json(#"{"ok":true,"agent":{"id":"claude"}}"#)) == .problems(NewSessionAddAgent.refused))
        #expect(NewSessionAddAgent.outcome(.null) == .problems(NewSessionAddAgent.refused))
    }

    @Test func argumentsSplitAndDescribe() {
        #expect(NewSessionAddAgent.splitArgs(#"--model "big one" 'x y' -v"#) == ["--model", "big one", "x y", "-v"])
        #expect(NewSessionAddAgent.splitArgs(#"a "" b"#) == ["a", "", "b"])
        #expect(NewSessionAddAgent.splitArgs("   ").isEmpty)
        #expect(NewSessionAddAgent.describeArgs(["--model", "big one", ""]) == #"--model "big one" """#)
        #expect(NewSessionAddAgent.argsHint("") == "Optional. A quoted argument stays in one piece.")
        #expect(NewSessionAddAgent.argsHint("-v") == "Sends: -v")
        #expect(NewSessionAddAgent.resumeHint("--continue") == "Continues with: --continue")
    }
}

@Suite("New session: remembered choices")
struct NewSessionMemoryTests {
    @Test func roundTripsInOrder() {
        var memory = NewSessionMemory()
        memory = memory.remembering(NewSessionRequest(cwd: "/a", provider: "claude", resume: false, profileId: "work", cols: 100, rows: 30, firstPrompt: "", title: nil))
        memory = memory.remembering(NewSessionRequest(cwd: "/b", provider: "codex", resume: true, profileId: nil, cols: 100, rows: 30, firstPrompt: "", title: nil))
        let back = NewSessionMemory.parse(memory.json)
        #expect(back == memory)
        #expect(back.entries.map(\.path) == ["/a", "/b"])
        #expect(back.defaults(for: "/a").profileId == "work")
        #expect(back.defaults(for: "/b/").provider == "codex", "the same folder however it was written")
    }

    @Test func readsNothingFromNothing() {
        #expect(NewSessionMemory.parse(nil).entries.isEmpty)
        #expect(NewSessionMemory.parse("not json").entries.isEmpty)
        #expect(NewSessionMemory.parse(#"{"/a":{"provider":"vim","profileId":"p"}}"#).defaults(for: "/a") == NewSessionDefaults(profileId: "p"),
                "a provider this build does not know is dropped")
    }

    @Test func keepsAtMostAHundredFoldersNewestLast() {
        var memory = NewSessionMemory()
        for i in 0..<105 {
            memory = memory.remembering(NewSessionRequest(cwd: "/p\(i)", provider: "claude", resume: false, profileId: nil, cols: 1, rows: 1, firstPrompt: "", title: nil))
        }
        #expect(memory.entries.count == 100)
        #expect(memory.entries.first?.path == "/p5" && memory.entries.last?.path == "/p104")
        let again = memory.remembering(NewSessionRequest(cwd: "/p50", provider: "codex", resume: false, profileId: nil, cols: 1, rows: 1, firstPrompt: "", title: nil))
        #expect(again.entries.last?.path == "/p50" && again.entries.count == 100)
    }
}

@Suite("New session: resolveStart")
struct NewSessionResolveTests {
    @Test func needsAFolder() {
        #expect(resolve(path: nil).problem == "Choose a project folder to run the session in.")
        #expect(resolve(path: "   ").problem == "Choose a project folder to run the session in.")
        #expect(resolve(path: " /w/app ").request?.cwd == "/w/app")
    }

    @Test func providerPrecedence() {
        let memory = NewSessionMemory(entries: [("/w/app", NewSessionDefaults(provider: "codex"))])
        #expect(resolve(provider: "shell", memory: memory).request?.provider == "shell")
        #expect(resolve(memory: memory, defaultProvider: "claude").request?.provider == "codex")
        #expect(resolve(defaultProvider: "codex").request?.provider == "codex")
        #expect(resolve().request?.provider == "claude", "the first installed one")
        #expect(resolve(path: "/w/app/", memory: memory).request?.provider == "codex", "however the path was written")
    }

    @Test func stepsPastAnUninstalledChoiceAndSaysSo() {
        let result = resolve(provider: "gemini")
        #expect(result.request?.provider == "claude")
        #expect(result.notices.map(\.code) == ["provider-substituted"])
        #expect(result.notices.first?.message == "Gemini CLI is not installed — starting Claude Code instead.")
        #expect(resolve(provider: "nope").notices.isEmpty, "an id not in the catalogue is ignored")
        let none = resolve(providerList: providers.map { var p = $0; p.available = false; return p })
        #expect(none.problem == "No agent could be found on your PATH, so there is nothing to start.")
        #expect(resolve(providerList: []).problem != nil)
    }

    @Test func resume() {
        #expect(resolve().request?.resume == false)
        #expect(resolve(resume: true).request?.resume == true)
        let shell = resolve(provider: "shell", resume: true)
        #expect(shell.request?.resume == false && shell.notices.map(\.code) == ["resume-unsupported"])
        let memory = NewSessionMemory(entries: [("/w/app", NewSessionDefaults(resume: true))])
        #expect(resolve(resume: nil, memory: memory).request?.resume == true)
        #expect(resolve(resume: false, memory: memory).request?.resume == false)
    }

    @Test func profiles() {
        #expect(resolve(profile: "work").request?.profileId == "work")
        let memory = NewSessionMemory(entries: [("/w/app", NewSessionDefaults(profileId: "work"))])
        #expect(resolve(memory: memory).request?.profileId == "work")
        #expect(resolve(defaultProfile: "work").request?.profileId == "work")
        #expect(resolve().request?.profileId == "sys", "ends on the system profile")
        let gone = resolve(profile: "deleted")
        #expect(gone.request?.profileId == "sys" && gone.notices.first?.message == "That profile no longer exists — using the default login instead.")
        let shell = resolve(provider: "shell", profile: "work")
        #expect(shell.request?.profileId == nil && shell.notices.map(\.code) == ["profile-not-applicable"])
        #expect(resolve(provider: "shell").notices.isEmpty)
        let empty = resolve(profile: "x", profileList: [])
        #expect(empty.request?.profileId == nil && empty.notices.first?.message == "That profile no longer exists, and no other login is available.")
    }

    @Test func theRequestCarriesTheDefaultSize() {
        let request = resolve().request
        #expect(request?.cols == 100 && request?.rows == 30 && request?.firstPrompt == "" && request?.title == nil)
    }
}

@Suite("New session: login line")
struct NewSessionLoginTests {
    @Test func parsesTheProbe() {
        #expect(NewSessionLogin.signIn(json(#"{"state":"signed-in","account":"a@b.c","plan":"Max"}"#))?.account == "a@b.c")
        #expect(NewSessionLogin.signIn(json(#"{"state":"maybe"}"#)) == nil)
        #expect(NewSessionLogin.signIn(json(#"{"state":"signed-in","account":""}"#))?.account == nil)
    }

    @Test func lines() {
        let signedIn = CodingAISignIn(state: .signedIn, account: "a@b.c", plan: "Max")
        #expect(NewSessionLogin.line(signedIn) == "a@b.c · Max")
        #expect(NewSessionLogin.line(CodingAISignIn(state: .signedIn, plan: "Pro")) == "Pro")
        #expect(NewSessionLogin.line(CodingAISignIn(state: .signedIn)) == "Signed in")
        #expect(NewSessionLogin.line(CodingAISignIn(state: .signedOut)) == "Not signed in")
        #expect(NewSessionLogin.line(CodingAISignIn(state: .unknown)) == "Sign-in state unknown")
        #expect(NewSessionLogin.line(nil) == nil && NewSessionLogin.line(CodingAISignIn(state: .unsupported)) == nil)
        #expect(NewSessionLogin.hint(signedIn, optionLabel: "a@b.c") == "Signed in · Max", "no address twice")
        #expect(NewSessionLogin.hint(signedIn, optionLabel: "Work") == "a@b.c · Max")
    }

    @Test func optionLabelsAndTheDefault() {
        let work = CodingAIAccount(id: "work", name: "Work", provider: "claude")
        let system = CodingAIAccount(id: "system", name: "system", provider: "claude", system: true)
        let report = CodingAISignIn(state: .signedIn, account: "me@x.y")
        #expect(NewSessionLogin.optionLabel(work, selectedId: "work", report: report) == "me@x.y")
        #expect(NewSessionLogin.optionLabel(work, selectedId: "other", report: report) == "Work")
        #expect(NewSessionLogin.isDefault(work, defaultId: "work"))
        #expect(NewSessionLogin.isDefault(system, defaultId: nil), "no default at all is the system login")
        #expect(!NewSessionLogin.isDefault(nil, defaultId: nil))
    }
}
