import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private enum ChatBind21CatalogueScope { @TaskLocal static var active = false }
private struct ChatBind21ScopedSurface: BackendDeckCoreCatalogueSurface {
    func listSessions() -> [NativeRPCValue] { [] }
    func listProjects() -> [NativeRPCValue] { [.object([.init("path", .string("/scratch/work"))])] }
    func sessionStatus(_ id: String) -> NativeRPCValue { .null }
    func appStateRoot() -> String { "/scratch/data" }
    func copilotRoot() -> String { "/scratch/data/hoot" }
    func windows(sessionID: String) -> [NativeRPCValue] { [] }
    func readSettings() -> NativeRPCValue { .object([]) }
    func writeSpec(directory: String, input: NativeRPCValue) throws -> NativeRPCValue { XCTFail("No brief was requested"); return .null }
    var hasAsyncAccountChoices: Bool { true }
    func accountsForSessionStart() async throws -> [NativeRPCValue]? {
        XCTAssertTrue(ChatBind21CatalogueScope.active)
        return [.object([.init("id", .string("scratch")), .init("name", .string("Scratch")), .init("provider", .string("claude"))])]
    }
    func withSessionStartContext(_ context: BackendDeckCoreSecurityCallContext,
        operation: @escaping @Sendable () async throws -> BackendDeckCoreSecurityToolOutput) async throws -> BackendDeckCoreSecurityToolOutput {
        XCTAssertEqual(context.caller.keyID, "original-key")
        return try await ChatBind21CatalogueScope.$active.withValue(true) { try await operation() }
    }
    func startSession(input: NativeRPCValue, forDevice: String?) async throws -> NativeRPCValue {
        XCTAssertTrue(ChatBind21CatalogueScope.active); XCTAssertEqual(input["profileId"].string, "scratch")
        return .object([.init("id", .string("made")), .init("cwd", .string("/scratch/work")), .init("provider", .string("claude"))])
    }
}
final class ChatBind21CatalogueScopeTests: XCTestCase, @unchecked Sendable {
    func testCatalogueStartScopesBothAccountLookupAndTheRealLaunch() async throws {
        let native = BackendMCPCallContext(sessionID: "", machineID: "", projectRoot: nil, attended: false,
            allowedTools: ["sessions.start"], allowedTiers: [.read, .act], cancellation: BackendMCPCancellation())
        let context = BackendDeckCoreSecurityCallContext(native: native, caller: .init(kind: .key, tiers: [.read, .act], keyID: "original-key"),
            callID: "original-call", attended: false, granted: ["sessions.start"], sessionLimits: .object([]),
            now: { 0 }, startedByCopilot: { _ in false }, noteStarted: { _ in })
        let result = try await BackendDeckCoreCatalogueBuiltins.run(id: "sessions.start", arguments: .object([
            .init("cwd", .string("/scratch/work")), .init("provider", .string("claude")), .init("account", .string("scratch")), .init("mode", .string("chat"))]),
            context: context, surface: ChatBind21ScopedSurface())
        XCTAssertEqual(result.value["session"]["id"].string, "made")
        XCTAssertFalse(ChatBind21CatalogueScope.active)
    }
}
