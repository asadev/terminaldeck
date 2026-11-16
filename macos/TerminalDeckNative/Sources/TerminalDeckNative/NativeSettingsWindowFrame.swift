import AppKit
import SwiftUI

/// The Settings window's size and place (owner, 14 Nov: "Make it double than the current size … It's too small to see
/// content inside"). About 1240 x 860 points (twice the old 760 x 560 in area and more); on a smaller screen as large as
/// fits with a comfortable margin, never under the menu bar or the Dock (the screen's visible frame excludes both). A
/// size he chose by dragging is remembered and used next time. It opens centred on the window he is using.
enum NativeSettingsWindowFrame {
    static let preferred = CGSize(width: 1240, height: 860)
    static let minimum = CGSize(width: 680, height: 440)
    /// The room kept free around the default size on a screen too small for it.
    static let margin: CGFloat = 40
    /// The pages' reading column inside the wider window: rows never stretch edge to edge. Review 14 Nov (item 11): one
    /// column on every page, the title and the first row on the same left edge, 704 pt of rows.
    static let readingWidth: CGFloat = 704 + 2 * DeckTokens.Metrics.pageHorizontal
    static let sizeKey = "settingsWindow.size.v2"

    /// The window's size on a screen whose visible frame is `visible`. His own size is kept whole when it fits; the
    /// default keeps `margin` free on every side.
    static func size(visible: CGRect, saved: CGSize?) -> CGSize {
        let room = saved == nil ? visible.insetBy(dx: margin, dy: margin).size : visible.size
        let wanted = saved ?? preferred
        func fit(_ value: CGFloat, floor: CGFloat, room: CGFloat, screen: CGFloat) -> CGFloat {
            min(max(value, floor), max(room, min(floor, screen)), screen).rounded()
        }
        return CGSize(width: fit(wanted.width, floor: minimum.width, room: room.width, screen: visible.width),
                      height: fit(wanted.height, floor: minimum.height, room: room.height, screen: visible.height))
    }

    /// The whole frame: centred on `anchor` (the window he is using), else on the screen, and kept on the screen
    /// (inside the margin when it fits there).
    static func frame(visible: CGRect, anchor: CGRect?, saved: CGSize?) -> CGRect {
        let size = size(visible: visible, saved: saved)
        let inset = visible.insetBy(dx: margin, dy: margin)
        let area = size.width <= inset.width && size.height <= inset.height ? inset : visible
        let centre = anchor.map { CGPoint(x: $0.midX, y: $0.midY) } ?? CGPoint(x: visible.midX, y: visible.midY)
        let x = min(max((centre.x - size.width / 2).rounded(), area.minX), area.maxX - size.width)
        let y = min(max((centre.y - size.height / 2).rounded(), area.minY), area.maxY - size.height)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    static func savedSize(_ defaults: UserDefaults) -> CGSize? {
        guard let values = defaults.array(forKey: sizeKey) as? [Double], values.count == 2,
              values.allSatisfy({ $0.isFinite && $0 > 0 }) else { return nil }
        return CGSize(width: values[0], height: values[1])
    }

    static func remember(_ size: CGSize, in defaults: UserDefaults) {
        guard size.width >= minimum.width, size.height >= minimum.height else { return }
        defaults.set([Double(size.width), Double(size.height)], forKey: sizeKey)
    }

    /// The window he is using: the frontmost ordinary window of this app other than Settings itself.
    @MainActor static func anchorWindow(excluding settings: NSWindow) -> NSWindow? {
        NSApp.orderedWindows.first {
            $0 !== settings && $0.isVisible && !$0.isMiniaturized && $0.level == .normal && !($0 is NSPanel)
                && $0.frame.width > 200 && $0.frame.height > 200
        }
    }
}

/// Places the Settings window each time it opens (a new window, or the same one shown again after closing) and
/// remembers a size he drags it to. Draws nothing and takes no clicks.
struct NativeSettingsWindowPlacer: NSViewRepresentable {
    var defaults: UserDefaults = .standard
    func makeNSView(context: Context) -> PlacerView { PlacerView(defaults: defaults) }
    func updateNSView(_ view: PlacerView, context: Context) {}

    @MainActor final class PlacerView: NSView {
        private let defaults: UserDefaults
        private weak var tracked: NSWindow?
        nonisolated(unsafe) private var tokens: [NSObjectProtocol] = []
        private var placeOnShow = false
        init(defaults: UserDefaults) { self.defaults = defaults; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window !== tracked else { return }
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            tracked = window
            let anchor = NativeSettingsWindowFrame.anchorWindow(excluding: window)
            place(window, anchor: anchor)
            // SwiftUI may still size the new window after this first layout: place it once more right after.
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window else { return }
                self.place(window, anchor: anchor)
            }
            let centre = NotificationCenter.default
            tokens.append(centre.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let self, let window else { return }
                    NativeSettingsWindowFrame.remember(window.frame.size, in: self.defaults)
                }
            })
            tokens.append(centre.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.placeOnShow = true }
            })
            tokens.append(centre.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let self, self.placeOnShow, let window else { return }
                    self.placeOnShow = false
                    self.place(window, anchor: NativeSettingsWindowFrame.anchorWindow(excluding: window))
                }
            })
        }

        private func place(_ window: NSWindow, anchor: NSWindow?) {
            guard let screen = anchor?.screen ?? window.screen ?? NSScreen.main else { return }
            let frame = NativeSettingsWindowFrame.frame(visible: screen.visibleFrame, anchor: anchor?.frame,
                                                        saved: NativeSettingsWindowFrame.savedSize(defaults))
            if window.frame != frame { window.setFrame(frame, display: true, animate: false) }
        }

        deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }
}
