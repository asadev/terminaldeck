import AppKit
import Observation

// Used ONLY inside the window check's throwaway copy, in place of
// NativeBrowserTabsAdapter.swift: an in-memory browser, so the check can prove the
// strip, selection, windows and closing without the real browser.

@MainActor
@Observable
final class FakeBrowserTabs: BrowserTabsProvider {
    static let shared = FakeBrowserTabs()
    private(set) var list: [BrowserTabInfo] = []
    private var next = 1

    var browserTabs: [BrowserTabInfo] { list }

    func newBrowserTab() -> String {
        let id = "b\(next)"
        next += 1
        list.append(BrowserTabInfo(id: id, title: "Start Page", favicon: nil, loading: false))
        return id
    }

    func selectBrowserTab(_ id: String) {}

    func closeBrowserTab(_ id: String) {
        list.removeAll { $0.id == id }
    }

    /// The browser's own "show this tab" (⌘T inside it, a link opened in a new tab).
    private(set) var onSelect: (@MainActor (String) -> Void)?
    func onBrowserSelect(_ handler: @escaping @MainActor (String) -> Void) { onSelect = handler }

    /// What the real browser does on ⌘T inside a tab: makes one and asks to show it.
    func simulateBrowserOpensTab() -> String {
        let id = newBrowserTab()
        onSelect?(id)
        return id
    }
}

extension BrowserTabsHook {
    static func connect() { provider = FakeBrowserTabs.shared }
}
