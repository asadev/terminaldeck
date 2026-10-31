import AppKit
import SwiftUI
import TerminalDeckNativeCore
import TerminalDeckBackend

/// The island's window: borderless, non-activating, one step above the menu bar
/// (below other apps' open menus), on every Space and over full-screen apps.
/// Hovering it never brings the app forward; a click on the grown panel makes it
/// the key window — without activating the app — so typing goes into it.
@MainActor
final class IslandPanel: NSPanel {
    /// A left click arrived. Return true to swallow it (a press on the resting pill).
    var onPress: (() -> Bool)?
    var onHeld: ((Bool) -> Void)?
    /// A right click arrived. Return true to swallow it.
    var onContextClick: ((NSEvent) -> Bool)?
    /// Whether it may take the keyboard now (only while grown).
    var allowsKey: () -> Bool = { false }

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false // the shape draws its own, only when grown
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isMovable = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        title = "Terminal Deck Island"
    }

    override var canBecomeKey: Bool { allowsKey() }
    override var canBecomeMain: Bool { false }

    /// Its top edge belongs in the menu bar; never pushed down below it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            onHeld?(true)
            if onPress?() == true { return }
        case .leftMouseUp: onHeld?(false)
        case .rightMouseDown:
            if onContextClick?(event) == true { return }
        default:
            break
        }
        super.sendEvent(event)
    }
}

/// Native Hoot's island window and pointer relay. The Hoot backend owns timing,
/// placement, focus and visibility; IslandGeometry supplies the drawn shape.
@MainActor
final class IslandController: NSObject {
    static let shared = IslandController()

    private static let menuItemID = NSUserInterfaceItemIdentifier("dev.terminaldeck.native.show-island")

    private let model: IslandViewModel
    var expandedForChecks: Bool { model.expanded }
    /// The drawn shape on screen (pill at rest, the grown panel when open), for the pointer monitors.
    var shapeOnScreen: CGRect? {
        guard let panel, let container, panel.isVisible else { return nil }
        return panel.convertToScreen(container.convert(container.trackingBox(container.bounds), to: nil))
    }
    private var panel: IslandPanel?
    private var container: IslandContainerView?
    private var started = false
    private var keyMonitor: Any?
    private var nativeShown = true
    func acceptNativeShown(_ shown: Bool) { nativeShown = shown; ensureMenuItem() }

    func hootPanel() -> IslandPanel { if panel == nil { makePanel() }; return panel! }
    func acceptNativeHoot(_ value: NativeRPCValue) {
        var builtIn = false
        if let screen = NativeHootScreens.selectedScreen(choice: NativeFIXESIslandPreferences.shared.persistedChoice) {
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            builtIn = CGDisplayIsBuiltin(id) != 0
        }
        model.acceptNativeSnapshot(value, screen: Self.islandScreen(), builtIn: builtIn,
            options: NativeFIXESIslandPreferences.shared.options)
        NativePermissionDesk.shared.sessionsChanged(value["sessions"].elements ?? [])
        let next = value["expanded"].bool == true
        withAnimation(.spring(duration: 0.3, bounce: 0.1)) { model.expanded = next }
        let layout = model.layout
        NativeCompositionHootUI.shared.reportPillSize(CGSize(width: layout.pill.outerWidth, height: layout.pill.height))
        container?.placeCanvas(); container?.refreshTracking()
    }

    private override init() {
        model = IslandViewModel(layout: IslandGeometry.layout(for: Self.islandScreen()))
        super.init()
    }

    var isShown: Bool { nativeShown }

    /// Called once when the app has finished launching.
    func start() {
        guard !started else { return }
        started = true

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(menuBeganTracking(_:)),
                           name: NSMenu.didBeginTrackingNotification, object: nil)
        center.addObserver(self, selector: #selector(appBecameActive(_:)),
                           name: NSApplication.didBecomeActiveNotification, object: nil)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let isEscape = event.keyCode == 53
            let window = event.window
            let swallow = MainActor.assumeIsolated { () -> Bool in
                guard isEscape, let self, let panel = self.panel, window === panel, self.model.expanded else { return false }
                NativeCompositionHootUI.shared.send("hoot-panel:close")
                return true
            }
            return swallow ? nil : event
        }

        ensureMenuItem()
        // SwiftUI may build the main menu after launch finishes.
        DispatchQueue.main.async { [weak self] in self?.ensureMenuItem() }
    }

    // MARK: Show / hide

    func setShown(_ shown: Bool) {
        nativeShown = shown
        NativeCompositionHootUI.shared.configureShown(shown)
    }

    @objc private func toggleShown(_ sender: Any?) {
        setShown(!isShown)
    }

    private func makePanel() {
        let frame = model.layout.collapsedFrame
        let panel = IslandPanel(frame: frame)
        let container = IslandContainerView(frame: NSRect(origin: .zero, size: frame.size))
        container.autoresizingMask = [.width, .height]
        let hosting = NSHostingView(rootView: IslandView(model: model))
        hosting.sizingOptions = [] // the window's size is ours, never the content's
        container.canvasFrame = { [weak self] size in
            self?.model.layout.canvasFrame(inWindowOfSize: size) ?? NSRect(origin: .zero, size: size)
        }
        container.host(hosting)
        panel.contentView = container

        container.trackingBox = { [weak self] bounds in
            guard let self else { return .zero }
            return self.model.layout.shapeBox(expanded: self.model.expanded, inWindowOfSize: bounds.size)
        }
        container.onEnter = { [weak container, weak panel] in
            // Tracking areas can be re-added under a still pointer; only a real hover opens Hoot.
            guard let container, let panel else { return }
            let box = panel.convertToScreen(container.convert(container.trackingBox(container.bounds), to: nil))
            guard NativeHootPointer.realHover(onScreenRect: box) else { return }
            NativeCompositionHootUI.shared.send("hoot-panel:pointer", [.bool(true)])
        }
        container.onExit = { NativeCompositionHootUI.shared.send("hoot-panel:pointer", [.bool(false)]) }
        panel.allowsKey = { true }
        panel.onPress = { [weak self] in self?.pressed() ?? false }
        panel.onHeld = { value in
            NativeCompositionHootUI.shared.send("hoot-panel:held", [.bool(value)])
        }
        panel.onContextClick = { [weak self] event in self?.contextClick(event) ?? false }

        self.panel = panel
        self.container = container
    }

    // MARK: Where it is

    /// The screen with the menu bar, as plain numbers.
    private static func islandScreen() -> IslandScreen {
        let selected = NativeHootScreens.selectedScreen(choice: NativeFIXESIslandPreferences.shared.persistedChoice)
        guard let screen = selected else {
            return IslandScreen(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 876))
        }
        return IslandScreen(frame: screen.frame,
                            visibleFrame: screen.visibleFrame,
                            safeAreaTop: screen.safeAreaInsets.top,
                            auxiliaryTopLeft: screen.auxiliaryTopLeftArea ?? .zero,
                            auxiliaryTopRight: screen.auxiliaryTopRightArea ?? .zero)
    }

    // MARK: Hover, press, keyboard

    /// Settle now — a session was opened from the panel (lane B, NativeIslandContent).
    func collapse() { NativeCompositionHootUI.shared.send("hoot-panel:close") }

    /// A press on the resting pill grows it at once and hands it the keyboard; the
    /// press itself is swallowed (the window changes size under it). A press on the
    /// grown panel goes to the page as usual.
    private func pressed() -> Bool {
        NativeCompositionHootUI.shared.send("hoot-panel:focus")
        return !model.expanded
    }

    /// Right-click on the resting pill: the two things the island itself needs.
    private func contextClick(_ event: NSEvent) -> Bool {
        NativeCompositionHootUI.shared.send("hoot-panel:menu")
        return true
    }

    // MARK: App menu ▸ Show Island

    /// SwiftUI owns the main menu and may rebuild it, so the item is put back
    /// whenever the menu bar is opened or the app comes forward.
    private func ensureMenuItem() {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu else { return }
        let state: NSControl.StateValue = isShown ? .on : .off
        if let item = appMenu.items.first(where: { $0.identifier == Self.menuItemID }) {
            item.state = state
            return
        }
        let item = NSMenuItem(title: "Show Island", action: #selector(toggleShown(_:)), keyEquivalent: "")
        item.identifier = Self.menuItemID
        item.target = self
        item.state = state
        let settings = appMenu.items.firstIndex { $0.keyEquivalent == "," }
        appMenu.insertItem(item, at: settings.map { $0 + 1 } ?? min(2, appMenu.items.count))
    }

    @objc private func menuBeganTracking(_ note: Notification) {
        guard let menu = note.object as? NSMenu, menu === NSApp.mainMenu else { return }
        ensureMenuItem()
    }

    @objc private func appBecameActive(_ note: Notification) {
        ensureMenuItem()
    }
}
