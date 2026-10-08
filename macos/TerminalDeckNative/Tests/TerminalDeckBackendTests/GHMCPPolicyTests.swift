import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor
final class GHMCPPolicyTests: XCTestCase {
    private func folder() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("gh-mcp-policy-\(UUID())")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path
    }
    private func seed(_ operation: BackendGHOperation,
                      run: @escaping BackendDeckCoreSecurityToolPolicy.Handler = { _, _ in .init(value: .bool(true)) }) throws -> BackendDeckCoreSecurityToolPolicy {
        let entry = try XCTUnwrap(BackendGHMCPCatalogue.entries().first { $0.operation == operation })
        return .init(tool: try entry.specification(), aliases: ["legacy-test"], summary: { _, _ in "Seed summary" }, run: run)
    }
    private func args(_ body: Bool = true) -> NativeRPCValue {
        var values = NativeRPCValue.object([.init("repo", .string("sample/deck")), .init("number", .number(7))])
        if body { values = values.setting("body", .string("private proposed comment")) }
        return values
    }
    func testProjectLimitedKeyCannotReadTheGlobalGitHubInbox() async throws {
        let effects = BackendDeckCoreSecurityTestBox<Int>(0)
        let policy = try BackendGHMCPPolicy.decorate(seed(.notificationsList, run: { _, _ in
            effects.edit { $0 += 1 }; return .init(value: .bool(true))
        }), scopePrecheck: { _, _ in })
        let broker = BackendDeckCoreSecurityConsentBroker(ask: { _ in false })
        let control = try BackendDeckCoreSecurityControl(log: .init(directory: folder()), consent: broker, policies: [policy])
        let key = BackendDeckCoreSecurityCaller(kind: .key, tiers: [.read], keyID: "fixture", folders: ["/work/project"])
        let result = await control.call(name: policy.tool.id, arguments: .object([]), options: .init(caller: key))
        XCTAssertEqual(result.refusal, .notGranted)
        XCTAssertEqual(effects.get(), 0)
    }
    func testInvalidArgumentsAndScopeRefusalHappenBeforeTheCoreConsentPrompt() async throws {
        let asks = BackendDeckCoreSecurityTestBox<Int>(0), effects = BackendDeckCoreSecurityTestBox<Int>(0)
        let policy = try BackendGHMCPPolicy.decorate(seed(.pullsComment, run: { _, _ in effects.edit { $0 += 1 }; return .init(value: .bool(true)) }),
            scopePrecheck: { _, _ in throw BackendDeckCoreSecurityRefusal(.notGranted, "The project grant was revoked.") })
        let broker = BackendDeckCoreSecurityConsentBroker(ask: { _ in asks.edit { $0 += 1 }; return false })
        let control = try BackendDeckCoreSecurityControl(log: .init(directory: folder()), consent: broker, policies: [policy])
        let malformed = await control.call(name: policy.tool.id, arguments: args().setting("number", .number(0)))
        XCTAssertFalse(malformed.ok)
        let outside = await control.call(name: policy.tool.id, arguments: args())
        XCTAssertEqual(outside.refusal, .notGranted)
        XCTAssertEqual(asks.get(), 0); XCTAssertEqual(effects.get(), 0)
    }
    func testEveryWriteForcesPersonConsentDespiteStandingKeyApproval() async throws {
        let asks = BackendDeckCoreSecurityTestBox<Int>(0), effects = BackendDeckCoreSecurityTestBox<Int>(0)
        let policy = try BackendGHMCPPolicy.decorate(seed(.pullsComment, run: { _, _ in effects.edit { $0 += 1 }; return .init(value: .bool(true)) }))
        let broker = BackendDeckCoreSecurityConsentBroker(ask: { _ in asks.edit { $0 += 1 }; return false })
        let control = try BackendDeckCoreSecurityControl(log: .init(directory: folder()), consent: broker, policies: [policy])
        let key = BackendDeckCoreSecurityCaller(kind: .key, tiers: [.read, .alter], keyID: "fixture", keyName: "Fixture AI", askFirst: false)
        let result = await control.call(name: policy.tool.id, arguments: args(), options: .init(caller: key))
        XCTAssertFalse(result.ok); XCTAssertEqual(asks.get(), 1); XCTAssertEqual(effects.get(), 0)
        for operation in BackendGHOperation.allCases where operation.isWrite {
            let decorated = try BackendGHMCPPolicy.decorate(seed(operation))
            XCTAssertEqual(try decorated.ownerMustAnswer?(.object([])), true, operation.rawValue)
        }
    }
    func testCoreActionLogRedactsCommentBodyWhileKeepingTheExistingRunWrapper() async throws {
        let observed = BackendDeckCoreSecurityTestBox<String?>(nil)
        let policy = try BackendGHMCPPolicy.decorate(seed(.pullsComment, run: { input, context in
            observed.set(input["body"].string)
            return .init(value: .object([.init("owner", context.caller.wireValue)]), summary: .object([.init("changed", .number(1))]))
        }))
        XCTAssertEqual(policy.aliases, ["legacy-test"])
        let log = BackendDeckCoreSecurityActionLog(directory: try folder())
        // Unattended keys cannot bypass person consent; a declined row proves
        // central logging masks text even when the handler never runs.
        let control = try BackendDeckCoreSecurityControl(log: log, consent: .init(ask: { _ in false }), policies: [policy])
        _ = await control.call(name: policy.tool.id, arguments: args())
        let rows = await log.tail()
        XCTAssertEqual(rows.count, 1); XCTAssertFalse(rows[0].compact.contains("private proposed comment"))
        let native = BackendMCPCallContext(sessionID: "", machineID: "", projectRoot: nil, attended: true, allowedTools: [policy.tool.id], allowedTiers: [.read, .alter], cancellation: .init())
        let context = BackendDeckCoreSecurityCallContext(native: native, caller: .local, callID: "fixture", attended: true, granted: nil,
            sessionLimits: .missing, now: { 0 }, startedByCopilot: { _ in false }, noteStarted: { _ in })
        _ = try await policy.run(args(), context)
        XCTAssertEqual(observed.get(), "private proposed comment")
    }
    func testDefaultPolicyRefusesSessionAndRemoteAccessBeforeConsent() async throws {
        let asks = BackendDeckCoreSecurityTestBox<Int>(0)
        let policy = try BackendGHMCPPolicy.decorate(seed(.pullsComment))
        let control = try BackendDeckCoreSecurityControl(log: .init(directory: folder()), consent: .init(ask: { _ in asks.edit { $0 += 1 }; return false }), policies: [policy])
        for kind in [BackendDeckCoreSecurityCaller.Kind.session, .remote] {
            let caller = BackendDeckCoreSecurityCaller(kind: kind, tiers: [.read, .alter], sessionID: "fixture", projectRoot: "/work/deck")
            let result = await control.call(name: policy.tool.id, arguments: args().setting("projectPath", .string("/work/deck")), options: .init(caller: caller))
            XCTAssertEqual(result.refusal, .notGranted)
        }
        XCTAssertEqual(asks.get(), 0)
    }
}
