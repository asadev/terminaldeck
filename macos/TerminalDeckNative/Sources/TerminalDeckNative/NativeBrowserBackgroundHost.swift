import AppKit
import WebKit
import TerminalDeckNativeCore

/// Each loaded page keeps one real, finite rendering surface until it closes.
/// It is never a child of the main window: minimising that window must not hide this one.
@MainActor
final class NativeBrowserBackgroundHost {
    private weak var tab: NativeBrowserTab?
    private weak var previousSuperview: NSView?
    private weak var previousWindow: NSWindow?
    private var previousFrame = NSRect.zero
    private var observers: [NSObjectProtocol] = []
    private var stopped = false

    init(tab: NativeBrowserTab) {
        self.tab = tab
        for name in [NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    var size: CGSize {
        guard let tab else { return CGSize(width: 1280, height: 800) }
        if let size = tab.automation.viewport { return size }
        if let frame = BRDeviceSize.frame(deviceID: tab.deviceID, customWidth: tab.customWidth, customHeight: tab.customHeight) {
            return tab.deviceLandscape ? CGSize(width: frame.height, height: frame.width) : CGSize(width: frame.width, height: frame.height)
        }
        let last = previousFrame.size
        if last.width > 0, last.height > 0 { return last }
        return CGSize(width: 1280, height: 800)
    }

    func refresh() {
        guard !stopped, let tab, let view = tab.webView else { return }
        if let previousWindow, !previousWindow.isMiniaturized, !NSApp.isHidden,
           let previousSuperview, view.window === tab.automation.parkingWindow {
            self.previousWindow = nil
            self.previousSuperview = nil
            previousSuperview.addSubview(view)
            view.frame = previousFrame
            return
        }
        if let window = view.window, !(window is NativeBrowserCaptureWindow) {
            guard window.isMiniaturized || NSApp.isHidden else { return }
            previousWindow = window
            previousSuperview = view.superview
            previousFrame = view.frame
        } else if view.window != nil { return }
        park()
    }

    func park() {
        guard !stopped, let tab, let view = tab.webView else { return }
        if view.window is NativeBrowserCaptureWindow { return }
        if view.frame.width > 0, view.frame.height > 0 { previousFrame = view.frame }
        let window = NativeBrowserCaptureWindow(contentRect: NSRect(origin: CGPoint(x: -32_000, y: -32_000), size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.canHide = false
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenNone]
        // Set ownership first: moving the page invokes windowChanged synchronously.
        tab.automation.parkingWindow = window
        window.contentView = view
        view.setFrameSize(size)
        window.orderBack(nil)
        if !tab.shownToPerson { view.setAllMediaPlaybackSuspended(true) }
    }

    func movedToWindow() {
        guard !stopped, let tab, let view = tab.webView else { return }
        if let parking = tab.automation.parkingWindow, let window = view.window, window !== parking {
            tab.automation.parkingWindow = nil
            parking.close()
            previousSuperview = nil
            previousWindow = nil
        }
        // Hosts exchange the view synchronously. Wait until that exchange finishes before parking it.
        Task { @MainActor [weak self] in self?.refresh() }
    }

    func stop() {
        stopped = true
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        previousSuperview = nil
        previousWindow = nil
        if let window = tab?.automation.parkingWindow {
            tab?.automation.parkingWindow = nil
            window.contentView = nil
            window.close()
        }
    }

    isolated deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
}
