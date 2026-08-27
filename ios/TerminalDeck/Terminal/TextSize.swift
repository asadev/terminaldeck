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
 * That was already true of the *storage* — one defaults key, no session in it —
 * and it was still not true of the app, which is the complaint:
 *
 * > *"this bigger and smaller should be going to inside the settings page for
 * > the all of the terminals with one setting we can just change this for
 * > overall appearance page should be there in the settings and from there we
 * > can change colors text size and everything for all of them."*
 *
 * He was looking at *Bigger text* and *Smaller text* sitting in one session's
 * `…` menu. A control that lives inside a session **reads** as a control over
 * that session, whatever the storage does underneath, and the two rows are gone
 * for that reason alone. The one place to change it is Settings → Appearance.
 *
 * ## And it reaches the terminals that already exist
 *
 * The second half of *"one setting … for all of them"*, and it is not free.
 * `TerminalBridge` is a UIKit object holding a SwiftTerm view that has already
 * been handed a font; a `UserDefaults` write is invisible to it. Before this,
 * changing the size caught a session up only when it was next opened — which is
 * exactly the shape of a setting that looks broken: you change it, you go back,
 * and the terminal you were just reading is the size it always was.
 *
 * So `save` announces, on `Notification.Name.terminalTextSizeChanged`, and every
 * bridge alive listens. The same mechanism `TerminalThemeStore` uses for the
 * colours, for the same reason, written twice because the two settings are
 * stored in different places rather than because anybody liked it.
 *
 * **`save` is the only announcer, and that is deliberate.** `setTextSize` is
 * called twenty times a second during a pinch; broadcasting from there would
 * resize every other session on the phone on every frame of one gesture. `save`
 * is called once, when a step is pressed or a pinch ends.
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
    /// The size a fresh install starts at, until somebody changes it.
    ///
    /// > *"By default in the mobile application the text size should be around
    /// > 14pt as the standard size of the text inside the terminal by default."*
    ///
    /// Was 12 — what the app drew at from the first build. 14 is his call. It
    /// moves only the fresh-install default: `stored` returns this solely when
    /// nothing has been saved, so a size the person already picked is untouched.
    static let standard: CGFloat = 14
    /// One press of the smaller/larger control.
    static let step: CGFloat = 1

    /**
     * The defaults key, and it is internal rather than private for exactly one
     * reader: the Appearance row in Settings binds an `@AppStorage` to it.
     *
     * That row has to say the current size, and this type is a `UserDefaults`
     * façade with nothing observable on it — a SwiftUI body that read `stored`
     * would be drawn once and never invalidated, so the row would keep saying
     * "12 pt" after somebody came back from having changed it. `@AppStorage` on
     * the key itself is the smallest honest fix and it is the same shape the
     * light/dark picker already uses on `Appearance.key`.
     */
    static let key = "terminaldeck.textSize.v1"

    /// The size in use. `standard` until somebody changes it, and clamped on the
    /// way out so a stored value from a build with different bounds — or from a
    /// corrupted defaults file — cannot produce a one-point terminal.
    static var stored: CGFloat {
        let saved = UserDefaults.standard.double(forKey: key)
        guard saved > 0 else { return standard }
        return clamp(CGFloat(saved))
    }

    /**
     * Remember a size, and tell every terminal on the phone about it.
     *
     * The announcement is conditional on the value actually changing, which is
     * not an optimisation: `TerminalBridge` answers it by setting `font`, and
     * setting `font` at all makes SwiftTerm soft-reset the emulator and drop
     * application-cursor mode — so a redundant post would make the arrow keys
     * send the wrong bytes inside vim in every *other* open session. The
     * bridge guards this a second time in `setTextSize`; both guards are cheap
     * and neither is the other's excuse.
     */
    static func save(_ size: CGFloat) {
        let clamped = clamp(size)
        let before = stored
        UserDefaults.standard.set(Double(clamped), forKey: key)
        guard clamped != before else { return }
        NotificationCenter.default.post(name: .terminalTextSizeChanged, object: nil)
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

    /// What the Appearance row and the stepper beside it read. Mono in the UI
    /// because it is a measurement, and the design brief's rule is that data is
    /// mono.
    static func label(_ size: CGFloat) -> String {
        "\(Int(clamp(size))) pt"
    }
}

extension Notification.Name {
    /**
     * Somebody changed the terminal text size, and every terminal has to follow.
     *
     * Posted by `TextSize.save` and answered by `TerminalBridge`, which is the
     * only object in the app that cannot hear it any other way — a SwiftUI
     * screen redraws from `@AppStorage` on the same key, and SwiftTerm's view
     * has already been handed a font object it will keep until it is given
     * another. Named beside its one sender, the way
     * `Notification.Name.terminalSchemeChanged` is.
     */
    static let terminalTextSizeChanged = Notification.Name("terminaldeck.terminalTextSizeChanged")
}
