import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendOSTestPortManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable () -> Void)?
    private(set) var timeout: Duration?
    func schedule(_ duration: Duration, _ fire: @escaping @Sendable () -> Void) -> BackendOSTimer {
        lock.withLock { timeout = duration; callback = fire }
        return .init { [weak self] in self?.lock.withLock { self?.callback = nil } }
    }
    func fire() { let action = lock.withLock { let action = callback; callback = nil; return action }; action?() }
}

final class BackendOSTestPortNativeGlue: BackendOSTestPortFixture {
    private func scrub(_ source: [String: String]) -> BackendOSInheritedEnvironment.Scrubbed {
        BackendOSInheritedEnvironment.scrub(source, ownUserData: "/Users/me/Library/Application Support/Native Proof/engine", isAppDataDirectory: { ["/Users/me/Library/Application Support/terminaldeck", "/Users/me/Library/Application Support/Native Proof/engine"].contains($0) })
    }
    private var measured: [String: String] { ["HOME": "/Users/me", "SHELL": "/bin/zsh", "TERM": "xterm-256color", "CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "parent-run", "CLAUDE_CODE_CHILD_SESSION": "1", "CLAUDE_EFFORT": "xhigh", "CLAUDE_PID": "3227", "CLAUDE_CONFIG_DIR": "/Users/me/Library/Application Support/terminaldeck/profiles/me-example-com", "TERMINALDECK_SESSION_ID": "their-session", "TERMINALDECK_ACCOUNT_TICKET": "secret-ticket", "TERMINALDECK_ACCOUNT_VAULT": "/Users/me/Library/Application Support/terminaldeck/account-vault/vault.sock", "ANTHROPIC_BASE_URL": "https://example.invalid", "PATH": "/Users/me/Library/Application Support/terminaldeck/account-vault-shim:/Users/me/Library/Application Support/terminaldeck/shim:/Users/me/.local/bin:/Users/me/tools/shim:/Users/me/Library/Application Support/Native Proof/engine/shim:/usr/bin"] }
    func testNativeMode57ParentRunAndTicketRemovedNamesOnly() {
        let answer = scrub(measured)
        for key in ["CLAUDECODE", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_EFFORT", "CLAUDE_PID", "CLAUDE_CONFIG_DIR", "TERMINALDECK_SESSION_ID", "TERMINALDECK_ACCOUNT_TICKET", "TERMINALDECK_ACCOUNT_VAULT"] { XCTAssertNil(answer.environment[key]); XCTAssertTrue(answer.removed.contains(key)) }
        XCTAssertEqual(answer.environment["ANTHROPIC_BASE_URL"], "https://example.invalid"); XCTAssertEqual(answer.environment["HOME"], "/Users/me"); XCTAssertFalse(answer.removed.joined(separator: " ").contains("secret-ticket"))
    }
    func testNativeMode80OtherShimsRemovedOursRetained() { XCTAssertEqual(scrub(measured).environment["PATH"]?.components(separatedBy: ":"), ["/Users/me/.local/bin", "/Users/me/tools/shim", "/Users/me/Library/Application Support/Native Proof/engine/shim", "/usr/bin"]) }
    func testNativeMode90StandingConfigKeptWithoutParent() { let answer = scrub(["HOME": "/Users/me", "CLAUDE_CONFIG_DIR": "/Users/me/.claude-work", "PATH": "/usr/bin"]); XCTAssertEqual(answer.environment["CLAUDE_CONFIG_DIR"], "/Users/me/.claude-work"); XCTAssertEqual(answer.removed, []) }
    @MainActor func testNativeMode100DialogsFrontAndNullParentRemoved() async throws {
        var calls: [[NativeRPCValue]] = [], fronted = 0
        let open: NativeRPCValue = .object([.init("title", .string("Add files"))]), box: NativeRPCValue = .object([.init("message", .string("Allow?"))]), parent: NativeRPCValue = .object([.init("window", .bool(true))]), save: NativeRPCValue = .object([.init("title", .string("Save"))])
        _ = try await BackendOSFrontedDialogs.call("showOpenDialog", arguments: [.null, open], front: { fronted += 1 }) { args in calls.append([.string("open")] + args); return .object([.init("canceled", .bool(true)), .init("filePaths", .array([]))]) }
        _ = try await BackendOSFrontedDialogs.call("showMessageBox", arguments: [box], front: { fronted += 1 }) { args in calls.append([.string("box")] + args); return .object([.init("response", .number(1))]) }
        _ = try await BackendOSFrontedDialogs.call("showSaveDialog", arguments: [parent, save], front: { fronted += 1 }) { args in calls.append([.string("save")] + args); return .object([.init("canceled", .bool(true))]) }
        XCTAssertEqual(fronted, 3); XCTAssertEqual(calls, [[.string("open"), open], [.string("box"), box], [.string("save"), parent, save]])
    }
    @MainActor func testNativeMode130FrontFailureStillCallsDialog() async throws {
        let expected: NativeRPCValue = .object([.init("message", .string("x"))])
        let result = try await BackendOSFrontedDialogs.call("showMessageBox", arguments: [expected], front: { throw NativeRPCError(code: "test", message: "no focus today") }) { $0[0] }
        XCTAssertEqual(result, expected)
    }
    func testNativeMode182PlainMachineNameOutsidePreview() { XCTAssertEqual(BackendOSNativeMode.machineName("mac-mini", preview: false), "mac-mini") }
    func testNativeMode188NativePreviewMachineSuffix() { XCTAssertEqual(BackendOSNativeMode.machineName("mac-mini", preview: true), "mac-mini (native)") }
    @MainActor func testNativeMode214NoApproverRefusesWithoutOpeningDialog() async {
        let consent = BackendPluginsNativeConsent(window: { nil })
        let result = await consent.ask(.init(id: "test", name: "test", version: "1.0.0", hash: "x", capabilities: [], projects: [], tools: [], message: "Let the plugin read files?", detail: "It asked to."))
        XCTAssertFalse(result.granted); XCTAssertEqual(result.reason, "no-approver"); await consent.shutdown()
    }
    func testNativeMode287HydratesOnlyFirstClient() async {
        actor Count { var count = 0; func add() { count += 1 }; func value() -> Int { count } }
        let count = Count(), hydration = BackendOSHydration()
        for _ in 0..<3 { await hydration.firstClient { await count.add() } }; let value = await count.value(); XCTAssertEqual(value, 1)
    }
    func testNativeRegistry125FlagExact() {
        XCTAssertTrue(BackendOSNativeMode.enabled(arguments: ["/Electron", "/repo", "--native-shell", "--user-data-dir=/x"]))
        XCTAssertFalse(BackendOSNativeMode.enabled(arguments: ["/Electron", "/repo"])); XCTAssertFalse(BackendOSNativeMode.enabled(arguments: ["/Electron", "/repo", "--native-shell=1"]))
    }
    func testNativeRegistry131ExactLegacyViewRefusals() { XCTAssertEqual(BackendOSNativeMode.refusedChannels.keys.sorted(), ["browser-view:claim", "browser:create"]); for sentence in BackendOSNativeMode.refusedChannels.values { XCTAssertTrue(sentence.contains("native shell")) } }
    func testRemoteNative98PreviewNameOfItsOwn() { XCTAssertTrue(BackendOSNativeMode.machineName("mac-mini", preview: true).hasSuffix(" (native)")) }
}

@MainActor
final class BackendOSTestPortNotifier: XCTestCase {
    final class Banner: BackendOSBanner {
        var shown = 0, closedCount = 0; var onClick: (@MainActor () -> Void)?, onClose: (@MainActor () -> Void)?
        func show() { shown += 1 }; func close() { closedCount += 1; onClose?() }
        func clicked(_ callback: @escaping @MainActor () -> Void) { onClick = callback }
        func closed(_ callback: @escaping @MainActor () -> Void) { onClose = callback }
    }
    final class Factory: BackendOSBannerFactory {
        let supported: Bool; var banners: [Banner] = []
        init(_ supported: Bool = true) { self.supported = supported }
        func make(title: String, body: String, silent: Bool) -> any BackendOSBanner { let banner = Banner(); banners.append(banner); return banner }
    }
    func testNativeMode254ShowsClicksAndClosesByID() throws {
        let factory = Factory(); var pushed: [(String, [NativeRPCValue])] = []
        let notifier = BackendOSNativeNotifier(factory: factory) { pushed.append(($0, $1)) }
        XCTAssertEqual(try notifier.notify(.object([.init("id", .string("n1")), .init("title", .string("Session finished")), .init("body", .string("deck"))])), .object([.init("shown", .bool(true))]))
        XCTAssertEqual(factory.banners[0].shown, 1); factory.banners[0].onClick?(); XCTAssertEqual(pushed.first?.0, "native-shell:notification-click"); XCTAssertEqual(pushed.first?.1, [.string("n1")])
        _ = try notifier.notify(.object([.init("id", .string("n2")), .init("title", .string("Needs you"))])); notifier.close(.string("n2")); XCTAssertEqual(factory.banners[1].closedCount, 1)
    }
    func testNativeMode275MissingTitleIDOrOSSupportShowsNothing() throws {
        let unsupported = BackendOSNativeNotifier(factory: Factory(false)) { _, _ in }
        XCTAssertEqual(try unsupported.notify(.object([.init("id", .string("n1")), .init("title", .string("x"))])), .object([.init("shown", .bool(false))]))
        let supported = BackendOSNativeNotifier(factory: Factory()) { _, _ in }
        XCTAssertEqual(try supported.notify(.object([.init("title", .string("x"))])), .object([.init("shown", .bool(false))])); XCTAssertEqual(try supported.notify(.string("junk")), .object([.init("shown", .bool(false))]))
    }
}

@MainActor
final class BackendOSTestPortTeardown: XCTestCase {
    func testTeardown35ManyOwnersOneKeyedRegistry() { let registry = BackendOSTeardowns(); for key in ["plan-limit", "cost", "mcp", "git-watch", "file-search"] { registry.on(owner: "window", key: key) {} }; XCTAssertEqual(registry.pending(owner: "window"), ["cost", "file-search", "git-watch", "mcp", "plan-limit"]) }
    func testTeardown54RepeatedKeyStaysOne() { let registry = BackendOSTeardowns(); for _ in 0..<50 { registry.on(owner: "window", key: "plan-limit") {} }; XCTAssertEqual(registry.pending(owner: "window"), ["plan-limit"]) }
    func testTeardown69LatestCallbackWins() { let registry = BackendOSTeardowns(); var first = 0, second = 0; registry.on(owner: "window", key: "cost") { first += 1 }; registry.on(owner: "window", key: "cost") { second += 1 }; registry.destroy(owner: "window"); XCTAssertEqual(first, 0); XCTAssertEqual(second, 1) }
    func testTeardown82RunsAllAndForgets() { let registry = BackendOSTeardowns(); var plan = 0, cost = 0; registry.on(owner: "window", key: "plan-limit") { plan += 1 }; registry.on(owner: "window", key: "cost") { cost += 1 }; registry.destroy(owner: "window"); XCTAssertEqual(plan, 1); XCTAssertEqual(cost, 1); XCTAssertEqual(registry.pending(owner: "window"), []) }
    func testTeardown96OwnersStaySeparate() { let registry = BackendOSTeardowns(); var a = 0, b = 0; registry.on(owner: "a", key: "cost") { a += 1 }; registry.on(owner: "b", key: "cost") { b += 1 }; registry.destroy(owner: "a"); XCTAssertEqual(a, 1); XCTAssertEqual(b, 0) }
    func testTeardown112DeadOwnerImmediate() { let registry = BackendOSTeardowns(); registry.destroy(owner: "window"); var called = 0; registry.on(owner: "window", key: "cost") { called += 1 }; XCTAssertEqual(called, 1); XCTAssertEqual(registry.pending(owner: "window"), []) }
    func testTeardown125ThrowIsReportedOthersRun() { var reports = 0, after = 0; let registry = BackendOSTeardowns { _ in reports += 1 }; registry.on(owner: "window", key: "throws") { throw NativeRPCError(code: "test", message: "teardown went wrong") }; registry.on(owner: "window", key: "after") { after += 1 }; registry.destroy(owner: "window"); XCTAssertEqual(after, 1); XCTAssertEqual(reports, 1) }
    func testTeardown143UnregisterDuringTeardownDoesNotSkipCopy() { let registry = BackendOSTeardowns(); var sibling = 0; registry.on(owner: "window", key: "first") { registry.off(owner: "window", key: "sibling") }; registry.on(owner: "window", key: "sibling") { sibling += 1 }; registry.destroy(owner: "window"); XCTAssertEqual(sibling, 1) }
    func testTeardown157EarlyUnregisterKeepsOtherOwner() { let registry = BackendOSTeardowns(); var gone = 0, remaining = 0; registry.on(owner: "window", key: "gone") { gone += 1 }; registry.on(owner: "window", key: "remaining") { remaining += 1 }; registry.off(owner: "window", key: "gone"); registry.destroy(owner: "window"); XCTAssertEqual(gone, 0); XCTAssertEqual(remaining, 1) }
}
