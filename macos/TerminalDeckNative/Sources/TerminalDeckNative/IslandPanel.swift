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

/// Terminal Deck's island at the top centre of the screen — the native one.
///
/// One black shape in the menu bar, centred on the notch (or the menu bar's middle
/// without one). At rest a pill that shows the status and a badge; the pointer
/// resting on it grows it down into a panel holding the island page. It settles a
/// moment after the pointer leaves, on Escape, or when a click elsewhere takes the
/// keyboard. The timing rules are `IslandHover`; the numbers are `IslandGeometry`.
///
/// At rest the window is exactly the pill, so nothing around it is covered. Growing
/// widens the window first (same centre, same top) and then morphs the shape inside
/// it; settling morphs first and shrinks the window once the shape has landed.
@MainActor
final class IslandController: NSObject, NSWindowDelegate {
    static let shared = IslandController()

    /// Remembered "Show Island"; absent is on.
    static let shownKey = "IslandShown"
    private static let menuItemID = NSUserInterfaceItemIdentifier("dev.terminaldeck.native.show-island")

    private let model: IslandViewModel
    private let web: IslandWeb
    private var panel: IslandPanel?
    private var container: IslandContainerView?
    private var hover = IslandHover()
    private var deadlineTask: Task<Void, Never>?
    /// Bumped by every grow and settle, so a settle that finishes late does nothing.
    private var settleGeneration = 0
    private var started = false
    private var keyMonitor: Any?
    private var nativeHoot = false
    private var nativeShown = true
    func acceptNativeShown(_ shown: Bool) { nativeShown = shown; ensureMenuItem() }

    func useNativeHoot() {
        nativeHoot = true; deadlineTask?.cancel(); deadlineTask = nil
        web.unload(); model.engineUp = true; model.pageLoaded = true
    }
    func hootPanel() -> IslandPanel { if panel == nil { makePanel() }; return panel! }
    func acceptNativeHoot(_ value: NativeRPCValue) {
        guard nativeHoot else { return }
        model.engineUp = true; model.pageLoaded = true
        model.nativeState = IslandState.native(sessionStatuses: (value["sessions"].elements ?? []).compactMap { $0["status"].string },
            line: value["label"]["text"].string ?? "Hoot", hootStatus: value["hoot"]["status"].string)
        let next = value["expanded"].bool == true
        withAnimation(.spring(duration: 0.3, bounce: 0.1)) { model.expanded = next }
        var layout = IslandGeometry.layout(for: Self.islandScreen(native: true))
        let displayWidth = CGFloat(value["geometry"]["displayWidth"].number ?? Double(layout.expandedFrame.width))
        let barHeight = CGFloat(value["geometry"]["barHeight"].number ?? Double(IslandMetrics.fallbackBar))
        // shared/hoot-island.ts's defaultExpanded; a remembered drag is clamped
        // by the same backend limits. Only the shape changes inside this canvas.
        let defaultWidth = min(BackendHootIslandBounds.limits(displayWidth: displayWidth, barHeight: barHeight).maxWidth,
            min(IslandMetrics.panelMaxWidth, max(IslandMetrics.panelMinWidth, (displayWidth / 3).rounded())))
        let size = BackendHootIslandBounds.clamp(displayWidth: displayWidth, barHeight: barHeight,
            size: CGSize(width: value["size"]["width"].number.map { CGFloat($0) } ?? defaultWidth,
                height: value["size"]["height"].number.map { CGFloat($0) } ?? 260))
        layout.panel.width = size.width; layout.panel.height = size.height
        layout.contentSize = CGSize(width: max(1, size.width - 2 * IslandMetrics.contentInset),
            height: max(1, size.height - layout.contentTop - IslandMetrics.contentInset))
        layout.expandedFrame.size = BackendHootIslandBounds.window(displayWidth: displayWidth, barHeight: barHeight)
        model.layout = layout
        NativeCompositionHootUI.shared.reportPillSize(CGSize(width: layout.pill.outerWidth, height: layout.pill.height))
        container?.placeCanvas(); container?.refreshTracking()
    }

    private override init() {
        model = IslandViewModel(layout: IslandGeometry.layout(for: Self.islandScreen()))
        web = IslandWeb(log: AppModel.shared.engine.log)
        super.init()
        web.onLoaded = { [weak self] loaded in self?.pageLoaded(loaded) }
    }

    var isShown: Bool { nativeHoot ? nativeShown : UserDefaults.standard.bool(forKey: Self.shownKey) }

    /// Called once when the app has finished launching.
    func start() {
        guard !started else { return }
        started = true
        UserDefaults.standard.register(defaults: [Self.shownKey: true])

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(screensChanged(_:)),
                           name: NSApplication.didChangeScreenParametersNotification, object: nil)
        center.addObserver(self, selector: #selector(menuBeganTracking(_:)),
                           name: NSMenu.didBeginTrackingNotification, object: nil)
        center.addObserver(self, selector: #selector(appBecameActive(_:)),
                           name: NSApplication.didBecomeActiveNotification, object: nil)

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let isEscape = event.keyCode == 53
            let window = event.window
            let swallow = MainActor.assumeIsolated { () -> Bool in
                guard isEscape, let self, let panel = self.panel, window === panel, self.model.expanded else { return false }
                if self.nativeHoot { NativeCompositionHootUI.shared.send("hoot-panel:close") }
                else { self.update { $0.dismiss() } }
                return true
            }
            return swallow ? nil : event
        }

        watchEngine()
        engineChanged()
        // The native graph owns the island (BackendHootMenuBar shows it only when "show in the menu
        // bar" is on); showing the legacy panel here first put it on screen with the setting off.
        if isShown && !NativeCompositionRoot.fullGraphSelected { show() }
        ensureMenuItem()
        // SwiftUI may build the main menu after launch finishes.
        DispatchQueue.main.async { [weak self] in self?.ensureMenuItem() }
    }

    // MARK: Show / hide

    func setShown(_ shown: Bool) {
        if nativeHoot { nativeShown = shown; NativeCompositionHootUI.shared.configureShown(shown); return }
        UserDefaults.standard.set(shown, forKey: Self.shownKey)
        if shown { show() } else { hide() }
        ensureMenuItem()
    }

    @objc private func toggleShown(_ sender: Any?) {
        setShown(!isShown)
    }

    private func show() {
        if panel == nil { makePanel() }
        place()
        panel?.orderFrontRegardless() // front-ok: the non-activating island panel itself; it never takes the keyboard
        syncPointer()
    }

    private func hide() {
        deadlineTask?.cancel()
        deadlineTask = nil
        if hover.expanded { hover.dismiss() }
        settleGeneration += 1
        model.expanded = false
        guard let panel else { return }
        if panel.isKeyWindow { giveKeyboardBack() }
        panel.orderOut(nil)
        panel.setFrame(model.layout.collapsedFrame, display: false)
        container?.refreshTracking()
    }

    private func makePanel() {
        let frame = model.layout.collapsedFrame
        let panel = IslandPanel(frame: frame)
        let container = IslandContainerView(frame: NSRect(origin: .zero, size: frame.size))
        container.autoresizingMask = [.width, .height]
        let hosting = NSHostingView(rootView: IslandView(model: model, webView: web.webView))
        hosting.sizingOptions = [] // the window's size is ours, never the content's
        container.canvasFrame = { [weak self] size in
            self?.model.layout.canvasFrame(inWindowOfSize: size) ?? NSRect(origin: .zero, size: size)
        }
        container.host(hosting)
        panel.contentView = container
        panel.delegate = self

        container.trackingBox = { [weak self] bounds in
            guard let self else { return .zero }
            return self.model.layout.shapeBox(expanded: self.model.expanded, inWindowOfSize: bounds.size)
        }
        container.onEnter = { [weak self, weak container, weak panel] in
            if self?.nativeHoot == true {
                // Only a real hover on the shape: AppKit also says "entered" when the tracking
                // area is re-added under a still pointer (every snapshot) or the screen changes.
                guard let container, let panel else { return }
                let box = panel.convertToScreen(container.convert(container.trackingBox(container.bounds), to: nil))
                guard NativeHootPointer.realHover(onScreenRect: box) else { return }
                NativeCompositionHootUI.shared.send("hoot-panel:pointer", [.bool(true)])
            }
            else { self?.update { $0.pointerEntered(at: Self.now()) } }
        }
        container.onExit = { [weak self] in
            if self?.nativeHoot == true { NativeCompositionHootUI.shared.send("hoot-panel:pointer", [.bool(false)]) }
            else { self?.update { $0.pointerExited(at: Self.now()) } }
        }
        panel.allowsKey = { [weak self] in self?.nativeHoot == true || self?.model.expanded == true }
        panel.onPress = { [weak self] in self?.pressed() ?? false }
        panel.onHeld = { [weak self] value in
            if self?.nativeHoot == true { NativeCompositionHootUI.shared.send("hoot-panel:held", [.bool(value)]) }
        }
        panel.onContextClick = { [weak self] event in self?.contextClick(event) ?? false }

        self.panel = panel
        self.container = container
    }

    // MARK: Where it is

    /// The screen with the menu bar, as plain numbers.
    private static func islandScreen(native: Bool = false) -> IslandScreen {
        var selected = NSScreen.screens.first
        if native, let raw = ProcessInfo.processInfo.environment["TERMINALDECK_ISLAND_DISPLAY_X"],
           let x = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)), x.isFinite,
           let chosen = NSScreen.screens.first(where: { x >= $0.frame.minX && x < $0.frame.maxX }) { selected = chosen }
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

    private func place() {
        if nativeHoot { container?.placeCanvas(); container?.refreshTracking(); return }
        let layout = IslandGeometry.layout(for: Self.islandScreen())
        if layout != model.layout { model.layout = layout }
        panel?.setFrame(layout.frame(expanded: model.expanded), display: true)
        container?.placeCanvas() // the canvas itself may have changed size
        container?.refreshTracking()
    }

    /// A display came or went, changed resolution, or the menu bar moved to another one.
    @objc private func screensChanged(_ note: Notification) {
        if nativeHoot { return } // The shared BackendHootScreenMonitor owns placement.
        if model.expanded { update { $0.dismiss() } }
        place()
        syncPointer()
    }

    // MARK: Hover, press, keyboard

    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Every input goes through here: the state machine decides, this makes the screen match.
    private func update(_ change: (inout IslandHover) -> Void) {
        if nativeHoot { return }
        let was = hover.expanded
        change(&hover)
        if hover.expanded != was {
            if hover.expanded { grow() } else { settle() }
        }
        scheduleDeadline()
    }

    private func scheduleDeadline() {
        deadlineTask?.cancel()
        deadlineTask = nil
        guard let deadline = hover.deadline else { return }
        let delay = max(0, deadline - Self.now())
        deadlineTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.update { $0.advance(to: Self.now()) }
        }
    }

    private func grow() {
        guard let panel else { return }
        settleGeneration += 1
        // Wider window first — same centre, same top, so the shape does not move —
        // then the shape morphs down inside it.
        panel.setFrame(model.layout.expandedFrame, display: true)
        withAnimation(.spring(duration: 0.34, bounce: 0.14)) {
            model.expanded = true
        }
        container?.refreshTracking()
        web.run(IslandCommand.expanded(true))
    }

    private func settle() {
        settleGeneration += 1
        let generation = settleGeneration
        web.run(IslandCommand.expanded(false))
        withAnimation(.spring(duration: 0.3, bounce: 0), completionCriteria: .logicallyComplete) {
            model.expanded = false
        } completion: { [weak self] in
            Task { @MainActor [weak self] in self?.finishSettle(generation) }
        }
        container?.refreshTracking()
        Task { @MainActor [weak self] in self?.syncPointer() }
    }

    /// Settle now — a session was opened from the panel (lane B, NativeIslandContent).
    func collapse() {
        if nativeHoot { NativeCompositionHootUI.shared.send("hoot-panel:close"); return }
        if model.expanded { update { $0.dismiss() } }
    }

    /// The shape has landed: shrink the window back to the pill.
    private func finishSettle(_ generation: Int) {
        guard generation == settleGeneration, !model.expanded, let panel else { return }
        if panel.isKeyWindow { giveKeyboardBack() }
        panel.setFrame(model.layout.collapsedFrame, display: true)
        container?.refreshTracking()
        syncPointer()
    }

    /// A press on the resting pill grows it at once and hands it the keyboard; the
    /// press itself is swallowed (the window changes size under it). A press on the
    /// grown panel goes to the page as usual.
    private func pressed() -> Bool {
        if nativeHoot { NativeCompositionHootUI.shared.send("hoot-panel:focus"); return !model.expanded }
        guard !model.expanded else {
            update { $0.pressed(at: Self.now()) }
            return false
        }
        update { $0.pressed(at: Self.now()) }
        if model.expanded { panel?.makeKey() }
        return true
    }

    /// Right-click on the resting pill: the two things the island itself needs.
    private func contextClick(_ event: NSEvent) -> Bool {
        if nativeHoot { NativeCompositionHootUI.shared.send("hoot-panel:menu"); return true }
        guard !model.expanded, let container else { return false }
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open Terminal Deck", action: #selector(openApp(_:)), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        let hide = NSMenuItem(title: "Hide Island", action: #selector(toggleShown(_:)), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)
        NSMenu.popUpContextMenu(menu, with: event, for: container)
        return true
    }

    @objc private func openApp(_ sender: Any?) {
        NativeFront.onlyForPerson("island Open") { NSApp.activate() }
    }

    /// The tracking area only reports crossings; after the window or the box changes
    /// under a still pointer, ask where the pointer actually is.
    private func syncPointer() {
        guard let panel, let container, panel.isVisible else { return }
        var box = panel.convertToScreen(container.convert(container.trackingBox(container.bounds), to: nil))
        box.size.height += 2 // a pointer pressed against the top edge of the screen is on it
        let inside = box.contains(NSEvent.mouseLocation)
        guard inside != hover.pointerInside else { return }
        update { inside ? $0.pointerEntered(at: Self.now()) : $0.pointerExited(at: Self.now()) }
    }

    /// Typing goes back to whatever had it before the island took it.
    private func giveKeyboardBack() {
        guard let panel else { return }
        if NSApp.isActive,
           let window = NSApp.orderedWindows.first(where: { $0 !== panel && $0.isVisible && $0.canBecomeKey }) {
            window.makeKey()
        } else {
            // Another app is in front: stepping out and back gives its window the keyboard again.
            panel.orderOut(nil)
            panel.orderFrontRegardless() // front-ok: the non-activating island panel itself; it never takes the keyboard
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        update { $0.keyboardChanged(true, at: Self.now()) }
    }

    func windowDidResignKey(_ notification: Notification) {
        update { $0.keyboardChanged(false, at: Self.now()) }
    }

    // MARK: The engine and the island page

    private func watchEngine() {
        withObservationTracking {
            _ = AppModel.shared.engine.phase
            _ = AppModel.shared.pageReady
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.engineChanged()
                self?.watchEngine()
            }
        }
    }

    /// The island page loads once the main page is up (its first load set the bridge
    /// cookie); when the engine goes, its page and what it said go too.
    private func engineChanged() {
        if nativeHoot { return }
        let app = AppModel.shared
        var engineURL: URL?
        if case .ready(let url) = app.engine.phase, app.pageReady { engineURL = url }
        if let engineURL {
            // lane B: with the content drawn in Swift there is no page to load or wait for.
            if NativeIslandContent.isNative { pageLoaded(true) } else { web.load(engineURL: engineURL) }
        }
        let up = engineURL != nil
        guard up != model.engineUp else { return }
        model.engineUp = up
        if !up {
            IslandRelay.shared.reset()
            web.unload()
            if NativeIslandContent.isNative { pageLoaded(false) } // lane B
        }
    }

    private func pageLoaded(_ loaded: Bool) {
        guard loaded != model.pageLoaded || !NativeIslandContent.isNative else { return } // lane B: told on every engine change
        model.pageLoaded = loaded
        update { $0.setAvailable(loaded) }
        if loaded, model.expanded { web.run(IslandCommand.expanded(true)) }
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
