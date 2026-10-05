import AppKit
import Observation
import TerminalDeckNativeCore

/// The terminal settings every native session terminal draws with — font, size,
/// copy-on-select, colour scheme and the app's light/dark — read through the same
/// channels the renderer reads them (`settings:get`, `prefs:get`) and followed live:
///
///  - `settings:changed` / `prefs:changed`, which the engine pushes for changes this
///    window did not make (the assistant, a paired phone);
///  - a fresh read whenever a window becomes key or the app becomes active, which
///    is how a change made in the Settings window reaches here: that page relays
///    its changes to the main page only, never to the engine's event stream;
///  - the system's own light/dark, for the "System" theme.
@MainActor
@Observable
final class NativeTerminalSettings {
    static let shared = NativeTerminalSettings()

    private(set) var preferences = TerminalPreferences() {
        didSet { if preferences != oldValue { notify() } }
    }
    /// The system's appearance, for the "System" theme.
    private(set) var systemIsDark = NativeTerminalSettings.readSystemIsDark() {
        didSet { if systemIsDark != oldValue { notify() } }
    }

    /// What the terminal paints right now.
    var scheme: TerminalScheme { preferences.scheme(systemIsDark: systemIsDark) }

    @ObservationIgnored private var storedSettings: Any?
    @ObservationIgnored private var storedPrefs: Any?
    @ObservationIgnored private var subscriptions: [EngineSubscription] = []
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var appearanceObservation: NSKeyValueObservation?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var reading: Task<Void, Never>?
    /// Every live terminal, told when anything here changes (held weakly).
    @ObservationIgnored private let terminals = NSHashTable<NativeTerminalSession>.weakObjects()

    private init() {}

    /// Repaint this terminal whenever the settings or the system appearance change.
    func follow(_ terminal: NativeTerminalSession) {
        terminals.add(terminal)
    }

    private func notify() {
        for terminal in terminals.allObjects { terminal.applyAppearance() }
    }

    /// Start following. Idempotent; the first terminal to appear calls it.
    func start() {
        guard !started else {
            reload()
            return
        }
        started = true
        subscriptions.append(EngineBridge.shared.on("settings:changed") { [weak self] args in
            guard let self, let first = args.first else { return }
            self.storedSettings = first
            self.recompute()
        })
        subscriptions.append(EngineBridge.shared.on("prefs:changed") { [weak self] args in
            guard let self, let first = args.first else { return }
            self.storedPrefs = first
            self.recompute()
        })
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSApplication.didBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            })
        }
        appearanceObservation = NSApplication.shared.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.systemIsDark = Self.readSystemIsDark() }
        }
        reload()
    }

    /// Read both stores again. A read that fails keeps what was last read.
    func reload() {
        guard EngineBridge.shared.isReady, reading == nil else { return }
        reading = Task { [weak self] in
            let s = try? await EngineBridge.shared.invoke("settings:get")
            let p = try? await EngineBridge.shared.invoke("prefs:get")
            guard let self else { return }
            if let s { self.storedSettings = s }
            if let p { self.storedPrefs = p }
            self.reading = nil
            self.recompute()
        }
    }

    private func recompute() {
        let next = TerminalPreferences.from(settings: storedSettings, prefs: storedPrefs)
        if next != preferences { preferences = next }
        let dark = Self.readSystemIsDark()
        if dark != systemIsDark { systemIsDark = dark }
    }

    private static func readSystemIsDark() -> Bool {
        NSApplication.shared.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

// MARK: - Turning the settings into AppKit values

extension TerminalPreferences {
    /// The font: the first of the person's family names this Mac has, else the
    /// app's own monospace face (SF Mono, as `--font-mono`).
    var nsFont: NSFont {
        let size = CGFloat(fontSize)
        for name in fontCandidates {
            // SF Mono is the system's own monospace face and is not reachable by family name.
            let squashed = name.lowercased().replacingOccurrences(of: " ", with: "")
            if squashed.hasPrefix("sfmono") || squashed == "ui-monospace" {
                return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            }
            if let font = NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: size) { return font }
            if let font = NSFont(name: name, size: size) { return font }
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

extension TerminalColour {
    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

extension TerminalScheme {
    func colour(_ hex: String, fallback: NSColor) -> NSColor {
        TerminalColour(hex: hex)?.nsColor ?? fallback
    }
}
