import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// Both scene observers share one drain. Tool requests reach the window opener
/// immediately; other screens wait for the existing person-action gate.
@MainActor
final class NativeScreenRequestDrain {
    private var awaitingPerson: [ScreenRef] = []

    func drain(takePending: () -> [ScreenRef], keepingCurrentFocus: (ScreenRef) -> Bool,
               prepare: @escaping @MainActor (ScreenRef) -> Void,
               whenPersonActs: (@escaping @MainActor () -> Void) -> Void,
               open: @escaping @MainActor (ScreenRef) -> Void) {
        let requests = takePending()
        guard !requests.isEmpty else { return }
        for ref in requests {
            if keepingCurrentFocus(ref) {
                // A later tool request also cancels a pending person-only reopen.
                awaitingPerson.removeAll { $0 == ref }
                prepare(ref)
                open(ref)
            } else if !awaitingPerson.contains(ref) {
                awaitingPerson.append(ref)
            }
        }
        guard !awaitingPerson.isEmpty else { return }
        // NativeFront replaces closures with the same key. Keep earlier batches
        // here, rather than capturing only the latest drained model queue.
        whenPersonActs { [self] in
            let waiting = awaitingPerson
            awaitingPerson = []
            for ref in waiting { prepare(ref); open(ref) }
        }
    }
}

/// Pages use the screen scene; tool requests preserve the person's focus.
@MainActor @Observable
final class NativePageWindows {
    static let emptyMainID = "page-window-home21"
    static let shared = NativePageWindows()
    static let agentWork = AWAgentsWatchModel()
    private(set) var moved: Set<ScreenRef> = []
    private var windows: [ScreenRef: WeakWindow] = [:]
    private var keptBehind: Set<ScreenRef> = []
    private var retainedFocus: [ScreenRef: WeakWindow] = [:]
    private let requestDrain = NativeScreenRequestDrain()
    private let defaults: UserDefaults
    private final class WeakWindow {
        weak var value: NSWindow?
        init(_ value: NSWindow) { self.value = value }
    }
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func page(kind: String, id: String) -> ScreenRef? {
        guard (kind == "panel" || kind == "hoot"), id != emptyMainID else { return nil }
        if kind == "hoot" || id == "hoot" { return ScreenRef(kind: .panel, id: "hoot", isHoot: true) }
        if id == "agents" || id.hasPrefix("agents-") { return ScreenRef(kind: .panel, id: "agents-all") }
        return ScreenRef(kind: .panel, id: id)
    }
    static func needsWebFocus(_ ref: ScreenRef) -> Bool {
        guard ref.kind == .panel else { return true }
        return !(ref.isHoot || ref.id.hasPrefix("settings:") || NativeScreens.registered.contains(ref.id)
                 || SHELLRoutes.owns(ref.id) || NativeFIXESDeviceTabs.deviceID(ref.id) != nil)
    }
    func contains(_ ref: ScreenRef) -> Bool { moved.contains(Self.page(kind: ref.screenKind, id: ref.id) ?? ref) }
    private func identity(_ ref: ScreenRef) -> ScreenRef { Self.page(kind: ref.screenKind, id: ref.id) ?? ref }
    func requested(_ ref: ScreenRef, bringForward: Bool = true) {
        let ref = identity(ref)
        moved.insert(ref)
        if bringForward { keptBehind.remove(ref) } else { keptBehind.insert(ref) }
    }
    func attached(_ ref: ScreenRef) { moved.insert(identity(ref)) }
    func keepsCurrentFocus(_ ref: ScreenRef) -> Bool { keptBehind.contains(identity(ref)) }
    func closed(_ ref: ScreenRef) {
        let ref = identity(ref)
        moved.remove(ref); windows[ref] = nil; keptBehind.remove(ref); retainedFocus[ref] = nil
    }
    func focus(_ ref: ScreenRef, bringForward: Bool = true) -> Bool {
        guard let window = windows[identity(ref)]?.value else { return false }
        if bringForward { NativeFront.whenPersonActs("page-window:\(ref.id)") { window.makeKeyAndOrderFront(nil) } }
        return true
    }
    func prepareToOpen(_ ref: ScreenRef) {
        let ref = identity(ref)
        if keptBehind.contains(ref), let window = NSApp.keyWindow { retainedFocus[ref] = WeakWindow(window) }
    }
    func openPendingScreens(from model: AppModel, using open: OpenWindowAction) {
        requestDrain.drain(takePending: model.takePendingScreens, keepingCurrentFocus: keepsCurrentFocus,
                           prepare: prepareToOpen,
                           whenPersonActs: { NativeFront.whenPersonActs("screens", $0) },
                           open: { ref in
                               guard UIGMemoryVisibility.showsScreen(ref) else { return }
                               open(value: ref)
                           })
    }
    func shown(_ ref: ScreenRef, in window: NSWindow) {
        let ref = identity(ref)
        windows[ref] = WeakWindow(window)
        // SwiftUI opens the existing screen scene. A tool request keeps the person's window key.
        if keptBehind.contains(ref) {
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.keptBehind.remove(ref) != nil else { return }
                window.orderBack(nil)
                if NSApp.isActive, let previous = self.retainedFocus.removeValue(forKey: ref)?.value, previous.isVisible { previous.makeKey() }
            }
        }
    }
    static func returnPageID(_ ref: ScreenRef, defaults: UserDefaults = .standard) -> String {
        if ref.id == "agents-all", let raw = defaults.string(forKey: "AGFRAME.view"), let mode = AGFRAMEAgentsPage.Mode(rawValue: raw) { return mode.sidebarID }
        return ref.id
    }
    func fallback() -> String {
        ["overview", "tasks", "agents-all", "memory", "servers"].first {
            let ref = ScreenRef(kind: .panel, id: $0)
            return UIGMemoryVisibility.showsScreen(ref) && !contains(ref)
        } ?? Self.emptyMainID
    }
    private func frameKey(_ ref: ScreenRef) -> String { "screenWindowFrame21.\(ref.kind.rawValue).\(ScreenRef.escape(ref.id))" }
    func saveFrame(_ ref: ScreenRef, frame: NSRect) { defaults.set(NSStringFromRect(frame), forKey: frameKey(ref)) }
    func savedFrame(_ ref: ScreenRef) -> NSRect? {
        guard let string = defaults.string(forKey: frameKey(ref)) else { return nil }
        let rect = NSRectFromString(string)
        return rect.width >= 480 && rect.height >= 320 ? rect : nil
    }
    static func visibleFrame(_ saved: NSRect, screens: [NSRect]) -> NSRect {
        guard let screen = screens.max(by: { $0.intersection(saved).area < $1.intersection(saved).area }) else { return saved }
        let size = NSSize(width: min(saved.width, screen.width), height: min(saved.height, screen.height))
        return NSRect(x: max(screen.minX, min(saved.minX, screen.maxX - size.width)),
                      y: max(screen.minY, min(saved.minY, screen.maxY - size.height)), width: size.width, height: size.height)
    }
}
private extension NSRect { var area: CGFloat { isNull ? 0 : width * height } }

private struct NativePageWindowKey: EnvironmentKey { static let defaultValue: ScreenRef? = nil }
extension EnvironmentValues {
    var pageWindow: ScreenRef? {
        get { self[NativePageWindowKey.self] }
        set { self[NativePageWindowKey.self] = newValue }
    }
}

/// The session header's exact icon, size, label and borderless treatment.
struct NativePagePopoutButton: View {
    let ref: ScreenRef
    var enabled = true
    var perform: ((ScreenRef) -> Void)? = nil
    @Environment(\.pageWindow) private var pageWindow
    var body: some View {
        if pageWindow == nil {
            Button { move() } label: {
                Image(systemName: "arrow.up.forward.square").font(.system(size: 14))
                    .frame(width: 28, height: 28).contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .help("Move to new window")
            .accessibilityLabel("Move to new window")
            .accessibilityIdentifier("page.move-to-window.\(ref.id)")
            .accessibilityAction { move() }
            .nativePaneDrag(.page(ref), title: ref.isHoot ? "Hoot" : ref.id, enabled: enabled)
            .disabled(!enabled)
        }
    }
    private func move() { if let perform { perform(ref) } else { AppModel.shared.movePageToWindow(ref) } }
}

extension View {
    func nativePageDrag(_ ref: ScreenRef, title: String) -> some View {
        modifier(NativePageDrag(ref: ref, title: title))
    }
}
private struct NativePageDrag: ViewModifier {
    let ref: ScreenRef
    let title: String
    @Environment(\.pageWindow) private var pageWindow
    func body(content: Content) -> some View {
        content.nativePaneDrag(.page(ref), title: title, enabled: pageWindow == nil)
    }
}

/// Save on move/resize, restore once. No activation or polling.
struct NativeScreenWindowPlacement: NSViewRepresentable {
    let ref: ScreenRef
    var store: NativePageWindows = .shared
    func makeNSView(context: Context) -> PlacementView { PlacementView(ref: ref, store: store) }
    func updateNSView(_ view: PlacementView, context: Context) {}
    final class PlacementView: NSView {
        let ref: ScreenRef
        let store: NativePageWindows
        private var observers: [NSObjectProtocol] = []
        init(ref: ScreenRef, store: NativePageWindows) { self.ref = ref; self.store = store; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver); observers = []
            guard let window else { return }
            store.shown(ref, in: window)
            if let saved = store.savedFrame(ref) {
                window.setFrame(NativePageWindows.visibleFrame(saved, screens: NSScreen.screens.map(\.visibleFrame)), display: false)
            }
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.willCloseNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] _ in
                    MainActor.assumeIsolated {
                        guard let self, let window else { return }
                        self.store.saveFrame(self.ref, frame: window.frame)
                    }
                })
            }
        }
        isolated deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
