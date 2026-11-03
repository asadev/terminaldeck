import CoreGraphics
import Foundation

/// Where the phone's trackpad puts this Mac's pointer (item 60, 1 Nov: "sometimes the cursor is not where I see it;
/// after a blink it shows somewhere else"). Measured cause: every move was added to the pointer position READ BACK
/// from the system, but a posted event moves the pointer a few ms later — read back too soon, it is the position
/// before the last move, so moves were lost, the Mac's pointer fell behind the one the phone draws, and the Mac's
/// report (also read back) pulled the drawn pointer to the stale place.
/// Now the Mac remembers where it last put the pointer for the phone and builds on that while it is fresh; a phone that
/// knows where it wants the pointer sends the place itself (absolute, a share of the display), so both agree exactly.
/// Positions are global display points (top-left origin, as `CGDisplayBounds`).
public final class MacPointerModel: @unchecked Sendable {
    /// How long the Mac trusts its own last placement over what the system reads back.
    public static let fresh: TimeInterval = 1.0
    private let lock = NSLock()
    private var placed: (point: CGPoint, at: TimeInterval)?

    public init() {}

    /// The pointer as the phone's moves see it: where this Mac last put it while that is fresh and on this display,
    /// else where the system says it is (the person at the Mac may have moved it), else the display's middle.
    public func current(real: CGPoint?, bounds: CGRect, now: TimeInterval) -> CGPoint {
        if let placed = placedIfFresh(bounds: bounds, now: now) { return placed }
        if let real, bounds.insetBy(dx: -1, dy: -1).contains(real) { return real }
        return CGPoint(x: bounds.midX, y: bounds.midY)
    }

    /// Where this Mac last put the pointer for the phone, while that is fresh and on this display.
    public func placedIfFresh(bounds: CGRect, now: TimeInterval) -> CGPoint? {
        guard let placed = lock.withLock({ placed }), now - placed.at < Self.fresh, bounds.insetBy(dx: -1, dy: -1).contains(placed.point) else { return nil }
        return placed.point
    }

    /// A move by a share of the display (older phones), from `current`.
    public func move(dx: Double, dy: Double, real: CGPoint?, bounds: CGRect, now: TimeInterval) -> CGPoint {
        let from = current(real: real, bounds: bounds, now: now)
        return place(Self.clamp(CGPoint(x: from.x + dx * bounds.width, y: from.y + dy * bounds.height), to: bounds), now: now)
    }

    /// A move to a place (0…1 across and down the display), as the phone draws it.
    public func moveTo(x: Double, y: Double, bounds: CGRect, now: TimeInterval) -> CGPoint {
        place(Self.clamp(CGPoint(x: bounds.minX + x * bounds.width, y: bounds.minY + y * bounds.height), to: bounds), now: now)
    }

    private func place(_ point: CGPoint, now: TimeInterval) -> CGPoint {
        lock.withLock { placed = (point, now) }
        return point
    }

    public static func clamp(_ point: CGPoint, to bounds: CGRect) -> CGPoint {
        CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX - 1), y: min(max(point.y, bounds.minY), bounds.maxY - 1))
    }
}
