/**
 * The palette, in one place, in both appearances and in all three of the type
 * systems that need it.
 *
 * These values are not invented here. They are `src/renderer/styles/tokens.css`
 * read across — the same hexes the desktop ships — because the phone and the
 * desktop are one product and a person who has both in front of them can see a
 * quarter-stop of difference in a grey even when they cannot name it. When that
 * file changes, this one changes with it.
 *
 * ## Both appearances are first-class
 *
 * This file used to hold one set of dark values, and the app was pinned dark in
 * three separate places on top of that: `UIUserInterfaceStyle` in `Info.plist`
 * (the operating system's own override, which no view can argue with), eleven
 * `.preferredColorScheme(.dark)` calls scattered over the screens, and the
 * palette itself having no light half to switch to. Asad: *"mobile iOS is only
 * dark mode — it should have both, in settings."* All three had to go, and the
 * order matters: the plist first, because while it is there nothing else has any
 * effect at all.
 *
 * The light values are `tokens.css`'s own light theme, carried across exactly as
 * the dark ones were. They are **not** the dark ones lightened. A light theme
 * derived by lightening a dark one gets the surfaces roughly right and every ink
 * on them wrong, because the ink has to go the other way and by a different
 * amount — which is how a "light mode" ends up as grey text on grey cards.
 *
 * ## Why the greys are exactly neutral
 *
 * `r == g == b`, deliberately, on every surface in both appearances. The set
 * this replaces carried three to four levels more red than blue: invisible in a
 * swatch, and enough to make a whole screen read as faintly orange once it fills
 * one. That was reported on the desktop before it was noticed here, and the
 * phone inherited the same bias from the same source. `AppearanceTests` asserts
 * neutrality rather than trusting it — it is a property a hex can be checked for
 * and a property a person cannot see one swatch at a time.
 *
 * ## Why the accent is this blue and not a nicer one
 *
 * `#3b8fee` is lifted verbatim from the app icon — the top stop of the spine
 * gradient in `build/art/icon.mjs`. It is not "a blue that goes with the icon",
 * it is the icon's own blue, which is the only way an accent and a mark stop
 * drifting apart over a year of small adjustments.
 *
 * The light theme cannot use that same hex and the reason is measurable rather
 * than aesthetic: `#3b8fee` on white is 3.3:1, which is not readable as 13-point
 * text. So the light accent is the *same hue* (≈213°) walked down in lightness
 * until it clears AA on paper — `#1a66c4`, 5.6:1 on white and 4.8:1 on the
 * darkest paper this app sets ink on. That is `tokens.css`'s own decision and
 * its own value; it is not re-derived here.
 *
 * ## Three types, because there are three rendering systems
 *
 * `Theme` is SwiftUI's `Color` and belongs to the chrome. `Palette` is UIKit's
 * `UIColor` and belongs to the terminal and the key bar, which are UIKit views
 * that never see a SwiftUI environment. `Palette.ansi(for:)` is SwiftTerm's own
 * 16-bit `Color` and belongs to the emulator. All three read from `Ink`, so a
 * colour can be changed once rather than in three places that will eventually
 * disagree.
 *
 * ## How one definition serves two appearances
 *
 * `UIColor(dynamicProvider:)`. It resolves against whatever trait collection is
 * asking, UIKit re-resolves it on every view that holds one when the appearance
 * changes, and `Color(uiColor:)` carries the same object into SwiftUI, where the
 * environment's `colorScheme` selects the half. So one `Duo` below produces a
 * correct `Color` and a correct `UIColor` with nothing written twice.
 *
 * **That is true of every UIKit view in this app except the terminal**, and the
 * exception is not a detail — see `TerminalBridge.applyColors`. SwiftTerm's
 * `nativeForegroundColor` setter immediately flattens the `UIColor` it is given
 * into a 16-bit RGB struct (`terminal.foregroundColor`), so what the emulator
 * holds is the value the colour had at the instant it was assigned. A dynamic
 * colour handed to it is resolved once and then frozen. The terminal therefore
 * re-applies its colours when the trait collection changes, and resolves them
 * explicitly rather than relying on the ambient `UITraitCollection.current`.
 */

import SwiftTerm
import SwiftUI
import UIKit

/**
 * One colour, written the way the CSS writes it.
 *
 * A hex literal rather than three integers because that is the form these values
 * are read across in — `#191919` in `tokens.css` is `0x191919` here, and a
 * transcription error is visible on the line rather than hidden in an argument
 * order. The alpha is separate because the tints (`--bg-hover`, `--border`) are
 * a colour *and* a strength, and the strength differs between the appearances
 * while the colour does not.
 */
private struct Shade {
    let red: Int
    let green: Int
    let blue: Int
    let alpha: Double

    init(_ hex: Int, alpha: Double = 1) {
        red = (hex >> 16) & 0xff
        green = (hex >> 8) & 0xff
        blue = hex & 0xff
        self.alpha = alpha
    }

    /// From a `#rrggbb` or `#rrggbbaa` string, which is the form the shared
    /// scheme table is written in. Only the terminal's own colours come this
    /// way; everything above is a literal read across from `tokens.css`.
    init(_ colour: String) {
        let rgba = TerminalPalette.components(colour) ?? (red: 0, green: 0, blue: 0, alpha: 255)
        red = rgba.red
        green = rgba.green
        blue = rgba.blue
        alpha = Double(rgba.alpha) / 255
    }

    var uiColor: UIColor {
        UIColor(red: CGFloat(red) / 255,
                green: CGFloat(green) / 255,
                blue: CGFloat(blue) / 255,
                alpha: CGFloat(alpha))
    }

    /// SwiftTerm's own colour type. `red8:` takes 8-bit components and widens
    /// them; the emulator stores 16 bits per channel because a terminal can be
    /// told a colour by an escape sequence at that precision.
    var terminalColor: SwiftTerm.Color {
        SwiftTerm.Color(red8: UInt16(red), green8: UInt16(green), blue8: UInt16(blue))
    }
}

/// One role, in both appearances. Everything below is one of these, so no colour
/// can exist in one appearance and not the other — which is the failure this
/// whole change is fixing, and the failure `tokens.css`'s own rule names:
/// *"Never define a colour only inside `[data-theme='dark']`."*
private struct Duo {
    let light: Shade
    let dark: Shade

    func shade(for style: UIUserInterfaceStyle) -> Shade {
        // `.unspecified` resolves light, which is what the system does with it
        // and what a phone with no preference expressed should get.
        style == .dark ? dark : light
    }
}

/// The raw values. Private to the three façades below so nothing else can reach
/// past them and hard-code a hex.
private enum Ink {
    /*
     * Surfaces — and the relationship between two of them is the whole of the
     * app's character.
     *
     * Asad, with the two apps he uses every day open beside this one: *"this app
     * does not have any character of itself, it's like very much of base colour
     * of iOS… they look smooth, clean, simple and have their own character."*
     *
     * He was right, and the cause was one inversion. This palette had **white
     * paper with grey cards** — which is iOS's own default grouped-list look, so
     * an app wearing it has, precisely, no character of its own. Every app he
     * pointed at does the opposite: a **tinted ground with lighter cards
     * floating on it**. Claude's is warm paper with warm-grey cards; ChatGPT's is
     * cool grey with white cards. Same idea both times, and it is the idea rather
     * than either palette that reads as *designed*.
     *
     * So the ground is off-white and the cards are white.
     *
     * **Exactly neutral, and that is not a small detail.** The first cut of this
     * was warm — `#f4f2ef`, five levels more red than blue — because Claude's
     * app is warm and it looks well. `AppearanceTests.testTheGreysAreExactlyNeutral`
     * refused it, and it was right to: the set *this palette replaced* ran three
     * to four levels warm, and a filled screen reading as faintly orange was
     * **reported on the desktop** and fixed. Reintroducing it here would have
     * reopened a defect this product has already had once, to buy a warmth
     * nobody had asked for by name.
     *
     * Nothing is lost. The character was never in the hue — it is in the
     * *relationship*, ground darker than card, and ChatGPT's is cool-grey and
     * reads every bit as designed. A neutral ground gets the whole effect and
     * keeps the guard that caught this.
     *
     * The contrast tiers below are **better** after this, not worse: they were
     * measured against the darkest paper here, and body text now lands mostly on
     * white. Primary is 16:1 on a card, secondary 7.4:1, muted 5.7:1; on the new
     * `sunken` they are 14:1, 6.3:1 and 4.9:1 — every tier still AA everywhere.
     *
     * Dark goes one step deeper at the ground for the same reason light goes one
     * step lighter at the card: a card has to separate from what it is lying on,
     * and `#191919` under `#202020` was three points of difference.
     */
    static let background = Duo(light: Shade(0xffffff), dark: Shade(0x191919))
    static let raised = Duo(light: Shade(0xf5f5f5), dark: Shade(0x202020))
    static let raisedHigh = Duo(light: Shade(0xededed), dark: Shade(0x252525))
    static let sunken = Duo(light: Shade(0xeaeaea), dark: Shade(0x121212))

    /* Text. `--text-primary` / `--text-secondary` / `--text-muted`.

       The light tier is checked against `--bg-sunken`, the darkest paper this
       app ever sets ink on, rather than against white: 14.6:1, 6.5:1 and 4.9:1
       measured on `--bg-tertiary`, the lightest surface a card uses. Even the
       quietest tier is AA body text wherever it lands, which is the property
       that stops a light theme from being grey-on-grey. */
    static let primary = Duo(light: Shade(0x1c1c1c), dark: Shade(0xededed))
    static let secondary = Duo(light: Shade(0x545454), dark: Shade(0xa8a8a8))
    static let muted = Duo(light: Shade(0x666666), dark: Shade(0x8f8f8f))

    /* The icon's blue and the ink that goes on top of it. See the header for why
       the two appearances cannot share one hex, and why the ink flips. */
    static let accent = Duo(light: Shade(0x1a66c4), dark: Shade(0x3b8fee))
    static let accentPressed = Duo(light: Shade(0x124a92), dark: Shade(0x7db4f5))
    static let onAccent = Duo(light: Shade(0xffffff), dark: Shade(0x0f1114))

    /* Status. The desktop's `--status-*`, unchanged: green means running, amber
       means it wants you, red means it stopped.

       The light half is not a lightening of the dark half — it is the same hue
       walked the other way, exactly as `tokens.css` does it, because a status
       dot is also a status *word* in this app and every one of these is set as
       text somewhere. All six clear 4.5:1 on the lightest surface they are ever
       drawn on, in both appearances. */
    static let working = Duo(light: Shade(0x1667c8), dark: Shade(0x64a6e8))
    static let waiting = Duo(light: Shade(0x8f5800), dark: Shade(0xddb04a))
    static let input = Duo(light: Shade(0xb83c08), dark: Shade(0xf0913f))
    static let completed = Duo(light: Shade(0x19714a), dark: Shade(0x5fbf95))
    static let critical = Duo(light: Shade(0xbd3a2c), dark: Shade(0xff6f60))
    static let positive = Duo(light: Shade(0x19714a), dark: Shade(0x5fbf95))
    static let warning = Duo(light: Shade(0x8f5800), dark: Shade(0xddb04a))

    /**
     * The fill under a swipe action that is not saying anything.
     *
     * The only colour in this file that is **the same in both appearances**, and
     * it has to be, because of a rule that belongs to UIKit rather than to this
     * palette: the label of a swipe action is always drawn in white, whatever
     * the tint and whatever the appearance. Every other pair here is a colour
     * walked in two directions so that ink stays readable on paper *and* on
     * near-black; a swipe tint has only one thing to be readable against and it
     * is white in both.
     *
     * That is not a hypothetical. `Theme.surfaceHigh` was used for exactly this
     * — the neutral swipe actions on the localhost list, and briefly the Details
     * one on the session list — and its light value is `#ededed`. White glyph,
     * near-white circle: **1.1:1**, an action that is invisible on paper and
     * perfectly legible in the dark, which is the failure this app has had
     * before and the reason the appearance suite photographs both. Caught by
     * looking at a light-mode screenshot, not by a test.
     *
     * `#767676` is the darkest grey that still reads as *quiet* beside the amber
     * and the blue it sits next to, and white on it is 4.6:1 — past AA for the
     * 15pt semibold a swipe label is set in. Apple's own neutral swipe action
     * (`systemGray`, `#8e8e93`) is 2.8:1 and this is deliberately darker than
     * that: the buttons here are round rather than full-height, so there is less
     * of the colour to carry the contrast.
     */
    static let neutralAction = Duo(light: Shade(0x767676), dark: Shade(0x767676))

    /*
     * Tints — a strength of the ink rather than a named grey, so a control sits
     * on any surface without knowing which one it is.
     *
     * The base flips with the appearance and that is the whole trick: a dark
     * theme tints *towards white*, a light theme tints *towards the ink*. A
     * light theme that kept the white tint would be painting white on
     * near-white, which is how a pressed state ends up invisible — which is
     * exactly what the two `Color.white.opacity(0.06)` row highlights this
     * replaces would have done.
     *
     * `rgb(56, 56, 56)` is `tokens.css`'s own tint base for the light theme,
     * chosen there as the neutral twin of a warm grey whose alphas were already
     * tuned, so the strengths below land where they were tuned to land.
     */
    static let hairline = Duo(light: Shade(0x383838, alpha: 0.1),
                              dark: Shade(0xffffff, alpha: 0.09))
    static let pressed = Duo(light: Shade(0x383838, alpha: 0.055),
                             dark: Shade(0xffffff, alpha: 0.055))
    static let key = Duo(light: Shade(0x383838, alpha: 0.11),
                         dark: Shade(0xffffff, alpha: 0.1))
    static let keyPressed = Duo(light: Shade(0x383838, alpha: 0.24),
                                dark: Shade(0xffffff, alpha: 0.22))
    static let keyDisabled = Duo(light: Shade(0x383838, alpha: 0.05),
                                 dark: Shade(0xffffff, alpha: 0.05))

    /*
     * The terminal's own paper and ink — **read from the shared scheme table,
     * not declared here.**
     *
     * These used to be two literal pairs, and that was the second copy of a
     * palette this product now declares once: `src/shared/terminal-theme.ts`
     * holds `deck-dark` and `deck-light`, the desktop's xterm.js reads them, and
     * `TerminalScheme` mirrors them into Swift. Deriving here means the app's
     * own terminal cannot drift from the scheme somebody can choose out of the
     * picker by that name, which is exactly the drift this whole change exists
     * to end.
     *
     * The reasoning behind the values is worth keeping even though the values
     * moved. On paper the terminal must **not** be the app's canvas —
     * `tokens.css` says why, in the words of the person who reported it: a
     * terminal painted `--bg-primary` in the light theme *"is pure white, and
     * inside the terminal itself it is a little bit different, like kind of
     * grey"*. It stops being a terminal and becomes an empty document with a
     * cursor in it. So `deck-light`'s ground is `#e8e8e8`, a genuinely recessed
     * paper twenty-three levels below the chrome. The ink is `#141414`, darker
     * than the app's own body text on purpose, because a terminal's job is to be
     * exact.
     *
     * **The dark ground moved, and it is the one visible change in this file.**
     * This app drew `#121212` — `--bg-sunken`, two levels below the desktop's
     * dark `--terminal-bg`. That gap was recorded here as a known difference
     * nobody had asked to fix. It is fixed now, at `#191919`, because the phone
     * and the desktop are being given one named scheme and *Deck Dark* cannot be
     * two colours depending on which screen it is read on. Nothing else about
     * the dark terminal changes.
     */
    private static func terminal(_ slot: ColourSlot) -> Duo {
        Duo(light: Shade(TerminalScheme.app(dark: false)[slot]),
            dark: Shade(TerminalScheme.app(dark: true)[slot]))
    }

    static let terminalPaper = terminal(.background)
    static let terminalInk = terminal(.foreground)

    /**
     * The sixteen ANSI colours, in both appearances, in the order the wire
     * numbers them: 0–7 then 8–15 — **read from the shared scheme table.**
     *
     * `deck-dark` and `deck-light` carry them now, and the argument for what
     * they are is on `TerminalScheme.appAnsiDark` / `appAnsiLight`. The short
     * version, kept here because this is where a reader of the app's palette
     * arrives: the dark set is `@xterm/xterm`'s Tango-derived defaults, which is
     * what a session has always shown on both halves of this product; the light
     * set is the same sixteen with every channel scaled toward black by one
     * factor, which preserves hue and saturation exactly and moves only value,
     * until each clears its contrast target on `#e8e8e8`. Nothing is re-hued and
     * nothing is chosen by eye — `AppearanceTests` recomputes the contrast and
     * the hue drift on every run and fails if either moves.
     *
     * Three deliberate exceptions, each a property of what an ANSI palette *is*
     * rather than a colour decision:
     *
     *  - **The normal eight target 4.6:1; the bright eight target 7:1.** On a
     *    dark ground "bright" means further from the ground, i.e. lighter. On
     *    paper the same idea is darker. Given both the same target they collapse
     *    onto each other — green and bright green ended eleven levels apart,
     *    which a diff renders as one colour.
     *  - **Black and bright black keep their places on the ramp**, because they
     *    already clear on paper (10.3:1 and 6.0:1) and darkening bright black
     *    past black would invert the pair.
     *  - **White and bright white are left alone, and they are unreadable as
     *    foreground on paper — 1.2:1 and 1.1:1.** That is what an ANSI colour
     *    is: those two are used as *backgrounds* as often as foregrounds, and
     *    darkening them would turn `ESC[47m` into a black band. Every light
     *    terminal scheme in use makes the same trade. A program that wants "the
     *    normal foreground" says `ESC[39m`, which is `terminalInk` and is 15:1
     *    on this paper.
     *
     * What none of this reaches is 256-colour and 24-bit output, which bypasses
     * the palette entirely — an agent that emits `ESC[38;2;…m` greys tuned for a
     * black background is unreadable on paper on the phone exactly as it is on
     * the desktop. That is a property of the programs rather than of this file,
     * and it is the one thing about light mode worth knowing before choosing it.
     */
    static let ansi: [Duo] = ColourSlot.ansi.map(terminal)
}

/// One `UIColor` that answers for both appearances. See the header for why this
/// is enough for every UIKit view in the app except the terminal.
private func uiKit(_ duo: Duo) -> UIColor {
    UIColor { traits in duo.shade(for: traits.userInterfaceStyle).uiColor }
}

/// The same object, seen from SwiftUI. `Color(uiColor:)` keeps the provider
/// rather than resolving it, so the environment's `colorScheme` picks the half —
/// which is what lets one declaration serve both façades.
private func swiftUI(_ duo: Duo) -> SwiftUI.Color {
    SwiftUI.Color(uiColor: uiKit(duo))
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
    /// The accent while a finger is on it. Lighter in the dark theme and darker
    /// in the light one: "pressed" reads as *further from the paper*, and which
    /// direction that is depends on which the paper is.
    static let accentPressed = swiftUI(Ink.accentPressed)
    /// What goes on top of a filled accent button. Near-black in the dark theme,
    /// and that is forced rather than chosen: no single blue is both readable as
    /// text on `#191919` and dark enough for white to be readable on top of it.
    /// Apple's own dark-mode tinted controls make the same trade. On paper the
    /// accent is dark enough to carry white, so it does.
    static let onAccent = swiftUI(Ink.onAccent)

    /*
     * **The page ground is the app ground, not the canvas — and that swap is
     * the whole of the character fix.**
     *
     * `Ink.background` is `--bg-primary`, which `tokens.css` calls *"the content
     * canvas"*; `Ink.raised` is `--bg-secondary`, *"the app ground the sidebar
     * sits on"*. The phone had them the wrong way round: it painted its page in
     * the canvas and drew its cards in the ground. In light that is white paper
     * with grey cards — which is iOS's own default grouped-list look, and
     * therefore no character at all. Asad, with the two apps he uses every day
     * open beside this one: *"this app does not have any character of itself,
     * it's like very much of base colour of iOS."*
     *
     * Every app he pointed at does what the desktop already does: a ground, with
     * lighter surfaces sitting on it. Reading the two tokens the way the desktop
     * names them gets that for free — and keeps the phone byte-identical to
     * `tokens.css`, which is the property `AppearanceTests` exists to hold.
     *
     * The first attempt at this changed the *values* instead — a warm off-white
     * ground of its own. `testTheGreysAreExactlyNeutral` refused it, and was
     * right to: the set this palette replaced ran three to four levels warm, and
     * a filled screen reading as faintly orange was **reported on the desktop**
     * and fixed. Nothing was lost by going neutral, because the character was
     * never in the hue — it is in which surface is on top.
     */
    static let background = swiftUI(Ink.raised)
    /// A card sitting on the background. Space separates things in this app;
    /// this is for the cases where space genuinely cannot.
    /// The cards. `--bg-primary`, the canvas — what sits *on* the ground above.
    static let surface = swiftUI(Ink.background)
    /// A surface on a surface — a chip inside a card.
    static let surfaceHigh = swiftUI(Ink.raisedHigh)
    /// The fill under a swipe action that carries no meaning of its own. Not a
    /// surface, and not a pair: UIKit draws a swipe label in white whatever the
    /// appearance, so this is one grey in both. See `Ink.neutralAction`, which
    /// carries the measurement and the bug it was written for.
    static let neutralAction = swiftUI(Ink.neutralAction)

    static let primary = swiftUI(Ink.primary)
    static let secondary = swiftUI(Ink.secondary)
    static let faint = swiftUI(Ink.muted)

    /// Kept because two places still genuinely need a line: the top of a banner
    /// that overlays scrolling content, and the edge of a text field. Every
    /// other divider in this app has been replaced by space.
    static let hairline = swiftUI(Ink.hairline)

    /// The wash under a finger on a row that is not a button with a fill of its
    /// own. It was `Color.white.opacity(0.06)`, written twice, which on paper
    /// is white on near-white — a pressed state that does not exist. See
    /// `Ink.pressed` for why the tint base flips.
    static let pressed = swiftUI(Ink.pressed)

    static let warning = swiftUI(Ink.warning)
    static let critical = swiftUI(Ink.critical)
    static let positive = swiftUI(Ink.positive)

    /// The dot on a session row. The vocabulary belongs to the desktop, so an
    /// unknown status gets a neutral colour rather than being dropped or
    /// guessed at.
    static func statusColor(_ status: String) -> SwiftUI.Color {
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
 * The terminal is a real emulator rendering real ANSI colour, so its palette is
 * a palette rather than a background and a foreground — see `Ink.ansi` for what
 * the sixteen are, where they come from and what a light ground does to them.
 *
 * These are `UIColor`s because the terminal and the key bar are UIKit views that
 * never see a SwiftUI environment. The key bar's take care of themselves: UIKit
 * re-resolves `backgroundColor` and `tintColor` on every appearance change. The
 * terminal's do not, and `TerminalBridge.applyColors` is where that is dealt
 * with rather than here.
 */
enum Palette {
    /**
     * The app's own two terminal schemes, seen as an appearance pair.
     *
     * Nothing in the app paints from these any more — `TerminalBridge` reads the
     * chosen scheme through `TerminalPalette`, which is the only thing that can,
     * because a chosen scheme is absolute and has no light half. They are kept
     * because `AppearanceTests` holds the app's *default* terminal to the same
     * contrast and hue rules as the rest of this file, and it is the default
     * that most people will look at for the life of the product.
     */
    static let terminalBackground = uiKit(Ink.terminalPaper)
    static let terminalForeground = uiKit(Ink.terminalInk)

    /*
     * **There is no `caret` or `selection` here any more.**
     *
     * Both were single app-wide values — the accent, and the accent at half
     * strength — and both are now *per scheme*: a cursor is `cursor` and a
     * selection is `selectionBackground`, twenty-one slots that somebody can
     * edit. `TerminalBridge` reads them off the chosen scheme. Leaving a
     * `Palette.caret` standing would have been a second, authoritative-looking
     * answer to a question this file no longer decides.
     *
     * The reasoning is not lost, it moved: the app's schemes carry `#3b8fee` as
     * the cursor because a selection on this platform is blue and this app's
     * blue is the icon's — SwiftTerm's own default is a teal, the only thing
     * that colour anywhere in the product, and it left the system's blue drag
     * handles sitting on a teal highlight. And the selection is written with an
     * alpha (`#3b8fee29`) rather than solid, because the glyphs stay on top of
     * it and a full-strength blue under a terminal's ink is a legibility problem
     * rather than a highlight.
     */

    /// A key cap at rest. A tint of the ink rather than a solid grey, so the bar
    /// picks up whatever the keyboard behind it is doing — and so it works over
    /// the light keyboard as well as the dark one.
    static let key = uiKit(Ink.key)
    /// A key cap under a finger. A control that looks pressable must respond —
    /// the old bar had no pressed state at all, so every key felt dead even
    /// when it worked.
    static let keyPressed = uiKit(Ink.keyPressed)
    /// A key that is refusing. Its own value rather than `key` at a lower alpha,
    /// for the reason `selection` is its own value.
    static let keyDisabled = uiKit(Ink.keyDisabled)
    /// A sticky modifier that is armed and waiting to be spent.
    static let keyArmed = uiKit(Ink.accent)
    /// Ink on an armed key. See `Theme.onAccent` for why it is not always white.
    static let onArmed = uiKit(Ink.onAccent)
    static let keyLabel = uiKit(Ink.primary)
    /// Group headers in the grid, and any label that is not the key itself.
    static let keyLabelFaint = uiKit(Ink.muted)

    /**
     * The sixteen ANSI colours for one appearance, resolved.
     *
     * Takes the style rather than reading the environment, because the one
     * caller has a view whose trait collection is the authority and because
     * SwiftTerm stores what it is given rather than holding on to a provider.
     * See `Ink.ansi`.
     */
    static func ansi(for style: UIUserInterfaceStyle) -> [SwiftTerm.Color] {
        Ink.ansi.map { $0.shade(for: style).terminalColor }
    }
}
