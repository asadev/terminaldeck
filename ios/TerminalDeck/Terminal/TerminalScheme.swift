/**
 * A terminal colour scheme, and the built-in set.
 *
 * Asad wants to choose the colour a session is drawn in and wants it everywhere
 * — *"phone also, for Windows, for MacBook, all of them"* — and the one he named
 * is **pure black**, which on this phone is the one that matters most: an OLED
 * panel does not light a `#000000` pixel at all, so a black terminal at night is
 * genuinely black rather than a grey rectangle glowing in a dark room.
 *
 * ## This file is a mirror. It is not a design.
 *
 * The scheme is declared once for the whole product in
 * `src/shared/terminal-theme.ts` — the file the desktop's xterm.js reads — and
 * everything here is that file in Swift: the same ids, the same names, the same
 * hexes, in the same order, with the same rules for copies and for parsing a
 * colour. `TerminalSchemeParityTests` reads the TypeScript at test time and
 * fails on any drift, which is the only thing that keeps *the same scheme on
 * every screen* true after the next person edits one of them.
 *
 * Nothing here is eyeballed or re-derived. Where a scheme is somebody's
 * published palette the source is named above it and the values are the
 * published ones, because "close to Nord" is worse than not shipping Nord.
 *
 * The field names are xterm.js's own — `cursorAccent`, `selectionBackground`,
 * `brightBlack` — rather than nicer Swift ones, for the same reason: a name that
 * differs between the two files is a value that gets copied into the wrong slot
 * exactly once and then never noticed again.
 *
 * ## Why the colours are strings
 *
 * Because the definition is a table of hexes shared with a TypeScript file, and
 * `#rrggbb` compares to its twin character for character. Parsing happens at the
 * edge — `TerminalPalette` turns one into `UIColor` and `SwiftTerm.Color` — so a
 * half-typed value in a custom scheme fails in one place rather than twenty-one.
 *
 * Some of them are **eight** digits. The selection genuinely needs an alpha:
 * xterm.js parses `#rrggbbaa`, a selection is drawn *under* text that has to
 * stay readable, and the alternatives are an opaque band that hides what it
 * covers or a twenty-second field in a shape whose whole promise is twenty-one.
 */

import Foundation

struct TerminalScheme: Codable, Identifiable, Hashable, Sendable {

    /// The stable key — what is stored, and what a saved choice still points at
    /// after a rename.
    var id: String
    /// The only field a person ever sees.
    var name: String

    var background: String
    var foreground: String
    var cursor: String
    var cursorAccent: String
    var selectionBackground: String

    var black: String
    var red: String
    var green: String
    var yellow: String
    var blue: String
    var magenta: String
    var cyan: String
    var white: String
    var brightBlack: String
    var brightRed: String
    var brightGreen: String
    var brightYellow: String
    var brightBlue: String
    var brightMagenta: String
    var brightCyan: String
    var brightWhite: String
}

/* -------------------------------------------------------------------------- */
/* The slots                                                                  */
/* -------------------------------------------------------------------------- */

/**
 * Every colour a scheme holds, surface first — the order the editor draws.
 *
 * `ColourSlot` in the shared file, split there into `SURFACE_SLOTS` and
 * `ANSI_SLOTS`. One enum here with the two groups as static arrays, because a
 * Swift enum can carry the labels and the subscript that an array of strings
 * cannot, and because `CaseIterable` in this order is what stops the editor's
 * grid and `TerminalScheme.ansi` from falling out of step.
 */
enum ColourSlot: String, CaseIterable, Identifiable, Sendable {
    case background, foreground, cursor, cursorAccent, selectionBackground
    case black, red, green, yellow, blue, magenta, cyan, white
    case brightBlack, brightRed, brightGreen, brightYellow
    case brightBlue, brightMagenta, brightCyan, brightWhite

    var id: String { rawValue }

    /// The surface, and the marks this app puts on it rather than a program.
    static let surface: [ColourSlot] = [.background, .foreground, .cursor,
                                        .cursorAccent, .selectionBackground]

    /// The sixteen, in the order the wire numbers them — ANSI 30–37 then 90–97,
    /// which is also the order every published scheme is written in.
    static let ansi: [ColourSlot] = [.black, .red, .green, .yellow,
                                     .blue, .magenta, .cyan, .white,
                                     .brightBlack, .brightRed, .brightGreen, .brightYellow,
                                     .brightBlue, .brightMagenta, .brightCyan, .brightWhite]

    /**
     * What the slot is called on screen — `SLOT_LABELS`, mirrored.
     *
     * Sentence case and no jargon where there is a plain word: somebody
     * changing the colour of the block under the cursor is not looking for
     * `cursorAccent`. The sixteen keep their ANSI names, because those are what
     * the documentation of every program that prints in colour calls them.
     */
    var label: String {
        switch self {
        case .background: return "Background"
        case .foreground: return "Text"
        case .cursor: return "Cursor"
        case .cursorAccent: return "Text under the cursor"
        case .selectionBackground: return "Selection"
        case .black: return "Black"
        case .red: return "Red"
        case .green: return "Green"
        case .yellow: return "Yellow"
        case .blue: return "Blue"
        case .magenta: return "Magenta"
        case .cyan: return "Cyan"
        case .white: return "White"
        case .brightBlack: return "Bright black"
        case .brightRed: return "Bright red"
        case .brightGreen: return "Bright green"
        case .brightYellow: return "Bright yellow"
        case .brightBlue: return "Bright blue"
        case .brightMagenta: return "Bright magenta"
        case .brightCyan: return "Bright cyan"
        case .brightWhite: return "Bright white"
        }
    }
}

extension TerminalScheme {

    /// The sixteen, in wire order, as one array — what `installColors` takes,
    /// and the one place the order could be got wrong silently.
    var ansi: [String] { ColourSlot.ansi.map { self[$0] } }

    subscript(slot: ColourSlot) -> String {
        get {
            switch slot {
            case .background: return background
            case .foreground: return foreground
            case .cursor: return cursor
            case .cursorAccent: return cursorAccent
            case .selectionBackground: return selectionBackground
            case .black: return black
            case .red: return red
            case .green: return green
            case .yellow: return yellow
            case .blue: return blue
            case .magenta: return magenta
            case .cyan: return cyan
            case .white: return white
            case .brightBlack: return brightBlack
            case .brightRed: return brightRed
            case .brightGreen: return brightGreen
            case .brightYellow: return brightYellow
            case .brightBlue: return brightBlue
            case .brightMagenta: return brightMagenta
            case .brightCyan: return brightCyan
            case .brightWhite: return brightWhite
            }
        }
        set {
            switch slot {
            case .background: background = newValue
            case .foreground: foreground = newValue
            case .cursor: cursor = newValue
            case .cursorAccent: cursorAccent = newValue
            case .selectionBackground: selectionBackground = newValue
            case .black: black = newValue
            case .red: red = newValue
            case .green: green = newValue
            case .yellow: yellow = newValue
            case .blue: blue = newValue
            case .magenta: magenta = newValue
            case .cyan: cyan = newValue
            case .white: white = newValue
            case .brightBlack: brightBlack = newValue
            case .brightRed: brightRed = newValue
            case .brightGreen: brightGreen = newValue
            case .brightYellow: brightYellow = newValue
            case .brightBlue: brightBlue = newValue
            case .brightMagenta: brightMagenta = newValue
            case .brightCyan: brightCyan = newValue
            case .brightWhite: brightWhite = newValue
            }
        }
    }

    /**
     * One colour changed, as a new scheme — `withColour`, mirrored.
     *
     * A refused colour returns the scheme unchanged rather than throwing: this
     * is called from a text field on every keystroke, and half a hex code is a
     * normal thing for that field to hold for a moment.
     */
    func with(_ slot: ColourSlot, _ value: String) -> TerminalScheme {
        guard let colour = TerminalPalette.normalized(value) else { return self }
        var edited = self
        edited[slot] = colour
        return edited
    }

    /// Whether this id belongs to a scheme this build ships — i.e. one that
    /// cannot be edited in place. `isBuiltinId`, mirrored.
    var isBuiltIn: Bool { TerminalScheme.builtIns.contains { $0.id == id } }

    /// Is this a scheme for a light room? Measured off the background rather
    /// than declared, at the midpoint of the luminance range — the same test
    /// `isLightScheme` makes, and the reason a light scheme gets a dark hairline
    /// round its preview instead of a light one.
    var isLight: Bool { TerminalPalette.luminance(background) > 0.5 }
}

/* -------------------------------------------------------------------------- */
/* The built-in set                                                           */
/* -------------------------------------------------------------------------- */

extension TerminalScheme {

    /**
     * The id that means *keep following the app's own light and dark* —
     * `FOLLOW_APP_SCHEME_ID`.
     *
     * Not a scheme: a refusal to pin one, and the default. It is what every
     * install has effectively been on since this app existed — the terminal
     * takes its ground and its ink from the appearance, so a phone that crosses
     * into dark at sunset takes its terminal with it. Somebody who never opens
     * the picker has to keep exactly that, which is what an id outside the list
     * buys.
     *
     * The moment a real scheme is chosen that link is cut, on purpose. A person
     * who picks Solarized Light has picked Solarized Light, and a terminal that
     * threw it away at sunset would be the app overruling the one choice this
     * whole screen exists to offer.
     */
    static let followAppID = "follow-app"

    /// The one Asad named. Spelt once here rather than at each use.
    static let pureBlackID = "pure-black"

    /** The app's own dark sixteen — Tango, which is what a session has always
     *  shown. `APP_ANSI_DARK`, and the same table `Ink.ansi` carries. */
    private static let appAnsiDark = (
        black: "#2e3436", red: "#cc0000", green: "#4e9a06", yellow: "#c4a000",
        blue: "#3465a4", magenta: "#75507b", cyan: "#06989a", white: "#d3d7cf",
        brightBlack: "#555753", brightRed: "#ef2929", brightGreen: "#8ae234",
        brightYellow: "#fce94f", brightBlue: "#729fcf", brightMagenta: "#ad7fa8",
        brightCyan: "#34e2e2", brightWhite: "#eeeeec")

    /**
     * The app's light sixteen — the dark set walked down its own hue lines.
     *
     * Not a second palette: `tokens.css` derives these by scaling all three
     * channels toward black by one factor, which preserves hue and saturation
     * and moves only value. `Ink.ansi` carries the same values with the whole
     * derivation written out above them, including the two colours it
     * deliberately leaves alone. `APP_ANSI_LIGHT`.
     */
    private static let appAnsiLight = (
        black: "#2e3436", red: "#cc0000", green: "#3b7405", yellow: "#7c6500",
        blue: "#3465a4", magenta: "#75507b", cyan: "#057375", white: "#d3d7cf",
        brightBlack: "#555753", brightRed: "#951a1a", brightGreen: "#335413",
        brightYellow: "#534d1a", brightBlue: "#384e65", brightMagenta: "#5d445b",
        brightCyan: "#135454", brightWhite: "#eeeeec")

    private static func scheme(
        id: String, name: String,
        background: String, foreground: String, cursor: String,
        cursorAccent: String, selectionBackground: String,
        ansi: (black: String, red: String, green: String, yellow: String,
               blue: String, magenta: String, cyan: String, white: String,
               brightBlack: String, brightRed: String, brightGreen: String, brightYellow: String,
               brightBlue: String, brightMagenta: String, brightCyan: String, brightWhite: String)
    ) -> TerminalScheme {
        TerminalScheme(
            id: id, name: name,
            background: background, foreground: foreground, cursor: cursor,
            cursorAccent: cursorAccent, selectionBackground: selectionBackground,
            black: ansi.black, red: ansi.red, green: ansi.green, yellow: ansi.yellow,
            blue: ansi.blue, magenta: ansi.magenta, cyan: ansi.cyan, white: ansi.white,
            brightBlack: ansi.brightBlack, brightRed: ansi.brightRed,
            brightGreen: ansi.brightGreen, brightYellow: ansi.brightYellow,
            brightBlue: ansi.brightBlue, brightMagenta: ansi.brightMagenta,
            brightCyan: ansi.brightCyan, brightWhite: ansi.brightWhite)
    }

    /**
     * Everything shipped, in the order the picker draws them —
     * `BUILTIN_SCHEMES`, mirrored entry for entry.
     *
     * The app's own two first, because they are what a session already looks
     * like; then the two Asad named, pure black and a dark grey; then the
     * palettes people arrive already knowing.
     */
    static let builtIns: [TerminalScheme] = [

        /* The app's dark theme, as a scheme. Values are `tokens.css`'s own
           --terminal-bg / --terminal-fg / --accent and the dark ANSI block. */
        scheme(id: "deck-dark", name: "Deck Dark",
               background: "#191919", foreground: "#ededed",
               cursor: "#3b8fee", cursorAccent: "#191919",
               /* --accent-soft is rgba(59,143,238,0.16); 0.16 × 255 rounds to 0x29. */
               selectionBackground: "#3b8fee29",
               ansi: appAnsiDark),

        /* And its light theme. The paper is deliberately not the chrome's white:
           a white terminal on a white toolbar stops looking like a terminal. */
        scheme(id: "deck-light", name: "Deck Light",
               background: "#e8e8e8", foreground: "#141414",
               cursor: "#1a66c4", cursorAccent: "#e8e8e8",
               /* --accent-soft in the light theme is rgba(26,102,196,0.1) → 0x1a. */
               selectionBackground: "#1a66c41a",
               ansi: appAnsiLight),

        /*
         * The one he asked for by name: *"we can choose pure black as
         * background"*.
         *
         * The app's dark scheme over a true black ground rather than a new
         * palette — the sixteen were drawn for a near-black surface and are
         * exactly as legible on #000000. The selection is a step heavier than
         * the app's, because sixteen per cent of the accent over #191919 is
         * visible and over black is very nearly not.
         *
         * On this phone specifically it is also the only scheme that is
         * *actually* black: an OLED panel switches the pixel off.
         */
        scheme(id: pureBlackID, name: "Pure Black",
               background: "#000000", foreground: "#ededed",
               cursor: "#3b8fee", cursorAccent: "#000000",
               selectionBackground: "#3b8fee3d",
               ansi: appAnsiDark),

        /* The other end of the same idea: a ground light enough to read as grey
           rather than as black, for a bright room. */
        scheme(id: "dark-grey", name: "Dark Grey",
               background: "#262626", foreground: "#ededed",
               cursor: "#3b8fee", cursorAccent: "#262626",
               selectionBackground: "#3b8fee33",
               ansi: appAnsiDark),

        /* Solarized Dark — Ethan Schoonover, ethanschoonover.com/solarized.
           base03 ground, base0 ink, and the accent set unchanged. The bright
           half is the rest of the base ramp rather than brighter accents, which
           is the design and is what most bad copies of Solarized "fix". */
        TerminalScheme(
            id: "solarized-dark", name: "Solarized Dark",
            background: "#002b36", foreground: "#839496",
            cursor: "#93a1a1", cursorAccent: "#002b36",
            selectionBackground: "#073642",
            black: "#073642", red: "#dc322f", green: "#859900", yellow: "#b58900",
            blue: "#268bd2", magenta: "#d33682", cyan: "#2aa198", white: "#eee8d5",
            brightBlack: "#002b36", brightRed: "#cb4b16", brightGreen: "#586e75",
            brightYellow: "#657b83", brightBlue: "#839496", brightMagenta: "#6c71c4",
            brightCyan: "#93a1a1", brightWhite: "#fdf6e3"),

        /* Solarized Light — the same palette, same source, base3 ground and
           base00 ink. The sixteen are identical to the dark scheme's by design:
           that invariance is the whole claim Solarized makes. */
        TerminalScheme(
            id: "solarized-light", name: "Solarized Light",
            background: "#fdf6e3", foreground: "#657b83",
            cursor: "#586e75", cursorAccent: "#fdf6e3",
            selectionBackground: "#eee8d5",
            black: "#073642", red: "#dc322f", green: "#859900", yellow: "#b58900",
            blue: "#268bd2", magenta: "#d33682", cyan: "#2aa198", white: "#eee8d5",
            brightBlack: "#002b36", brightRed: "#cb4b16", brightGreen: "#586e75",
            brightYellow: "#657b83", brightBlue: "#839496", brightMagenta: "#6c71c4",
            brightCyan: "#93a1a1", brightWhite: "#fdf6e3"),

        /* Nord — nordtheme.com. nord0 ground, nord4 ink; the sixteen are the
           project's own terminal mapping (nord1/3 for the two blacks, nord7 for
           bright cyan, nord5/6 for the two whites). */
        TerminalScheme(
            id: "nord", name: "Nord",
            background: "#2e3440", foreground: "#d8dee9",
            cursor: "#d8dee9", cursorAccent: "#2e3440",
            selectionBackground: "#434c5e",
            black: "#3b4252", red: "#bf616a", green: "#a3be8c", yellow: "#ebcb8b",
            blue: "#81a1c1", magenta: "#b48ead", cyan: "#88c0d0", white: "#e5e9f0",
            brightBlack: "#4c566a", brightRed: "#bf616a", brightGreen: "#a3be8c",
            brightYellow: "#ebcb8b", brightBlue: "#81a1c1", brightMagenta: "#b48ead",
            brightCyan: "#8fbcbb", brightWhite: "#eceff4"),

        /* Dracula — draculatheme.com, the project's published ANSI set. */
        TerminalScheme(
            id: "dracula", name: "Dracula",
            background: "#282a36", foreground: "#f8f8f2",
            cursor: "#f8f8f2", cursorAccent: "#282a36",
            selectionBackground: "#44475a",
            black: "#21222c", red: "#ff5555", green: "#50fa7b", yellow: "#f1fa8c",
            blue: "#bd93f9", magenta: "#ff79c6", cyan: "#8be9fd", white: "#f8f8f2",
            brightBlack: "#6272a4", brightRed: "#ff6e6e", brightGreen: "#69ff94",
            brightYellow: "#ffffa5", brightBlue: "#d6acff", brightMagenta: "#ff92df",
            brightCyan: "#a4ffff", brightWhite: "#ffffff"),

        /* Gruvbox Dark — morhetz/gruvbox, the "dark medium" ground with the
           neutral/bright pairs the palette defines. */
        TerminalScheme(
            id: "gruvbox-dark", name: "Gruvbox Dark",
            background: "#282828", foreground: "#ebdbb2",
            cursor: "#ebdbb2", cursorAccent: "#282828",
            selectionBackground: "#504945",
            black: "#282828", red: "#cc241d", green: "#98971a", yellow: "#d79921",
            blue: "#458588", magenta: "#b16286", cyan: "#689d6a", white: "#a89984",
            brightBlack: "#928374", brightRed: "#fb4934", brightGreen: "#b8bb26",
            brightYellow: "#fabd2f", brightBlue: "#83a598", brightMagenta: "#d3869b",
            brightCyan: "#8ec07c", brightWhite: "#ebdbb2"),

        /* One Half Dark — sonph/onehalf. */
        TerminalScheme(
            id: "one-half-dark", name: "One Half Dark",
            background: "#282c34", foreground: "#dcdfe4",
            cursor: "#dcdfe4", cursorAccent: "#282c34",
            selectionBackground: "#474e5d",
            black: "#282c34", red: "#e06c75", green: "#98c379", yellow: "#e5c07b",
            blue: "#61afef", magenta: "#c678dd", cyan: "#56b6c2", white: "#dcdfe4",
            brightBlack: "#5a6374", brightRed: "#e06c75", brightGreen: "#98c379",
            brightYellow: "#e5c07b", brightBlue: "#61afef", brightMagenta: "#c678dd",
            brightCyan: "#56b6c2", brightWhite: "#dcdfe4"),

        /* One Half Light — the same project's light half. */
        TerminalScheme(
            id: "one-half-light", name: "One Half Light",
            background: "#fafafa", foreground: "#383a42",
            cursor: "#383a42", cursorAccent: "#fafafa",
            selectionBackground: "#bfceff",
            black: "#383a42", red: "#e45649", green: "#50a14f", yellow: "#c18301",
            blue: "#0184bc", magenta: "#a626a4", cyan: "#0997b3", white: "#fafafa",
            brightBlack: "#4f525d", brightRed: "#df6c75", brightGreen: "#98c379",
            brightYellow: "#e4c07a", brightBlue: "#61afef", brightMagenta: "#c577dd",
            brightCyan: "#56b5c1", brightWhite: "#ffffff"),

        /* Tango Dark — the GNOME Tango palette over a black ground. This is
           where the app's own dark sixteen came from, which is why the two look
           related: the difference is the ground and the ink, not the palette. */
        TerminalScheme(
            id: "tango", name: "Tango Dark",
            background: "#000000", foreground: "#d3d7cf",
            cursor: "#ffffff", cursorAccent: "#000000",
            selectionBackground: "#ffffff40",
            black: "#000000", red: "#cc0000", green: "#4e9a06", yellow: "#c4a000",
            blue: "#3465a4", magenta: "#75507b", cyan: "#06989a", white: "#d3d7cf",
            brightBlack: "#555753", brightRed: "#ef2929", brightGreen: "#8ae234",
            brightYellow: "#fce94f", brightBlue: "#729fcf", brightMagenta: "#ad7fa8",
            brightCyan: "#34e2e2", brightWhite: "#eeeeec"),

        /* Campbell — the palette that ships as the default on Windows, and the
           one most people arriving from that platform already have in their eye.
           This app talks to Windows machines; somebody whose PC's shell is
           Campbell can have the same colours on the phone driving it. */
        TerminalScheme(
            id: "campbell", name: "Campbell",
            background: "#0c0c0c", foreground: "#cccccc",
            cursor: "#ffffff", cursorAccent: "#0c0c0c",
            selectionBackground: "#ffffff40",
            black: "#0c0c0c", red: "#c50f1f", green: "#13a10e", yellow: "#c19c00",
            blue: "#0037da", magenta: "#881798", cyan: "#3a96dd", white: "#cccccc",
            brightBlack: "#767676", brightRed: "#e74856", brightGreen: "#16c60c",
            brightYellow: "#f9f1a5", brightBlue: "#3b78ff", brightMagenta: "#b4009e",
            brightCyan: "#61d6d6", brightWhite: "#f2f2f2"),
    ]

    /// The two the app falls back to when nothing is pinned. `appScheme`.
    static func app(dark: Bool) -> TerminalScheme {
        let id = dark ? "deck-dark" : "deck-light"
        // Non-null by construction: both ids are declared above, and
        // `TerminalSchemeTests` fails if either is ever renamed away.
        return builtIns.first { $0.id == id } ?? builtIns[0]
    }

    // MARK: - Copies

    /// How many of somebody's own schemes are kept. `MAX_CUSTOM_SCHEMES`.
    static let maxCustomSchemes = 40
    /// The longest a scheme's name may be — long enough for a published one.
    static let maxNameLength = 48

    /**
     * The name a copy gets. `copyName`.
     *
     * *"(yours)"* rather than *"(copy)"*, because it answers the question
     * somebody asks when they see two Draculas in the list: which of these is
     * the one I changed. Copying a copy does not stack the suffix.
     */
    static func copyName(_ name: String) -> String {
        name.hasSuffix(" (yours)") ? name : "\(name) (yours)"
    }

    /// An id nothing else is using. `newCustomId` — `custom-1`, `custom-2`, …
    static func newCustomID(taken: [String]) -> String {
        let used = Set(taken)
        var n = 1
        while used.contains("custom-\(n)") { n += 1 }
        return "custom-\(n)"
    }

    /**
     * A person's copy of a scheme, ready to store. `copyOf`.
     *
     * Editing a built-in never overwrites it — the picker keeps every shipped
     * palette exactly as published, which is the only way "Nord" can go on
     * meaning Nord.
     */
    func copy(taken: [String], name: String? = nil) -> TerminalScheme {
        var copy = self
        copy.id = TerminalScheme.newCustomID(taken: taken)
        copy.name = name ?? TerminalScheme.copyName(self.name)
        return copy
    }

    /// Trimmed, collapsed and cut to length; empty when there is nothing left.
    /// `cleanName`. The caller decides what an empty name means — see
    /// `TerminalThemeStore.rename`.
    static func cleanName(_ raw: String) -> String {
        let collapsed = raw.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
        return String(collapsed.prefix(maxNameLength))
    }
}
