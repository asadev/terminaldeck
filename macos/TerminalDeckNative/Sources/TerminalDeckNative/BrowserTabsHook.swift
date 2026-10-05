import AppKit

// The native browser's tabs live in the main tab strip, after the page's session
// tabs, exactly like the Electron app. This is everything the strip needs from the
// native browser — the browser itself (its pages, its screen) is lane B's.
//
// The browser connects through one adapter (NativeBrowserTabsAdapter.swift), the
// only file that knows the browser's own type names.

struct BrowserTabInfo: Identifiable, Equatable {
    let id: String
    let title: String
    let favicon: NSImage?
    let loading: Bool
}

@MainActor
protocol BrowserTabsProvider: AnyObject {
    /// In the order the person arranged them. Read inside SwiftUI, so an
    /// @Observable source keeps the strip up to date by itself.
    var browserTabs: [BrowserTabInfo] { get }
    /// Makes a tab (showing its start page), selects it, returns its id.
    func newBrowserTab() -> String
    func selectBrowserTab(_ id: String)
    func closeBrowserTab(_ id: String)
    /// The browser made and wants to show a tab itself (⌘T inside it, a link opened
    /// in a new tab, window.open): the strip brings it forward.
    func onBrowserSelect(_ handler: @escaping @MainActor (String) -> Void)
}

@MainActor
enum BrowserTabsHook {
    /// nil when this build has no native browser: the globe then asks the page.
    static var provider: (any BrowserTabsProvider)?
}
