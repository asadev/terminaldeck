import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// HOOTFIX 2026-10-09: Asad's installed 0.20.2-local refused every Hoot send with
/// "Hoot defaults are awaiting integration." (the app root dropped readyDefaults
/// while copying Hoot's inputs) and "... the original authorized profile-read
/// context has not been fully connected." (window channels outside the sessions
/// area reached the HOST profile view with no scope). Both must stay fixed.
final class HOOTFIXRegressionTests: XCTestCase {
    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HOOTFIX-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }

    /// Ready defaults are ON for every first-run user: no flag, no setup.
    func testReadyDefaultsAreEnabledByDefaultWithoutAnyFlag() async throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(HootReadyDefaults.enabled([:]))
        XCTAssertTrue(HootReadyDefaults.enabled(ProcessInfo.processInfo.environment.filter { $0.key != "TD_HOOT_DISABLED" }))
        let claude = BackendAccountProfile(id: "system:claude", name: "Claude", provider: "claude", configDir: "/scratch/claude",
                                           system: true, color: "#000000", createdAt: 0)
        // No `enabled:` argument: exactly how production composition constructs it.
        let defaults = BackendHootReadyDefaults(settings: BackendAppSettingsStore(userData: root, writable: true),
            profiles: { provider, _ in provider == .claude ? [claude] : [] }, available: { $0 == .claude },
            signedIn: { _, _ in true })
        do {
            let selected = try await defaults.read(projectPath: root.path)
            XCTAssertTrue(selected.ready); XCTAssertEqual(selected.provider, .claude); XCTAssertEqual(selected.profile?.id, claude.id)
        } catch { XCTFail("first-run Hoot defaults refused: \(error.localizedDescription)") }
    }

    #if TD_HOST_ACCOUNT_BRIDGE
    /// Every registry-dispatched channel (Hoot, accounts, settings…) carries its
    /// own authenticated dispatcher context into the HOST profile reads.
    func testRegistryDispatchBindsTheOriginalProfileReadContext() async throws {
        let registry = NativeChannelRegistry()
        let owner = "hootfix-test"
        try await registry.register("hootfix:read", ownerID: owner) { _, _ in
            let current = try BackendHOSTProfileScope.requireCurrent()
            return .object([.init("request", .string(current.requestID.uuidString)), .init("owner", .string(current.ownerID))])
        }
        let request = UUID()
        let context = NativeRPCContext(caller: .nativeApp, ownerID: BackendCompositionRoot.appOwnerID, requestID: request)
        let answer = try await registry.invoke("hootfix:read", context: context, arguments: [])
        XCTAssertEqual(answer["request"].string, request.uuidString)
        XCTAssertEqual(answer["owner"].string, BackendCompositionRoot.appOwnerID)

        // A send listener is the same: its own request context, never a default.
        let seen = Seen()
        let subscription = try await registry.onSend("hootfix:send", ownerID: owner) { _, _ in
            await seen.set(try BackendHOSTProfileScope.requireCurrent().requestID)
        }
        defer { subscription.cancel() }
        let sendID = UUID()
        _ = try await registry.send("hootfix:send", context: .init(caller: .nativeApp, ownerID: BackendCompositionRoot.appOwnerID, requestID: sendID), arguments: [])
        let observed = await seen.value
        XCTAssertEqual(observed, sendID)
    }

    /// An explicit scope still wins, and with neither scope nothing is minted.
    func testExplicitScopeWinsAndMissingScopeStillRefuses() async throws {
        XCTAssertThrowsError(try BackendHOSTProfileScope.requireCurrent())
        let outer = NativeRPCContext(caller: .nativeApp, ownerID: "outer"), inner = NativeRPCContext(caller: .nativeApp, ownerID: "inner")
        let chosen = try await NativeCompositionCallContext.$rpc.withValue(outer) {
            try await BackendHOSTProfileScope.withContext(inner) { try BackendHOSTProfileScope.requireCurrent().ownerID }
        }
        XCTAssertEqual(chosen, "inner")
        let dispatcher = try NativeCompositionCallContext.$rpc.withValue(outer) { try BackendHOSTProfileScope.requireCurrent().ownerID }
        XCTAssertEqual(dispatcher, "outer")
    }
    private actor Seen { var value: UUID?; func set(_ id: UUID) { value = id } }
    #endif
}
