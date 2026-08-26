/**
 * What is on the key bar, what is in the grid, and what every one of them sends.
 *
 * Pure data with no UIKit in it, so the two questions worth getting wrong can be
 * answered by a test rather than by squinting at a simulator: **does the fixed
 * bar fit the narrowest iPhone**, and **does every key send the bytes a terminal
 * actually acts on**.
 *
 * ## Why the bar is fixed and the rest is a grid
 *
 * The bar this replaces put twenty-six buttons in one horizontal scroll view and
 * added *dismiss* last. So the control reached for most often was the one
 * furthest away: to put the keyboard down you scrolled past the whole symbol
 * row, the four signals, home, end, pgup, pgdn, copy and paste. A long scroll is
 * also the wrong shape for a key bar in general — you cannot see what is in it,
 * a key's position moves as you scroll so no muscle memory ever forms, and every
 * press costs a swipe plus a hunt.
 *
 * So: a bar that **never scrolls**, holding only what is pressed constantly
 * while typing a command, with *more* and *dismiss* pinned hard right where they
 * cannot move; and everything else in a grid that opens where the keyboard was,
 * grouped and labelled so it can be read instead of hunted.
 *
 * ## Why the arrows split
 *
 * `↑`/`↓` recall history and are pressed constantly. `←`/`→` only matter while
 * editing a line you are already looking at, which is rarer and survives one
 * extra tap. Seven targets at 44pt is about 350pt of content, which fits a 375pt
 * phone with room for the gaps; adding the two horizontal arrows needs roughly
 * 396pt and brings back the scroll this whole change exists to remove. If daily
 * use says that was the wrong pair, swap them — but the bar does not grow.
 *
 * ## Why there is no cmd and no win
 *
 * A PTY cannot receive them. A terminal sees Ctrl, Alt/Meta and Escape
 * sequences; there is no byte for Command or for the Windows key, so those caps
 * would send nothing at all. A control that does nothing is exactly what this
 * file exists to remove, and adding two of them to a brand-new grid would be a
 * strange way to start. `alt` takes their place: it is the real key, it is what
 * most "Cmd-ish" terminal habits actually map to (`alt-b`, `alt-f`, `alt-.`),
 * and it sends the ESC prefix a shell genuinely acts on.
 *
 * Driving the *host operating system's* Command key — as opposed to the shell's
 * — is a real and interesting feature and a completely different one: it means
 * driving the desktop's GUI from the phone. If that is ever wanted it gets
 * designed on its own rather than smuggled in as a key cap.
 */

import Foundation

/// What pressing a key does. Three kinds, because three different things have
/// to happen: bytes go to the session, a modifier changes the *terminal's*
/// state, and copy/paste are the app's business rather than the wire's.
enum KeyAction: Equatable {
    /// Literal bytes, unaffected by the terminal's mode.
    case bytes([UInt8])
    /**
     * A cursor key, which is two different byte sequences.
     *
     * In application-cursor mode (DECCKM, which every full-screen program sets)
     * an arrow is `ESC O A`; otherwise it is `ESC [ A`. Sending the wrong one
     * means the arrows work at a shell prompt and do nothing inside vim, which
     * is the shape of bug that gets reported as "the arrows are broken" a week
     * after somebody checked that the arrows worked.
     */
    case cursor(Character)
    /// A sticky modifier the terminal view owns. See `KeyboardAccessory`.
    case modifier(Modifier)
    case copy
    case paste
    /// Open the photo picker. Raised to the screen, which owns the sheet.
    case sendMedia
    /// Open the file picker. Same.
    case sendFile

    enum Modifier: Equatable {
        case control
        case meta
    }
}

/// One key cap.
struct KeyCap: Equatable {
    /// What is written on it. A glyph for the arrows, a word for everything
    /// else — a terminal key bar is one of the few places a word beats an icon,
    /// because `esc` and `tab` have no icons anybody would recognise.
    let label: String
    /// What VoiceOver says, and what a UI test looks the button up by when the
    /// label is a symbol rather than a word.
    let title: String
    let action: KeyAction
    /// Whether holding it repeats. True only for the four arrows: holding `~`
    /// to get forty of them is not a thing anyone wants, and holding `^C` to
    /// send forty interrupts is actively bad.
    var repeats: Bool = false
}

/// A labelled run of keys in the grid. The label is the whole point — the thing
/// this replaces was a wall of identical squares in one line.
struct KeyGroup: Equatable {
    let title: String
    let keys: [KeyCap]
}

enum KeyPlan {

    /* --------------------------------------------------------- the bar --- */

    /// The keys on the fixed bar, in tap order, left to right.
    ///
    /// `ctrl` sits third rather than first: on a phone held in one hand the far
    /// left of the row is the least reachable spot, and `esc` and `tab` are the
    /// two that get hit blind.
    static let bar: [KeyCap] = [
        KeyCap(label: "esc", title: "Escape", action: .bytes([0x1b])),
        KeyCap(label: "tab", title: "Tab", action: .bytes([0x09])),
        KeyCap(label: "ctrl", title: "Control — applies to the next key",
               action: .modifier(.control)),
        KeyCap(label: "↑", title: "Up arrow", action: .cursor("A"), repeats: true),
        KeyCap(label: "↓", title: "Down arrow", action: .cursor("B"), repeats: true),
    ]

    /* -------------------------------------------------------- the grid --- */

    /**
     * The grid, in the order the groups are read.
     *
     * Ordered by how often a group is wanted rather than by any taxonomy,
     * because the grid opens at the top and only the first two or three groups
     * are visible without scrolling: edit and signals are what a phone reaches
     * for in a hurry, symbols are what it reaches for while typing, and the
     * function keys are the ones nobody presses twice a week.
     */
    static let grid: [KeyGroup] = [
        /*
         * **Sending is a keyboard act, so it is on the keyboard.**
         *
         * > *"can we give media and file button in the bar that comes with
         * > keyboard for special buttons instead of dropdown?"*
         *
         * They were two rows in the session's `…`, which is where a screen keeps
         * the things it does *about* a session — details, model, windows. Handing
         * a photo to an agent is not one of those; it is a thing you do **while
         * typing to it**, in the same breath as the sentence you are writing. So
         * it belongs to the keyboard, and this is the keyboard's own surface.
         *
         * On this panel and not on the fixed bar, and that is arithmetic rather
         * than taste: `minimumBarWidth` already comes to 366 points against a
         * narrowest phone of 375, so five keys and two pinned
         * buttons is what fits at Apple's 44-point touch target. A sixth and
         * seventh would put the bar at 416 and something would have to scroll,
         * which is the exact defect this whole layout was written to remove. The
         * rule at `minimumBarWidth` says what to do instead — *move a key into
         * the grid* — so a key that was never on the bar starts there, first
         * group, one press from the bar.
         */
        KeyGroup(title: sendGroupTitle, keys: [
            KeyCap(label: "photo", title: "Send a photo or video", action: .sendMedia),
            KeyCap(label: "file", title: "Send a file", action: .sendFile),
        ]),
        KeyGroup(title: "Edit", keys: [
            KeyCap(label: "copy", title: "Copy the selection, or the screen", action: .copy),
            KeyCap(label: "paste", title: "Paste", action: .paste),
        ]),
        KeyGroup(title: "Signals", keys: [
            // Written out rather than composed from the ctrl key, because these
            // four are the ones worth one tap: interrupt, end-of-file, suspend,
            // clear.
            KeyCap(label: "^C", title: "Interrupt", action: .bytes([0x03])),
            KeyCap(label: "^D", title: "End of file", action: .bytes([0x04])),
            KeyCap(label: "^Z", title: "Suspend", action: .bytes([0x1a])),
            KeyCap(label: "^L", title: "Clear the screen", action: .bytes([0x0c])),
        ]),
        KeyGroup(title: "Navigation", keys: [
            KeyCap(label: "←", title: "Left arrow", action: .cursor("D"), repeats: true),
            KeyCap(label: "→", title: "Right arrow", action: .cursor("C"), repeats: true),
            KeyCap(label: "home", title: "Home", action: .cursor("H")),
            KeyCap(label: "end", title: "End", action: .cursor("F")),
            KeyCap(label: "pgup", title: "Page up", action: .bytes([0x1b, 0x5b, 0x35, 0x7e])),
            KeyCap(label: "pgdn", title: "Page down", action: .bytes([0x1b, 0x5b, 0x36, 0x7e])),
        ]),
        KeyGroup(title: "Symbols", keys: ["|", "/", "\\", "-", "_", "~", ":", "*"].map { character in
            KeyCap(label: character, title: symbolName(character),
                   action: .bytes(Array(character.utf8)))
        }),
        KeyGroup(title: "Modifiers", keys: [
            KeyCap(label: "alt", title: "Alt — sends the next key with an Escape prefix",
                   action: .modifier(.meta)),
        ]),
        KeyGroup(title: "Function", keys: (1 ... 12).map { number in
            KeyCap(label: "F\(number)", title: "Function key \(number)",
                   action: .bytes(functionKey(number)))
        }),
    ]

    /**
     * The bytes for a function key, as xterm sends them.
     *
     * F1–F4 are SS3 sequences — `ESC O P` through `ESC O S` — and F5 upwards are
     * CSI sequences with a number in them. The numbering skips: there is no 16,
     * 22 or 27, because the original DEC keyboard had keys there that a PC one
     * does not. Getting this from a table rather than from a formula is the only
     * way it is right, and it is why the values are written out.
     */
    static func functionKey(_ number: Int) -> [UInt8] {
        switch number {
        case 1: return [0x1b, 0x4f, 0x50]
        case 2: return [0x1b, 0x4f, 0x51]
        case 3: return [0x1b, 0x4f, 0x52]
        case 4: return [0x1b, 0x4f, 0x53]
        case 5: return csi("15")
        case 6: return csi("17")
        case 7: return csi("18")
        case 8: return csi("19")
        case 9: return csi("20")
        case 10: return csi("21")
        case 11: return csi("23")
        case 12: return csi("24")
        default: return []
        }
    }

    /// `ESC [ <number> ~`.
    private static func csi(_ number: String) -> [UInt8] {
        [0x1b, 0x5b] + Array(number.utf8) + [0x7e]
    }

    /**
     * The bytes for a cursor key, given the terminal's current mode.
     *
     * `home` and `end` travel through the same path because they are cursor keys
     * too — `ESC [ H` and `ESC [ F` — and a phone that sent the application form
     * of the arrows and the normal form of Home would be inconsistent inside a
     * single program.
     */
    static func cursorBytes(_ final: Character, applicationCursor: Bool) -> [UInt8] {
        [0x1b, applicationCursor ? 0x4f : 0x5b, final.asciiValue ?? 0x41]
    }

    /// The word for a punctuation mark, for VoiceOver. A screen reader saying
    /// "vertical line" is the difference between a usable key bar and a row of
    /// unpronounced glyphs.
    private static func symbolName(_ character: String) -> String {
        switch character {
        case "|": return "Pipe"
        case "/": return "Slash"
        case "\\": return "Backslash"
        case "-": return "Hyphen"
        case "_": return "Underscore"
        case "~": return "Tilde"
        case ":": return "Colon"
        case "*": return "Asterisk"
        default: return character
        }
    }

    /* ------------------------------------------------------- geometry ---- */

    /**
     * The narrowest iPhone this app runs on, in points.
     *
     * 375. The deployment target is iOS 17, which needs an A12 or better, and
     * the smallest screen in that set is the iPhone SE (2nd and 3rd generation)
     * and the 12/13 mini — all 375 points wide. This is the number the fixed bar
     * has to fit inside, and it is written down here so the test that checks it
     * is checking a stated rule rather than a number somebody remembered.
     */
    static let narrowestPhoneWidth: CGFloat = 375

    /// The *Send* group's name, spelled once: `KeyGridView` finds that group by
    /// it to hide it on a machine that cannot receive a file, and a heading
    /// matched against a literal in another file is a heading that gets renamed
    /// and silently stops being found.
    static let sendGroupTitle = "Send"

    /// The smallest a key may be and still be a touch target. Apple's own
    /// minimum, and the reason the bar cannot simply grow another key.
    static let minimumTouchTarget: CGFloat = 44

    /// Gap between key caps.
    static let keySpacing: CGFloat = 6
    /// Gap between the key group and the two pinned buttons, which is larger so
    /// that *more* and *dismiss* read as a separate thing rather than as two
    /// more keys.
    static let pinnedSpacing: CGFloat = 12
    /// Distance from the edge of the screen to the first key.
    static let barMargin: CGFloat = 8

    /**
     * How wide the fixed bar has to be before something has to scroll.
     *
     * Every key at the minimum touch target, plus the two pinned buttons, plus
     * every gap. If this is ever larger than `narrowestPhoneWidth` the bar has
     * grown past the phone and the answer is to move a key into the grid — not
     * to add a scroll view, which is the thing being removed.
     */
    static var minimumBarWidth: CGFloat {
        let caps = CGFloat(bar.count + pinnedCount)
        let gaps = CGFloat(bar.count - 1 + pinnedCount - 1) * keySpacing + pinnedSpacing
        return barMargin * 2 + caps * minimumTouchTarget + gaps
    }

    /// `more` and `dismiss`. Named rather than a literal 2 so the arithmetic
    /// above stays true if a third pinned control is ever justified.
    static let pinnedCount = 2
}
