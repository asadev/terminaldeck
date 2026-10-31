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
    private var measured: [String: String] { ["HOME": "/Users/me", "SHELL": "/bin/zsh", "TERM": "xterm-256color", "CLAUDECODE": "1", "CLAUDE_CODE_SESSION_ID": "parent-run", "CLAUDE_CODE_CHILD_SESSION": "1", "CLAUDE_EFFORT": "xhigh", "CLAUDE_PID": "3227", "CLAUDE_CONFIG_DIR": "/Users/me/Library/Application Support/terminaldeck/profiles/me-example-com", "TERMINALDECK_SESSION_ID": "their-session", "TERMINALDECK_ACCOUNT_TICKET": "secret-ticket", "TERMINALDECK_ACCOUNT_VAULT": "/Users/me/Library/Application Support/terminaldeck/account-vault/vault.sock", "ANTHROPIC_BASE_URL": "https://example.invalid", "PATH": "/Users/me/Library/Application Support/terminaldeck/account-vault-shim:/Users/me/Library/Application Support/terminaldeck/shim:/Users/me/.local/bin:/Users/me/tools/shim:/Users/me/Library/Application Support/Native Proof/engine/shim:/usr/bin"] }
    @MainActor func testNativeMode214NoApproverRefusesWithoutOpeningDialog() async {
        let consent = BackendPluginsBrokerConsent(broker: BackendDeckCoreSecurityConsentBroker(ask: { _ in false }))
        let result = await consent.ask(.init(id: "test", name: "test", version: "1.0.0", hash: "x", capabilities: [], projects: [], tools: [], message: "Let the plugin read files?", detail: "It asked to."))
        XCTAssertFalse(result.granted); XCTAssertEqual(result.reason, "no-approver"); await consent.shutdown()
    }
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
}
