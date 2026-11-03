import AppKit
import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// The app's physical island/catcher owners. Their contexts are supplied by
/// Hoot's authority, never reconstructed from UI message arguments.
@MainActor
final class NativeCompositionHootUI {
    static let shared = NativeCompositionHootUI()
    private var registry: NativeChannelRegistry?
    private var authority: BackendHootJoinSourceAuthority?
    private var assembled: BackendHootJoinAssembly.Assembled?
    private var catcher: NSPanel?
    private var lastSend: Task<Void, Never>?
    private var pillSize: CGSize?
    private var geometry: (width: CGFloat, barHeight: CGFloat)?
    private var pointerMonitor: Any?
    private var localPointerMonitor: Any?
    private var pointerScreenID: String?
    private var appearanceObservation: NSKeyValueObservation?
    var isBound: Bool { authority != nil }
    private init() {}

    func supply(registry: NativeChannelRegistry, authority: BackendHootJoinSourceAuthority) -> BackendHootJoinMenuSupply.UI {
        self.registry = registry; self.authority = authority
        NativeFIXESIslandPreferences.shared.bind { [weak self] patch in
            guard let registry = self?.registry else { throw NativeRPCError(code: "unavailable", message: "Dynamic Island settings are not connected.") }
            return try await registry.invoke("settings:set", context: .init(caller: .nativeApp, ownerID: BackendCompositionRoot.appOwnerID), arguments: [patch])
        }
        return .init(makeIsland: { [weak self] in
            guard let self else { throw NativeRPCError(code: "unavailable", message: "The native island owner is closed.") }
            return NativeHootIslandBinding(panel: IslandController.shared.hootPanel(), ownerID: authority.islandOwnerID,
                primaryTop: { NSScreen.screens.first?.frame.maxY ?? 0 }, send: { [weak self] channel, values in self?.receive(channel, values) })
        }, makeCatcher: { [weak self] in
            guard let self else { throw NativeRPCError(code: "unavailable", message: "The native catcher owner is closed.") }
            let panel = NativeCompositionHootCatcherPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            let view = NativeCompositionHootCatcherView(frame: .zero)
            view.event = { [weak self] value in self?.send("hoot-panel:catch", [.string(value)], catcher: true) }
            panel.contentView = view; self.catcher = panel
            return NativeHootCatcherBinding(panel: panel, ownerID: authority.catcherOwnerID,
                primaryTop: { NSScreen.screens.first?.frame.maxY ?? 0 })
        }, place: { (try? NativeHootScreens.place(choice: NativeFIXESIslandPreferences.shared.persistedChoice)) ?? .init(display: .zero, barHeight: 24) },
        // A click on the island reaches here as a page message: the person's press a moment
        // ago brings the app forward; a hover, a scroll or a background request never does.
        showSession: { id in NativeFront.onlyForPerson("Hoot show-session") { AppModel.shared.selectTab(id); NSApp.activate(ignoringOtherApps: true) } },
        openApp: { page in
            // The island's sliders button opens Hoot's own quick settings panel, not the app's Settings.
            if page == "hoot-settings" { HootQuickSettingsPanel.show(); return }
            NativeFront.onlyForPerson("Hoot open-app") { NSApp.activate(ignoringOtherApps: true) }
        }, quit: { NativeQuit.terminate("Hoot's Quit") }, shownChanged: { [weak self] in
            Task { do {
                guard let self, let registry = self.registry else { return }
                let value = try await registry.invoke("hoot-menubar:config", context: .init(caller: .nativeApp, ownerID: BackendCompositionRoot.appOwnerID), arguments: [])
                IslandController.shared.acceptNativeShown(value["enabled"].bool == true)
            } catch { NSLog("[native Hoot] %@", error.localizedDescription) } }
        }, appearance: {
            NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"
        }, presentation: { NativeFIXESIslandPreferences.shared.options },
        settingsChanged: { NativeFIXESIslandPreferences.shared.accept($0) }, log: { message, details in
            NSLog("[native Hoot] %@", message)
            // Every island open names its reason and where the pointer was (Asad, 7 Oct).
            if message.hasPrefix("island: opened") {
                let reason = details["reason"].string ?? "?"
                AppModel.shared.engine.log.note("hoot: " + message + " (" + reason + "; " + NativeHootPointer.described + ")")
            }
        })
    }
    func bind(_ assembled: BackendHootJoinAssembly.Assembled) {
        self.assembled = assembled
        NativePermissionDesk.shared.present = { [weak self] in self?.openForRequest() }
        NativePermissionDesk.shared.cleared = { [weak self] in self?.requestsCleared() }
        var previousWidth = NativeFIXESIslandPreferences.shared.options.width
        NativeFIXESIslandPreferences.shared.changed = { [weak self] in
            do { try self?.assembled?.menu.apply() }
            catch { NSLog("[native Hoot] Could not show the island: %@", error.localizedDescription) }
            let width = NativeFIXESIslandPreferences.shared.options.width
            if width != previousWidth {
                do { try self?.assembled?.menu.useWidthPreset() }
                catch { NSLog("[native Hoot] Could not apply island width: %@", error.localizedDescription) }
                previousWidth = width
            }
            self?.pointerScreenID = nil; self?.assembled?.menu.displaysChanged()
        }
        appearanceObservation = NSApplication.shared.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.themeChanged() }
        }
        let pointerEvents: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: pointerEvents) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: pointerEvents) { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }; return event
        }
    }
    private var catcherHover = false
    /// Hover-to-open (Asad, 10 Oct: "its not coming with hover anymore only when we click"). The catcher's
    /// own tracking area misses enters while another app is in front, so the pointer monitors that already
    /// run decide too: inside the resting pill says "enter", out says "leave"; the menu bar's open delay
    /// keeps a passing pointer from opening it.
    func catcherHoverCheck(at point: CGPoint) -> Bool? {
        guard let catcher, catcher.isVisible else {
            if catcherHover { catcherHover = false; send("hoot-panel:catch", [.string("leave")], catcher: true) }
            return nil
        }
        // Open: the grown panel's shape decides, so leaving it closes (unless the person clicked in to type).
        if IslandController.shared.expandedForChecks, let shape = IslandController.shared.shapeOnScreen {
            let inside = shape.insetBy(dx: 0, dy: -1).contains(point)
            if inside != catcherHover { catcherHover = inside; send("hoot-panel:pointer", [.bool(inside)]) }
            return inside
        }
        let inside = catcher.frame.insetBy(dx: 0, dy: -1).contains(point)
        if inside != catcherHover {
            catcherHover = inside
            send("hoot-panel:catch", [.string(inside ? "enter" : "leave")], catcher: true)
        }
        return inside
    }
    private func pointerMoved() {
        _ = catcherHoverCheck(at: NSEvent.mouseLocation)
        guard NativeFIXESIslandPreferences.shared.choice.mode == .pointer else { return }
        let screens = NSScreen.screens, pointer = NSEvent.mouseLocation
        guard let screen = screens.first(where: { $0.frame.contains(pointer) }) ?? screens.first else { return }
        // The moving-pointer path only compares this attachment's numeric ID.
        // Stable UUID lookup and geometry work run once when its screen changes.
        let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? screen.localizedName
        guard id != pointerScreenID else { return }
        pointerScreenID = id; assembled?.menu.displaysChanged()
    }
    func receive(_ channel: String, _ values: [NativeRPCValue]) {
        guard channel == "hoot-panel:snapshot", let value = values.first else { return }
        if let width = value["geometry"]["displayWidth"].number, let bar = value["geometry"]["barHeight"].number {
            geometry = (CGFloat(width), CGFloat(bar))
        }
        IslandController.shared.acceptNativeHoot(value)
    }
    func invoke(_ channel: String, _ values: [NativeRPCValue] = []) async throws -> NativeRPCValue {
        guard let registry, let authority else { throw NativeRPCError(code: "unavailable", message: "The native island is not connected.") }
        return try await registry.invoke(channel, context: authority.islandContext(), arguments: values)
    }
    func send(_ channel: String, _ values: [NativeRPCValue] = [], catcher: Bool = false) {
        guard let registry, let authority else { return }
        let context = catcher ? authority.catcherContext() : authority.islandContext(), previous = lastSend
        lastSend = Task { await previous?.value
            do { _ = try await registry.send(channel, context: context, arguments: values) }
            catch { NSLog("[native Hoot] %@", error.localizedDescription) }
        }
    }
    func configureShown(_ shown: Bool) {
        guard let registry else { return }
        Task { do {
            _ = try await registry.invoke("hoot-menubar:configure", context: .init(caller: .nativeApp, ownerID: BackendCompositionRoot.appOwnerID),
                arguments: [.object([.init("enabled", .bool(shown))])])
        } catch { NSLog("[native Hoot] %@", error.localizedDescription) } }
    }
    func themeChanged() { assembled?.menu.themeChanged() }
    /// NativePermissionDesk: a request drops the island down; answering them all lets it settle.
    func openForRequest() { assembled?.menu.openForRequest() }
    func requestsCleared() { assembled?.menu.requestsCleared() }
    func reportPillSize(_ size: CGSize) {
        guard isBound, pillSize != size else { return }
        pillSize = size
        send("hoot-panel:size", [.object([.init("width", .number(Double(size.width))), .init("height", .number(Double(size.height)))])])
    }
    func clampPanelSize(_ size: CGSize) -> CGSize {
        guard let geometry else { return size }
        return BackendHootIslandBounds.clamp(displayWidth: geometry.width, barHeight: geometry.barHeight, size: size)
    }
    func resizePanel(_ size: CGSize) {
        let size = clampPanelSize(size)
        send("hoot-panel:resize", [.object([.init("width", .number(Double(size.width))), .init("height", .number(Double(size.height)))])])
    }
    func stop() async {
        appearanceObservation?.invalidate(); appearanceObservation = nil
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }; pointerMonitor = nil
        if let localPointerMonitor { NSEvent.removeMonitor(localPointerMonitor) }; localPointerMonitor = nil
        NativeFIXESIslandPreferences.shared.stop(); pointerScreenID = nil
        await lastSend?.value; lastSend = nil
        NativePermissionDesk.shared.present = nil; NativePermissionDesk.shared.cleared = nil
        catcher?.close(); catcher = nil; assembled = nil; registry = nil; authority = nil; pillSize = nil; geometry = nil
    }
}

/// TS makeCatcher: one level above the island ('main-menu' + 4), on every space and over
/// full-screen apps, never in Mission Control, see-through, never key.
private final class NativeCompositionHootCatcherPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backing, defer: flag)
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear; isOpaque = false; hasShadow = false
        hidesOnDeactivate = false; isReleasedWhenClosed = false; acceptsMouseMovedEvents = true
    }
}

/// Where the pointer is and whether it really moved there (NativeHoverRule).
@MainActor enum NativeHootPointer {
    static var secondsSinceMoved: Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .mouseMoved)
    }
    static func realHover(onScreenRect rect: CGRect) -> Bool {
        NativeHoverRule.isRealHover(pointer: NSEvent.mouseLocation, shape: rect, secondsSincePointerMoved: secondsSinceMoved)
    }
    /// "x,y on <display>, moved <n> ms ago" for engine.log.
    static var described: String {
        let point = NSEvent.mouseLocation
        let display = NSScreen.screens.firstIndex(where: { $0.frame.contains(point) }).map { "display \($0 + 1)" } ?? "no display"
        return "pointer \(Int(point.x)),\(Int(point.y)) on \(display), moved \(Int(secondsSinceMoved * 1000)) ms ago"
    }
}
private final class NativeCompositionHootCatcherView: NSView {
    var event: ((String) -> Void)?
    private var gate = BackendHootCatcherEntryGate()
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(next); tracking = next
    }
    // TS bindCatcher: only a real move on the pill says "enter" — never an enter AppKit
    // reports because the catcher was placed under a still pointer, a space or display
    // changed, or the display woke.
    override func mouseMoved(with event: NSEvent) {
        guard let window, NativeHootPointer.realHover(onScreenRect: window.frame) else { return }
        if let value = gate.moved(at: ProcessInfo.processInfo.systemUptime * 1000) { self.event?(value) }
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { if let value = gate.left() { self.event?(value) } }
    override func mouseDown(with event: NSEvent) { if let value = gate.pressed(button: event.buttonNumber) { self.event?(value) } }
}
