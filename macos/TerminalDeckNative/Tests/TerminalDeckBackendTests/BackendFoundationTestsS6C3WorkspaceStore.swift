import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Ports workspace-store.test.ts through BackendWorkspaceService persistence
/// (userData/workspaces.json, ownership .exclusive) with a fake git.
/// Skipped: "hand out copies" (Swift records are value types, nothing to mutate).
/// PARITY GAPS expected red until NIGHT-REQUESTS (S6/C3 workspace store) is applied:
/// testUnreadableFileIsMovedAsideRatherThanOverwritten.
final class BackendFoundationTestsS6C3WorkspaceStoreTests: XCTestCase {
    private func record(_ taskID: String, repo: String, state: String = "active", updatedAt: Double = 1, path: String? = nil) -> NativeRPCValue {
        .object([.init("taskId", .string(taskID)), .init("repo", .string(repo)), .init("path", .string(path ?? "/data/workspaces/k/\(taskID)")),
                 .init("branch", .string("td/x-\(taskID)")), .init("project", .string(repo)), .init("base", .string("abc123")), .init("createdAt", .number(1)),
                 .init("state", .string(state)), .init("reason", .null), .init("updatedAt", .number(updatedAt))])
    }
    private func service(_ temp: S6C3WSTemp, repo: String, ownership: NativeStateStore.Ownership = .exclusive) throws -> BackendWorkspaceService {
        try BackendWorkspaceService(userData: temp.sub("data"), git: S6C3WS.fakeGit(S6C3WSFakeGit(repo: repo)), ownership: ownership)
    }
    private func stored(_ temp: S6C3WSTemp) throws -> NativeRPCValue {
        try NativeRPCValue.parseJSON(Data(contentsOf: temp.sub("data/workspaces.json")))
    }
    private func seed(_ temp: S6C3WSTemp, _ json: String) throws {
        _ = try temp.mkdir("data"); try Data(json.utf8).write(to: temp.sub("data/workspaces.json"))
    }
    private func makeFile(_ workspaces: [NativeRPCValue], refused: [NativeRPCValue] = []) throws -> String {
        let value = NativeRPCValue.object([.init("v", .number(1)), .init("workspaces", .array(workspaces)), .init("refused", .array(refused))])
        return String(decoding: try value.encodedJSON(), as: UTF8.self)
    }

    func testRecordsAreWrittenAsOneWholeFileAndReadBackAfterRestart() async throws {
        let temp = try S6C3WSTemp("store1"), repo = try temp.mkdir("repo").path
        let first = try service(temp, repo: repo)
        let folder = try await first.folderFor(taskID: "local:a", project: repo, useWorkspace: true, title: "x", context: S6C3WS.context)
        XCTAssertNotNil(folder)
        let file = try stored(temp)
        XCTAssertEqual(file["v"].number, 1); XCTAssertEqual(file["workspaces"].elements?.count, 1)
        // Through a temporary file and a rename: nothing half-written is left beside it.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: temp.sub("data").path).filter { $0 != "workspaces" }, ["workspaces.json"])
        let again = try service(temp, repo: repo)
        let view = try await again.view(taskID: "local:a", context: S6C3WS.context)
        XCTAssertEqual(view["workspace"]["taskId"].string, "local:a"); XCTAssertEqual(view["workspace"]["path"].string, folder)
    }
    func testRefusalIsPersistedAndReadBackAfterRestart() async throws {
        let temp = try S6C3WSTemp("store2"), repo = try temp.mkdir("repo").path
        let git = BackendGitService(authority: S6C3WS.authority, runner: S6C3WSRefusingGit())
        let first = try BackendWorkspaceService(userData: temp.sub("data"), git: git, ownership: .exclusive)
        let none = try await first.folderFor(taskID: "local:b", project: repo, useWorkspace: true, title: "x", context: S6C3WS.context)
        XCTAssertNil(none)
        XCTAssertEqual(try stored(temp)["refused"].elements?.count, 1)
        let again = try BackendWorkspaceService(userData: temp.sub("data"), git: git, ownership: .exclusive)
        let reason = try await again.view(taskID: "local:b", context: S6C3WS.context)["refusal"].string
        XCTAssertNotNil(reason)
    }
    func testWholeFileSurvivesASaveThatCannotBeMade() async throws {
        let temp = try S6C3WSTemp("store3"), repo = try temp.mkdir("repo").path
        let svc = try service(temp, repo: repo)
        _ = try await svc.folderFor(taskID: "local:a", project: repo, useWorkspace: true, title: "x", context: S6C3WS.context)
        let before = try String(contentsOf: temp.sub("data/workspaces.json"), encoding: .utf8)
        let data = temp.sub("data")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: data.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: data.path) }
        try XCTSkipIf(getuid() == 0, "root ignores folder modes")
        do { _ = try await svc.folderFor(taskID: "local:b", project: repo, useWorkspace: true, title: "y", context: S6C3WS.context); XCTFail("save should have failed") } catch {}
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: data.path)
        XCTAssertEqual(try String(contentsOf: temp.sub("data/workspaces.json"), encoding: .utf8), before)
        let restarted = try service(temp, repo: repo)
        let view = try await restarted.view(taskID: "local:a", context: S6C3WS.context)
        XCTAssertFalse(view["workspace"].isNullish)
    }
    func testUnreadableFileIsMovedAsideRatherThanOverwritten() async throws {
        let temp = try S6C3WSTemp("store4"), repo = try temp.mkdir("repo").path
        try seed(temp, "{ not json")
        let svc = try service(temp, repo: repo)
        let live = try await svc.liveFolders()
        XCTAssertEqual(live, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.sub("data/workspaces.json").path))
        let aside = try FileManager.default.contentsOfDirectory(atPath: temp.sub("data").path).filter { $0.hasPrefix("workspaces.json.unreadable-") }
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try String(contentsOf: temp.sub("data/" + aside[0]), encoding: .utf8), "{ not json")
    }
    func testMalformedRecordsAreDroppedAndTheRestKept() async throws {
        let temp = try S6C3WSTemp("store5"), repo = try temp.mkdir("repo").path, live = try temp.mkdir("live").path
        let a = record("local:a", repo: repo, path: live)
        let bad = NativeRPCValue.object([.init("taskId", .string("local:b"))])
        let lost = record("local:c", repo: repo, state: "lost", path: live)
        try seed(temp, try makeFile([a, bad, lost], refused: [.null]))
        let svc = try service(temp, repo: repo)
        let folders = try await svc.liveFolders()
        XCTAssertEqual(folders, [live])
        let view = try await svc.view(taskID: "local:b", context: S6C3WS.context); XCTAssertTrue(view["workspace"].isNullish)
        let viewC = try await svc.view(taskID: "local:c", context: S6C3WS.context); XCTAssertTrue(viewC["workspace"].isNullish)
    }
    func testRefusalIsClearedOnceTheTaskHasAWorkspace() async throws {
        let temp = try S6C3WSTemp("store6"), repo = try temp.mkdir("repo").path
        try seed(temp, try makeFile([], refused: [.object([.init("taskId", .string("local:a")), .init("project", .string(repo)), .init("reason", .string("no commits")), .init("at", .number(1))])]))
        let svc = try service(temp, repo: repo)
        let before = try await svc.view(taskID: "local:a", context: S6C3WS.context)
        XCTAssertEqual(before["refusal"].string, "no commits")
        _ = try await svc.folderFor(taskID: "local:a", project: repo, useWorkspace: true, title: "x", context: S6C3WS.context)
        let after = try await svc.view(taskID: "local:a", context: S6C3WS.context)
        XCTAssertEqual(after["refusal"], .null)
    }
    func testKeepsOnlyTheNewestRemovedRecordsAndNeverDropsALiveOne() async throws {
        let temp = try S6C3WSTemp("store7"), repo = try temp.mkdir("repo").path, live = try temp.mkdir("live").path
        var rows = [record("local:live", repo: repo, updatedAt: 0, path: live)]
        for i in 0...200 { rows.append(record("local:r\(i)", repo: repo, state: "removed", updatedAt: Double(i + 1))) }
        try seed(temp, try makeFile(rows))
        let svc = try service(temp, repo: repo)
        // Any write saves the whole file, applying the cap.
        _ = try await svc.folderFor(taskID: "local:new", project: repo, useWorkspace: true, title: "x", context: S6C3WS.context)
        let saved = try stored(temp)["workspaces"].elements ?? []
        XCTAssertEqual(saved.filter { $0["state"].string == "removed" }.count, 200)
        XCTAssertFalse(saved.contains { $0["taskId"].string == "local:r0" })
        XCTAssertTrue(saved.contains { $0["taskId"].string == "local:live" })
    }
    func testReadOnlyOwnershipNeverWrites() async throws {
        let temp = try S6C3WSTemp("store8"), repo = try temp.mkdir("repo").path
        let svc = try service(temp, repo: repo, ownership: .readOnly)
        do { _ = try await svc.folderFor(taskID: "local:a", project: repo, useWorkspace: true, title: "x", context: S6C3WS.context); XCTFail("wrote while read-only") }
        catch let error as NativeRPCError { XCTAssertEqual(error.code, "read-only") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.sub("data/workspaces.json").path))
    }
}

/// Git that cannot find a repository, so every workspace request is refused.
private struct S6C3WSRefusingGit: BackendGitExecuting {
    func run(cwd: String, arguments: [String], context: NativeRPCContext, writing: Bool, timeoutMilliseconds: Int, maximumBytes: Int) async throws -> BackendGitOutcome {
        BackendGitOutcome(ok: false, stdout: "", stderr: "fatal: not a git repository (or any of the parent directories): .git", missing: false, exitCode: 128, timedOut: false)
    }
}
