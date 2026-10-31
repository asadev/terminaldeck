import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class ChatBind21ScopeTests: XCTestCase, @unchecked Sendable {
    private func context() -> BackendDeckCoreSecurityCallContext {
        let native = BackendMCPCallContext(sessionID: "scratch-session", machineID: "scratch-machine", projectRoot: "/scratch/work",
            attended: false, allowedTools: ["sessions.start"], allowedTiers: [.read, .act], cancellation: BackendMCPCancellation())
        return .init(native: native, caller: .init(kind: .key, tiers: [.read, .act], keyID: "scratch-key"),
            callID: "original-call", attended: false, granted: ["sessions.start"], sessionLimits: .object([]),
            now: { 123 }, startedByCopilot: { _ in false }, noteStarted: { _ in })
    }
    func testProfileScopeBridgeRetainsTheRealCallerGrantAndFolderAndRevokesItsChildAfterReturn() async throws {
        let owner = BackendDeckCoreToolContextAuthority(), original = context()
        let native = try await owner.withContext(original) { child in
            let actual = try await owner.context(for: child)
            XCTAssertEqual(actual.caller.kind, .key); XCTAssertEqual(actual.caller.keyID, "scratch-key")
            XCTAssertEqual(actual.granted, original.granted); XCTAssertEqual(actual.callID, "original-call")
            XCTAssertEqual(child.projectRoot, "/scratch/work"); XCTAssertEqual(child.allowedTiers, original.native.allowedTiers)
            XCTAssertFalse(child.cancellation === original.native.cancellation)
            return child
        }
        XCTAssertTrue(native.cancellation.isCancelled); XCTAssertFalse(original.cancellation.isCancelled)
        do { _ = try await owner.context(for: native); XCTFail("A completed request's profile scope stayed valid.") } catch {}
    }
    func testParentCancellationStillCancelsTheOriginalScopedRead() async throws {
        let owner = BackendDeckCoreToolContextAuthority(), original = context()
        try await owner.withContext(original) { child in
            original.cancellation.cancel()
            XCTAssertTrue(child.cancellation.isCancelled)
            do { _ = try await owner.context(for: child); XCTFail("Cancelled read kept its scope.") } catch {}
        }
    }
}
