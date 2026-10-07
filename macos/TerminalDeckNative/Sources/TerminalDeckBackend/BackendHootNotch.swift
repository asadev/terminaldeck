import Foundation
import TerminalDeckNativeCore
#if canImport(AppKit)
import AppKit
#endif

/// `hoot-notch.ts`: AppKit is called directly in the native process. No JXA child
/// process, screen polling, or live-data access is needed.
public struct BackendHootScreenReport: Equatable, Sendable {
    public var x: Double, width: Double, height: Double, left: Double, right: Double, top: Double
    public init(x: Double, width: Double, height: Double, left: Double, right: Double, top: Double) {
        self.x = x; self.width = width; self.height = height; self.left = left; self.right = right; self.top = top
    }
}

public enum BackendHootNotch {
    public static func parseScreens(_ raw: String) -> [BackendHootScreenReport] {
        guard let data = BackendSharedText.trim(raw).data(using: .utf8), let value = try? NativeRPCValue.parseJSON(data), let rows = value.elements else { return [] }
        return rows.compactMap { row in
            guard row.fields != nil || row.elements != nil else { return nil }
            return .init(x: row["x"].number ?? 0, width: row["width"].number ?? 0, height: row["height"].number ?? 0,
                         left: row["left"].number ?? 0, right: row["right"].number ?? 0, top: row["top"].number ?? 0)
        }
    }

    /// Match x and size, ignoring y just as the old Electron/AppKit bridge did.
    /// Reuse the existing native notch type and plausibility rule.
    public static func notchOf(_ display: CGRect, screens: [BackendHootScreenReport]) -> IslandNotch? {
        guard let s = screens.first(where: { abs($0.x - display.minX) < 1 && abs($0.width - display.width) < 1 && abs($0.height - display.height) < 1 }) else { return nil }
        let reportedFrame = CGRect(x: display.minX, y: display.minY, width: s.width, height: s.height)
        guard var notch = IslandGeometry.notch(of: .init(frame: reportedFrame, visibleFrame: reportedFrame,
            auxiliaryTopLeft: CGRect(x: 0, y: 0, width: s.left, height: s.top),
            auxiliaryTopRight: CGRect(x: 0, y: 0, width: s.right, height: s.top))) else { return nil }
        notch.minX = display.minX + floor(s.left + 0.5); notch.width = floor(notch.width + 0.5); notch.height = floor(notch.height + 0.5)
        return notch
    }

    @MainActor public static func readScreens() -> [BackendHootScreenReport] {
        #if canImport(AppKit)
        return NSScreen.screens.map { screen in
            let left = screen.auxiliaryTopLeftArea ?? .zero, right = screen.auxiliaryTopRightArea ?? .zero
            return .init(x: screen.frame.minX, width: screen.frame.width, height: screen.frame.height,
                         left: left.width, right: right.width, top: max(left.height, right.height))
        }
        #else
        return [] // AppKit-only code is not applicable outside the Mac backend.
        #endif
    }

    /// Wire rectangles use the old top-down coordinates. AppKit bindings use this
    /// conversion when placing the already-existing native NSPanel.
    public static func appKitFrame(_ wire: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: wire.minX, y: primaryTop - wire.minY - wire.height, width: wire.width, height: wire.height)
    }
}

/// Only the backend limits that the existing SwiftUI geometry does not expose:
/// remembered drag limits and the fixed maximum window from `hoot-island.ts`.
public enum BackendHootIslandBounds {
    public static func limits(displayWidth: CGFloat, barHeight: CGFloat) -> (minWidth: CGFloat, maxWidth: CGFloat, minHeight: CGFloat, maxHeight: CGFloat) {
        let maxWidth = min(max(320, displayWidth - 16 * 2 - 10 * 2), 960).rounded(.toNearestOrAwayFromZero)
        let row = min(44, max(22, barHeight)).rounded(.toNearestOrAwayFromZero)
        return (min(420, maxWidth), maxWidth, max(180, row + 120), 520)
    }
    public static func clamp(displayWidth: CGFloat, barHeight: CGFloat, size: CGSize) -> CGSize {
        let l = limits(displayWidth: displayWidth, barHeight: barHeight)
        return CGSize(width: min(l.maxWidth, max(l.minWidth, size.width)).rounded(.toNearestOrAwayFromZero),
                      height: min(l.maxHeight, max(l.minHeight, size.height)).rounded(.toNearestOrAwayFromZero))
    }
    public static func window(displayWidth: CGFloat, barHeight: CGFloat) -> CGSize {
        let l = limits(displayWidth: displayWidth, barHeight: barHeight)
        return CGSize(width: l.maxWidth + 10 * 2 + 44 * 2, height: l.maxHeight + 56)
    }
    public static func place(display: CGRect, notch: IslandNotch?, size: CGSize) -> CGRect {
        let centre = notch?.midX ?? display.midX
        let width = min(floor(size.width + 0.5), display.width), height = min(floor(size.height + 0.5), display.height)
        let x = min(display.maxX - width, max(display.minX, centre - width / 2))
        return CGRect(x: floor(x + 0.5), y: display.minY, width: width, height: height)
    }
}
