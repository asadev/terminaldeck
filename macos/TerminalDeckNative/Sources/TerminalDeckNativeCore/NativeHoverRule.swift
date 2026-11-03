import Foundation

/// When an "the pointer arrived" from the island or its catcher counts as a
/// real hover (Asad, 7 Oct: "island is opening itself even when I don't hover").
///
/// TS opens the island only from the catcher page's `mousemove`, a real pointer
/// move inside the resting pill. AppKit also says "entered" when the island's
/// tracking area is re-added (every snapshot), when the catcher is placed under
/// a still pointer, on a space or display change and after display sleep — none
/// of which is the person hovering. So an arrival counts only when the pointer
/// is inside the shape now AND it moved just now (the system's own record of the
/// last pointer move, not the event that reported it).
public enum NativeHoverRule {
    /// A pointer move older than this did not bring the pointer here.
    public static let movedWithinSeconds: Double = 0.25

    public static func isRealHover(pointer: CGPoint, shape: CGRect, secondsSincePointerMoved: Double) -> Bool {
        guard secondsSincePointerMoved >= 0, secondsSincePointerMoved <= movedWithinSeconds else { return false }
        // A pointer pressed against the top edge of the screen is on the shape.
        return shape.insetBy(dx: 0, dy: -1).contains(pointer)
    }
}
