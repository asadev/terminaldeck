import AppKit
import SwiftUI
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor final class HotfixPinsAccountTests: XCTestCase {
    private func scratch(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "dev.terminaldeck.hotfix-pins-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    func testPinsFollowStableTabsAcrossTwoKeeperRestartsAndUnpinPersists() throws {
        try scratch { defaults in
            let first = SIDEBARPins(defaults: defaults)
            first.observe(["id": "process-one", "tabKey": "stable-tab"])
            first.toggle("process-one")
            XCTAssertEqual(defaults.stringArray(forKey: SIDEBARPins.stableKey), ["stable-tab"])
            let second = SIDEBARPins(defaults: defaults)
            second.observe(["id": "process-two", "tabKey": "stable-tab"])
            XCTAssertTrue(second.isPinned("process-two"))
            XCTAssertEqual(second.ids, ["process-two"])
            let third = SIDEBARPins(defaults: defaults)
            third.observe(["id": "process-three", "tabKey": "stable-tab"])
            third.toggle("process-three")
            XCTAssertFalse(SIDEBARPins(defaults: defaults).isPinned("stable-tab"))
            XCTAssertEqual(defaults.stringArray(forKey: SIDEBARPins.stableKey), [])
        }
    }

    func testLegacyPinsMigrateExactlyWithoutDroppingUnresolvedPinsOrOrder() throws {
        try scratch { defaults in
            defaults.set(["old-a", "unresolved", "old-b"], forKey: SIDEBARPins.key)
            let pins = SIDEBARPins(defaults: defaults)
            pins.observe(["id": "old-b", "tabKey": "tab-b"])
            pins.observe(["id": "old-a", "tabKey": "tab-a"])
            pins.observe(["id": "unrelated", "tabKey": "unrelated-tab"])
            pins.observe(["id": "unresolved", "tabKey": ""])
            XCTAssertEqual(defaults.stringArray(forKey: SIDEBARPins.stableKey), ["tab-a", "unresolved", "tab-b"])
            // Keep the old preference untouched as recovery evidence.
            XCTAssertEqual(defaults.stringArray(forKey: SIDEBARPins.key), ["old-a", "unresolved", "old-b"])
            let reopened = SIDEBARPins(defaults: defaults)
            reopened.observe(["id": "new-b", "tabKey": "tab-b"])
            reopened.observe(["id": "new-a", "tabKey": "tab-a"])
            XCTAssertEqual(reopened.ids, ["new-a", "unresolved", "new-b"])
            XCTAssertFalse(reopened.isPinned("unrelated"))
        }
    }

    func testLateMetadataMigratesAPinAndDuplicateEventsDoNotDuplicateIt() throws {
        try scratch { defaults in
            let pins = SIDEBARPins(defaults: defaults)
            pins.toggle("process")
            pins.observe(["id": "process", "tabKey": "tab"])
            pins.observe(["id": "process", "tabKey": "tab"])
            XCTAssertEqual(defaults.stringArray(forKey: SIDEBARPins.stableKey), ["tab"])
            pins.toggle("process")
            XCTAssertFalse(pins.isPinned("process"))
        }
    }

    func testAccountReplacementKeepsTheStablePinThroughTheNextRestart() throws {
        try scratch { defaults in
            let pins = SIDEBARPins(defaults: defaults)
            pins.observe(["id": "before-switch", "tabKey": "conversation-tab"])
            pins.toggle("before-switch")
            pins.replaced("before-switch", with: "after-switch")
            pins.observe(["id": "after-switch", "tabKey": "conversation-tab"])
            XCTAssertTrue(pins.isPinned("after-switch"))
            XCTAssertEqual(defaults.stringArray(forKey: SIDEBARPins.stableKey), ["conversation-tab"])
            let reopened = SIDEBARPins(defaults: defaults)
            reopened.observe(["id": "after-reboot", "tabKey": "conversation-tab"])
            XCTAssertTrue(reopened.isPinned("after-reboot"))
        }
    }

    func testAccountReplyOpensItsRowBeforeSelectionEvenWhenCreatedEventIsDelayed() async {
        let id = "11111111-1111-4111-8111-111111111111"
        let buttons = NativeButtonActions(effects: .init(invoke: { _, _ in NSNull() }, presentSession: { _ in }, confirm: { _ in true }))
        var selection: Task<Bool, Never>?
        XCTAssertTrue(NativeAccountSwitcher.openCreatedSession(["id": id, "cwd": "/scratch/project", "provider": "claude"],
            created: buttons.created, select: { selection = buttons.run(.selectTab($0)) }))
        let success = await selection?.value
        XCTAssertEqual(success, true)
        XCTAssertEqual(buttons.tabs.activeID, id)
        XCTAssertNil(buttons.problem)
        buttons.created(["id": id, "cwd": "/scratch/project"])
        XCTAssertEqual(buttons.tabs.tabs.filter { $0.id == id }.count, 1)
    }

    func testBadAccountReplyDoesNotSelectOrInventASession() {
        let replies: [Any] = [NSNull(), ["id": ""], ["id": "not-a-session"], ["cwd": "/scratch"]]
        for raw in replies {
            XCTAssertFalse(NativeAccountSwitcher.openCreatedSession(raw, created: { _ in XCTFail() }, select: { _ in XCTFail() }))
        }
    }

    func testShellInstructionsSayWhatChangesAndHowToSignIn() {
        let words = NativeLocalAccountChip.shellAccountHelp
        XCTAssertTrue(words.contains("type /login"))
        XCTAssertTrue(words.contains("opens a new session"))
        XCTAssertTrue(words.contains("this shell stays open"))
    }

    func testRenderShellAccountExplanationAtBothMenuWidthsAndThemes() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = try XCTUnwrap(ProcessInfo.processInfo.environment["TD_HOTFIX_PINS_FRAMES"])
        try FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)
        for width in [CGFloat(260), CGFloat(420)] {
            for (scheme, name) in [(ColorScheme.light, "light"), (.dark, "dark")] {
                let view = VStack(alignment: .leading, spacing: 2) {
                    NativeLocalAccountChip.shellAccountInstructions
                    AccountRowLine(current: false, color: nil, provider: "claude", login: "New session · example@example.com", state: "Signed in")
                    AccountRowLine(current: false, color: nil, provider: "codex", login: "New session · Work", state: "Signed in")
                }.padding(6).frame(width: width).background(DeckTokens.frame).environment(\.colorScheme, scheme)
                let host = NSHostingView(rootView: view)
                host.sizingOptions = []
                host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                host.frame = NSRect(origin: .zero, size: CGSize(width: width, height: 220))
                host.layoutSubtreeIfNeeded()
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.appearance?.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: rep) }
                let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: output).appendingPathComponent("shell-account-\(name)-\(Int(width)).png"))
                XCTAssertGreaterThan(data.count, 1000)
            }
        }
        XCTAssertTrue(NSApp.windows.allSatisfy { !$0.isVisible })
    }

}
