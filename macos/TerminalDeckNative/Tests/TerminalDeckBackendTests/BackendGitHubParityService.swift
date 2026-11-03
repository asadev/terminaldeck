import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor final class BackendGitHubParityService: XCTestCase {
    func testRelativeAndGoneFolderRejectedBeforeAnyTool() async throws {
        let dir = try BackendGitHubParityDirectory("path"); defer { try? FileManager.default.removeItem(at: dir) }
        let tools = BackendGitHubParityTools { _ in throw NativeRPCError(code: "unexpected", message: "No tool should run") }, service = BackendGitHubService(environment: [:], tools: tools)
        let relative = await service.resolveRepo("relative/path"), gone = await service.resolveRepo(dir.appendingPathComponent("vanished").path), calls = await tools.calls()
        XCTAssertEqual(relative["ok"].bool, false); XCTAssertEqual(gone["kind"].string, "no-such-folder"); XCTAssertTrue(calls.isEmpty)
    }
    func testPlainFolderHasSourceControlAdviceAndNoAction() async throws {
        let dir = try BackendGitHubParityDirectory("plain"); defer { try? FileManager.default.removeItem(at: dir) }
        let tools = BackendGitHubParityTools { _ in BackendGitHubParityOutcome(stderr: "fatal: --local can only be used inside a git repository", code: 128) }, service = BackendGitHubService(environment: [:], tools: tools)
        let result = await service.resolveRepo(dir.path)
        XCTAssertEqual(result["kind"].string, "not-a-repo"); XCTAssertEqual(result["action"], .null); XCTAssertTrue(result["message"].string!.contains("Source control"))
    }
    func testNoRemoteAndNonGithubRemoteStayDistinct() async throws {
        let dir = try BackendGitHubParityDirectory("remotes"); defer { try? FileManager.default.removeItem(at: dir) }
        let empty = BackendGitHubService(environment: [:], tools: BackendGitHubParityTools { _ in BackendGitHubParityOutcome(code: 1) })
        let gitlab = BackendGitHubService(environment: [:], tools: BackendGitHubParityTools { _ in BackendGitHubParityOutcome(stdout: "remote.origin.url https://gitlab.com/g/p.git\n") })
        let noRemote = await empty.resolveRepo(dir.path), noGitHub = await gitlab.resolveRepo(dir.path)
        XCTAssertEqual(noRemote["kind"].string, "no-remote"); XCTAssertEqual(noGitHub["kind"].string, "no-github-remote"); XCTAssertNotEqual(noRemote["message"], noGitHub["message"]); XCTAssertTrue(noRemote["action"].string!.contains("git remote add"))
    }
    func testCanonicalRepoAndTokenInNonGithubRemoteNeverLeaks() async throws {
        let dir = try BackendGitHubParityDirectory("identity"); defer { try? FileManager.default.removeItem(at: dir) }
        let hub = BackendGitHubService(environment: [:], tools: BackendGitHubParityTools { _ in BackendGitHubParityOutcome(stdout: "remote.origin.url git@github.com:cli/cli.git\n") })
        let repo = await hub.resolveRepo(dir.path)
        XCTAssertEqual(repo["nameWithOwner"].string, "cli/cli"); XCTAssertEqual(repo["url"].string, "https://github.com/cli/cli")
        let lab = BackendGitHubService(environment: [:], tools: BackendGitHubParityTools { _ in BackendGitHubParityOutcome(stdout: "remote.origin.url https://x-access-token:ghp_leakme@gitlab.com/g/p.git\n") })
        let failure = await lab.resolveRepo(dir.path)
        XCTAssertEqual(failure["kind"].string, "no-github-remote"); XCTAssertFalse(failure.compact.contains("ghp_leakme")); XCTAssertTrue(failure["detail"].string!.contains("***@gitlab.com"))
    }
    func testBranchOrdinaryAndUnbornUseSymbolicRefOnly() async throws {
        let dir = try BackendGitHubParityDirectory("branch"); defer { try? FileManager.default.removeItem(at: dir) }
        // Both source states have the same lightweight answer; no real git or
        // repository commits are created. The fake rejects any second command.
        for state in ["ordinary", "unborn"] {
            let tools = BackendGitHubParityTools { call in
                guard call.args == ["symbolic-ref", "--quiet", "--short", "HEAD"] else { throw NativeRPCError(code: "unexpected", message: "Branch probe must not use rev-parse") }
                return BackendGitHubParityOutcome(stdout: "main\n")
            }, service = BackendGitHubService(environment: [:], tools: tools)
            let branch = await service.readBranch(dir.path), calls = await tools.calls()
            XCTAssertEqual(branch, try BackendGitHubParityJSON(#"{"name":"main","detached":false,"head":null}"#), state); XCTAssertEqual(calls.count, 1)
        }
    }
    func testDetachedHeadUsesSecondCommandAndNonRepoDoesNot() async throws {
        let dir = try BackendGitHubParityDirectory("detached"); defer { try? FileManager.default.removeItem(at: dir) }
        let tools = BackendGitHubParityTools { call in call.args.first == "symbolic-ref" ? BackendGitHubParityOutcome(code: 1) : BackendGitHubParityOutcome(stdout: "a1b2c3d\n") }, service = BackendGitHubService(environment: [:], tools: tools)
        let branch = await service.readBranch(dir.path), calls = await tools.calls()
        XCTAssertEqual(branch, try BackendGitHubParityJSON(#"{"name":null,"detached":true,"head":"a1b2c3d"}"#)); XCTAssertEqual(calls.count, 2); XCTAssertEqual(calls[1].args, ["rev-parse", "--short", "HEAD"])
        let noRepoTools = BackendGitHubParityTools { _ in BackendGitHubParityOutcome(stderr: "fatal: not a git repository", code: 128) }, noRepo = BackendGitHubService(environment: [:], tools: noRepoTools)
        let noBranch = await noRepo.readBranch(dir.path), relative = await noRepo.readBranch("relative/path"), noRepoCalls = await noRepoTools.calls()
        XCTAssertEqual(noBranch, .null); XCTAssertEqual(relative, .null); XCTAssertEqual(noRepoCalls.count, 1)
    }
    func testEveryPanelChannelAuthSubsetBadArgumentsAndClearSend() async throws {
        let dir = try BackendGitHubParityDirectory("channels"); defer { try? FileManager.default.removeItem(at: dir) }
        let cache = BackendGitHubCache(now: { 0 }), tools = BackendGitHubParityCLI(installed: false), registry = NativeChannelRegistry()
        let service = BackendGitHubService(environment: [:], tools: tools, cache: cache)
        let auth = try BackendGitHubAuthenticator(dataDirectory: dir, environment: [:], http: BackendGitHubParityHTTP { _ in throw NativeRPCError(code: "unexpected", message: "No fake route") }, tools: tools, resolveRepo: { await service.resolveRepo($0) }, onAuthChanged: { await cache.clear() })
        let subscription = try await BackendGitHubChannels.register(registry: registry, ownerID: "fixture", service: service, auth: auth)
        defer { subscription.cancel() }
        let channels = await registry.channels()
        XCTAssertEqual(channels, ["github:auth-await", "github:auth-cancel", "github:auth-connect", "github:auth-disconnect", "github:auth-status", "github:overview", "github:refresh", "github:repo"])
        XCTAssertEqual(channels.filter { $0.hasPrefix("github:auth-") }, ["github:auth-await", "github:auth-cancel", "github:auth-connect", "github:auth-disconnect", "github:auth-status"])
        for channel in ["github:overview", "github:refresh", "github:repo"] {
            let result = try await registry.invoke(channel, context: .init(caller: .nativeApp, ownerID: "fixture"), arguments: [.string("../etc")]); XCTAssertEqual(result["ok"].bool, false); XCTAssertEqual(result["kind"].string, "error")
        }
        let nonString = try await registry.invoke("github:overview", context: .init(caller: .nativeApp, ownerID: "fixture"), arguments: [.number(42)]); XCTAssertEqual(nonString["ok"].bool, false)
        let counter = BackendGitHubParityCounter(), load: @Sendable () async -> NativeRPCValue = { .number(Double(await counter.increment())) }
        _ = try await cache.through("probe", load: load, ttl: { _ in 60_000 })
        let handled = try await registry.send("github:clear-cache", context: .init(caller: .nativeApp, ownerID: "fixture"), arguments: [])
        XCTAssertTrue(handled); _ = try await cache.through("probe", load: load, ttl: { _ in 60_000 }); let count = await counter.value(); XCTAssertEqual(count, 2)
    }
    func testOverviewHasOnlyPullsIssuesAndNoNotificationRequests() async throws {
        let dir = try BackendGitHubParityDirectory("no-notifications"); defer { try? FileManager.default.removeItem(at: dir) }
        let tools = BackendGitHubParityTools { call in call.tool == "git" ? BackendGitHubParityOutcome(stdout: "remote.origin.url https://github.com/asadev/terminaldeck.git\n") : BackendGitHubParityOutcome(stdout: "[]") }
        let service = BackendGitHubService(environment: [:], tools: tools, cache: BackendGitHubCache(now: { 0 }), now: { 0 }), view = await service.overview(cwd: dir.path)
        XCTAssertEqual(Set(view.fields!.map(\.key)), Set(["ok", "cwd", "repo", "pulls", "issues", "limit", "fetchedAt"]))
        let calls = await tools.calls(); XCTAssertFalse(calls.contains { $0.args.contains { $0.lowercased().contains("notification") } })
        XCTAssertEqual(Set(calls.filter { $0.tool == "gh" }.compactMap { $0.args.first }), Set(["pr", "issue"]))
    }
}
