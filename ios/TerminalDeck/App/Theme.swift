/**
 * The palette, in one place, in both of the type systems that need it.
 *
 * These values are not invented here. They are `src/renderer/styles/tokens.css`
 * read across — the same hexes the desktop ships — because the phone and the
 * desktop are one product and a person who has both in front of them can see a
 * quarter-stop of difference in a grey even when they cannot name it. When that
 * file changes, this one changes with it.
 *
 * ## Why the accent is this blue and not a nicer one
 *
 * `#3b8fee` is lifted verbatim from the app icon — the top stop of the spine
 * gradient in `build/art/icon.mjs`. It is not "a blue that goes with the icon",
 * it is the icon's own blue, which is the only way an accent and a mark stop
 * drifting apart over a year of small adjustments.
 *
 * ## Why the greys are exactly neutral
 *
 * `r == g == b`, deliberately, on every surface. The set this replaces carried
 * three to four levels more red than blue: invisible in a swatch, and enough to
 * make a whole screen read as faintly orange once it fills one. That was
 * reported on the desktop before it was noticed here, and the phone inherited
 * the same bias from the same source.
 *
 * ## Two types, because there are two rendering systems
 *
 * `Theme` is SwiftUI's `Color` and belongs to the chrome. `Palette` is UIKit's
 * `UIColor` and belongs to the terminal and the key bar, which are UIKit views
 * that never see a SwiftUI environment. Both read from `Ink`, so a colour can be
 * changed once rather than in two places that will eventually disagree.
 */

import SwiftUI
import UIKit

/// The raw values. Private to the two façades below so nothing else can reach
/// past them and hard-code a hex.
private enum Ink {
    /* Surfaces. `--bg-primary` … `--bg-sunken`. */
    static let background = (0x19, 0x19, 0x19)
    static let raised = (0x20, 0x20, 0x20)
    static let raisedHigh = (0x25, 0x25, 0x25)
    static let sunken = (0x12, 0x12, 0x12)

    /* Text. `--text-primary` / `--text-secondary` / `--text-muted`. */
    static let primary = (0xed, 0xed, 0xed)
    static let secondary = (0xa8, 0xa8, 0xa8)
    static let muted = (0x8f, 0x8f, 0x8f)

    /* The icon's blue and the ink that goes on top of it. */
    static let accent = (0x3b, 0x8f, 0xee)
    static let accentPressed = (0x7d, 0xb4, 0xf5)
    static let onAccent = (0x0f, 0x11, 0x14)

    /* Status. The desktop's `--status-*`, unchanged: green means running, amber
       means it wants you, red means it stopped. */
    static let working = (0x64, 0xa6, 0xe8)
    static let waiting = (0xdd, 0xb0, 0x4a)
    static let input = (0xf0, 0x91, 0x3f)
    static let completed = (0x5f, 0xbf, 0x95)
    static let critical = (0xff, 0x6f, 0x60)
    static let positive = (0x5f, 0xbf, 0x95)
    static let warning = (0xdd, 0xb0, 0x4a)
}

private func channel(_ value: Int) -> Double { Double(value) / 255 }

private func swiftUI(_ rgb: (Int, Int, Int)) -> Color {
    Color(red: channel(rgb.0), green: channel(rgb.1), blue: channel(rgb.2))
}

private func uiKit(_ rgb: (Int, Int, Int)) -> UIColor {
    UIColor(red: channel(rgb.0), green: channel(rgb.1), blue: channel(rgb.2), alpha: 1)
}

/**
 * The app's own colours — everything that is not the terminal.
 *
 * Deliberately few. The design brief's rule is that hierarchy comes from weight
 * and colour rather than from six type sizes, and it only works if there are
 * three text colours rather than nine.
 */
enum Theme {
    /// The one accent. It means "this is the action" — a screen where four
    /// things are blue has no accent at all.
    static let accent = swiftUI(Ink.accent)
    /// The accent while a finger is on it. Lighter rather than darker, because
    /// on a dark surface "pressed" reads as *more* light, not less.
    static let accentPressed = swiftUI(Ink.accentPressed)
    /// What goes on top of a filled accent button. Near-black rather than
    /// white, and that is forced rather than chosen: no single blue is both
    /// readable as text on `#191919` and dark enough for white to be readable
    /// on top of it. Apple's own dark-mode tinted controls make the same trade.
    static let onAccent = swiftUI(Ink.onAccent)

    static let background = swiftUI(Ink.background)
    /// A card sitting on the background. Space separates things in this app;
    /// this is for the cases where space genuinely cannot.
    static let surface = swiftUI(Ink.raised)
    /// A surface on a surface — a chip inside a card.
    static let surfaceHigh = swiftUI(Ink.raisedHigh)

    static let primary = swiftUI(Ink.primary)
    static let secondary = swiftUI(Ink.secondary)
    static let faint = swiftUI(Ink.muted)

    /// Kept because two places still genuinely need a line: the top of a banner
    /// that overlays scrolling content, and the edge of a text field. Every
    /// other divider in this app has been replaced by space.
    static let hairline = Color(white: 1, opacity: 0.09)

    static let warning = swiftUI(Ink.warning)
    static let critical = swiftUI(Ink.critical)
    static let positive = swiftUI(Ink.positive)

    /// The dot on a session row. The vocabulary belongs to the desktop, so an
    /// unknown status gets a neutral colour rather than being dropped or
    /// guessed at.
    static func statusColor(_ status: String) -> Color {
        switch status {
        case "working": return swiftUI(Ink.working)
        case "waiting", "input": return swiftUI(Ink.waiting)
        case "completed": return swiftUI(Ink.completed)
        case "exited": return swiftUI(Ink.critical)
        case "idle": return swiftUI(Ink.muted)
        default: return swiftUI(Ink.muted)
        }
    }
}

/**
 * The terminal's colours, and the key bar's.
 *
 * Not in an asset catalog because the terminal is dark in both appearances — a
 * light-mode terminal would be a different palette, not a lighter one, and
 * inventing that here would be guessing.
 *
 * The background is the *sunken* surface rather than a black of its own. That is
 * the design brief drawn as a colour: the chrome is a raised Apple surface, the
 * terminal is the well cut into it, and the two are one product rather than a
 * black rectangle pasted onto a grey app.
 */
enum Palette {
    static let terminalBackground = uiKit(Ink.sunken)
    static let terminalForeground = uiKit(Ink.primary)
    static let caret = uiKit(Ink.accent)

    /// A key cap at rest. Light on dark rather than a solid grey, so the bar
    /// picks up whatever the keyboard behind it is doing.
    static let key = UIColor(white: 1, alpha: 0.10)
    /// A key cap under a finger. A control that looks pressable must respond —
    /// the old bar had no pressed state at all, so every key felt dead even
    /// when it worked.
    static let keyPressed = UIColor(white: 1, alpha: 0.22)
    /// A sticky modifier that is armed and waiting to be spent.
    static let keyArmed = uiKit(Ink.accent)
    /// Ink on an armed key. See `Theme.onAccent` for why it is not white.
    static let onArmed = uiKit(Ink.onAccent)
    static let keyLabel = uiKit(Ink.primary)
    /// Group headers in the grid, and any label that is not the key itself.
    static let keyLabelFaint = uiKit(Ink.muted)
}
