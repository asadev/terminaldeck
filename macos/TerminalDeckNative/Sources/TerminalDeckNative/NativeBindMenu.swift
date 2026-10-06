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

    /// Read the menu and pop it up where the pointer is — on the button that was pressed.
    static func popUp(sessionId: String, machineId: String = "") {
        Task {
            guard let rows = await rows(sessionId: sessionId, machineId: machineId) else { return }
            let menu = NSMenu()
            menu.autoenablesItems = false
            for row in rows {
                if row.kind == .separator {
                    menu.addItem(.separator())
                    continue
                }
                let item = NSMenuItem(title: row.label, action: nil, keyEquivalent: "")
                item.isEnabled = row.enabled
                if row.kind == .checkbox { item.state = row.checked ? .on : .off }
                if row.enabled, let act = row.act {
                    let handler = BindMenuHandler { perform(act, sessionId: sessionId, machineId: machineId) }
                    item.target = handler
                    item.action = #selector(BindMenuHandler.fire)
                    item.representedObject = handler
                }
                menu.addItem(item)
            }
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
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
/// moment it opens, with no time to ask the engine first. Read again whenever the
/// bindings, the rail or the tabs change.
@MainActor @Observable
final class NativeBindMenuStore {
    static let shared = NativeBindMenuStore()
    private(set) var rows: [String: [BindMenuRow]] = [:]
    @ObservationIgnored private var started = false
    @ObservationIgnored private var subscription: EngineSubscription?

    private static func key(_ sessionId: String, _ machineId: String) -> String { "\(machineId)\u{1F}\(sessionId)" }

    func rows(sessionId: String, machineId: String) -> [BindMenuRow]? { rows[Self.key(sessionId, machineId)] }

    func start() {
        guard !started else { return }
        started = true
        subscription = EngineBridge.shared.on("browser:bindings") { [weak self] _ in self?.refresh() }
        follow()
        refresh()
    }

    private func follow() {
        withObservationTracking {
            _ = AppModel.shared.sidebar
            _ = AppModel.shared.tabs
            _ = AppModel.shared.engineIsUp
        } onChange: {
            Task { @MainActor [weak self] in
                self?.refresh()
                self?.follow()
            }
        }
    }

    private func refresh() {
        let app = AppModel.shared
        let servers = Dictionary((app.tabs?.tabs ?? []).compactMap { tab in tab.server.map { (tab.id, $0) } },
                                 uniquingKeysWith: { first, _ in first })
        let sessions = (app.sidebar?.allItems ?? []).filter { $0.kind == .session }
        for item in sessions {
            guard let key = BindMenuRow.key(tabId: item.id, server: servers[item.id]) else { continue }
            Task {
                guard let read = await NativeBindMenu.rows(sessionId: key.sessionId, machineId: key.machineId) else { return }
                rows[Self.key(key.sessionId, key.machineId)] = read
            }
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
            .onAppear { store.start() }
        }
    }

    private func press(_ row: BindMenuRow, _ key: (sessionId: String, machineId: String)) {
        guard let act = row.act else { return }
        NativeBindMenu.perform(act, sessionId: key.sessionId, machineId: key.machineId)
    }
}
