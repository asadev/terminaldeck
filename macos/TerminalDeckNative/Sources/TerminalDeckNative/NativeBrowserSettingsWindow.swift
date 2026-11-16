import AppKit
import SwiftUI

/// The Browser's settings in a small window of their own (owner, 15 Nov: "When we click here, its own settings pop-up
/// will come up ... Its own window will come up"). The same controls Settings → Browser had (pages, sign-ins,
/// passwords, downloads, capture), nothing lost, drawn with the Settings window's pieces (top bar with the page name,
/// a centred column). Opened from the Browser's profile button ("Browser Settings…", "Passwords", "Scraping") and from
/// every old link to Settings → Browser or Scraping.
@MainActor
enum NativeBrowserSettingsWindow {
    static let identifier = NSUserInterfaceItemIdentifier("browser-settings")
    static let size = NSSize(width: 640, height: 720)
    private static var window: NSWindow?

    /// The old Settings ids this window answers for.
    static func handles(_ section: String) -> Bool { section == "browser" || section == "scraping" }

    /// Front gate (as the old Settings window): it comes forward for the person's own click; a request that is not
    /// theirs (an AI, the web page) waits until they bring the app forward themselves.
    static func show() {
        NativeFront.whenPersonActs("browser-settings") {
            if let window = Self.window {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()
                return
            }
            let host = NSHostingController(rootView: NativeBrowserSettingsWindowContent())
            host.sizingOptions = []
            let made = NSWindow(contentViewController: host)
            made.identifier = Self.identifier
            made.title = "Browser Settings"
            made.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            made.setContentSize(Self.size)
            made.contentMinSize = NSSize(width: 520, height: 420)
            made.isReleasedWhenClosed = false
            made.setFrameAutosaveName("TerminalDeckBrowserSettings")
            if made.frame.origin == .zero { made.center() }
            Self.window = made
            made.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
    }
}

/// The window's content: the Browser page in the Settings look, without back and forward.
struct NativeBrowserSettingsWindowContent: View {
    var body: some View {
        NativeBrowserSettings()
            .environment(\.deckSettingsColumn, true)
            .environment(\.deckSettingsNavigation, false)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .background(NativeSettingsStyle.page)
    }
}
