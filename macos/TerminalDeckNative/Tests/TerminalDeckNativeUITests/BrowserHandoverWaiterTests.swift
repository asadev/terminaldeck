import Foundation
import XCTest
@testable import TerminalDeckNative
import TerminalDeckBackend
import TerminalDeckNativeCore

/// The agent's handover loop: browser_handover answers "still-waiting", the agent asks again,
/// then the person presses Carry on. An isolated, never-loaded tab; no engine, no saved pages.
@MainActor
final class BrowserHandoverWaiterTests: XCTestCase {
    func testSecondCallKeepsItsWaiterAndCarryOnResumes() async throws {
        let tabs = NativeBrowserTabs.shared, map = BackendBrowserBindings()
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("td-handover-\(UUID().uuidString)")
        let runtime = NativeSafariRuntime(tabs: tabs, bindings: map, dataRoot: scratch, screenshotDirectory: scratch,
                                          browserData: { _, _ in NSNull() }, authorizePopup: { _, _, _ in }, publish: { _, _ in })
        let tab = tabs.create(isolated: true, show: false)
        defer { tabs.close(tab.id) }
        map.observe(.init(tabID: tab.id, viewID: tab.id))
        _ = try map.attach(tab.id, to: BrowserDriverSession(sessionId: "agent"))
        let first = Task { await runtime.handOver(tab.id, prompt: "Sign in, please.", windowMs: 10_000) }
        for _ in 0..<500 where tab.handoverWaiter == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(tab.handoverWaiter)
        let second = Task { await runtime.handOver(tab.id, prompt: "Sign in, please.", windowMs: 10_000) }
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, "still-waiting")
        tab.endHandover("resumed") // Carry on, only after the first call has fully returned.
        let secondOutcome = await second.value
        XCTAssertEqual(secondOutcome, "resumed")
        XCTAssertNotNil(map.owner(of: tab.id), "Carry on must keep the agent's window attached.")
    }
}
