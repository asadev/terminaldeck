/**
 * A scheme's hexes, turned into the colour types this app has to hand one.
 *
 * `TerminalScheme` is a table of hex strings because it is shared with a
 * TypeScript file character for character. Nothing else in the app wants a
 * string, so every conversion happens here: `UIColor` for the emulator and the
 * frame around it, `SwiftTerm.Color` for the sixteen the emulator installs, and
 * `SwiftUI.Color` for the previews and the wells in the editor.
 *
 * `normalized` is `normaliseColour` from `src/shared/terminal-theme.ts`, rule
 * for rule: `#rgb` and `#rgba` are doubled out the way CSS specifies, everything
 * is lower-cased, and anything else is refused. Refusing is the point — a scheme
 * is stored as text and can be hand-edited, so this function is the only thing
 * standing between whatever is in that file and the emulator's theme.
 *
 * ## Eight digits, and where the alpha survives
 *
 * A selection is drawn *under* text that has to stay readable, so several of the
 * shipped schemes carry `#rrggbbaa` in that slot. `color` keeps the alpha and
 * `UIColor` carries it into `selectedTextBackgroundColor`, which is exactly what
 * the old hand-written `withAlphaComponent(0.5)` did. Nothing else keeps it:
 * `SwiftTerm.Color` has no alpha channel, and none of the sixteen has one to
 * lose.
 *
 * ## Parsing never fails to a colour
 *
 * The hexes in `builtIns` are literals and cannot be wrong at runtime, but a
 * *custom* scheme is somebody's typing — a hex field holds `#12` for as long as
 * it takes to type the rest. So `color` takes a fallback rather than returning
 * an optional: an unreadable value paints what the scheme would have painted
 * anyway rather than black, because a terminal that goes black under a
 * half-typed hex is a terminal somebody cannot type the other half into.
 */

import SwiftTerm
import SwiftUI
import UIKit

enum TerminalPalette {

    /**
     * The scheme actually painted, for the appearance the view is in.
     *
     * Every real scheme is absolute: choosing Nord gets Nord in both
     * appearances, and a terminal that threw that away at sunset would be the
     * app overruling the one choice the picker exists to offer.
     *
     * The exception is not a scheme at all. `follow-app` is the default and
     * means *keep doing what this app has always done* — take the ground and the
     * ink from the phone's own light/dark, which here resolves to **Deck Dark**
     * or **Deck Light**. Somebody who never opens the picker keeps that
     * behaviour exactly, which is the whole reason the shared file spends an id
     * on a refusal.
     */
    static func resolved(_ scheme: TerminalScheme?, style: UIUserInterfaceStyle) -> TerminalScheme {
        guard let scheme, scheme.id != TerminalScheme.followAppID else {
            // `.unspecified` resolves dark here, which is what this app has
            // always drawn and what `Duo.shade(for:)` does with it in reverse
            // for the chrome — the chrome's neutral is light, the terminal's is
            // dark, and both are what was on screen before this file existed.
            return TerminalScheme.app(dark: style != .light)
        }
        return scheme
    }

    // MARK: - Colours

    /// `#rrggbb` or `#rrggbbaa` → `UIColor`, or `fallback` if it is not a colour
    /// yet. See the header for why this cannot be an optional.
    static func color(_ hex: String, fallback: UIColor = .clear) -> UIColor {
        guard let rgba = components(hex) else { return fallback }
        return UIColor(red: CGFloat(rgba.red) / 255,
                       green: CGFloat(rgba.green) / 255,
                       blue: CGFloat(rgba.blue) / 255,
                       alpha: CGFloat(rgba.alpha) / 255)
    }

    static func swiftUIColor(_ hex: String, fallback: UIColor = .clear) -> SwiftUI.Color {
        SwiftUI.Color(uiColor: color(hex, fallback: fallback))
    }

    /// SwiftTerm's own type. `red8:` takes 8-bit components and widens them —
    /// the emulator stores sixteen bits a channel because an escape sequence can
    /// name a colour at that precision. Alpha is dropped; an ANSI slot has none.
    static func terminalColor(_ hex: String) -> SwiftTerm.Color {
        let rgba = components(hex) ?? (red: 0, green: 0, blue: 0, alpha: 255)
        return SwiftTerm.Color(red8: UInt16(rgba.red),
                               green8: UInt16(rgba.green),
                               blue8: UInt16(rgba.blue))
    }

    /// The sixteen, in wire order, ready for `installColors`.
    static func ansi(_ scheme: TerminalScheme) -> [SwiftTerm.Color] {
        scheme.ansi.map(terminalColor)
    }

    /**
     * The chosen background as one `UIColor` that answers for both appearances.
     *
     * For the screen *around* the emulator, which is SwiftUI and does keep a
     * dynamic provider — so the letterbox above and below a session follows the
     * appearance on its own, and only the choice has to be handed in. Without it
     * the terminal would be `#000000` inside a `#191919` frame the moment
     * anybody chose Pure Black, which is the seam a person notices first.
     */
    static func dynamicBackground(_ scheme: TerminalScheme?) -> UIColor {
        UIColor { traits in
            color(resolved(scheme, style: traits.userInterfaceStyle).background, fallback: .black)
        }
    }

    // MARK: - Text

    /**
     * Whether a string is a colour.
     *
     * A separate question from `color`'s: the hex field has to be able to hold
     * an unfinished value while somebody types, without the terminal following
     * it to every intermediate colour.
     */
    static func isColor(_ hex: String) -> Bool { components(hex) != nil }

    /**
     * The one spelling everything downstream is written in — lower case, `#`,
     * six digits or eight. `normaliseColour`.
     *
     * `#FFF` and `ffffff` both land on `#ffffff`, so a value typed by hand and a
     * value copied out of the shared table compare as equal strings.
     */
    static func normalized(_ hex: String) -> String? {
        var text = hex.trimmingCharacters(in: .whitespaces).lowercased()
        guard text.hasPrefix("#") else { return nil }
        text.removeFirst()
        guard text.allSatisfy({ $0.isHexDigit }) else { return nil }
        switch text.count {
        // #rgb → #rrggbb and #rgba → #rrggbbaa. Doubling each digit is the
        // expansion CSS itself specifies, so a three-digit colour means here
        // what it meant in the sheet somebody copied it out of.
        case 3, 4: return "#" + text.map { "\($0)\($0)" }.joined()
        case 6, 8: return "#" + text
        default: return nil
        }
    }

    /// The six-digit part, for a control that cannot express transparency —
    /// which is every one of them, `UIColorPickerViewController` included when
    /// opacity is switched off. `opaquePart`.
    static func opaquePart(_ hex: String) -> String {
        String((normalized(hex) ?? "#000000").prefix(7))
    }

    /// The two alpha digits, or "" when the colour is opaque. `alphaPart`. Kept
    /// so a well that can only return six digits does not silently throw away
    /// the alpha a shipped scheme was written with.
    static func alphaPart(_ hex: String) -> String {
        let normalised = normalized(hex) ?? "#000000"
        return normalised.count == 9 ? String(normalised.suffix(2)) : ""
    }

    /**
     * `UIColor` → `#rrggbb`, lower case.
     *
     * `getRed` is asked for the *display* components: a colour that came back
     * from `UIColorPickerViewController` can be in a wide-gamut space, and a P3
     * red clamps to `#ff0000` rather than failing.
     */
    static func hex(_ color: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return "#000000" }
        func byte(_ v: CGFloat) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(r), byte(g), byte(b))
    }

    static func hex(_ color: SwiftUI.Color) -> String { hex(UIColor(color)) }

    /// sRGB channels and alpha, 0–255. `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`.
    static func components(_ hex: String) -> (red: Int, green: Int, blue: Int, alpha: Int)? {
        guard let normalised = normalized(hex) else { return nil }
        let digits = normalised.dropFirst()
        func byte(_ offset: Int) -> Int {
            let start = digits.index(digits.startIndex, offsetBy: offset)
            let end = digits.index(start, offsetBy: 2)
            return Int(digits[start..<end], radix: 16) ?? 0
        }
        return (byte(0), byte(2), byte(4), digits.count == 8 ? byte(6) : 255)
    }

    // MARK: - Contrast

    /**
     * WCAG relative luminance. `relativeLuminance`.
     *
     * Two readers: whether a scheme is a light one — which decides the hairline
     * round its preview — and whether a label drawn *on* a swatch should be
     * black or white. Neither is a quality gate. A terminal scheme is allowed to
     * be low contrast; several published ones are, and nothing here refuses a
     * colour.
     */
    static func luminance(_ hex: String) -> Double {
        guard let rgba = components(hex) else { return 0 }
        func channel(_ v: Int) -> Double {
            let s = Double(v) / 255
            return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgba.red) + 0.7152 * channel(rgba.green) + 0.0722 * channel(rgba.blue)
    }

    /// The WCAG ratio, 1–21. `contrastRatio`.
    static func contrast(_ a: String, _ b: String) -> Double {
        let first = luminance(a), second = luminance(b)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }
}
