import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private struct GHMCPCloneCancelledOutcome: BackendGitHubToolRunning {
    func run(tool: String, arguments: [String], cwd: String?, environment: [String: String], timeoutMilliseconds: Int, maximumBytes: Int) async throws -> BackendGitOutcome {
        withUnsafeCurrentTask { $0?.cancel() }
        return .init(ok: true, stdout: "", stderr: "", missing: false, exitCode: 0, timedOut: false)
    }
}
private struct GHMCPCloneSuccess: BackendGitHubToolRunning {
    func run(tool: String, arguments: [String], cwd: String?, environment: [String: String], timeoutMilliseconds: Int, maximumBytes: Int) async throws -> BackendGitOutcome {
        .init(ok: true, stdout: "", stderr: "", missing: false, exitCode: 0, timedOut: false)
    }
}
private actor GHMCPCloneProjects {
    private var paths: [String] = []
    func add(_ path: String) -> NativeRPCValue { paths.append(path); return .string(path) }
    func count() -> Int { paths.count }
}

@MainActor
final class GHMCPCloneSafetyTests: XCTestCase {
    private func parent() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("gh-mcp-clone-cancel-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }
    func testCancellationAfterGitFinishesDoesNotAddTheProject() async throws {
        let folder = try parent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tools = GHMCPCloneCancelledOutcome(), projects = GHMCPCloneProjects()
        let auth = try BackendGitHubAuthenticator(dataDirectory: folder, environment: ["GH_TOKEN": "fixture-token-only"], tools: tools, resolveRepo: { _ in .null })
        let clone = BackendGHCloneService(auth: auth, tools: tools, environment: [:], addProject: { path in await projects.add(path) })
        let task = Task {
            try await clone.clone(.init(repo: "sample/deck", host: "github.com", parentPath: folder.path, directoryName: "copy", branch: nil))
        }
        do { _ = try await task.value; XCTFail("Cancellation was converted into clone success") }
        catch is CancellationError { }
        let added = await projects.count(); XCTAssertEqual(added, 0)
    }
    func testCancellationDuringAddProjectIsNotReportedAsSuccessWithWarning() async throws {
        let folder = try parent()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tools = GHMCPCloneSuccess()
        let auth = try BackendGitHubAuthenticator(dataDirectory: folder, environment: ["GH_TOKEN": "fixture-token-only"], tools: tools, resolveRepo: { _ in .null })
        let clone = BackendGHCloneService(auth: auth, tools: tools, environment: [:], addProject: { _ in throw CancellationError() })
        do {
            _ = try await clone.clone(.init(repo: "sample/deck", host: "github.com", parentPath: folder.path, directoryName: "copy", branch: nil))
            XCTFail("Cancellation was converted into clone success")
        } catch is CancellationError { }
    }
}
