import Observation
import Foundation
import TerminalDeckNativeCore
import TerminalDeckBackend

/// What the island view draws.
@MainActor
@Observable
final class IslandViewModel {
    var layout: IslandLayout
    /// Grown into the panel (set inside an animation).
    var expanded = false
    /// The engine is up and the main page is loaded.
    var engineUp = false
    /// The island's own page has loaded and can be shown.
    var pageLoaded = false
    var nativeState: IslandState?
    var appearance = "dark"
    var builtInScreen = false
    var cameraNotchScreen = false
    var options = FIXESIslandOptions()
    var quiet = true
    var hiddenWhileQuiet: Bool { quiet && !expanded && options.whenQuiet == .hide }
    var usesBlack: Bool { darkAppearance }
    var darkAppearance: Bool { FIXESIslandDisplayPolicy.dark(appearance: appearance, builtIn: builtInScreen, hasNotch: cameraNotchScreen || layout.notched, look: options.look) }

    init(layout: IslandLayout) {
        self.layout = layout
    }

    /// Only real state: nothing while the engine is down or before the page has spoken.
    var state: IslandState? { engineUp ? nativeState : nil }

    /// The production snapshot projector also accepts injected screen numbers
    /// for hermetic previews. It performs no IO and constructs no app owner.
    func acceptNativeSnapshot(_ value: NativeRPCValue, screen: IslandScreen, builtIn: Bool, options: FIXESIslandOptions) {
        engineUp = true; pageLoaded = true; appearance = value["appearance"].string ?? "dark"
        self.options = options; quiet = value["quiet"].bool ?? true; builtInScreen = builtIn
        var statuses = (value["sessions"].elements ?? []).compactMap { $0["status"].string }
        if value["hoot"]["busy"].bool == true { statuses.append("working") }
        nativeState = IslandState.native(sessionStatuses: statuses,
            line: value["label"]["text"].string ?? "Hoot", hootStatus: value["hoot"]["status"].string)
        var next = FIXESIslandDisplayPolicy.layout(for: screen, options: options, quiet: quiet)
        cameraNotchScreen = screen.safeAreaTop > 0 || next.notched
        let displayWidth = CGFloat(value["geometry"]["displayWidth"].number ?? Double(screen.frame.width))
        let barHeight = CGFloat(value["geometry"]["barHeight"].number ?? Double(next.row))
        let size = BackendHootIslandBounds.clamp(displayWidth: displayWidth, barHeight: barHeight,
            size: CGSize(width: value["size"]["width"].number.map { CGFloat($0) } ?? options.width.grown,
                height: value["size"]["height"].number.map { CGFloat($0) } ?? 420)) // room for Hoot's chat by default (Asad, 10 Oct)
        next.panel.width = size.width; next.panel.height = size.height
        next.contentSize = CGSize(width: max(1, size.width - 2 * IslandMetrics.contentInset),
            height: max(1, size.height - next.contentTop - IslandMetrics.contentInset))
        let canvas = BackendHootIslandBounds.window(displayWidth: displayWidth, barHeight: barHeight)
        next.expandedFrame = CGRect(x: next.centreX - canvas.width / 2, y: screen.frame.maxY - canvas.height,
            width: canvas.width, height: canvas.height)
        layout = next
    }
}
