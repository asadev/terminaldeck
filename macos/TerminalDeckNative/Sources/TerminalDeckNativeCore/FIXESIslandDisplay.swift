import Foundation
import CoreGraphics

/// Persist the screen's stable identifier, not its changing order or position.
public struct FIXESIslandScreenChoice: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case main, builtIn, pointer, named }
    public var mode: Mode
    public var screenID: String?
    public var screenName: String?
    private enum CodingKeys: String, CodingKey { case mode, screenID = "screenUUID", screenName }
    public init(mode: Mode, screenID: String? = nil, screenName: String? = nil) {
        self.mode = mode; self.screenID = screenID; self.screenName = screenName
    }
    public static let main = Self(mode: .main)
    public static let pointer = Self(mode: .pointer)
    public var label: String {
        switch mode {
        case .main: "Screen with the menu bar"
        case .builtIn: "Built-in display"
        case .pointer: "Screen with the mouse"
        case .named: screenName ?? "Chosen screen"
        }
    }
}

public struct FIXESIslandDisplay: Equatable, Sendable {
    public var id: String
    public var name: String
    public var frame: CGRect
    public var builtIn: Bool
    public init(id: String, name: String, frame: CGRect, builtIn: Bool) {
        self.id = id; self.name = name; self.frame = frame; self.builtIn = builtIn
    }
}

public struct FIXESIslandOptions: Equatable, Sendable {
    public enum Look: String, CaseIterable, Sendable { case matchApp = "app", dark }
    public enum Width: String, CaseIterable, Sendable {
        case compact, standard, wide
        public var resting: CGFloat { switch self { case .compact: 260; case .standard: 340; case .wide: 420 } }
        public var grown: CGFloat { switch self { case .compact: 440; case .standard: 480; case .wide: 520 } }
    }
    public enum WhenQuiet: String, CaseIterable, Sendable { case show = "small", hide }
    public var look: Look
    public var width: Width
    public var whenQuiet: WhenQuiet
    public init(look: Look = .matchApp, width: Width = .standard, whenQuiet: WhenQuiet = .show) {
        self.look = look; self.width = width; self.whenQuiet = whenQuiet
    }
}

public enum FIXESIslandDisplayPolicy {
    /// The first screen is the menu bar's main screen. A disconnected named
    /// screen falls back there without erasing the choice for when it returns.
    public static func select(_ choice: FIXESIslandScreenChoice, screens: [FIXESIslandDisplay], pointer: CGPoint) -> FIXESIslandDisplay? {
        switch choice.mode {
        case .main: return screens.first
        case .builtIn: return screens.first(where: \.builtIn) ?? screens.first
        case .pointer: return screens.first(where: { $0.frame.contains(pointer) }) ?? screens.first
        case .named: return screens.first(where: { $0.id == choice.screenID }) ?? screens.first
        }
    }
    public static func usesBlack(builtIn: Bool, hasNotch: Bool) -> Bool { builtIn && hasNotch }
    public static func dark(appearance: String, builtIn: Bool, hasNotch: Bool, look: FIXESIslandOptions.Look = .matchApp) -> Bool {
        usesBlack(builtIn: builtIn, hasNotch: hasNotch) || appearance == "dark" || look == .dark
    }
    public static func pill(notchWidth: CGFloat?, barHeight: CGFloat, options: FIXESIslandOptions, quiet: Bool) -> CGSize {
        // Asad 10 Oct: the chosen width applies at rest too ("always small as before" was the
        // quiet pill ignoring it). Quiet only keeps the slimmer 26 pt height off a notch.
        let wanted: CGFloat = options.width.resting
        let width = max(wanted, notchWidth.map { $0 + 120 } ?? 0)
        return CGSize(width: width, height: quiet && notchWidth == nil ? 26 : min(44, max(22, barHeight)))
    }
    public static func layout(for screen: IslandScreen, options: FIXESIslandOptions, quiet: Bool) -> IslandLayout {
        var layout = IslandGeometry.layout(for: screen)
        let size = pill(notchWidth: layout.notch?.width, barHeight: layout.row, options: options, quiet: quiet)
        let room = max(1, screen.frame.width - 2 * IslandMetrics.screenEdge - 2 * IslandMetrics.panelShoulder)
        layout.pill.width = min(size.width, room); layout.pill.height = size.height; layout.row = size.height
        layout.ear = layout.notch.map { max(0, (layout.pill.width - $0.width) / 2) } ?? 0
        layout.gap = layout.notch?.width ?? 0
        layout.panel.width = min(options.width.grown, room); layout.panel.radius = 26
        layout.contentTop = layout.row + IslandMetrics.contentGap
        layout.contentSize = CGSize(width: max(1, layout.panel.width - 2 * IslandMetrics.contentInset),
            height: max(1, layout.panel.height - layout.contentTop - IslandMetrics.contentInset))
        layout.collapsedFrame = CGRect(x: layout.centreX - layout.pill.outerWidth / 2, y: screen.frame.maxY - size.height,
            width: layout.pill.outerWidth, height: size.height)
        // Keep the canvas stable across idle/active transitions and width changes.
        let windowWidth = min(screen.frame.width, max(FIXESIslandOptions.Width.wide.grown, layout.pill.width)
            + 2 * IslandMetrics.panelShoulder + 2 * IslandMetrics.shadowSide)
        layout.expandedFrame = CGRect(x: layout.centreX - windowWidth / 2, y: screen.frame.maxY - layout.expandedFrame.height,
            width: windowWidth, height: layout.expandedFrame.height)
        return layout
    }
}
