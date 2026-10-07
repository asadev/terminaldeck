import Foundation
import TerminalDeckNativeCore
#if canImport(AppKit)
import AppKit

@MainActor private final class BackendHootMenuTarget: NSObject {
    let action: @MainActor () -> Void
    init(action: @escaping @MainActor () -> Void) { self.action = action }
    @objc func perform(_ sender: Any?) { action() }
}

/// Wrap the native island's existing panel. This owns no view or second island,
/// no delegate, and no pointer monitor; the existing view forwards shape events.
@MainActor public final class BackendHootNativeIslandBinding: BackendHootIslandSurface {
    public let ownerID: String
    private let panel: NSPanel
    private let primaryTop: () -> CGFloat
    private let push: (String, [NativeRPCValue]) -> Void
    private var closed = false
    private var observers: [NSObjectProtocol] = []
    private var callbacks: [String: @MainActor () -> Void] = [:]
    private var menuTargets: [BackendHootMenuTarget] = []
    public init(panel: NSPanel, ownerID: String, primaryTop: @escaping () -> CGFloat,
                send: @escaping (String, [NativeRPCValue]) -> Void) {
        self.panel = panel; self.ownerID = ownerID; self.primaryTop = primaryTop; push = send
        panel.styleMask.insert(.nonactivatingPanel)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        panel.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle])
        panel.hidesOnDeactivate = false; panel.hasShadow = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.isMovable = false; panel.isMovableByWindowBackground = false; panel.acceptsMouseMovedEvents = true
        for (name, event) in [(NSWindow.didBecomeKeyNotification, "focus"), (NSWindow.didResignKeyNotification, "blur"), (NSWindow.willCloseNotification, "closed")] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                // AppKit delivers these synchronously on its main thread. Run
                // synchronously so a press/blur retains the 500ms grace ordering.
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if event == "closed" { self.closed = true }
                    self.callbacks[event]?()
                }
            })
        }
    }
    public var destroyed: Bool { closed }
    public var focused: Bool { panel.isKeyWindow }
    public var bounds: CGRect {
        let frame = panel.frame
        return CGRect(x: frame.minX, y: primaryTop() - frame.maxY, width: frame.width, height: frame.height)
    }
    public func setBounds(_ bounds: CGRect) { panel.setFrame(BackendHootNotch.appKitFrame(bounds, primaryTop: primaryTop()), display: true) }
    public func showInactive() { panel.orderFrontRegardless() }
    public func focus() { panel.makeKeyAndOrderFront(nil) }
    public func blur() { panel.resignKey() }
    public func destroy() {
        guard !closed else { return }; panel.close(); closed = true
        for observer in observers { NotificationCenter.default.removeObserver(observer) }; observers = []; callbacks = [:]
    }
    public func ignoreMouseEvents(_ ignore: Bool) { panel.ignoresMouseEvents = ignore; panel.acceptsMouseMovedEvents = true }
    public func send(_ channel: String, arguments: [NativeRPCValue]) { guard !closed else { return }; push(channel, arguments) }
    public func on(_ event: String, action: @escaping @MainActor () -> Void) { callbacks[event] = action }
    public func menu(_ actions: [BackendHootMenuAction]) {
        let menu = NSMenu(); menuTargets = []
        for action in actions {
            guard let label = action.label else { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            if let run = action.run {
                let target = BackendHootMenuTarget(action: run); menuTargets.append(target)
                item.target = target; item.action = #selector(BackendHootMenuTarget.perform(_:))
            }; menu.addItem(item)
        }
        if let view = panel.contentView {
            menu.popUp(positioning: nil, at: view.convert(panel.mouseLocationOutsideOfEventStream, from: nil), in: view)
        }
    }
}

/// Wrap the invisible native pointer catcher supplied by the island controller.
@MainActor public final class BackendHootNativeCatcherBinding: BackendHootCatcherSurface {
    public let ownerID: String
    private let panel: NSPanel
    private let primaryTop: () -> CGFloat
    public private(set) var destroyed = false
    public init(panel: NSPanel, ownerID: String, primaryTop: @escaping () -> CGFloat) {
        self.panel = panel; self.ownerID = ownerID; self.primaryTop = primaryTop
        panel.styleMask.insert(.nonactivatingPanel)
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 4)
        panel.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle])
        panel.hidesOnDeactivate = false; panel.hasShadow = false; panel.isOpaque = false; panel.backgroundColor = .clear
        panel.isMovable = false; panel.isMovableByWindowBackground = false; panel.acceptsMouseMovedEvents = true
    }
    public func setBounds(_ bounds: CGRect) { panel.setFrame(BackendHootNotch.appKitFrame(bounds, primaryTop: primaryTop()), display: false) }
    public func showInactive() { if !panel.isVisible { panel.orderFrontRegardless() } }
    public func ignoreMouseEvents(_ ignore: Bool) { panel.ignoresMouseEvents = ignore }
    public func destroy() { guard !destroyed else { return }; destroyed = true; panel.close() }
}
#endif
