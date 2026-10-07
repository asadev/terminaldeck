import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Ports workspaces-ipc.test.ts through BackendWorkspaceChannels + NativeChannelRegistry.
/// "answer only the app's own window": TS tested a foreign sender; Swift gates on caller == .nativeApp.
final class BackendFoundationTestsS6C3WorkspaceIpcTests: XCTestCase {
    private final class Opened: @unchecked Sendable {
        private let lock = NSLock(); private var paths: [String] = []; private var live: [String] = []
        func add(_ path: String) { lock.lock(); paths.append(path); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return paths }
        func setLive(_ folders: [String]) { lock.lock(); live = folders; lock.unlock() }
        var liveFolders: [String] { lock.lock(); defer { lock.unlock() }; return live }
    }
    private struct Wire { let temp: S6C3WSTemp; let git: BackendGitService; let registry: NativeChannelRegistry; let service: BackendWorkspaceService; let opened: Opened; let channels: [String] }
    private func wire() async throws -> Wire {
        try XCTSkipUnless(S6C3WS.hasGit, "git not installed")
        let temp = try S6C3WSTemp("ipc"), git = S6C3WS.git(), opened = Opened(), registry = NativeChannelRegistry()
        let service = try BackendWorkspaceService(userData: temp.sub("data"), git: git, ownership: .exclusive)
        let channels = try await BackendWorkspaceChannels.register(registry: registry, ownerID: "s6c3", workspaces: service,
            liveFolders: { opened.liveFolders }, openFolder: { path in opened.add(path); return "" })
        return Wire(temp: temp, git: git, registry: registry, service: service, opened: opened, channels: channels)
    }
    private func repository(_ w: Wire) async throws -> String {
        let repo = try await S6C3WS.repository(w.git, at: w.temp.sub("repo")); return repo
    }
    private func call(_ w: Wire, _ channel: String, _ args: NativeRPCValue..., caller: NativeRPCContext.Caller = .nativeApp) async throws -> NativeRPCValue {
        try await w.registry.invoke(channel, context: NativeRPCContext(caller: caller, ownerID: "main-window"), arguments: args)
    }

    func testRegistersTheThreeChannelsThePreloadCalls() async throws {
        let w = try await wire()
        XCTAssertEqual(w.channels.sorted(), ["tasks:workspace", "tasks:workspace-open", "tasks:workspace-remove"])
        let registered = await w.registry.channels(); XCTAssertEqual(registered, ["tasks:workspace", "tasks:workspace-open", "tasks:workspace-remove"])
    }
    func testAnswersOnlyTheAppsOwnWindow() async throws {
        let w = try await wire()
        for channel in w.channels {
            for caller in [NativeRPCContext.Caller.page, .pairedDevice] {
                do { _ = try await call(w, channel, .string("local:a"), caller: caller); XCTFail("\(channel) answered \(caller)") }
                catch let error as NativeRPCError { XCTAssertEqual(error.code, "access-denied"); XCTAssertTrue(error.message.contains("own window")) }
            }
        }
    }
    func testShowsOpensAndRemovesATasksWorkspaceWhenClean() async throws {
        let w = try await wire(); let repo = try await repository(w)
        let found = try await w.service.folderFor(taskID: "local:a", project: repo, useWorkspace: true, title: "Wired", context: S6C3WS.context)
        let folder = try XCTUnwrap(found)
        let view = try await call(w, "tasks:workspace", .string("local:a"))
        XCTAssertEqual(view["workspace"]["folder"].string, folder); XCTAssertEqual(view["workspace"]["state"].string, "active")
        let opened = try await call(w, "tasks:workspace-open", .string("local:a"))
        XCTAssertEqual(opened, .object([.init("ok", .bool(true))])); XCTAssertEqual(w.opened.all, [folder])
        let removed = try await call(w, "tasks:workspace-remove", .string("local:a"))
        XCTAssertEqual(removed["ok"].bool, true); XCTAssertFalse(S6C3WS.exists(folder))
        let reopened = try await call(w, "tasks:workspace-open", .string("local:a"))
        XCTAssertEqual(reopened, .object([.init("ok", .bool(false)), .init("error", .string("This task has no workspace folder to open."))]))
        XCTAssertEqual(w.opened.all, [folder])
    }
    func testNeverRemovesAWorkspaceARunningSessionIsIn() async throws {
        let w = try await wire(); let repo = try await repository(w)
        let found = try await w.service.folderFor(taskID: "local:a", project: repo, useWorkspace: true, title: "Busy", context: S6C3WS.context)
        let folder = try XCTUnwrap(found); w.opened.setLive([folder])
        let outcome = try await call(w, "tasks:workspace-remove", .string("local:a"))
        XCTAssertEqual(outcome["ok"].bool, false); XCTAssertTrue(S6C3WS.exists(folder))
    }
    func testTakesATaskIdAndNothingElse() async throws {
        let w = try await wire()
        let view = try await call(w, "tasks:workspace", .object([.init("path", .string("/"))]))
        XCTAssertEqual(view, .object([.init("workspace", .null), .init("refusal", .null)]))
        let open = try await call(w, "tasks:workspace-open", .string("/")); XCTAssertEqual(open["ok"].bool, false)
        let removal = try await call(w, "tasks:workspace-remove", .number(42)); XCTAssertEqual(removal["ok"].bool, false)
        XCTAssertEqual(w.opened.all, [])
    }
}
