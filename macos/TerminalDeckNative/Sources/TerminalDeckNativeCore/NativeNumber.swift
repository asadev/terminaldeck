import Foundation

/// The ONE safe way to turn a number from a tool, a request, an AI answer or a
/// saved file into an Int. `Int(Double)` traps, ending the whole app, for any
/// value outside Int's range (a JSON 1e300 is a valid number), so every such
/// conversion goes through here and an absurd number is refused or clamped.
public enum NativeNumber {
    /// The whole number in `range`; nil when missing, fractional, not finite or out of range.
    public static func integer(_ value: Double?, in range: ClosedRange<Int>) -> Int? {
        guard let value, let whole = Int(exactly: value), range.contains(whole) else { return nil }
        return whole
    }

    /// The number with its fraction dropped, held inside `range`; `fallback` when missing or not finite.
    public static func clamped(_ value: Double?, to range: ClosedRange<Int>, fallback: Int) -> Int {
        guard let value, value.isFinite else { return fallback }
        let whole = value.rounded(.towardZero)
        if whole <= Double(range.lowerBound) { return range.lowerBound }
        if whole >= Double(range.upperBound) { return range.upperBound }
        return Int(whole)
    }
}
