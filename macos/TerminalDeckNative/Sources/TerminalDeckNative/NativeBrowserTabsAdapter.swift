import AppKit

// Connects lane B's native browser (NativeBrowserTabs.swift) to the main tab strip
// (BrowserTabsHook.swift). The ONLY file that names the browser's own types: if they
// are renamed, this is the one place to follow.

extension NativeBrowserTabs: BrowserTabsProvider {
    var browserTabs: [BrowserTabInfo] {
        tabs.map { BrowserTabInfo(id: $0.id, title: $0.displayTitle, favicon: $0.favicon, loading: $0.isLoading) }
    }

    func newBrowserTab() -> String {
        create(show: true).id
    }

    func selectBrowserTab(_ id: String) {
        select(id)
    }

    func closeBrowserTab(_ id: String) {
        close(id)
    }

    func onBrowserSelect(_ handler: @escaping @MainActor (String) -> Void) {
        onSelect = { id in handler(id) }
    }
}

extension BrowserTabsHook {
    /// Called once at launch (AppModel).
    static func connect() {
        provider = NativeBrowserTabs.shared
    }
}
