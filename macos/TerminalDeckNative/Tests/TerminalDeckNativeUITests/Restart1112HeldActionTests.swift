import AppKit
import SwiftUI
import Foundation
import XCTest
import TerminalDeckBackend
import TerminalDeckNativeCore
@testable import TerminalDeckNative

private struct HeldActionProviders: BackendProviderLaunchResolver {
    var readiness: BackendLaunchReadiness { .ready }
    func loginPath() async throws -> String { "/usr/bin" }
    func resolve(_ input: BackendCreateSessionInput, loginPath: String) async throws -> BackendProviderSpec {
        .init(id: "claude", command: "/never-run", args: [], resumeArgs: ["--resume"])
    }
}
private actor HeldActionStarter: BackendRestoreSessionStarting {
    let restoredID = UUID().uuidString
    var inputs: [BackendCreateSessionInput] = []
    var live: [BackendSessionMeta] = []
    func create(_ input: BackendCreateSessionInput, context: BackendLaunchContext, holdOnFailure: Bool) async throws -> BackendSessionMeta {
        inputs.append(input)
        let meta = BackendSessionMeta(id: restoredID, input: input,
            spawn: .init(provider: "claude", command: "/never-run", args: [], path: "/usr/bin", homeProfileId: input.homeProfileId,
                agentSessionId: input.resumeConversationId, tabKey: input.tabKey))
        live.append(meta)
        return meta
    }
    func liveSessions() async -> [BackendSessionMeta] { live }
}

/// Production sidebar visibility and its visible row's Retry reach EngineBridge/shared Retry. All state is scratch-only.
@MainActor final class Restart1112HeldActionTests: XCTestCase {
    func testRound5HeldLoginRetryPreservesCurrentThenSelectsTheRealRestoredTab() async throws { try await exercise(historyRemoved: false) }
    func testRound5HeldHistoryRetryPreservesCurrentThenSelectsTheRealRestoredTab() async throws { try await exercise(historyRemoved: true) }

    private func exercise(historyRemoved: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-held-action-" + UUID().uuidString)
        for directory in ["data", "home"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true) }
        let state = try NativeStateStore(file: root.appendingPathComponent("data/state.json"), ownership: .exclusive)
        let configuration = try BackendAccountConfiguration(dataDirectory: root.appendingPathComponent("data"), homeDirectory: root.appendingPathComponent("home"),
            appName: "Fixture", appID: "fixture", helperExecutable: root.appendingPathComponent("never-run"), inheritedEnvironment: [:])
        let profiles = try BackendAccountProfileStore(configuration: configuration, stateStore: state)
        let removed = try await profiles.create(name: "Original account", vaultManaged: false)
        let working = try await profiles.create(name: "Other account", vaultManaged: false)
        let transcript = URL(fileURLWithPath: removed.configDir).appendingPathComponent("projects/" + NativeTranscriptPaths.encodeProjectPath(root.path) + "/saved-chat.jsonl")
        try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("fixture history".utf8).write(to: transcript)
        _ = try await profiles.removeMetadata(id: removed.id)
        try await state.startSessionLedger()
        var saved = NativeRPCValue.object([.init("cwd", .string(root.path)), .init("provider", .string("claude")),
            .init("tabKey", .string("saved-tab")), .init("profileId", .string(historyRemoved ? working.id : removed.id)), .init("agentSessionId", .string("saved-chat"))])
        if historyRemoved { saved = saved.setting("homeProfileId", .string(removed.id)) }
        let held = try await state.holdSession(saved, reason: "the saved account is unavailable")
        let starter = HeldActionStarter()
        let context = BackendSessionRestoreContext(readiness: .ready) { device, folder in .init(deviceKey: device, folder: folder) }
        let planner = BackendSessionRestorePlanner(profiles: profiles, providers: HeldActionProviders(), context: context)
        let restore = BackendSessionRestoreCoordinator(starter: starter, planner: planner, store: state, context: context, excludedAppWorkingDirectories: [], emit: { _ in })
        let graph = try BackendCompositionRoot(dataRoot: root.appendingPathComponent("data"), state: state, environment: [:], home: root.appendingPathComponent("home").path)
        let bridge = EngineBridge()
        try await graph.registry.register("session:held-retry", ownerID: "held-action") { caller, args in
            try BackendCompositionRoot.requireLocalUI(caller)
            return try await BackendSessionLifecycleRPC.retryHeld(restore: restore, args: args)
        }
        let currentID = UUID().uuidString
        let restoredID = await starter.restoredID
        let currentRow = NativeRPCValue.object([.init("id", .string(currentID)), .init("cwd", .string(root.path)),
            .init("provider", .string("claude")), .init("tabKey", .string("current-tab")), .init("title", .string("Current conversation"))])
        try await graph.registry.register("sessions:held", ownerID: "held-action") { _, _ in .array(try await state.heldSessions().map(\.wireValue)) }
        try await graph.registry.register("session:list", ownerID: "held-action") { _, _ in
            let restored = try await starter.liveSessions().map { try NativeRPCValue.parseJSON(JSONEncoder().encode($0)) }
            return .array([currentRow] + restored)
        }
        try await graph.retain(.init(name: "held-action", domains: ["held-action"], ownerID: "held-action",
            invokes: ["session:held-retry", "sessions:held", "session:list"], stop: {}))
        try await bridge.configure(native: graph)
        weak var fixtureModel: AppModel?
        let actions = NativeButtonActions(effects: .init(invoke: { try await bridge.invoke($0, $1) }, presentSession: { _ in }, confirm: { _ in false },
            changed: { fixtureModel?.applyButtonState() }))
        let resources = root.appendingPathComponent("resources")
        for name in NativeWebAssets.required {
            let file = resources.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        let engine = EngineController(configuration: .init(source: .nativeOnly(try NativeWebAssets.discover(resources: resources)), dataRoot: root))
        engine.nativeStarter = { URL(string: "http://127.0.0.1:1/")! } // inert readiness, no server or WebKit load
        engine.start()
        for _ in 0..<10 {
            if case .ready = engine.phase { break }
            await Task.yield()
        }
        let model = AppModel(restartFixture: engine, buttons: actions)
        fixtureModel = model
        model.web.onMessage?(.tabs(.init(tabs: [.init(id: currentID, title: "Current conversation", kind: "session", active: true, closable: true)],
            canNewTerminal: true, canNewBrowser: true)))
        let suite = "restart-held-visible-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SIDEBARProjectStore(defaults: defaults)
        store.liveIDs = []
        let pins = SIDEBARPins(defaults: defaults), pages = Sidebar21Store(defaults: defaults)
        pages.initialize(existingUser: false, pages: Sidebar21Pages.standard)
        func visiblePanel() async throws -> SIDEBARPanel<EmptyView, EmptyView> {
            let items = try await state.heldSessions().map { tab in
                SidebarItem(id: "held:" + tab.key, title: "Claude Code", symbol: "pause.circle", kind: .session,
                    status: "held", subtitle: "Not reopened", help: "Claude Code — Not reopened: " + tab.reason)
            }
            let current = SidebarItem(id: currentID, title: "Current conversation", kind: .session, status: "idle")
            let sidebar = SidebarState(groups: [], projects: [.init(id: root.path, title: "Fixture", expanded: false, sessions: [current] + items)], selectedId: currentID)
            model.web.onMessage?(.sidebar(sidebar))
            return SIDEBARPanel(state: model.visibleSidebar ?? sidebar, selected: model.sidebarSelection, store: store,
                choose: { id in
                    model.select(id) // The production AppModel callback that previously created the fake held tab.
                    XCTAssertEqual(model.tabs?.activeID, currentID, "Retry must preserve the real tab synchronously, before the backend replies")
                    XCTAssertFalse(model.tabs?.tabs.contains { $0.id.hasPrefix("held:") } ?? true)
                },
                openProject: {}, newSession: { _ in }, closeProject: { _ in }, openWindow: { _ in },
                rename: { _ in }, close: { _ in }, stop: { _ in }, sessionPins: pins, pagePins: pages) {
                    EmptyView()
                } hostFailure: { EmptyView() }
        }
        let firstPanel = try await visiblePanel()
        let visibleRow = try XCTUnwrap(firstPanel.heldRows.first)
        XCTAssertTrue(firstPanel.rowIDs.contains(visibleRow.id), "A held tab must be reachable even with no live session and a collapsed project")
        XCTAssertTrue(visibleRow.statusText.contains("Not reopened:"))
        try await renderVisibleReason(firstPanel, id: visibleRow.id, reason: visibleRow.statusText, dark: false,
            name: historyRemoved ? "history-initial" : "login-initial", press: true)
        await actions.waitForRestartFixture()
        XCTAssertNil(actions.problem)
        XCTAssertEqual(model.tabs?.activeID, currentID)
        XCTAssertEqual(model.visibleTabs?.activeID, currentID)
        XCTAssertEqual(model.currentScreen?.id, currentID)
        XCTAssertFalse(model.tabs?.tabs.contains { $0.id.hasPrefix("held:") } ?? true)
        XCTAssertFalse(actions.tabs.tabs.contains { $0.id.hasPrefix("held:") })
        // A stale renderer snapshot must not resurrect the old synthetic held tab or deactivate the real one.
        model.web.onMessage?(.tabs(.init(tabs: [
            .init(id: currentID, title: "Current conversation", kind: "session", active: false, closable: true),
            .init(id: visibleRow.id, title: "Stale held item", kind: "session", active: true, closable: true)],
            canNewTerminal: true, canNewBrowser: true)))
        XCTAssertEqual(model.tabs?.activeID, currentID)
        XCTAssertEqual(model.currentScreen?.id, currentID)
        XCTAssertFalse(model.tabs?.tabs.contains { $0.id.hasPrefix("held:") } ?? true)
        let failed = try await state.heldSessions()
        XCTAssertEqual(failed.first?.saved, saved)
        XCTAssertTrue(failed.first?.reason.contains("Add it again with its original name in Settings › Coding AIs, then press Retry.") == true)
        let before = await starter.inputs
        XCTAssertTrue(before.isEmpty)
        let savedRows = await state.getOpenSessions()
        XCTAssertEqual(savedRows.first, saved)
        let readded = try await profiles.create(name: "Original account", vaultManaged: false)
        XCTAssertEqual(readded.id, removed.id)
        let secondPanel = try await visiblePanel()
        let retryRow = try XCTUnwrap(secondPanel.heldRows.first)
        XCTAssertTrue(retryRow.statusText.contains("then press Retry"))
        for dark in [false, true] {
            try await renderVisibleReason(secondPanel, id: retryRow.id, reason: retryRow.statusText, dark: dark,
                name: historyRemoved ? "history" : "login", press: dark)
        }
        await actions.waitForRestartFixture()
        XCTAssertNil(actions.problem)
        XCTAssertEqual(model.tabs?.activeID, restoredID)
        XCTAssertEqual(model.visibleTabs?.activeID, restoredID)
        XCTAssertEqual(model.currentScreen?.id, restoredID)
        XCTAssertFalse(model.tabs?.tabs.contains { $0.id.hasPrefix("held:") } ?? true)
        XCTAssertFalse(actions.tabs.tabs.contains { $0.id.hasPrefix("held:") })
        let inputs = await starter.inputs, remaining = try await state.heldSessions()
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(inputs.first?.profileId, historyRemoved ? working.id : removed.id)
        XCTAssertEqual(inputs.first?.homeProfileId, historyRemoved ? removed.id : nil)
        XCTAssertEqual(inputs.first?.resumeConversationId, "saved-chat")
        XCTAssertTrue(remaining.isEmpty)
        let restoredPanel = try await visiblePanel()
        XCTAssertTrue(restoredPanel.heldRows.isEmpty)
        await bridge.disconnectNative(); try await graph.shutdown(); await profiles.close(); await state.close()
        try FileManager.default.removeItem(at: root)
    }

    /// SwiftUI publishes its accessibility elements only after an assistive client has asked
    /// the app for them. A test process has none (no VoiceOver, no UI automation), so the walk
    /// found no buttons at all. Ask on its behalf, the way an assistive client does.
    private func enableAccessibilityTree() {
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXManualAccessibility"))
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    }
    private func renderVisibleReason<V: View>(_ panel: V, id: String, reason: String, dark: Bool, name: String, press: Bool) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        enableAccessibilityTree()
        let size = CGSize(width: 264, height: 820)
        let host = NSHostingView(rootView: panel.environment(\.colorScheme, dark ? .dark : .light).frame(width: size.width, height: size.height))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -30000, y: -30000), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = host.appearance; window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let nodes = accessibilityNodes(host)
        let button = try XCTUnwrap(nodes.first { string($0, "accessibilityIdentifier") == "restart-held-retry-" + id }, "The production panel must render Retry")
        XCTAssertTrue(nodes.contains {
            string($0, "accessibilityIdentifier") == "restart-held-reason-" + id &&
                [string($0, "accessibilityLabel"), string($0, "accessibilityValue")].compactMap { $0 }.contains(reason)
        }, "The reason must be visible text, not a tooltip on a hidden row")
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let output = URL(fileURLWithPath: "/tmp/restart-1112-round4.noindex")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try png.write(to: output.appendingPathComponent(name + (dark ? "-dark.png" : "-light.png")))
        XCTAssertFalse(window.isVisible)
        if press {
            // Invoke the rendered SwiftUI button's accessibility action, not a hand-built held selection.
            let selector = NSSelectorFromString("accessibilityPerformPress")
            XCTAssertTrue(button.responds(to: selector))
            let implementation = try XCTUnwrap(button.method(for: selector))
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            let performPress = unsafeBitCast(implementation, to: Press.self)
            XCTAssertTrue(performPress(button, selector))
            await Task.yield()
        }
    }
    private func string(_ object: NSObject, _ key: String) -> String? {
        guard object.responds(to: NSSelectorFromString(key)) else { return nil }
        return object.value(forKey: key) as? String
    }
    private func accessibilityNodes(_ root: NSObject) -> [NSObject] {
        var seen = Set<ObjectIdentifier>(), pending: [NSObject] = [root], result: [NSObject] = []
        while let node = pending.popLast(), result.count < 10_000 {
            guard seen.insert(ObjectIdentifier(node)).inserted else { continue }
            result.append(node)
            if node.responds(to: NSSelectorFromString("accessibilityChildren")), let children = node.value(forKey: "accessibilityChildren") as? [NSObject] { pending += children }
            if let view = node as? NSView { pending += view.subviews }
        }
        return result
    }
}
