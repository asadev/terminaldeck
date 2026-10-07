import Foundation
import AppKit
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor final class BackendMacAppWindowsMenuTests: XCTestCase {
    private func rig() -> (BackendMacAppWindowsMenu, BackendMacAppWindowsTestMenuHost) {
        let host = BackendMacAppWindowsTestMenuHost(); return (.init(host: host, version: "9.9.9"), host)
    }
    private func rows(_ menu: NSMenu) -> [(menu: String, item: NSMenuItem)] {
        var found: [(String, NSMenuItem)] = []
        func descend(_ name: String, _ menu: NSMenu) { for item in menu.items { found.append((name, item)); if let submenu = item.submenu { descend(name, submenu) } } }
        for top in menu.items { if let submenu = top.submenu { descend(top.title, submenu) } }; return found
    }
    private func command(_ item: NSMenuItem) -> String? {
        guard let value = item.representedObject as? String, !value.hasPrefix("role:"), !value.hasPrefix("url:") else { return nil }; return value
    }
    private func one(_ id: String) throws -> NSMenuItem {
        let (menu, _) = rig(), found = rows(menu.template()).filter { command($0.item) == id }
        XCTAssertEqual(found.count, 1); return try XCTUnwrap(found.first?.item)
    }
    func testDarwinSettingsIsReachableOnce() throws { XCTAssertEqual(try one("app.preferences").title, "Settings…") }
    func testDarwinSettingsRegistersCommandComma() throws { let item = try one("app.preferences"); XCTAssertEqual(item.keyEquivalent, ","); XCTAssertEqual(item.keyEquivalentModifierMask, .command) }
    func testDarwinKeyboardShortcutsIsReachableOnce() throws { XCTAssertEqual(try one("app.shortcuts").title, "Keyboard Shortcuts") }
    func testDarwinKeyboardShortcutsRegistersCommandSlash() throws { let item = try one("app.shortcuts"); XCTAssertEqual(item.keyEquivalent, "/"); XCTAssertEqual(item.keyEquivalentModifierMask, .command) }
    func testDarwinAboutIsReachableOnce() throws { XCTAssertEqual(try one("app.about").title, "About Terminal Deck") }
    func testDarwinHasExactlyOneQuitRole() {
        let (menu, _) = rig(); XCTAssertEqual(rows(menu.template()).filter { ($0.item.representedObject as? String) == "role:quit" }.count, 1)
    }
    func testAppleStandardAppMenuKeepsServicesAndHideBlock() {
        let (menu, _) = rig(), template = menu.template(), items = rows(template)
        XCTAssertEqual(template.items.first?.title, "Terminal Deck")
        for id in ["app.about", "app.preferences", "app.shortcuts"] { XCTAssertEqual(items.first { command($0.item) == id }?.menu, "Terminal Deck") }
        XCTAssertEqual(items.first { ($0.item.representedObject as? String) == "role:quit" }?.menu, "Terminal Deck")
        for role in ["services", "hide", "hideOthers", "unhide"] { XCTAssertTrue(items.contains { ($0.item.representedObject as? String) == "role:" + role }) }
    }
    func testMacMenuBarRemainsVisible() { XCTAssertFalse(BackendMacAppWindowsMenu.hidesMenuBar) }
    func testUninstalledFeaturesHideExactlyTheirCommands() throws {
        let (menu, _) = rig(); try menu.updateHidden(.array([.string("view.browser"), .string("pane.split"), .string("view.swarm")]))
        let commands = rows(menu.template()).compactMap { command($0.item) }
        for id in ["view.browser", "pane.split", "view.swarm"] { XCTAssertFalse(commands.contains(id)) }
        for id in ["session.new", "app.preferences", "view.terminal", "view.sidebar"] { XCTAssertTrue(commands.contains(id)) }
    }
    func testHiddenFeatureLosesItsAccelerator() throws {
        let (menu, _) = rig(); try menu.updateHidden(.array([.string("view.browser"), .string("pane.split"), .string("view.swarm")]))
        let keys = rows(menu.template()).map { $0.item.keyEquivalent }
        XCTAssertFalse(keys.contains("d")); XCTAssertFalse(keys.contains("\\")); XCTAssertTrue(keys.contains("b"))
    }
    func testNothingHiddenOffersAllOptionalFeatures() {
        let (menu, _) = rig(); let commands = rows(menu.template()).compactMap { command($0.item) }
        for id in ["view.browser", "pane.split", "view.swarm"] { XCTAssertTrue(commands.contains(id)) }
    }
    private func separatorCase(_ mask: Int) throws {
        let (menu, _) = rig(), gated = ["view.browser", "pane.split", "view.swarm"]
        let hidden = gated.enumerated().compactMap { mask & (1 << $0.offset) != 0 ? NativeRPCValue.string($0.element) : nil }
        try menu.updateHidden(.array(hidden))
        func check(_ submenu: NSMenu) {
            XCTAssertFalse(submenu.items.first?.isSeparatorItem == true); XCTAssertFalse(submenu.items.last?.isSeparatorItem == true)
            for pair in zip(submenu.items, submenu.items.dropFirst()) { XCTAssertFalse(pair.0.isSeparatorItem && pair.1.isSeparatorItem) }
            for item in submenu.items { if let child = item.submenu, !child.items.isEmpty { check(child) } }
        }
        for item in menu.template().items { if let submenu = item.submenu { check(submenu) } }
    }
    func testNoStrandedSeparatorWithNothingHidden() throws { try separatorCase(0) }
    func testNoStrandedSeparatorWithBrowserHidden() throws { try separatorCase(1) }
    func testNoStrandedSeparatorWithSplitHidden() throws { try separatorCase(2) }
    func testNoStrandedSeparatorWithBrowserAndSplitHidden() throws { try separatorCase(3) }
    func testNoStrandedSeparatorWithSwarmHidden() throws { try separatorCase(4) }
    func testNoStrandedSeparatorWithBrowserAndSwarmHidden() throws { try separatorCase(5) }
    func testNoStrandedSeparatorWithSplitAndSwarmHidden() throws { try separatorCase(6) }
    func testNoStrandedSeparatorWithAllOptionalFeaturesHidden() throws { try separatorCase(7) }
    func testBuildInstallsFullMenuAtLaunch() throws {
        let (menu, host) = rig(); try menu.build(); XCTAssertEqual(host.installed.count, 1)
        let labels = rows(try XCTUnwrap(host.installed.last)).map { $0.item.title }
        for label in ["Browser", "Split the Window", "Swarm View"] { XCTAssertTrue(labels.contains(label)) }
        XCTAssertEqual(host.aboutName, "Terminal Deck"); XCTAssertEqual(host.aboutVersion, "9.9.9")
    }
    func testFeatureRemovalRebuildsMenu() throws {
        let (menu, host) = rig(); try menu.build(); try menu.updateHidden(.array([.string("pane.split"), .string("view.swarm")]))
        XCTAssertEqual(host.installed.count, 2); let labels = rows(try XCTUnwrap(host.installed.last)).map { $0.item.title }
        XCTAssertFalse(labels.contains("Split the Window")); XCTAssertFalse(labels.contains("Swarm View")); XCTAssertTrue(labels.contains("Browser")); XCTAssertTrue(labels.contains("Toggle Sidebar"))
    }
    func testReinstalledFeaturesReturnToMenu() throws {
        let (menu, host) = rig(); try menu.build(); try menu.updateHidden(.array([.string("pane.split")])); try menu.updateHidden(.array([]))
        XCTAssertEqual(host.installed.count, 3); let labels = rows(try XCTUnwrap(host.installed.last)).map { $0.item.title }
        for label in ["Browser", "Split the Window", "Swarm View"] { XCTAssertTrue(labels.contains(label)) }
    }
    func testUnchangedFeatureSetDoesNotTouchOpenMenu() throws {
        let (menu, host) = rig(); try menu.build(); try menu.updateHidden(.array([.string("pane.split")])); try menu.updateHidden(.array([.string("pane.split")]))
        XCTAssertEqual(host.installed.count, 2)
    }
    func testMalformedFeatureMessageHidesNothingAndDoesNotRebuild() throws {
        let (menu, host) = rig(); try menu.build()
        for junk in [NativeRPCValue.missing, .null, .string("pane.split"), .number(42), .object([.init("0", .string("pane.split"))]), .array([.number(7), .string(""), .null])] { try menu.updateHidden(junk) }
        XCTAssertEqual(host.installed.count, 1)
    }
    func testRepeatedBuildLeavesOneOwnedListener() async throws {
        let (menu, host) = rig(), registry = NativeChannelRegistry()
        try await menu.register(on: registry); try await menu.register(on: registry); try await menu.register(on: registry)
        XCTAssertEqual(host.installed.count, 3)
        _ = try await registry.send("menu:hidden-commands", context: .init(caller: .nativeApp, ownerID: "main"), arguments: [.array([.string("pane.split")])])
        XCTAssertEqual(host.installed.count, 4)
    }
    func testCommandsRouteThroughFocusedPopoutBeforeMainWindow() async throws {
        let r = BackendMacAppWindowsTestRig(), host = BackendMacAppWindowsTestMenuHost()
        _ = try r.registry.open("s1"); r.windows[0].focused = true
        let menu = BackendMacAppWindowsMenu(host: host, version: "test", route: { try r.registry.routeMenu($0) })
        let handled = try await menu.dispatch("session.close"); XCTAssertTrue(handled); XCTAssertFalse(r.registry.isPopped("s1")); XCTAssertEqual(host.commands, [])
    }
    func testCommandWithoutPopoutReachesExistingMainOwner() async throws {
        let (menu, host) = rig(); let handled = try await menu.dispatch("session.new"); XCTAssertTrue(handled); XCTAssertEqual(host.commands, ["session.new"])
    }
    func testMacTitleBarHasHiddenInsetAndSystemTrafficLights() {
        XCTAssertEqual(BackendMacAppWindowsTitleBar.chrome, .object([.init("titleBarStyle", .string("hiddenInset")), .init("trafficLightPosition", .object([.init("x", .number(14)), .init("y", .number(12))]))]))
        XCTAssertEqual(BackendMacAppWindowsTitleBar.overlay(), .null); XCTAssertEqual(BackendMacAppWindowsTitleBar.overlay(dimmed: true), .null)
    }
    func testMacGetsNoControlsOverlayToSet() { XCTAssertFalse(BackendMacAppWindowsTitleBar.usesWindowControlsOverlay); XCTAssertEqual(BackendMacAppWindowsTitleBar.overlay(), .null) }
    func testExplicitAppearanceChoiceWinsOverSystem() {
        XCTAssertEqual(BackendMacAppWindowsTitleBar.resolveAppearance(.dark, systemPrefersDark: false), .dark)
        XCTAssertEqual(BackendMacAppWindowsTitleBar.resolveAppearance(.light, systemPrefersDark: true), .light)
    }
    func testSystemAppearanceFollowsOnlyWhenAsked() {
        XCTAssertEqual(BackendMacAppWindowsTitleBar.resolveAppearance(.system, systemPrefersDark: true), .dark)
        XCTAssertEqual(BackendMacAppWindowsTitleBar.resolveAppearance(.system, systemPrefersDark: false), .light)
    }
    func testNativeFactoryUsesSharedTitleBarAdapter() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/TerminalDeckBackend/BackendMacAppWindowsNative.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("BackendMacAppWindowsTitleBar.apply(to: window)"))
        XCTAssertFalse(source.contains("window.titleVisibility =")); XCTAssertFalse(source.contains("window.titlebarAppearsTransparent ="))
    }
}

@MainActor final class BackendMacAppWindowsTestMenuHost: BackendMacAppWindowsMenuHost {
    var installed: [NSMenu] = [], commands: [String] = [], roles: [String] = [], external: [URL] = []
    var aboutName = "", aboutVersion = ""
    func install(_ menu: NSMenu) { installed.append(menu) }
    func setAbout(name: String, version: String) { aboutName = name; aboutVersion = version }
    func sendMain(command: String) -> Bool { commands.append(command); return true }
    func openExternal(_ url: URL) { external.append(url) }
    func performRole(_ role: String) { roles.append(role) }
    func failed(_ error: Error) { XCTFail(error.localizedDescription) }
}
