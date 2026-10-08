import Foundation

/// The menu-bar commands the Electron app had (`src/main/menu.ts`), for the native
/// menu bar. A page command goes to the main page as
/// `window.tdNative.run('menu-command', '<Electron command id>')` — the very id the
/// Electron menu sent on `menu:command`, so the page runs the same handler for it.
///
/// Already in the native menus elsewhere, so not repeated here: New Session ⌘T,
/// Open Project… ⌘O, Settings… ⌘, (the scene's own commands), the sidebar (the
/// system's Show/Hide Sidebar ⌃⌘S), Edit, Window, full screen and Quit (the system's).
public struct AppMenuCommand: Equatable, Sendable {
    public enum Menu: String, Equatable, Sendable, CaseIterable {
        /// After Settings… in the app menu (About replaces the system's About).
        case app
        /// After New Session / Open Project… in File.
        case file
        /// In View, after the sidebar item.
        case view
        /// The Help menu.
        case help
    }

    public enum Action: Equatable, Sendable {
        /// `menu-command` with the Electron command id.
        case page(String)
        /// The page's zoom in the window in front: 0 = actual size, +1 in, -1 out.
        case zoom(Int)
        /// An address for the default browser.
        case openURL(String)
    }

    public var menu: Menu
    public var title: String
    /// The key equivalent (always with ⌘), if it has one.
    public var key: String?
    public var shift: Bool
    public var action: Action
    /// A divider goes above this one.
    public var dividerBefore: Bool

    public init(_ menu: Menu, _ title: String, key: String? = nil, shift: Bool = false,
                _ action: Action, dividerBefore: Bool = false) {
        self.menu = menu
        self.title = title
        self.key = key
        self.shift = shift
        self.action = action
        self.dividerBefore = dividerBefore
    }

    /// The script for the main page, for a page command.
    public var script: String? {
        guard case .page(let id) = action else { return nil }
        return PageScript.run(AppCommandCatalog.pageCommand, .string(id))
    }

    /// "⇧⌘T" — for tests and logs.
    public var shortcut: String? {
        guard let key else { return nil }
        return (shift ? "⇧" : "") + "⌘" + key.uppercased()
    }
}

public enum AppCommandCatalog {
    /// The `tdNative.run` name the page answers menu commands on.
    public static let pageCommand = "menu-command"

    /// Shortcuts the native app already binds elsewhere; nothing here may reuse one.
    public static let reservedShortcuts: Set<String> = [
        "⌘T", "⌘O", "⌘,", "⌘W", "⌘Q", "⌘H", "⌘M", "⌘N", "⌘C", "⌘V", "⌘X", "⌘A", "⌘Z", "⇧⌘Z", "⌘S",
    ]

    /// Zoom steps, as Safari and the Electron app take them.
    public static let zoomSteps: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    /// The next zoom from `current` in `direction` (0 = actual size).
    public static func zoom(from current: Double, direction: Int) -> Double {
        guard direction != 0 else { return 1 }
        let now = current.isFinite && current > 0 ? current : 1
        if direction > 0 { return zoomSteps.first { $0 > now + 0.001 } ?? zoomSteps.last! }
        return zoomSteps.last { $0 < now - 0.001 } ?? zoomSteps.first!
    }

    public static let all: [AppMenuCommand] = [
        // App menu
        AppMenuCommand(.app, "Keyboard Shortcuts", key: "/", .page("app.shortcuts")),

        // File
        AppMenuCommand(.file, "New Session…", key: "t", shift: true, .page("session.newDialog")),
        // ⌘W stays the system's Close (the window), as everywhere on the Mac.
        AppMenuCommand(.file, "Delete Session", .page("session.close"), dividerBefore: true),

        // View
        AppMenuCommand(.view, "Sessions", .page("view.terminal"), dividerBefore: true),
        AppMenuCommand(.view, "Project Overview", .page("view.overview")),
        AppMenuCommand(.view, "Browser", .page("view.browser")),
        AppMenuCommand(.view, "Split the Window", key: "d", .page("pane.split"), dividerBefore: true),
        AppMenuCommand(.view, "Swarm View", key: "\\", .page("view.swarm")),
        AppMenuCommand(.view, "Command Palette", key: "k", .page("app.palette"), dividerBefore: true),
        AppMenuCommand(.view, "Quick Open", key: "p", .page("app.quickOpen")),
        AppMenuCommand(.view, "Search Sessions", key: "f", shift: true, .page("panel.search")),
        AppMenuCommand(.view, "Session Inspector", key: "i", shift: true, .page("app.inspector")),
        AppMenuCommand(.view, "Actual Size", key: "0", .zoom(0), dividerBefore: true),
        AppMenuCommand(.view, "Zoom In", key: "=", .zoom(1)),
        AppMenuCommand(.view, "Zoom Out", key: "-", .zoom(-1)),

        // Help
        AppMenuCommand(.help, "Terminal Deck Help", .page("app.help")),
        AppMenuCommand(.help, "Setup & Diagnostics", .page("app.setup")),
        AppMenuCommand(.help, "Report an Issue", .openURL("https://github.com/"), dividerBefore: true),
    ]

    /// The app menu's About, which replaces the system's About panel.
    public static let about = AppMenuCommand(.app, "About Terminal Deck", .page("app.about"))

    public static func commands(in menu: AppMenuCommand.Menu) -> [AppMenuCommand] {
        all.filter { $0.menu == menu && UIGMemoryVisibility.showsMenuCommand($0) }
    }
}
