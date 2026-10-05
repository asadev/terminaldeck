import Foundation
import CoreGraphics

/// One screen, as AppKit describes it (global coordinates, origin bottom-left).
/// Filled from `NSScreen` by the app; plain numbers so the maths can be tested.
public struct IslandScreen: Equatable, Sendable {
    /// `NSScreen.frame`
    public var frame: CGRect
    /// `NSScreen.visibleFrame` — its top tells how tall the menu bar is.
    public var visibleFrame: CGRect
    /// `NSScreen.safeAreaInsets.top` — non-zero under a camera housing.
    public var safeAreaTop: CGFloat
    /// `NSScreen.auxiliaryTopLeftArea` / `auxiliaryTopRightArea`: the menu-bar strips
    /// either side of the notch. Empty on a screen without one.
    public var auxiliaryTopLeft: CGRect
    public var auxiliaryTopRight: CGRect

    public init(frame: CGRect, visibleFrame: CGRect, safeAreaTop: CGFloat = 0,
                auxiliaryTopLeft: CGRect = .zero, auxiliaryTopRight: CGRect = .zero) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeAreaTop = safeAreaTop
        self.auxiliaryTopLeft = auxiliaryTopLeft
        self.auxiliaryTopRight = auxiliaryTopRight
    }
}

/// The camera housing, in global x.
public struct IslandNotch: Equatable, Sendable {
    public var minX: CGFloat
    public var width: CGFloat
    public var height: CGFloat
    public var midX: CGFloat { minX + width / 2 }
}

/// One state of the island's outline: its body, the radius of its bottom corners,
/// and the concave "shoulders" that flare its top corners out into the menu bar.
public struct IslandShapeSize: Equatable, Sendable {
    public var width: CGFloat
    public var height: CGFloat
    public var radius: CGFloat
    public var shoulder: CGFloat
    /// The body plus both shoulders: the box a pointer counts as "on it".
    public var outerWidth: CGFloat { width + shoulder * 2 }
}

/// The numbers, in points. The same as the Electron island's (`shared/hoot-island.ts`)
/// where the two have the same part.
public enum IslandMetrics {
    /// The menu bar's height when the screen does not say (a menu bar set to hide itself).
    public static let fallbackBar: CGFloat = 24
    public static let minRow: CGFloat = 22
    public static let maxRow: CGFloat = 44
    /// Each side of a notch: room for the status on the left and the badge on the right.
    public static let ear: CGFloat = 40
    /// No notch: a compact pill with its status and badge side by side — no
    /// notch-wide block, no empty gap. The Electron island's smallest pill (64)
    /// already holds a status and a "99+" badge.
    public static let plainWidth: CGFloat = 64
    public static let pillRadius: CGFloat = 12
    public static let pillShoulder: CGFloat = 6
    /// The grown panel: a third of the screen across, between these.
    public static let panelShare: CGFloat = 1.0 / 3.0
    public static let panelMinWidth: CGFloat = 620
    public static let panelMaxWidth: CGFloat = 720
    /// The panel's height below the top row.
    public static let panelBody: CGFloat = 236
    public static let panelRadius: CGFloat = 22
    public static let panelShoulder: CGFloat = 10
    /// Kept clear of the screen's edges on a narrow display.
    public static let screenEdge: CGFloat = 16
    /// Room around the grown panel for its shadow, so the window edge never cuts it.
    public static let shadowSide: CGFloat = 40
    public static let shadowBottom: CGFloat = 52
    /// The web content sits this far inside the panel, below the top row.
    public static let contentInset: CGFloat = 10
    public static let contentGap: CGFloat = 4
}

/// Where everything goes on one screen.
///
/// The island's window is centred on the notch (or the screen's middle), its top
/// on the screen's top edge — inside the menu bar, not under it. At rest the window
/// is exactly the pill; grown, it is the panel plus room for its shadow. Both
/// windows share one centre line, so the shape (drawn top-centre inside) never
/// moves when the window changes size.
public struct IslandLayout: Equatable, Sendable {
    public var screenFrame: CGRect
    public var centreX: CGFloat
    /// The top row's height: the notch's, else the menu bar's.
    public var row: CGFloat
    public var notch: IslandNotch?
    /// Beside a notch: the two ends of the top row (status left, badge right) and the
    /// notch between them. Both 0 without a notch, where the two sit side by side.
    public var ear: CGFloat
    public var gap: CGFloat
    /// Decided per screen: an external display beside a notched MacBook has none.
    public var notched: Bool { notch != nil }
    public var pill: IslandShapeSize
    public var panel: IslandShapeSize
    /// Window frames, global coordinates.
    public var collapsedFrame: CGRect
    public var expandedFrame: CGRect
    /// The web content: its size, and its top inside the panel.
    public var contentSize: CGSize
    public var contentTop: CGFloat

    public func frame(expanded: Bool) -> CGRect { expanded ? expandedFrame : collapsedFrame }

    /// The shape's box (shoulders included) inside a window of `size`, in the
    /// window's own bottom-left coordinates — the tracking area.
    public func shapeBox(expanded: Bool, inWindowOfSize size: CGSize) -> CGRect {
        let shape = expanded ? panel : pill
        return CGRect(x: (size.width - shape.outerWidth) / 2, y: size.height - shape.height,
                      width: shape.outerWidth, height: shape.height)
    }
}

public enum IslandGeometry {
    private static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        min(high, max(low, value))
    }

    /// Rounded up to an even number, so a window centred on a line sits on whole points
    /// the same way at every size.
    private static func even(_ value: CGFloat) -> CGFloat {
        (value / 2).rounded(.up) * 2
    }

    /// The notch, if this screen has one: both strips present, and a gap between them
    /// that is plausibly a camera housing (not a rounding error, not most of the screen).
    /// Widths only — they agree whatever coordinate space the strips are reported in.
    public static func notch(of screen: IslandScreen) -> IslandNotch? {
        let left = screen.auxiliaryTopLeft.width
        let right = screen.auxiliaryTopRight.width
        let strips = max(screen.auxiliaryTopLeft.height, screen.auxiliaryTopRight.height)
        let height = strips > 0 ? strips : screen.safeAreaTop
        guard left > 0, right > 0, height > 0 else { return nil }
        let width = screen.frame.width - left - right
        guard width >= 40, width <= screen.frame.width / 2 else { return nil }
        return IslandNotch(minX: screen.frame.minX + left, width: width, height: height)
    }

    /// The menu bar's height on this screen.
    public static func barHeight(of screen: IslandScreen, notch: IslandNotch?) -> CGFloat {
        if let notch { return notch.height }
        let bar = screen.frame.maxY - screen.visibleFrame.maxY
        return bar > 0 ? bar : IslandMetrics.fallbackBar
    }

    public static func layout(for screen: IslandScreen) -> IslandLayout {
        typealias M = IslandMetrics
        let frame = screen.frame
        let notch = notch(of: screen)
        let row = clamp(barHeight(of: screen, notch: notch).rounded(), M.minRow, M.maxRow)
        let centreX = notch?.midX ?? frame.midX

        // The pill: the notch plus an ear each side, or a short plain pill.
        let ear: CGFloat = notch == nil ? 0 : M.ear
        let pillWidth = notch.map { even($0.width + M.ear * 2) } ?? M.plainWidth
        let pill = IslandShapeSize(width: pillWidth, height: row,
                                   radius: min(M.pillRadius, row / 2), shoulder: M.pillShoulder)

        // The panel: a third of the screen, kept off its edges.
        let room = max(320, frame.width - M.screenEdge * 2 - M.panelShoulder * 2)
        var panelWidth = even(min(room, clamp((frame.width * M.panelShare).rounded(), M.panelMinWidth, M.panelMaxWidth)))
        let panelHeight = min((row + M.panelBody).rounded(), (frame.height * 0.7).rounded())

        // Both windows are centred on the same line; a window that would cross the
        // screen's edge is made narrower rather than moved off that line.
        let half = max(0, min(centreX - frame.minX, frame.maxX - centreX))
        var expandedWidth = even(panelWidth + M.panelShoulder * 2 + M.shadowSide * 2)
        if expandedWidth > half * 2 {
            expandedWidth = max(even(pill.outerWidth), (half * 2 / 2).rounded(.down) * 2)
            panelWidth = max(pill.width, expandedWidth - M.panelShoulder * 2 - M.shadowSide * 2)
        }
        let panel = IslandShapeSize(width: panelWidth, height: panelHeight,
                                    radius: M.panelRadius, shoulder: M.panelShoulder)

        let collapsedWidth = even(pill.outerWidth)
        let collapsed = CGRect(x: (centreX - collapsedWidth / 2).rounded(.down), y: frame.maxY - row,
                               width: collapsedWidth, height: row)
        let expandedHeight = panelHeight + M.shadowBottom
        let expanded = CGRect(x: (centreX - expandedWidth / 2).rounded(.down), y: frame.maxY - expandedHeight,
                              width: expandedWidth, height: expandedHeight)

        let contentTop = row + M.contentGap
        let content = CGSize(width: max(0, panelWidth - M.contentInset * 2),
                             height: max(0, panelHeight - contentTop - M.contentInset))

        return IslandLayout(screenFrame: frame, centreX: centreX, row: row, notch: notch,
                            ear: ear, gap: notch == nil ? 0 : max(0, pillWidth - ear * 2), pill: pill, panel: panel,
                            collapsedFrame: collapsed, expandedFrame: expanded,
                            contentSize: content, contentTop: contentTop)
    }
}
