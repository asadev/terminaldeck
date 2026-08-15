/**
 * How big the terminal's text is, and why that is a number rather than a zoom.
 *
 * A phone shows about fifty columns at twelve point. A desktop agent draws its
 * boxes, its diffs and its tables for eighty, so on a phone every one of them
 * wraps — and a wrapped table is not a smaller table, it is an unreadable one.
 * Dropping to ten point buys about ten columns; in landscape it reaches eighty
 * and the wrapping stops. Going the other way, at sixteen point a phone at
 * arm's length is readable by somebody who would otherwise have to bring it to
 * their face.
 *
 * So this is not a display zoom and must not be built as one. The column count
 * *is* the font: SwiftTerm divides the view's width by the advance of one
 * character, so changing the size changes the session's real geometry, sends a
 * `resize`, and makes the program on the far end reflow to it. That is the
 * point. A zoom that scaled pixels would leave the far end still writing eighty
 * columns into fifty and hand back a magnified mess.
 *
 * ## Why it is one setting for the whole phone
 *
 * Because it is about the person's eyes and the phone's screen, neither of which
 * changes between sessions. A per-session size would mean the same phone showed
 * two different sizes depending on which row was tapped, and would have to be
 * carried in the store for sessions that live on somebody else's machine.
 *
 * ## The bounds
 *
 * Nine points is where a lower-case `l` and a `1` stop being distinguishable on
 * a 3× screen, which in a terminal is not cosmetic — it is the difference
 * between reading a hash correctly and not. Twenty-two is where a portrait phone
 * is down to about twenty-eight columns, at which point a shell prompt alone
 * wraps and nothing can be read anyway. Whole points, because the useful step is
 * a column count and a fractional point size gives two sizes that look identical
 * and behave differently.
 */

import CoreGraphics
import Foundation

enum TextSize {

    /// Below this a `1`, an `l` and an `I` are the same shape.
    static let minimum: CGFloat = 9
    /// Above this a portrait phone cannot hold a shell prompt on one line.
    static let maximum: CGFloat = 22
    /// What the app has always drawn at, and what it still starts at.
    static let standard: CGFloat = 12
    /// One press of the smaller/larger control.
    static let step: CGFloat = 1

    private static let key = "terminaldeck.textSize.v1"

    /// The size in use. `standard` until somebody changes it, and clamped on the
    /// way out so a stored value from a build with different bounds — or from a
    /// corrupted defaults file — cannot produce a one-point terminal.
    static var stored: CGFloat {
        let saved = UserDefaults.standard.double(forKey: key)
        guard saved > 0 else { return standard }
        return clamp(CGFloat(saved))
    }

    static func save(_ size: CGFloat) {
        UserDefaults.standard.set(Double(clamp(size)), forKey: key)
    }

    /// Rounded to a whole point and held inside the bounds. Every path into a
    /// font size goes through here, including the pinch, so there is one place
    /// that can be wrong.
    static func clamp(_ size: CGFloat) -> CGFloat {
        min(maximum, max(minimum, size.rounded()))
    }

    /// A pinch, applied to the size the gesture started at rather than to the
    /// current one — compounding a scale factor twenty times a second turns a
    /// gentle spread into an instant jump to the maximum.
    static func scaled(_ base: CGFloat, by scale: CGFloat) -> CGFloat {
        clamp(base * scale)
    }

    static func larger(_ size: CGFloat) -> CGFloat { clamp(size + step) }
    static func smaller(_ size: CGFloat) -> CGFloat { clamp(size - step) }

    static func canGoLarger(_ size: CGFloat) -> Bool { clamp(size) < maximum }
    static func canGoSmaller(_ size: CGFloat) -> Bool { clamp(size) > minimum }

    /// What the menu row reads. Mono in the UI because it is a measurement, and
    /// the design brief's rule is that data is mono.
    static func label(_ size: CGFloat) -> String {
        "\(Int(clamp(size))) pt"
    }
}
