import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Ports workspace-names.test.ts through the only public surface that names things
/// (BackendWorkspaceService.folderFor with a fake git). slugOf/branchFor/folderNameOf/
/// repoKeyOf are private in Swift; observed as the recorded branch, the folder name
/// and the repo-key parent folder.
final class BackendFoundationTestsS6C3WorkspaceNamesTests: XCTestCase {
    private let nasty = ["Fix the login page!", "../../etc/passwd", "--force", "-b main", "a..b.lock", "feature@{1}~^:?*[\\", "refs/heads/main", ".hidden/",
                         "tab\tand\nnewline", "\"; rm -rf ~; echo \"", "🚀🚀🚀", "", "   ", "Café déjà vu", String(repeating: "x", count: 300)]

    private struct Rig { let temp: S6C3WSTemp; let repo: String; let fake: S6C3WSFakeGit; let service: BackendWorkspaceService; let data: URL }
    private func rig(taken: Set<String> = []) throws -> Rig {
        let temp = try S6C3WSTemp("names"), repo = try temp.mkdir("repo").path, data = temp.sub("data")
        let fake = S6C3WSFakeGit(repo: repo, taken: taken)
        return Rig(temp: temp, repo: repo, fake: fake, service: try BackendWorkspaceService(userData: data, git: S6C3WS.fakeGit(fake), ownership: .memory), data: data)
    }
    /// The branch and folder a workspace for this title/id was given.
    private func named(_ r: Rig, title: String, id: String) async throws -> (branch: String, path: String) {
        let folder = try await r.service.folderFor(taskID: id, project: r.repo, useWorkspace: true, title: title, context: S6C3WS.context)
        let view = try await r.service.view(taskID: id, context: S6C3WS.context)
        XCTAssertNotNil(folder, "title \(title.debugDescription)")
        return (view["workspace"]["branch"].string ?? "", view["workspace"]["path"].string ?? "")
    }
    private func slug(_ branch: String, id: String) -> String {
        let suffix = "-" + S6C3WS.shortID(id)
        XCTAssertTrue(branch.hasPrefix("td/") && branch.hasSuffix(suffix), branch)
        return String(branch.dropFirst(3).dropLast(suffix.count))
    }
    private func slugFor(_ title: String) async throws -> String {
        let r = try rig(); let id = "local:slug"
        return slug(try await named(r, title: title, id: id).branch, id: id)
    }

    func testSlugKeepsTheWordsAndDropsEverythingElse() async throws {
        let expected: [(String, String)] = [("Fix the login page!", "fix-the-login-page"), ("../../etc/passwd", "etc-passwd"), ("--force", "force"),
            ("a..b.lock", "a-b-lock"), ("feature@{1}~^:?*[\\", "feature-1"), ("\"; rm -rf ~; echo \"", "rm-rf-echo")]
        for (title, slug) in expected { let got = try await slugFor(title); XCTAssertEqual(got, slug, title) }
    }
    func testSlugFoldsAccents() async throws { let got = try await slugFor("Café déjà vu"); XCTAssertEqual(got, "cafe-deja-vu") }
    func testSlugIsNeverEmpty() async throws {
        for title in ["", "   ", "🚀🚀🚀"] { let got = try await slugFor(title); XCTAssertEqual(got, "task", title.debugDescription) }
    }
    func testSlugIsCutToItsLengthWithoutADanglingDash() async throws {
        let long = try await slugFor(String(repeating: "word ", count: 40))
        XCTAssertLessThanOrEqual(long.count, 40); XCTAssertFalse(long.hasSuffix("-"))
        let x = try await slugFor(String(repeating: "x", count: 300)); XCTAssertEqual(x, String(repeating: "x", count: 40))
    }
    func testSlugOnlyHoldsLowercaseLettersDigitsAndSingleInnerDashes() async throws {
        for title in nasty {
            let got = try await slugFor(title)
            XCTAssertNotNil(got.range(of: #"^[a-z0-9]+(-[a-z0-9]+)*$"#, options: .regularExpression), title.debugDescription)
        }
    }
    func testBranchIsTdSlugShortIdStableForOneTask() async throws {
        let r = try rig()
        let a = try await named(r, title: "Fix the login page!", id: "local:abc").branch
        XCTAssertEqual(a, "td/fix-the-login-page-" + S6C3WS.shortID("local:abc"))
        let b = try await named(r, title: "Fix the login page!", id: "local:abd").branch
        XCTAssertNotEqual(a, b)
        XCTAssertNotNil(S6C3WS.shortID("local:abc").range(of: "^[0-9a-f]{8}$", options: .regularExpression))
        // Same task asked again keeps its recorded branch.
        let again = try await named(r, title: "Fix the login page!", id: "local:abc").branch
        XCTAssertEqual(again, a)
    }
    func testBranchCountsOnPastANameAlreadyTaken() async throws {
        let base = "td/fix-it-" + S6C3WS.shortID("local:abc")
        let r = try rig(taken: [base])
        let got = try await named(r, title: "Fix it", id: "local:abc").branch
        XCTAssertEqual(got, base + "-2")
    }
    func testBranchIsANameGitItselfAccepts() async throws {
        try XCTSkipUnless(S6C3WS.hasGit, "git not installed"); let git = S6C3WS.git(); let temp = try S6C3WSTemp("refformat")
        for title in nasty {
            let r = try rig(); let branch = try await named(r, title: title, id: "local:\(title)").branch
            let outcome = try await git.workspaceCommand(cwd: temp.path, arguments: ["check-ref-format", "--branch", branch], context: S6C3WS.context, writing: false)
            XCTAssertTrue(outcome.ok, "\(branch): \(outcome.stderr)")
        }
    }
    func testFolderNameKeepsIdReadableAndAddsItsHash() async throws {
        let r = try rig(); let got = try await named(r, title: "x", id: "local:abc")
        XCTAssertEqual(URL(fileURLWithPath: got.path).lastPathComponent, "local-abc-" + S6C3WS.shortID("local:abc"))
    }
    func testTwoIdsThatCleanUpTheSameGetTwoFolders() async throws {
        let r = try rig()
        let a = try await named(r, title: "x", id: "a:b"), b = try await named(r, title: "x", id: "a/b")
        XCTAssertNotEqual(a.path, b.path)
    }
    func testFolderNameOnlyHoldsSafeCharactersAndStaysShort() async throws {
        let r = try rig()
        for id in ["local:abc", "../..", "a\\b", "con:", "...", String(repeating: "x", count: 200), "ünï:cödé"] {
            let name = URL(fileURLWithPath: try await named(r, title: "t", id: id).path).lastPathComponent
            XCTAssertNotNil(name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*[0-9a-f]$"#, options: .regularExpression), "\(id): \(name)")
            XCTAssertLessThanOrEqual(name.count, 64, id)
        }
        let dots = URL(fileURLWithPath: try await named(r, title: "t", id: "...").path).lastPathComponent
        XCTAssertEqual(dots, "task-" + S6C3WS.shortID("..."))
    }
    func testRepoKeyIs16HexStableForOnePath() async throws {
        let r = try rig(); let got = try await named(r, title: "x", id: "local:key")
        let key = URL(fileURLWithPath: got.path).deletingLastPathComponent().lastPathComponent
        XCTAssertEqual(key, S6C3WS.repoKey(r.repo))
        XCTAssertNotNil(key.range(of: "^[0-9a-f]{16}$", options: .regularExpression))
        XCTAssertNotEqual(S6C3WS.repoKey("/work/app"), S6C3WS.repoKey("/work/app2"))
    }
}
