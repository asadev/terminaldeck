import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// 18 Oct, Part 20 (U49): the small account bugs in Settings › Coding AIs and Agent settings.
@MainActor
struct NativeAccountSmallBugsTests {
    private let project = NativeAccountLevelRow(id: "project:p", kind: .project, title: "P",
                                                levels: [["kind": "project", "path": "/work/a"], ["kind": "project", "path": "/work/b"]])

    // #143: a project whose folders use different accounts says so, never only its first folder's choice.
    @Test func projectWithFoldersOnDifferentAccountsShowsMixed() {
        let model = NativeAccountLevelsModel()
        model.setFixture(app: [:], projects: ["/work/b": ["claude": "work"]], seats: [:], sessions: [], usage: [:])
        #expect(model.mixed(project))
        #expect(model.assigned(project) == nil)
        #expect(model.effective(project).id == NativeAccountLevelsModel.mixedID)
        model.setFixture(app: [:], projects: ["/work/a": ["claude": "work"], "/work/b": ["claude": "work"]], seats: [:], sessions: [], usage: [:])
        #expect(!model.mixed(project))
        #expect(model.assigned(project) == "work")
    }

    // #515: a failure halfway puts the folders already written back on their old account.
    @Test func settingSeveralFoldersIsAllOrNothing() async {
        struct Refused: Error {}
        var writes: [(String, String?)] = []
        let levels: [(level: [String: String], account: String?)] = [(["path": "/a"], "old-a"), (["path": "/b"], nil), (["path": "/c"], "old-c")]
        var refused = false
        do {
            try await NativeAccountLevelsModel.setAll(levels, to: "new") { level, account in
                if level["path"] == "/c" { throw Refused() }
                writes.append((level["path"] ?? "", account))
            }
        } catch { refused = error is Refused }
        #expect(refused)
        #expect(writes.map { $0.0 } == ["/a", "/b", "/b", "/a"])
        #expect(writes.map { $0.1 } == ["new", "new", nil, "old-a"])
    }

    // #514: Try Again after a failed Add runs the whole Add again (its account was removed when it failed).
    @Test func tryAgainAfterFailedAddStartsTheAddAgain() {
        let model = NativeAccountSignInModel()
        var added = 0
        model.retry = { added += 1 }
        model.active = .init(id: "flow", accountID: "gone", accountName: "Claude account", provider: "claude", state: "failed",
                             message: "The sign-in did not finish. Try again.", namesItself: true, createdHere: true)
        model.tryAgain([])
        #expect(added == 1)
        #expect(model.active == nil)
    }

    // #530: the row, Switch now and the session list match a project's folders one way (both sides standardized).
    @Test func switchNowMatchesFoldersTheWayTheRowDoes() {
        let model = NativeAccountLevelsModel()
        let row = NativeAccountLevelRow(id: "project:p", kind: .project, title: "P", project: PROJProject(id: "p", name: "P", folders: ["/work/a/"]),
                                        levels: [["kind": "project", "path": "/work/a/"]])
        let session = NativeAccountSession(id: "s1", title: "S", cwd: "/work/./a/sub", projectID: nil, provider: "claude", accountID: nil)
        model.setFixture(app: [:], projects: ["/work/a": ["claude": "work"]], seats: [:], sessions: [session], usage: [:])
        #expect(model.assigned(row) == "work")
        model.planSwitch(row, rows: [row], names: [:])
        #expect(model.plan?.moves.map(\.target) == ["work"], "the session under the row moves to the row's account")
        #expect(NativeAccountLevelsModel.within("/work/a", "/work/a/"))
        #expect(!NativeAccountLevelsModel.within("/work/ab", "/work/a"))
    }

    // #516: an unset thinking level stays unset in the form, and its default is named.
    @Test func defaultsEditorShowsTheStoredThinkingLevel() {
        let shown = NativeAGSDefaultsEditor.shown(AGSDefaults(providers: [:]), provider: "claude")
        #expect(shown.effort == nil)
        #expect(shown.provider == "claude")
        #expect(NativeAGSDefaultsEditor.effortDefaultLabel(provider: "claude") == "App default (Extra high)")
        #expect(NativeAGSDefaultsEditor.effortDefaultLabel(provider: "gemini") == "App default")
    }
}
