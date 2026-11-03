import AppKit
import SwiftUI
import XCTest
@testable import TerminalDeckNative

@MainActor final class NativeAccountVaultRecoveryViewTests: XCTestCase {
    func testMountReadsStatusWithoutRequestingKeychainPermission() async throws {
        var calls: [String] = []
        let view = NativeAccountVaultRecovery(store: .shared, invoke: { channel in
            calls.append(channel)
            return ["ready": true, "needsPermission": true, "detail": "Click Allow login store. If the Mac asks, choose Always Allow."]
        })
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 540, height: 120), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderBack(nil)
        defer { window.close() }
        hosting.layoutSubtreeIfNeeded()
        for _ in 0..<100 where calls.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(calls, ["profiles:vault-status"])
        // The real view must mount even before it knows that permission is needed.
        // No vault-recover invocation (and therefore no Keychain dialog) at mount.
    }
}
