import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Mac 0.23.6 (Asad, 23 Nov: "Not in your Cloud yet from this Mac: API keys"): the saved-passwords engine read API
/// accounts with its own `.internalEngine` context, which the app's account authority refuses (only the app's own window
/// context or an AI call's ticket pass). Every look failed and was said as "not available just now". The app now hands
/// the service its own local context.
final class CloudKeysContext0236Tests: XCTestCase {
    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var callers: [NativeRPCContext.Caller] = []
        func add(_ caller: NativeRPCContext.Caller) { lock.withLock { callers.append(caller) } }
        var all: [NativeRPCContext.Caller] { lock.withLock { callers } }
    }

    func testAPIKeysAreReadWithTheContextTheAccountAuthorityTakes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("api-keys-0236-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = try BackendAccountConfiguration(dataDirectory: root.appendingPathComponent("data"), homeDirectory: root.appendingPathComponent("home"),
            appName: "API Account Fixture", appID: "terminaldeck", helperExecutable: URL(fileURLWithPath: "/usr/bin/true"), inheritedEnvironment: [:])
        let seen = Seen()
        // As `BackendCompositionAuthority.ticket` does: anything but the app's own context (or an AI call's ticket) is refused.
        let refuseOthers: @Sendable (NativeRPCContext) throws -> Void = { context in
            seen.add(context.caller)
            guard context.caller == .nativeApp else {
                throw NativeRPCError(code: "unavailable", message: "a current credential-resolved core call (caller \(context.caller))")
            }
        }
        let service = BackendAPIAccountService(configuration: configuration, access: .init(
            find: { _, context in try refuseOthers(context); return nil },
            list: { context in try refuseOthers(context); return [] },
            create: { _, _, _, _ in throw BackendAccountFailure("unused") },
            rename: { _, _, _ in throw BackendAccountFailure("unused") }, remove: { _, _ in .null }), authorizeMutation: { _ in })
        let store = BackendCloudKeysAPIStore(owner: service, stateRoot: nil, thisMac: { "Mac mini" })

        // Before: refused at every look (the Mac mini's log: "saving API keys did not finish" at every start since 18 Nov).
        do { _ = try await store.capture(); XCTFail("the engine's own context must be refused, as it was") } catch {}
        XCTAssertEqual(seen.all, [.internalEngine])

        // After: the app's own local context (what `NativeCompositionINT2HOSTManaged` sets) passes; nothing to send is
        // an empty list, not a failure.
        await service.useCloudCaller { NativeRPCContext(caller: .nativeApp, ownerID: "terminal-deck-app") }
        let records = try await store.capture()
        XCTAssertEqual(records.count, 0)
        XCTAssertEqual(seen.all, [.internalEngine, .nativeApp])
    }
}
