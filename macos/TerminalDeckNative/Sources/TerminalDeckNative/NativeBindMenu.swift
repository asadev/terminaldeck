import AppKit
import SwiftUI
import TerminalDeckNativeCore

// "Attach browser" (PaneBar) and "Connect browser ▸" (the session row's menu): the
// engine's bind menu, drawn natively. The engine pops it as an Electron menu in the
// Electron window; the native engine has no window, so it hands the same rows over
// as data (`browser:bind-menu-items`) and a press goes back through `browser:bind`,
// `browser:unbind` or `browser:bind-new-window`.

@MainActor
enum NativeBindMenu {
    /// The rows for one session, read now.
    static func rows(sessionId: String, machineId: String) async -> [BindMenuRow]? {
        guard let raw = try? await EngineBridge.shared.invoke("browser:bind-menu-items",
                                                              [["sessionId": sessionId, "machineId": machineId]]) else { return nil }
        return BindMenuRow.list(CodingAIJSON(raw))
    }

    /// Send a press back to the engine.
    static func perform(_ act: BindMenuRow.Act, sessionId: String, machineId: String) {
        let command = BindMenuRow.command(act, sessionId: sessionId, machineId: machineId)
        EngineBridge.shared.send(command.channel, [command.arg.foundation])
    }

    /// Keep the click location while the engine reads the menu.
    static func popUp(sessionId: String, machineId: String = "") {
        NativeActionMenu.popUp(load: {
            guard let rows = await rows(sessionId: sessionId, machineId: machineId) else { return nil }
            return rows.map { row in
                NativeActionMenu.Row(separator: row.kind == .separator, label: row.label,
                    enabled: row.enabled, checked: row.kind == .checkbox ? row.checked : nil,
                    action: row.act.map { act in { perform(act, sessionId: sessionId, machineId: machineId) } })
            }
        })
    }
}

/// An NSMenuItem's target that runs a closure (held by the item's `representedObject`).
@MainActor
final class BindMenuHandler: NSObject {
    private let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

/// The rows for every session on the rail, kept current — a context menu is drawn the
/// moment it opens, with no time to ask the engine first. Every row is read again when the
/// bindings change or the engine comes up; a session new to the rail is read when it
/// arrives, and a row when its menu opens. A tab switch or a new title reads nothing.
@MainActor @Observable
final class NativeBindMenuStore {
    static let shared = NativeBindMenuStore()
    private(set) var rows: [String: [BindMenuRow]] = [:]
    @ObservationIgnored private var started = false
    @ObservationIgnored private var subscription: EngineSubscription?
    /// The rail's sessions as last seen, by their key in `rows`.
    @ObservationIgnored private var listed: [String: (sessionId: String, machineId: String)] = [:]
    @ObservationIgnored private var engineWasUp = false

    private static func key(_ sessionId: String, _ machineId: String) -> String { "\(machineId)\u{1F}\(sessionId)" }

    func rows(sessionId: String, machineId: String) -> [BindMenuRow]? { rows[Self.key(sessionId, machineId)] }

    func start() {
        guard !started else { return }
        started = true
        subscription = EngineBridge.shared.on("browser:bindings") { [weak self] _ in self?.readAll() }
        follow()
        railChanged()
    }

    private func follow() {
        withObservationTracking {
            _ = AppModel.shared.sidebar
            _ = AppModel.shared.tabs
            _ = AppModel.shared.engineIsUp
        } onChange: {
            Task { @MainActor [weak self] in
                self?.railChanged()
                self?.follow()
            }
        }
    }

    /// The rail and the tabs are reassigned on every tab switch and title change, with the
    /// same sessions listed: only a session new to the rail is read, and a gone one's rows go.
    private func railChanged() {
        let app = AppModel.shared
        let servers = Dictionary((app.tabs?.tabs ?? []).compactMap { tab in tab.server.map { (tab.id, $0) } },
                                 uniquingKeysWith: { first, _ in first })
        var now: [String: (sessionId: String, machineId: String)] = [:]
        for item in (app.sidebar?.allItems ?? []) where item.kind == .session {
            guard let key = BindMenuRow.key(tabId: item.id, server: servers[item.id]) else { continue }
            now[Self.key(key.sessionId, key.machineId)] = key
        }
        let cameUp = app.engineIsUp && !engineWasUp
        engineWasUp = app.engineIsUp
        let fresh = cameUp ? Array(now.keys) : now.keys.filter { listed[$0] == nil }
        listed = now
        if rows.keys.contains(where: { now[$0] == nil }) { rows = rows.filter { now[$0.key] != nil } }
        for key in fresh { if let session = now[key] { read(session) } }
    }

    private func readAll() {
        for session in listed.values { read(session) }
    }

    /// A row's menu opened: read it again, so it is current the next time.
    func menuOpened(sessionId: String, machineId: String) {
        read((sessionId, machineId))
    }

    private func read(_ session: (sessionId: String, machineId: String)) {
        let key = Self.key(session.sessionId, session.machineId)
        Task {
            guard let read = await NativeBindMenu.rows(sessionId: session.sessionId, machineId: session.machineId),
                  listed[key] != nil else { return }
            rows[key] = read
        }
    }
}

/// "Connect browser ▸" for a session row's menu: the bind menu as a submenu.
struct NativeConnectBrowserMenu: View {
    let tabId: String

    var body: some View {
        let store = NativeBindMenuStore.shared
        let server = AppModel.shared.tabs?.tabs.first { $0.id == tabId }?.server
        if let key = BindMenuRow.key(tabId: tabId, server: server) {
            Menu("Connect browser") {
                if let rows = store.rows(sessionId: key.sessionId, machineId: key.machineId) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        switch row.kind {
                        case .separator:
                            Divider()
                        case .checkbox:
                            Toggle(row.label, isOn: Binding(
                                get: { row.checked },
                                set: { _ in press(row, key) }
                            ))
                            .disabled(!row.enabled)
                        case .item:
                            Button(row.label) { press(row, key) }.disabled(!row.enabled)
                        }
                    }
                } else {
                    Button("Reading…") {}.disabled(true)
                }
            }
            .onAppear {
                store.start()
                store.menuOpened(sessionId: key.sessionId, machineId: key.machineId)
            }
        }
    }

    private func press(_ row: BindMenuRow, _ key: (sessionId: String, machineId: String)) {
        guard let act = row.act else { return }
        NativeBindMenu.perform(act, sessionId: key.sessionId, machineId: key.machineId)
    }
}

/// Both browser menus use the same native rows and retained action targets.
@MainActor
enum NativeActionMenu {
    struct Row {
        var separator = false
        var label: String
        var enabled: Bool
        var checked: Bool?
        var action: (() -> Void)?
    }

    @discardableResult
    static func popUp(location: () -> NSPoint = { NSEvent.mouseLocation },
                      load: @escaping @MainActor () async -> [Row]?,
                      show: @escaping @MainActor (NSMenu, NSPoint) -> Void = { menu, anchor in
                          menu.popUp(positioning: nil, at: anchor, in: nil)
                      }) -> Task<Void, Never> {
        let anchor = location()
        return Task {
            guard let rows = await load() else { return }
            show(make(rows), anchor)
        }
    }

    static func make(_ rows: [Row]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for row in rows {
            if row.separator { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: row.label, action: nil, keyEquivalent: "")
            item.isEnabled = row.enabled && row.action != nil
            if let checked = row.checked { item.state = checked ? .on : .off }
            if row.enabled, let action = row.action {
                let handler = BindMenuHandler(action)
                item.target = handler
                item.action = #selector(BindMenuHandler.fire)
                item.representedObject = handler
            }
            menu.addItem(item)
        }
        return menu
    }
}
