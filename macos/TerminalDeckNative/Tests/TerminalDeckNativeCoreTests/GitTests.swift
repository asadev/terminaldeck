import Foundation
import Testing
@testable import TerminalDeckNativeCore

/// The native Source control page's rules, mirroring `GitPanel.test.tsx`.
@Suite("Git rules")
struct GitRulesTests {
    @Test func namesEveryKindAndNeverABareQuestionMarkForUntracked() {
        #expect(GitRules.changeLabel(.added, code: "A ") == "Added")
        #expect(GitRules.changeLabel(.typechange, code: "T ") == "Type")
        #expect(GitRules.changeLabel(.untracked, code: "??") == "Untracked")
        #expect(GitRules.changeLabel(.conflicted, code: "UU") == "Conflict")
        #expect(GitRules.changeLabel(.unknown, code: " X") == "X")
        #expect(GitRules.changeLabel(.unknown, code: "  ") == "?")
    }

    @Test func asksGitTheQuestionTheGroupAnswers() {
        #expect(GitRules.diffMode(.staged) == ["staged": true])
        #expect(GitRules.diffMode(.untracked) == ["untracked": true])
        #expect(GitRules.diffMode(.unstaged).isEmpty && GitRules.diffMode(.conflicted).isEmpty)
    }

    @Test func dropsTheFileHeaderKeepsTheHunkAndNeverPaintsTheNames() {
        let lines = GitRules.parseUnifiedDiff("diff --git a/x b/x\nindex 1..2 100644\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n same\n")
        #expect(lines.map(\.kind) == [.meta, .meta, .meta, .meta, .hunk, .del, .add, .context])
        #expect(lines[5].text == "old" && lines[6].text == "new" && lines[7].text == "same")
        #expect(GitRules.parseUnifiedDiff("").isEmpty)
        #expect(GitRules.parseUnifiedDiff("+a\n").count == 1)
    }

    @Test func saysWhereAChangeIsWaiting() {
        #expect(GitRules.groupState(.untracked) == "not tracked yet")
        #expect(GitRules.groupState(.staged) == "ready to commit")
        #expect(GitRules.groupState(.unstaged) == "not staged yet")
        #expect(GitRules.groupState(.conflicted) == "needs resolving")
        let file = GitFile(path: "src/a.ts", group: .unstaged, code: " M", kind: .modified, insertions: 3, deletions: 1)
        #expect(GitRules.diffMeta(file, group: .unstaged) == "Modified · not staged yet · +3 −1")
        let bin = GitFile(path: "a.png", group: .staged, code: "A ", kind: .added, binary: true)
        #expect(GitRules.diffMeta(bin, group: .staged) == "Added · ready to commit · binary")
    }

    @Test func saysWhyAFolderAndABinaryHaveNoDiff() {
        #expect(GitRules.noDiffReason(GitFile(path: "build/", group: .untracked, kind: .untracked))?.hasPrefix("This is a folder git has not looked inside yet") == true)
        #expect(GitRules.noDiffReason(GitFile(path: "a.png", group: .staged, kind: .added, binary: true)) == "A binary file. There is no text to line up side by side.")
        #expect(GitRules.noDiffReason(GitFile(path: "a.ts", group: .unstaged, kind: .deleted)) == nil)
    }

    @Test func offersARepositoryOnlyWhereOneCanBeMade() {
        let notRepo = GitStatusResult.notRepo(cwd: "/a", reason: .notARepo, message: "fatal: not a git repository", canInit: true)
        #expect(GitRules.unavailable(notRepo) == GitUnavailableView(title: "Nothing to track here", message: "This folder is not a git repository.", canInit: true))
        #expect(GitRules.unavailable(notRepo, hasInit: false).message == "fatal: not a git repository")
        let refusing = GitStatusResult.notRepo(cwd: "/a", reason: .error, message: "dubious ownership", canInit: false)
        #expect(GitRules.unavailable(refusing) == GitUnavailableView(title: "Source control is unavailable", message: "dubious ownership", canInit: false))
        #expect(GitRules.unavailable(nil) == GitUnavailableView(title: "Source control is unavailable", message: "git could not read this folder", canInit: false))
        #expect(GitRules.unavailable(.notRepo(cwd: "", reason: .gitMissing, message: "", canInit: false)).title == "git is not installed")
        #expect(GitRules.unavailable(.notRepo(cwd: "", reason: .noSuchFolder, message: "", canInit: false)).title == "That folder is gone")
    }

    @Test func usesTheOverviewTilesFourHeadingsAndChoosesAFileWithADiff() throws {
        let json: [String: Any] = [
            "repo": true, "cwd": "/p", "root": "/p", "clean": false,
            "branch": ["name": "main", "detached": false, "oid": "abc", "upstream": "origin/main", "ahead": 2, "behind": 0],
            "staged": [["path": "staged.txt", "origPath": NSNull(), "group": "staged", "code": "A ", "kind": "added", "insertions": 1, "deletions": 0, "binary": false]],
            "unstaged": [["path": "src/a.ts", "group": "unstaged", "code": " M", "kind": "modified", "insertions": 1, "deletions": 1, "binary": false]],
            "untracked": [["path": "build/", "group": "untracked", "code": "??", "kind": "untracked", "binary": false]],
            "conflicted": [] as [Any],
        ]
        let status = try #require(GitStatusResult(json: json)?.repo)
        #expect(GitRules.groups(status).map(\.label) == ["Staged", "Changes", "Untracked"])
        #expect(status.changeCount == 3 && status.branch.label == "main" && status.branch.ahead == 2)
        #expect(GitRules.firstChoice(GitRules.groups(status)) == "staged.txt")
        #expect(GitBranch(name: nil, detached: true, oid: "1a2b3c4d5e").label == "detached at 1a2b3c4")
        #expect(GitBranch(name: nil).label == "no branch")
        #expect(GitRules.baseName("src/a.ts") == "a.ts" && GitRules.dirName("src/a.ts") == "src" && GitRules.baseName("build/") == "build/")
        #expect(GitRules.rowDetail(GitFile(path: "b.ts", origPath: "a.ts", group: .staged, kind: .renamed)) == "← a.ts")
        #expect(GitRules.rowTitle(GitFile(path: "b.ts", origPath: "a.ts", group: .staged, code: "R ", kind: .renamed)) == "a.ts → b.ts — git status R")
        #expect(GitRules.moreLines(1234) .hasSuffix("more lines not shown."))
    }
}
