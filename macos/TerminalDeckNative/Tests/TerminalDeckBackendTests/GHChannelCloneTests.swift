import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

private actor GHChannelFake: BackendGHWorkspaceServing {
    var calls = 0
    func perform(operation: String, arguments: NativeRPCValue) async throws -> NativeRPCValue {
        calls += 1; return .object([.init("ok", .bool(true))])
    }
    func count() -> Int { calls }
}
private actor GHCloneTools: BackendGitHubToolRunning {
    struct Call: Sendable { let arguments: [String]; let environment: [String: String] }
    var calls: [Call] = []
    func run(tool: String, arguments: [String], cwd: String?, environment: [String: String], timeoutMilliseconds: Int, maximumBytes: Int) async throws -> BackendGitOutcome {
        calls.append(.init(arguments: arguments, environment: environment))
        return .init(ok: true, stdout: "", stderr: "", missing: false, exitCode: 0, timedOut: false)
    }
    func captured() -> [Call] { calls }
}
@MainActor
final class GHChannelCloneTests: XCTestCase {
    private func request(_ operation: String, approved: Bool = false) -> NativeRPCValue {
        .object([.init("operation", .string(operation)), .init("arguments", .object([])), .init("approved", .bool(approved))])
    }
    func testAllWritesRefusedWithoutConfirmationBeforeService() async throws {
        let service = GHChannelFake(), registry = NativeChannelRegistry()
        try await BackendGHChannels.register(registry: registry, ownerID: "gh", service: service)
        for operation in BackendGHOperation.allCases where operation.isWrite {
            do {
                _ = try await registry.invoke(BackendGHChannels.channel, context: .init(caller: .nativeApp, ownerID: "test"), arguments: [request(operation.rawValue)])
                XCTFail("Unconfirmed write ran: \(operation)")
            } catch let error as NativeRPCError { XCTAssertEqual(error.code, "approval-required") }
        }
        let count = await service.count(); XCTAssertEqual(count, 0)
    }
    func testReadAndConfirmedWriteReachService() async throws {
        let service = GHChannelFake(), registry = NativeChannelRegistry()
        try await BackendGHChannels.register(registry: registry, ownerID: "gh", service: service)
        _ = try await registry.invoke(BackendGHChannels.channel, context: .init(caller: .nativeApp, ownerID: "test"), arguments: [request("repos.list")])
        _ = try await registry.invoke(BackendGHChannels.channel, context: .init(caller: .nativeApp, ownerID: "test"), arguments: [request("issues.create", approved: true)])
        let count = await service.count(); XCTAssertEqual(count, 2)
    }
    func testPageDeviceAndEngineCannotClaimNativeApproval() async throws {
        let service = GHChannelFake(), registry = NativeChannelRegistry()
        try await BackendGHChannels.register(registry: registry, ownerID: "gh", service: service)
        for caller in [NativeRPCContext.Caller.page, .pairedDevice, .internalEngine] {
            do {
                _ = try await registry.invoke(BackendGHChannels.channel, context: .init(caller: caller, ownerID: "test"), arguments: [request("issues.create", approved: true)])
                XCTFail("Non-native caller reached GitHub")
            } catch let error as NativeRPCError { XCTAssertEqual(error.code, "access-denied") }
        }
        let count = await service.count(); XCTAssertEqual(count, 0)
    }
    func testUnknownOperationIsNeverForwarded() async throws {
        let service = GHChannelFake(), registry = NativeChannelRegistry()
        try await BackendGHChannels.register(registry: registry, ownerID: "gh", service: service)
        do {
            _ = try await registry.invoke(BackendGHChannels.channel, context: .init(caller: .nativeApp, ownerID: "test"), arguments: [request("unsafe.arbitrary", approved: true)])
            XCTFail("Unknown operation ran")
        } catch let error as NativeRPCError { XCTAssertEqual(error.code, "invalid-arguments") }
        let count = await service.count(); XCTAssertEqual(count, 0)
    }
    func testCloneKeepsCredentialsOutOfArgumentsAndIgnoresInheritedGitConfig() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("gh-clone-\(UUID())")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let tools = GHCloneTools(), token = "ghp_testCredentialOnly0123456789"
        let auth = try BackendGitHubAuthenticator(dataDirectory: parent, environment: ["GH_TOKEN": token], tools: tools, resolveRepo: { _ in .null })
        let clone = BackendGHCloneService(auth: auth, tools: tools,
            environment: ["HOME": parent.path, "GIT_TRACE": "1", "GIT_SSL_NO_VERIFY": "1", "GH_TOKEN": token, "GIT_CONFIG_COUNT": "90"],
            addProject: { path in .string(path) })
        let result = try await clone.clone(.init(repo: "owner/repo", host: "github.com", parentPath: parent.path, directoryName: "copy", branch: "feature/safe"))
        XCTAssertEqual(result["projectAdded"].bool, true)
        let calls = await tools.captured(); XCTAssertEqual(calls.count, 1)
        XCTAssertFalse(calls[0].arguments.joined().contains(token))
        XCTAssertNil(calls[0].environment["GIT_TRACE"]); XCTAssertNil(calls[0].environment["GIT_SSL_NO_VERIFY"])
        XCTAssertNil(calls[0].environment["GH_TOKEN"])
        XCTAssertEqual(calls[0].environment["GIT_CONFIG_COUNT"], "9")
        XCTAssertEqual(calls[0].environment["GIT_CONFIG_VALUE_4"], "false")
        XCTAssertFalse(result.compact.contains(token))
    }
    func testCloneNeverTouchesExistingDestination() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("gh-clone-\(UUID())")
        let destination = parent.appendingPathComponent("copy")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let sentinel = destination.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        let tools = GHCloneTools()
        let auth = try BackendGitHubAuthenticator(dataDirectory: parent, environment: ["GH_TOKEN": "test-only-token"], tools: tools, resolveRepo: { _ in .null })
        let clone = BackendGHCloneService(auth: auth, tools: tools, environment: [:])
        do {
            _ = try await clone.clone(.init(repo: "owner/repo", host: "github.com", parentPath: parent.path, directoryName: "copy", branch: nil))
            XCTFail("Existing folder overwritten")
        } catch let error as NativeRPCError { XCTAssertEqual(error.code, "destination-unavailable") }
        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "keep")
        let calls = await tools.captured(); XCTAssertTrue(calls.isEmpty)
    }
}
