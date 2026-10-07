import Foundation
import TerminalDeckNativeCore
#if canImport(AppKit)
import AppKit
#endif

/// Native replacement for `wireHootMenuBar`'s display selection and screen
/// notifications. The composition still supplies the already-existing panels.
@MainActor public final class BackendHootScreenMonitor {
    private weak var bar: BackendHootMenuBar?
    private var observer: NSObjectProtocol?
    public init() { }

    public static func place(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> BackendHootIslandPlace {
        #if canImport(AppKit)
        // NSScreen.main follows the key window. screens[0] is the primary menu-bar
        // display, matching Electron's getPrimaryDisplay.
        let screens = NSScreen.screens
        guard let primary = screens.first else { throw NativeRPCError(code: "unavailable", message: "Hoot island has no display to live on.") }
        var chosen = primary
        if let raw = environment["TERMINALDECK_ISLAND_DISPLAY_X"], !raw.isEmpty,
           let x = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)), x.isFinite,
           let found = screens.first(where: { x >= $0.frame.minX && x < $0.frame.maxX }) { chosen = found }
        let wireFrame = CGRect(x: chosen.frame.minX, y: primary.frame.maxY - chosen.frame.maxY, width: chosen.frame.width, height: chosen.frame.height)
        let notch = BackendHootNotch.notchOf(wireFrame, screens: BackendHootNotch.readScreens())
        let menuBar = chosen.frame.maxY - chosen.visibleFrame.maxY
        return .init(display: wireFrame, barHeight: notch?.height ?? (menuBar > 0 ? menuBar : 24), notch: notch)
        #else
        throw NativeRPCError(code: "unavailable", message: "Hoot island is only available on Mac.")
        #endif
    }

    /// Once at startup, again on screen changes; these are subscriptions, never
    /// a timer. The app owns theme notifications and calls bar.themeChanged().
    public func start(bar: BackendHootMenuBar) {
        stop(); self.bar = bar
        #if canImport(AppKit)
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.bar?.displaysChanged() }
        }
        #endif
        bar.displaysChanged()
    }
    public func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil; bar = nil
    }
}

/// The transparent catcher can miss mouseExited when it hands input to the
/// island. Match hoot-catcher.ts's repeat entry rule in its native mouseMoved
/// binding, so the second hover wakes the same controller again.
public struct BackendHootCatcherEntryGate: Sendable {
    public static let repeatMS = 100.0
    private var inside = false, said = 0.0
    public init() { }
    public mutating func moved(at milliseconds: Double) -> String? {
        guard !inside || milliseconds - said >= Self.repeatMS else { return nil }
        inside = true; said = milliseconds; return "enter"
    }
    public mutating func left() -> String? {
        guard inside else { return nil }; inside = false; return "leave"
    }
    public func pressed(button: Int) -> String? { button == 0 ? "press" : nil }
}
