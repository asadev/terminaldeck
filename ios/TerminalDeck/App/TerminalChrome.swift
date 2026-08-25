/**
 * A session screen wears the terminal's own colours — the bar over it included.
 *
 * Asad, having just been given thirteen schemes and no way to make the rest of
 * the screen agree with the one he picked:
 *
 * > *"When we enter in the, let's say, terminal page — whatever the theme colour
 * > we decide to keep, in the black for example, in the terminal. For example I
 * > choose black, dark black: my header should be also dark black. Other than
 * > the buttons, that top header should be also dark black, everything should be
 * > black, not just base colour. Only buttons can stay as they are — they are
 * > anyway liquid, they are not colourful I guess. But background, full page
 * > should be black."*
 *
 * Photographed before this file existed, on the default scheme with the phone in
 * light: the terminal drew on `#e8e8e8` and the whole band above it — status bar,
 * navigation bar and the session row under it — was `#ffffff`, a hard edge across
 * the screen at 148 points. On Pure Black it is not a seam, it is two different
 * screens stuck together: `#000000` under `#ffffff`.
 *
 * ## Why the colour is not the app's to know
 *
 * `Theme.background` is one pair of greys read across from `tokens.css`. A
 * terminal scheme is one of thirteen published palettes or somebody's own,
 * twenty-one editable slots, chosen on this phone and pinned absolutely — see
 * `TerminalThemeStore`. The bar over a session has to take the second, and no
 * other bar in the app may, which is why this is a modifier written on one screen
 * rather than a `UINavigationBar.appearance()` proxy: the proxy is global, it
 * repaints Sessions, Browser and Menu as well, and it is not undone by leaving.
 *
 * ## Two statements, because a colour and an appearance are different things
 *
 * **The colour**, for the surfaces this app paints itself: the scheme's
 * `background`, handed over still dynamic so `follow-app` keeps following.
 *
 * **The appearance**, for everything that can only be told *light or dark*: the
 * glass under the toolbar buttons, the tint they draw their glyphs in, the
 * material under a toast, and every `Theme` colour used by the strip above the
 * session and by the conversation. Decided by the scheme's own background at the
 * midpoint of the luminance range — `TerminalScheme.isLight`, which already
 * answers exactly that question for the hairline round a preview in the picker,
 * so a scheme cannot be light in one place and dark in the other.
 *
 * See `TerminalChromeModifier` for the three modifiers that carry those two
 * statements, why it takes three, where in the chain they have to sit, and the
 * one surface none of them reach — the status bar's own glyphs, which belong to
 * the window.
 *
 * ## `follow-app` states nothing at all, and that is load bearing
 *
 * The default is not a scheme, it is a refusal to pin one, and answering for it
 * would break the very thing it means. A phone crossing into dark at sunset with
 * a session open would keep the appearance the screen was *entered* in — frozen,
 * because a stated value does not change when the phone does, while the emulator
 * three points below carries on following it. So `pinnedStyle` returns `nil`, and
 * the modifier that would have carried it is skipped rather than given a default:
 * the difference between *following* the phone and *guessing what the phone said
 * when you opened the screen*.
 *
 * ## What is deliberately not restyled
 *
 * The buttons: *"only buttons can stay as they are."* They keep their glass and
 * the app's accent — what they are given is the right half of that accent to
 * resolve against, which is what makes `Theme.accent` land on `#3b8fee` over Pure
 * Black (5.0:1) and on `#1a66c4` over Solarized Light (5.6:1) rather than the
 * other way round. And the status dot in the header keeps `Theme.statusColor`:
 * working, waiting and exited are meanings rather than decoration, and a scheme
 * that repainted them would be a scheme that changed what the screen says.
 */

import SwiftUI
import UIKit

enum TerminalChrome {

    /// The ground a session is drawn on: the chosen scheme's background, still
    /// dynamic so `follow-app` keeps following. The same call `SessionChatView`
    /// already paints a code block with, so a block and the page under it cannot
    /// disagree.
    static func paper(_ scheme: TerminalScheme?) -> Color {
        Color(TerminalPalette.dynamicBackground(scheme))
    }

    /**
     * Text this app draws on that ground — the scheme's own `foreground`.
     *
     * Not `Theme.primary`, which is measured against the app's paper and says
     * nothing about this one: on Pure Black in a light appearance it is `#1a1a1a`
     * on `#000000`, a title that is there and cannot be read. The scheme's
     * foreground is what the emulator draws ordinary output in, three points
     * below, on exactly this colour — so it is the one value guaranteed to be the
     * pairing whoever wrote the scheme intended, and a title that did not match
     * the prompt underneath it would read as a fault in the scheme.
     */
    static func ink(_ scheme: TerminalScheme?) -> Color {
        Color(uiColor: inkColor(scheme))
    }

    /**
     * The quieter of the two tiers, and the only relationship here that is not
     * read straight off the scheme.
     *
     * A scheme has one `foreground` and no second tier, so a status line sitting
     * under a title has to be derived from something. Six tenths is the ratio
     * `--text-muted` keeps to `--text-primary` in `tokens.css`, so the two lines
     * read the same distance apart here as they do everywhere else in the product.
     */
    static func dimInk(_ scheme: TerminalScheme?) -> Color {
        Color(uiColor: dimInkColor(scheme))
    }

    static let dimmed = 0.6

    /**
     * The appearance this screen is pinned to, or `nil` when there is nothing to
     * pin.
     *
     * Decided by the scheme's background rather than by the phone, which is the
     * whole point: a black terminal under a phone in light mode needs the glass,
     * the tint and every `Theme` colour on this screen taken from the dark half,
     * and the phone's own setting is not evidence about a colour somebody pinned.
     *
     * `nil` for `follow-app` — see the header. It is not "dark by default"; it is
     * *no answer*, so the phone keeps giving one.
     */
    static func pinnedStyle(_ scheme: TerminalScheme?) -> ColorScheme? {
        guard let scheme, scheme.id != TerminalScheme.followAppID else { return nil }
        return scheme.isLight ? .light : .dark
    }

    /// The scheme's `foreground` as one `UIColor` that answers for both
    /// appearances — the arrangement `TerminalPalette.dynamicBackground` makes for
    /// the ground, for the same reason and with the same fallback discipline. The
    /// fallback is `.label` rather than a constant, so a half-typed hex in a
    /// custom scheme leaves a readable title rather than an invisible one.
    static func inkColor(_ scheme: TerminalScheme?) -> UIColor {
        UIColor { traits in
            TerminalPalette.color(TerminalPalette.resolved(scheme, style: traits.userInterfaceStyle).foreground,
                                  fallback: .label)
        }
    }

    /// The quieter tier, as a `UIColor`. `withAlphaComponent` on a dynamic colour
    /// keeps the provider and applies the alpha to whatever it resolves to, so the
    /// second tier follows `follow-app` across an appearance change exactly as the
    /// first does — and so a test can resolve it and read the number back.
    static func dimInkColor(_ scheme: TerminalScheme?) -> UIColor {
        inkColor(scheme).withAlphaComponent(dimmed)
    }
}

/* -------------------------------------------------------------------------- */
/* Wearing it                                                                 */
/* -------------------------------------------------------------------------- */

extension View {
    /**
     * Dress this screen in the terminal's colours.
     *
     * One call, on the screen that wants it, so the two stacks that push a
     * session — Sessions and Copilot — cannot end up with different bars.
     */
    func terminalChrome(_ scheme: TerminalScheme?) -> some View {
        modifier(TerminalChromeModifier(scheme: scheme))
    }
}

/**
 * Three statements, and each one is here because the other two do not reach where
 * it reaches.
 *
 * **`.toolbarBackground`, twice.** `toolbarBackground(_:for:)` states *what* the
 * background is and `toolbarBackground(.visible,·)` states *that* there is one; a
 * bar over a screen that is not a scroll view has none by default, so the colour
 * on its own leaves it transparent. Measured on iOS 27: with both, a session on
 * Pure Black photographs `#000000` across the status bar, the navigation bar, the
 * session row and the terminal, where the same frame before this change was
 * `#ffffff` over `#e8e8e8`.
 *
 * The iOS 17 spellings deliberately, and not `toolbarBackgroundVisibility`, which
 * arrived in 18: this app deploys to 17 — see `project.yml`, where the target is
 * pinned to the release `@Observable` and `NavigationStack` need — so the newer
 * name would have to be reached through an availability branch producing the
 * identical bar. A deprecation warning is the cheaper of the two.
 *
 * **`.toolbarColorScheme`**, because the navigation bar is not inside this
 * screen's view — it belongs to the navigation controller and is a sibling of it,
 * so nothing stated in the view tree reaches the glass under the buttons or the
 * half of `Theme.accent` they tint themselves with.
 *
 * **`.transformEnvironment(\.colorScheme)`**, for everything this app draws on
 * the scheme's paper: the strip above the session, the conversation, the toast's
 * material. `transform` rather than `.environment(_:_:)` because `follow-app` must
 * state **nothing** — see `pinnedStyle` — and a modifier that has to be absent in
 * one case cannot be written as a value.
 *
 * ## Where it is applied, and why that is not a detail
 *
 * At the **end** of the screen's modifier chain, after `.safeAreaInset`, and
 * before the sheets. An environment modifier reaches what is already inside it
 * and nothing added afterwards: written above the inset — which is where it was
 * first — the session row above the terminal kept the phone's appearance while
 * the terminal under it took the scheme's, and photographed as a dark chip row on
 * cream paper. Written *after* the sheets it would follow a detail sheet or a
 * file reader out of the session, which are the app's own screens and stay the
 * app's.
 *
 * ## What this does not reach: the status bar's own glyphs
 *
 * The clock, the wifi arc and the battery are drawn by the system from the
 * *window's* interface style, which is `RootView`'s to state and nothing here can
 * argue with — a `.preferredColorScheme` on this screen is simply overruled by
 * the root's, measured, and a `UIViewControllerRepresentable` reaching for the
 * window is handed `nil`: logged from inside `updateUIViewController`, where the
 * controller has no parent, no `navigationController` and no window at all.
 *
 * In practice that leaves one quadrant wrong and it is worth naming rather than
 * discovering: **a light scheme pinned while the app is forced Dark**. The bar
 * and the page are the scheme's cream, and the glyphs above them stay white —
 * `#ffffff` on `#fdf6e3`, which is 1.05:1 and effectively invisible. The three
 * other quadrants are right, and the one he asked about is right for a reason
 * rather than by luck: `.toolbarColorScheme(.dark)` puts the bar into
 * `barStyle == .black`, which is the one input `UINavigationController` turns
 * into an explicit `.lightContent`. Closing the last quadrant means letting
 * `RootView` account for the pinned scheme, which repaints the window — and
 * therefore flashes the screen underneath for the length of a push. That is a
 * decision about the whole app rather than about this screen, so it is left to be
 * made rather than taken here.
 */
private struct TerminalChromeModifier: ViewModifier {
    let scheme: TerminalScheme?

    func body(content: Content) -> some View {
        let pinned = TerminalChrome.pinnedStyle(scheme)
        return content
            .toolbarColorScheme(pinned, for: .navigationBar)
            .toolbarBackground(TerminalChrome.paper(scheme), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .transformEnvironment(\.colorScheme) { current in
                if let pinned { current = pinned }
            }
    }
}
