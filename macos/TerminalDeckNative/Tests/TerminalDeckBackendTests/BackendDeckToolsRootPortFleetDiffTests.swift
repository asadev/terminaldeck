import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// fleet-diff.test.ts Mac cases. Actual Git service/review run on a fake Git
/// process and temporary mtime fixtures. Windows comparison cases are skipped
/// individually in the Test map; no Git executable or clock wait is used.
final class BackendDeckToolsRootPortFleetDiffTests: XCTestCase {
    static func o(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue { BackendDeckToolsSupport.object(pairs) }
    actor Git: BackendGitExecuting {
        let root: String, paths: [(String, String)], binary: Set<String>, size: Int, repo: Bool
        var requests: [[String]] = []
        init(root: String, paths: [(String, String)], binary: Set<String>, size: Int, repo: Bool) { self.root = root; self.paths = paths; self.binary = binary; self.size = size; self.repo = repo }
        func run(cwd: String, arguments: [String], context: NativeRPCContext, writing: Bool, timeoutMilliseconds: Int, maximumBytes: Int) async throws -> BackendGitOutcome {
            let output: String
            if arguments.first == "rev-parse" { if !repo { return .init(ok: false, stdout: "", stderr: "fatal: not a git repository", missing: false, exitCode: 128, timedOut: false) }; output = root + "\n" }
            else if arguments.first == "status" {
                output = "# branch.head main\0" + paths.map { path, group in group == "untracked" ? "? \(path)\0" : "1 \(group == "staged" ? "M." : group == "deleted" ? ".D" : ".M") N... 100644 100644 100644 aaaaaa bbbbbb \(path)\0" }.joined()
            } else if arguments.contains("--numstat") { output = paths.map { path, _ in binary.contains(path) ? "-\t-\t\(path)\0" : "3\t1\t\(path)\0" }.joined() }
            else if arguments.contains("--no-index"), let path = arguments.last {
                // git.ts readFileDiff L579-596: an untracked file is diffed by git
                // itself (`diff --no-index -- /dev/null <path>`), which exits 1
                // with the new file's lines on stdout. The fake reads the file
                // the way git would so the diff carries its real contents.
                requests.append(arguments)
                let lines = ((try? String(contentsOfFile: root + "/" + path, encoding: .utf8)) ?? "").split(separator: "\n", omittingEmptySubsequences: false)
                let body = lines.filter { !$0.isEmpty }.map { "+" + $0 }.joined(separator: "\n")
                return .init(ok: false, stdout: "--- /dev/null\n+++ b/\(path)\n@@ -0,0 +1 @@\n\(body)\n", stderr: "", missing: false, exitCode: 1, timedOut: false)
            }
            else { requests.append(arguments); output = String(repeating: "x", count: size) }
            return .init(ok: true, stdout: output, stderr: "", missing: false, exitCode: 0, timedOut: false)
        }
        func diffCalls() -> [[String]] { requests }
    }
    struct Rig {
        let root: URL, git: Git, review: BackendGitReview
        func run(path: String? = nil, max: Int = 25) async throws -> NativeRPCValue { try await BackendDeckToolsFleetDiff.collect(review: review, cwd: root.path, path: path, maxFiles: max, context: .init(caller: .nativeApp, ownerID: "fixture")) }
        func dispose() { try? FileManager.default.removeItem(at: root) }
    }
    private func rig(paths: [(String, String)] = [("src/a.ts", "unstaged")], mtime: Double? = 5000,
                     sessions: [(String, Double, String)] = [], binary: Set<String> = [], size: Int = 30, repo: Bool = true) throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BackendDeckToolsRootPortFleet-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let actual = root.resolvingSymlinksInPath()
        if let mtime { for (path, group) in paths where group != "deleted" {
            let file = actual.appendingPathComponent(path); try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: file); try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: mtime / 1000)], ofItemAtPath: file.path)
        } }
        let views = sessions.map { id, at, suffix in Self.o([("id", .string(id)), ("cwd", .string(actual.path + suffix)), ("title", .string(id)), ("provider", .string("claude")), ("attention", .string("running")), ("createdAt", .number(at)), ("startedByCopilot", .bool(false))]) }
        let git = Git(root: actual.path, paths: paths, binary: binary, size: size, repo: repo), authority = BackendFilesystemAuthority { _ in .init(readRoots: [actual]) }
        return Rig(root: actual, git: git, review: .init(git: .init(authority: authority, runner: git), sessionViews: { views }))
    }
    func testOnlySessionBornBeforeWriteIsNamed() async throws { let r = try rig(sessions: [("early",1000,""),("late",9000,"")]); defer { r.dispose() }; let value = try await r.run(); let owner = value["files"].elements![0]["attribution"]; XCTAssertEqual(owner["candidates"], .array([.string("early")])); XCTAssertEqual(owner["sessionId"], .string("early")); XCTAssertTrue(value["attributionNote"].string!.contains("1 traceable to one session")) }
    func testTwoOverlappingSessionsRemainAmbiguous() async throws { let r = try rig(mtime:9000,sessions:[("one",1000,""),("two",2000,"")]); defer { r.dispose() }; let value = try await r.run(), owner = value["files"].elements![0]["attribution"]; XCTAssertEqual(owner["sessionId"], .null); XCTAssertEqual(owner["candidates"].elements?.count,2); XCTAssertTrue(value["attributionNote"].string!.contains("could be any of 2 sessions")) }
    func testEarlierHumanOrOldChangeBlamesNobody() async throws { let r = try rig(mtime:500,sessions:[("one",1000,"")]); defer { r.dispose() }; let owner = try await r.run()["files"].elements![0]["attribution"]; XCTAssertEqual(owner["candidates"],.array([])); XCTAssertTrue(owner["reason"].string!.contains("before any session")) }
    func testDeletedFileStaysListedWithNoTimeReason() async throws { let r = try rig(paths:[("src/gone.ts","deleted")],sessions:[("one",1000,"")]); defer { r.dispose() }; let value = try await r.run(), row = value["files"].elements![0]; XCTAssertEqual(value["files"].elements?.count,1); XCTAssertEqual(row["attribution"]["modifiedAt"],.null); XCTAssertTrue(row["attribution"]["reason"].string!.contains("file is gone")) }
    func testNestedSessionBelongsToRepository() async throws { let r = try rig(paths:[("web/src/a.ts","unstaged")],sessions:[("nested",1000,"/web")]); defer { r.dispose() }; let value = try await r.run(); XCTAssertEqual(value["sessions"].elements?.map { $0["id"].string! },["nested"]) }
    func testPrefixNeighborIsNotInRepository() async throws { let r = try rig(sessions:[("elsewhere",1000,"-two")]); defer { r.dispose() }; let value = try await r.run(); XCTAssertEqual(value["sessions"],.array([])); XCTAssertTrue(value["attributionNote"].string!.contains("No session is running")) }
    func testStagedAndWorkingDiffFlagsMatchGroups() async throws {
        let r = try rig(paths:[("a.ts","staged"),("b.ts","untracked"),("c.ts","unstaged")]); defer { r.dispose() }; let value = try await r.run(); let calls = await r.git.diffCalls()
        // fleet-diff.test.ts L166-183: three asks — staged, untracked and
        // unstaged — and git.ts L579-603 runs one git diff for each (the
        // untracked one with --no-index), so three requests reach git.
        XCTAssertEqual(calls.count,3); XCTAssertTrue(calls[0].contains("--cached")); XCTAssertFalse(calls[1].contains("--cached"))
        XCTAssertEqual(calls.filter { $0.contains("--cached") }.map { $0.last }, ["a.ts"])
        XCTAssertEqual(calls.filter { $0.contains("--no-index") }.map { Array($0.suffix(2)) }, [["/dev/null", "b.ts"]])
        XCTAssertEqual(calls.filter { !$0.contains("--cached") && !$0.contains("--no-index") }.map { $0.last }, ["c.ts"])
        let untracked = value["files"].elements!.first { $0["path"].string == "b.ts" }!
        XCTAssertEqual(untracked["group"], .string("untracked")); XCTAssertTrue(untracked["diff"].string!.contains("+fixture"))
    }
    func testAllFilesListedButOnlyFirstFiveCarryDiff() async throws { let r = try rig(paths:(0..<40).map { ("src/f\($0).ts","unstaged") }); defer { r.dispose() }; let value = try await r.run(max:5), calls = await r.git.diffCalls(); XCTAssertEqual(value["changedFiles"],.number(40)); XCTAssertEqual(value["withDiff"],.number(5)); XCTAssertEqual(calls.count,5); XCTAssertEqual(value["bound"],.string("file-limit")); XCTAssertEqual(value["files"].elements![10]["omitted"],.string("file-limit")) }
    func testTotalByteCeilingIsReported() async throws { let r = try rig(paths:(0..<30).map { ("src/f\($0).ts","unstaged") },size:12_000); defer { r.dispose() }; let value = try await r.run(max:30); XCTAssertLessThanOrEqual(value["diffChars"].number!,60_000); XCTAssertEqual(value["bound"],.string("byte-limit")); XCTAssertTrue(value["files"].elements!.contains { $0["omitted"] == .string("byte-limit") }) }
    func testHugeFileDiffIsTruncatedAndMarked() async throws { let r = try rig(paths:[("package-lock.json","unstaged")],size:36_000); defer { r.dispose() }; let row = try await r.run()["files"].elements![0]; XCTAssertEqual(row["diff"].string?.utf16.count,12_000); XCTAssertEqual(row["diffTruncated"],.bool(true)) }
    func testBinaryFileNeverRequestsDiff() async throws { let r = try rig(paths:[("logo.png","unstaged")],binary:["logo.png"]); defer { r.dispose() }; let value = try await r.run(), calls = await r.git.diffCalls(); XCTAssertTrue(calls.isEmpty); XCTAssertEqual(value["files"].elements![0]["omitted"],.string("binary")) }
    func testNamedPathNarrowsActualDiffRequest() async throws { let r = try rig(paths:[("a.ts","unstaged"),("b.ts","unstaged")]); defer { r.dispose() }; let value = try await r.run(path:"b.ts"), calls = await r.git.diffCalls(); XCTAssertEqual(value["changedFiles"],.number(1)); XCTAssertEqual(calls.count,1); XCTAssertEqual(calls[0].last,"b.ts") }
    func testNonRepositoryIsNotPretendedToBeOne() async throws { let r = try rig(repo:false); defer { r.dispose() }; let value = try await r.run(); XCTAssertEqual(value["repo"],.bool(false)); XCTAssertTrue(value["reason"].string!.contains("not a git repository")); XCTAssertTrue(value["attributionNote"].string!.contains("not a git repository")) }
    func testPosixContainmentRemainsSeparatorExact() async throws { let r = try rig(sessions:[("web",1000,"/packages/web"),("other",1000,"-two/src")]); defer { r.dispose() }; let value = try await r.run(); XCTAssertEqual(value["sessions"].elements?.map { $0["id"].string! },["web"]) }
}
