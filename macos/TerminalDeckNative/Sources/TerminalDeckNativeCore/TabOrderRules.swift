import Foundation

/// The order of the tabs in the top strip, as the person arranged them (Asad, 2026-10-09: "i cant move tabs
/// of the windows left right rearrange as i want"). The page and the native browser own WHICH tabs exist;
/// this only decides the order they are drawn in, and it is remembered.
public enum TabOrderRules {
    /// The tabs in the saved order; tabs the saved list has never seen (new ones) go after, in their own order;
    /// saved ids that no longer exist are dropped.
    public static func arranged(_ ids: [String], saved: [String]) -> [String] {
        let present = Set(ids)
        var seen = Set<String>(), result: [String] = []
        for id in saved where present.contains(id) && seen.insert(id).inserted { result.append(id) }
        for id in ids where seen.insert(id).inserted { result.append(id) }
        return result
    }

    /// `id` moved to place `index` (0-based, clamped) among `order`.
    public static func moved(_ order: [String], id: String, to index: Int) -> [String] {
        guard let from = order.firstIndex(of: id) else { return order }
        var next = order; next.remove(at: from)
        next.insert(id, at: max(0, min(next.count, index)))
        return next
    }

    /// Where a tab grabbed at place `start` and slid `translation` points sideways belongs, tabs being `step` apart.
    public static func targetIndex(start: Int, translation: Double, step: Double, count: Int) -> Int {
        guard step > 0, count > 0 else { return start }
        return max(0, min(count - 1, start + Int((translation / step).rounded())))
    }

    /// Far enough out of the strip (sideways past the window, or up/down past `reach` points from the strip's
    /// edge) that letting go opens the tab in a window of its own.
    public static func popsOut(pointerY: Double, stripHeight: Double, reach: Double = 56) -> Bool {
        pointerY < -reach || pointerY > stripHeight + reach
    }
}
