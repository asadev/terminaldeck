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
    var isBound: Bool { authority != nil }
    private init() {}

    func supply(registry: NativeChannelRegistry, authority: BackendHootJoinSourceAuthority) -> BackendHootJoinMenuSupply.UI {
        self.registry = registry; self.authority = authority
        IslandController.shared.useNativeHoot()
        return .init(makeIsland: { [weak self] in
            guard let self else { throw NativeRPCError(code: "unavailable", message: "The native island owner is closed.") }
            return BackendHootNativeIslandBinding(panel: IslandController.shared.hootPanel(), ownerID: authority.islandOwnerID,
                primaryTop: { NSScreen.screens.first?.frame.maxY ?? 0 }, send: { [weak self] channel, values in self?.receive(channel, values) })
        }, makeCatcher: { [weak self] in
            guard let self else { throw NativeRPCError(code: "unavailable", message: "The native catcher owner is closed.") }
            let panel = NativeCompositionHootCatcherPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            let view = NativeCompositionHootCatcherView(frame: .zero)
            view.event = { [weak self] value in self?.send("hoot-panel:catch", [.string(value)], catcher: true) }
            panel.contentView = view; self.catcher = panel
            return BackendHootNativeCatcherBinding(panel: panel, ownerID: authority.catcherOwnerID,
                primaryTop: { NSScreen.screens.first?.frame.maxY ?? 0 })
        }, place: { (try? BackendHootScreenMonitor.place()) ?? .init(display: .zero, barHeight: 24) },
        // A click on the island reaches here as a page message: the person's press a moment
        // ago brings the app forward; a hover, a scroll or a background request never does.
        showSession: { id in NativeFront.onlyForPerson("Hoot show-session") { AppModel.shared.selectTab(id); NSApp.activate(ignoringOtherApps: true) } },
        openApp: { page in
            NativeFront.onlyForPerson("Hoot open-app") { NSApp.activate(ignoringOtherApps: true) }
            if page == "hoot-settings" { AppModel.shared.requestSettings() }
        }, quit: { NSApp.terminate(nil) }, shownChanged: { [weak self] in
            Task { do {
                guard let self, let registry = self.registry else { return }
                let value = try await registry.invoke("hoot-menubar:config", context: .init(caller: .nativeApp, ownerID: BackendCompositionRoot.appOwnerID), arguments: [])
                IslandController.shared.acceptNativeShown(value["enabled"].bool == true)
            } catch { NSLog("[native Hoot] %@", error.localizedDescription) } }
        }, appearance: {
            NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? "dark" : "light"
        }, log: { message, details in
            NSLog("[native Hoot] %@", message)
            // Every island open names its reason and where the pointer was (Asad, 7 Oct).
            if message.hasPrefix("island: opened") {
                let reason = details["reason"].string ?? "?"
                AppModel.shared.engine.log.note("hoot: " + message + " (" + reason + "; " + NativeHootPointer.described + ")")
            }
        })
    }
    func bind(_ assembled: BackendHootJoinAssembly.Assembled) { self.assembled = assembled }
    func receive(_ channel: String, _ values: [NativeRPCValue]) {
        guard channel == "hoot-panel:snapshot", let value = values.first else { return }
        if let width = value["geometry"]["displayWidth"].number, let bar = value["geometry"]["barHeight"].number {
            geometry = (CGFloat(width), CGFloat(bar))
        }
        NativeIslandFeed.shared.acceptNative(value)
        NativeIslandChat.shared.acceptNative(value)
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
        await lastSend?.value; lastSend = nil
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
