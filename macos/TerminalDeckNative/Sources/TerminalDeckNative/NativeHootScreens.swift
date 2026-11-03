import AppKit
import ColorSync
import TerminalDeckBackend
import TerminalDeckNativeCore

@MainActor enum NativeHootScreens {
    public static func displays() -> [FIXESIslandDisplay] {
        NSScreen.screens.map { screen in
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let id: String
            if let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() {
                id = CFUUIDCreateString(nil, uuid) as String
            } else { id = "display-\(displayID)" }
            return .init(id: id, name: screen.localizedName, frame: screen.frame, builtIn: CGDisplayIsBuiltin(displayID) != 0)
        }
    }
    public static func selectedScreen(choice: FIXESIslandScreenChoice? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> NSScreen? {
        let screens = NSScreen.screens
        if let choice {
            let displays = displays()
            guard let selected = FIXESIslandDisplayPolicy.select(choice, screens: displays, pointer: NSEvent.mouseLocation),
                  let index = displays.firstIndex(where: { $0.id == selected.id }), screens.indices.contains(index) else { return screens.first }
            return screens[index]
        }
        if let raw = environment["TERMINALDECK_ISLAND_DISPLAY_X"], !raw.isEmpty,
           let x = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)), x.isFinite,
           let found = screens.first(where: { x >= $0.frame.minX && x < $0.frame.maxX }) { return found }
        return screens.first
    }
    public static func place(environment: [String: String] = ProcessInfo.processInfo.environment,
        choice: FIXESIslandScreenChoice? = nil) throws -> BackendHootIslandPlace {
        // NSScreen.main follows the key window. screens[0] is the primary menu-bar
        // display, matching Electron's getPrimaryDisplay.
        let screens = NSScreen.screens
        guard let primary = screens.first else { throw NativeRPCError(code: "unavailable", message: "Hoot island has no display to live on.") }
        let chosen = selectedScreen(choice: choice, environment: environment) ?? primary
        let wireFrame = CGRect(x: chosen.frame.minX, y: primary.frame.maxY - chosen.frame.maxY, width: chosen.frame.width, height: chosen.frame.height)
        // Read the chosen screen directly: matching only x/size can mistake a
        // stacked external screen for an equally sized notched built-in screen.
        let notch = IslandGeometry.notch(of: IslandScreen(frame: chosen.frame, visibleFrame: chosen.visibleFrame,
            safeAreaTop: chosen.safeAreaInsets.top, auxiliaryTopLeft: chosen.auxiliaryTopLeftArea ?? .zero,
            auxiliaryTopRight: chosen.auxiliaryTopRightArea ?? .zero))
        let menuBar = chosen.frame.maxY - chosen.visibleFrame.maxY
        return .init(display: wireFrame, barHeight: notch?.height ?? (menuBar > 0 ? menuBar : 24), notch: notch)
    }

    static func monitor() -> BackendHootScreenMonitor {
        BackendHootScreenMonitor(observe: { changed in
            let token = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
                Task { @MainActor in changed() }
            }
            return { NotificationCenter.default.removeObserver(token) }
        })
    }
}
