import AppKit
import Observation
import SwiftUI

struct ObjectRef: Codable, Hashable, Sendable {
    let kind: String
    let id: String

    init(kind: String, id: String) {
        self.kind = kind
        self.id = id
    }
}

/// Only registered, working item settings may open. No data registry or placeholder provider.
@MainActor
@Observable
final class ObjectWindows {
    static let shared = ObjectWindows()
    static let sceneID = "object"
    static let kinds: Set<String> = ["server", "device", "mcp", "source", "project", "agent"]

    private(set) var request = 0
    /// Every matching window observes its own revision; no window drains another item's close.
    private(set) var closeRequests: [ObjectRef: Int] = [:]
    private(set) var lastError: String?
    @ObservationIgnored private var pending: [ObjectRef] = []
    @ObservationIgnored private var openRevisions: [ObjectRef: Int] = [:]
    @ObservationIgnored private var providers: [String: Provider] = [:]
    /// Opt-in. Hidden checks must inject their private UserDefaults suite, never .standard.
    @ObservationIgnored fileprivate var frameDefaults: UserDefaults?

    private struct Provider {
        let title: @MainActor (ObjectRef) -> String
        let defaultSize: CGSize?
        let content: @MainActor (ObjectRef) -> AnyView
    }

    private init() {}

    @discardableResult
    static func register(kind: String,
                         title: @escaping @MainActor (ObjectRef) -> String,
                         defaultSize: CGSize? = nil,
                         content: @escaping @MainActor (ObjectRef) -> AnyView) -> Bool {
        let router = shared
        guard kinds.contains(kind) else {
            router.lastError = "This settings view could not be registered."
            return false
        }
        guard router.providers[kind] == nil else {
            router.lastError = "This settings view is already registered."
            return false
        }
        if let defaultSize {
            guard defaultSize.width.isFinite, defaultSize.height.isFinite,
                  defaultSize.width > 0, defaultSize.height > 0 else {
                router.lastError = "This settings window needs a valid size."
                return false
            }
        }
        router.providers[kind] = Provider(title: title, defaultSize: defaultSize, content: content)
        router.lastError = nil
        return true
    }

    static func hasProvider(for ref: ObjectRef) -> Bool {
        kinds.contains(ref.kind) && !ref.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && shared.providers[ref.kind] != nil
    }

    /// Accepted means queued through the existing person-action policy, not yet displayed.
    @discardableResult
    static func open(_ ref: ObjectRef) -> Bool {
        let router = shared
        guard hasProvider(for: ref) else {
            router.lastError = "Settings for this item aren't available yet."
            return false
        }
        router.lastError = nil
        let closeRevision = router.closeRequests[ref] ?? 0
        NativeFront.whenPersonActs("object-settings-" + frameKey(ref)) {
            // Closing/deleting the item cancels an older deferred open, without affecting other refs.
            guard (router.closeRequests[ref] ?? 0) == closeRevision else { return }
            // A provider can only be read here; it never opens/activates a window directly.
            guard hasProvider(for: ref) else {
                router.lastError = "Settings for this item aren't available yet."
                return
            }
            router.openRevisions[ref] = closeRevision
            if !router.pending.contains(ref) { router.pending.append(ref) }
            router.request &+= 1
        }
        return true
    }

    func takePendingObjects() -> [ObjectRef] {
        defer { pending.removeAll() }
        return pending
    }

    /// After a successful deletion, dismiss only this object's scene value. No app activation.
    @discardableResult
    static func close(_ ref: ObjectRef) -> Bool {
        guard kinds.contains(ref.kind), !ref.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            shared.lastError = "This settings window could not be identified."
            return false
        }
        shared.pending.removeAll { $0 == ref }
        shared.closeRequests[ref] = (shared.closeRequests[ref] ?? 0) &+ 1
        return true
    }

    fileprivate static func shouldDismiss(_ ref: ObjectRef) -> Bool {
        (shared.closeRequests[ref] ?? 0) > (shared.openRevisions[ref] ?? 0)
    }

    static func title(for ref: ObjectRef) -> String? {
        guard hasProvider(for: ref) else { return nil }
        return shared.providers[ref.kind]?.title(ref)
    }

    static func content(for ref: ObjectRef) -> AnyView? {
        guard hasProvider(for: ref) else { return nil }
        return shared.providers[ref.kind]?.content(ref)
    }

    static func defaultSize(for ref: ObjectRef) -> CGSize? {
        guard hasProvider(for: ref) else { return nil }
        return shared.providers[ref.kind]?.defaultSize ?? DeckTokens.Metrics.objectSize
    }

    /// Production wiring chooses its existing preference store. A proof chooses a private suite.
    static func configureFrameMemory(defaults: UserDefaults?) {
        shared.frameDefaults = defaults
    }

    fileprivate static func frameKey(_ ref: ObjectRef) -> String {
        // JSON encoded stable identity avoids delimiter collisions and path-shaped keys.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = (try? encoder.encode(ref)) ?? Data()
        return "objectWindow.frame." + bytes.base64EncodedString()
    }
}

/// One scene value per item. Its provider supplies DeckSettingsFrame and its real controls.
struct ObjectWindow: View {
    let ref: ObjectRef?
    @Environment(\.dismissWindow) private var dismissWindow

    private var initialSize: CGSize {
        ref.flatMap { ObjectWindows.defaultSize(for: $0) } ?? DeckTokens.Metrics.objectSize
    }

    var body: some View {
        Group {
            if let ref, let content = ObjectWindows.content(for: ref) {
                content
            } else {
                DeckSettingsFrame(title: "Settings") {
                    DeckError(title: "This settings view isn't available",
                              message: "Return to the item and open its settings again.")
                }
            }
        }
        // Ideal only: the scene's initial placement reads this; saved/user frames remain resizable.
        .frame(idealWidth: initialSize.width, idealHeight: initialSize.height)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .backgroundExtensionEffect(isEnabled: false)
        .modifier(NativeWindowChrome())
        .deckWindowAppear() // glass until the first layout, then a 0.15 s fade in
        .navigationTitle(ref.flatMap { ObjectWindows.title(for: $0) } ?? "Settings")
        .onChange(of: ref.flatMap { ObjectWindows.shared.closeRequests[$0] } ?? 0, initial: true) {
            guard let ref, ObjectWindows.shouldDismiss(ref) else { return }
            dismissWindow(id: ObjectWindows.sceneID, value: ref)
        }
        .background {
            if let ref { ObjectWindowFrameMemory(ref: ref) }
        }
    }
}

/// No polling, display ordering, activation or hit-testing. Writes only the explicitly supplied store.
private struct ObjectWindowFrameMemory: NSViewRepresentable {
    let ref: ObjectRef

    func makeNSView(context: Context) -> Reader { Reader() }

    func updateNSView(_ view: Reader, context: Context) {
        view.ref = ref
        view.attach()
    }

    static func dismantleNSView(_ view: Reader, coordinator: Void) { view.detach() }

    final class Reader: NSView {
        var ref: ObjectRef?
        private weak var trackedWindow: NSWindow?
        private var trackedRef: ObjectRef?
        private var tokens: [NSObjectProtocol] = []
        private var restorePending = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }

        func attach() {
            guard let window, let ref else { detach(); return }
            guard trackedWindow !== window || trackedRef != ref else { return }
            detach()
            trackedWindow = window
            trackedRef = ref
            restorePending = true
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.trackedWindow === window,
                      self.trackedRef == ref else { return }
                self.restore(window, ref: ref)
                self.restorePending = false
                self.observe(window)
            }
        }

        func detach() {
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens.removeAll()
            trackedWindow = nil
            trackedRef = nil
            restorePending = false
        }

        private func restore(_ window: NSWindow, ref: ObjectRef) {
            // No configured store means no frame writes or reads (including hidden harness defaults).
            guard let defaults = ObjectWindows.shared.frameDefaults else { return }
            if let values = defaults.array(forKey: ObjectWindows.frameKey(ref)) as? [Double],
               values.count == 4, values.allSatisfy(\.isFinite), values[2] > 0, values[3] > 0 {
                let saved = NSRect(x: values[0], y: values[1], width: values[2], height: values[3])
                window.setFrame(visibleFrame(saved, screen: window.screen), display: false)
            } else if let main = NativeLaunchWindow.mainWindow(), main !== window {
                var frame = window.frame
                frame.origin = NSPoint(x: main.frame.maxX + 12, y: main.frame.maxY - frame.height)
                window.setFrame(visibleFrame(frame, screen: main.screen), display: false)
            }
        }

        private func observe(_ window: NSWindow) {
            for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                         NSWindow.didEndLiveResizeNotification, NSWindow.willCloseNotification] {
                tokens.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.save() }
                })
            }
        }

        private func save() {
            guard !restorePending, let window = trackedWindow, let ref = trackedRef,
                  let defaults = ObjectWindows.shared.frameDefaults else { return }
            let frame = window.frame
            defaults.set([Double(frame.minX), Double(frame.minY), Double(frame.width), Double(frame.height)],
                         forKey: ObjectWindows.frameKey(ref))
        }

        private func visibleFrame(_ requested: NSRect, screen: NSScreen?) -> NSRect {
            // Keep only this new object's frame reachable when the saved display is absent.
            guard let safe = (screen ?? NSScreen.main)?.visibleFrame else { return requested }
            var frame = requested
            frame.size.width = min(frame.width, safe.width)
            frame.size.height = min(frame.height, safe.height)
            frame.origin.x = min(max(frame.minX, safe.minX), safe.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, safe.minY), safe.maxY - frame.height)
            return frame
        }
    }
}
