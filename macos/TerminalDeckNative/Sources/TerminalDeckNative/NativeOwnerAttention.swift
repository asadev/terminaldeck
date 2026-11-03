import AppKit
import TerminalDeckBackend
import TerminalDeckNativeCore

/// HOOTFIX (2026-10-09, Commander's 09:19–09:28 servers.manage requests): an owner question from
/// an AI app's key was drawn ONLY as a sheet on Terminal Deck's main window. With the person in
/// another app (his log: the front was Terminal) nothing reached him — no banner, no Dock sign —
/// and 45 seconds later it timed out. Every owner question from a key now also: posts a Mac banner (clicking it brings the question forward),
/// bounces the Dock icon once and counts on the Dock badge and the sidebar bell. The banner is
/// posted off the question's path, so it can never hold the question up.
@MainActor
enum NativeOwnerAttention {
    private static var open: [String: String] = [:]          // question id → what

    /// A new owner question (inline consent).
    static func ask(id: String, asker: String, what: String, why: String?) {
        guard open[id] == nil else { return }
        open[id] = what; refreshBadge()
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        let body = what + "." + (why.map { " Why: " + $0 } ?? "") + " Answer it in Terminal Deck."
        Task {
            _ = await NativeCompositionBanners.shared.post(title: "\(asker) needs your approval", body: body, clicked: {
                NSApp.activate() // front-ok: the person clicked this approval's banner (NativeOSBridge announces the click first)
                // Running in the background, every window was ordered out: bring them back as a Dock click does.
                NativeSVResident.shared.reopen()
                NativeLaunchWindow.ensureShown(front: true)
                NSApp.windows.first { $0.canBecomeMain && $0.isVisible }?.makeKeyAndOrderFront(nil) // front-ok: same banner click
            })
        }
    }
    static func settled(id: String) { if open.removeValue(forKey: id) != nil { refreshBadge() } }
    private static func refreshBadge() {
        NSApp.dockTile.badgeLabel = open.isEmpty ? nil : String(open.count)
    }
}
