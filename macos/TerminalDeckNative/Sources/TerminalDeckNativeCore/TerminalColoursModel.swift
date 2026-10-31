import Foundation

// Settings → Appearance → Terminal colours (`settings/sections/TerminalColours.tsx`
// and the scheme helpers in `shared/terminal-theme.ts`): pick a scheme, make your
// own, edit any colour, paste one from another terminal, copy one as JSON.

public enum TerminalColours {
    /// Every colour slot, surface first — the order the editor draws (`COLOUR_SLOTS`).
    public static let slots = ["background", "foreground", "cursor", "cursorAccent", "selectionBackground"] + TerminalScheme.ansiSlots

    /// `SLOT_LABELS`.
    public static let labels: [String: String] = [
        "background": "Background", "foreground": "Text", "cursor": "Cursor", "cursorAccent": "Text under the cursor",
        "selectionBackground": "Selection", "black": "Black", "red": "Red", "green": "Green", "yellow": "Yellow",
        "blue": "Blue", "magenta": "Magenta", "cyan": "Cyan", "white": "White", "brightBlack": "Bright black",
        "brightRed": "Bright red", "brightGreen": "Bright green", "brightYellow": "Bright yellow", "brightBlue": "Bright blue",
        "brightMagenta": "Bright magenta", "brightCyan": "Bright cyan", "brightWhite": "Bright white",
    ]

    public static let maxCustom = 40
    public static let maxName = 48

    /// The two preview lines every card prints, each run in the slot it names (`PREVIEW_LINE`, `PREVIEW_LINE_TWO`).
    public static let previewLine: [(text: String, slot: String)] = [
        ("➜ ", "green"), ("app ", "cyan"), ("git:(", "blue"), ("main", "red"), (") ", "blue"), ("npm test", "foreground"),
    ]
    public static let previewLineTwo: [(text: String, slot: String)] = [
        ("✓ 42 passed", "green"), ("  ", "foreground"), ("! 1 skipped", "yellow"), ("  ", "foreground"), ("✗ 0", "red"),
    ]

    /// The setting's chosen id, or "follow-app".
    public static func chosenId(_ values: [String: Any]) -> String {
        (values[TerminalSchemes.settingKey] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? TerminalSchemes.followApp
    }

    public static func isBuiltin(_ id: String) -> Bool {
        TerminalSchemes.builtins.contains { $0.id == id }
    }

    /// `copyName`.
    public static func copyName(_ name: String) -> String {
        name.hasSuffix(" (yours)") ? name : "\(name) (yours)"
    }

    /// `newCustomId`: the first free `custom-N`.
    public static func newCustomId(_ taken: [String]) -> String {
        let used = Set(taken)
        var n = 1
        while used.contains("custom-\(n)") { n += 1 }
        return "custom-\(n)"
    }

    /// `copyOf`.
    public static func copy(_ scheme: TerminalScheme, taken: [String], name: String? = nil) -> TerminalScheme {
        scheme.renamed(id: newCustomId(taken), name: name ?? copyName(scheme.name))
    }

    /// `cleanName`.
    public static func cleanName(_ raw: String) -> String {
        String(raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces).prefix(maxName))
    }

    /// `storedScheme`: what a custom scheme's key holds — its name and its colours.
    public static func stored(_ scheme: TerminalScheme) -> String {
        var out: [String: String] = ["name": scheme.name]
        for slot in slots { out[slot] = scheme.colour(slot) }
        return json(out, pretty: false)
    }

    /// `exportScheme`: the copy-as-JSON text, with the aliases other terminals use.
    public static func export(_ scheme: TerminalScheme) -> String {
        var out: [String: String] = ["name": scheme.name, "id": scheme.id]
        for slot in slots { out[slot] = scheme.colour(slot) }
        out["cursorColor"] = scheme.cursor
        out["purple"] = scheme.magenta
        out["brightPurple"] = scheme.brightMagenta
        return json(out, pretty: true) + "\n"
    }

    private static func json(_ object: [String: String], pretty: Bool) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    public enum ParseResult: Equatable {
        case ok(TerminalScheme)
        case problem(String)
    }

    private static let aliases = ["cursorColor": "cursor", "purple": "magenta", "brightPurple": "brightMagenta"]

    /// `parseScheme`: a pasted scheme, from this app or another terminal.
    public static func parse(_ text: String, taken: [String]) -> ParseResult {
        guard let parsed = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) else {
            return .problem("That is not JSON — check for a missing brace or comma.")
        }
        guard var raw = parsed as? [String: Any] else { return .problem("A scheme is a JSON object.") }
        if let list = raw["schemes"] as? [Any] {
            guard let first = list.first as? [String: Any] else { return .problem("That file has no schemes in it.") }
            raw = first
        }
        var colours: [String: String] = [:]
        var missing: [String] = []
        for slot in slots {
            let alias = aliases.first { $0.value == slot }?.key
            let direct = (raw[slot] as? String).flatMap(TerminalColour.normalise)
            let aliased = alias.flatMap { raw[$0] as? String }.flatMap(TerminalColour.normalise)
            if let colour = direct ?? aliased { colours[slot] = colour } else { missing.append(slot) }
        }
        let still = missing.filter { $0 != "cursorAccent" && $0 != "selectionBackground" }
        if !still.isEmpty {
            let named = still.prefix(3).map { (labels[$0] ?? $0).lowercased() }
            let rest = still.count - named.count
            let list = named.count == 1 ? named[0] : named.dropLast().joined(separator: ", ") + " or " + named.last!
            return .problem("That scheme has no \(list)\(rest > 0 ? ", and \(rest) more" : "").")
        }
        colours["cursorAccent"] = colours["cursorAccent"] ?? colours["background"]
        colours["selectionBackground"] = colours["selectionBackground"] ?? String(colours["foreground"]!.prefix(7)) + "40"
        let name = cleanName(raw["name"] as? String ?? "")
        let wanted = raw["id"] as? String ?? ""
        let finalName = !name.isEmpty ? name : (wanted.isEmpty ? "Imported scheme" : cleanName(wanted))
        return .ok(TerminalScheme(id: newCustomId(taken), name: finalName, background: colours["background"]!,
                                  foreground: colours["foreground"]!, cursor: colours["cursor"]!,
                                  cursorAccent: colours["cursorAccent"]!, selectionBackground: colours["selectionBackground"]!,
                                  ansi: TerminalScheme.ansiSlots.map { colours[$0]! }))
    }

    /// `contrastRatio` of two colours, alpha ignored.
    public static func contrast(_ a: String, _ b: String) -> Double {
        let la = TerminalColour(hex: String(a.prefix(7)))?.relativeLuminance ?? 0
        let lb = TerminalColour(hex: String(b.prefix(7)))?.relativeLuminance ?? 0
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// The opaque `#rrggbb` part (`opaquePart`) and the two alpha digits or "" (`alphaPart`).
    public static func opaque(_ colour: String) -> String { String((TerminalColour.normalise(colour) ?? "#000000").prefix(7)) }
    public static func alpha(_ colour: String) -> String {
        let n = TerminalColour.normalise(colour) ?? "#000000"
        return n.count == 9 ? String(n.suffix(2)) : ""
    }

    /// The sentences under the row and the editor.
    public static func rowHelp(active: TerminalScheme?) -> String {
        active.map { "Every session is drawn in \($0.name)." } ?? "Sessions follow the app’s own light and dark."
    }
    public static let more = "Choosing a scheme pins it: the terminal stays in those colours whether the app is light or dark. Follow the app is the first card and is what an untouched install does."
    public static let followNote = "Dark colours in the dark theme, light ones in the light theme. What every session has always done."
    public static let pasteHelp = "A scheme in JSON, from this app or from another terminal — the usual spellings of the cursor and the two magentas are both understood."
    public static let pastePlaceholder = "{ \"name\": \"…\", \"background\": \"#000000\", … }"
    public static let full = "You already have 40 of your own schemes. Delete one first."
    public static let fullShort = "You already have 40 of your own."

    public static func contrastLine(_ scheme: TerminalScheme) -> String {
        let ratio = String(format: "%.1f", contrast(scheme.foreground, scheme.background))
        var line = "Text on this background measures \(ratio):1. Anything under 4.5 is hard to read."
        if isBuiltin(scheme.id) { line += " \(scheme.name) came with the app, so changing a colour makes you a copy of it." }
        return line
    }

    public static func lightness(_ scheme: TerminalScheme) -> String {
        scheme.isLight
            ? "A light scheme. It stays light while the app is dark — the window’s theme and the terminal’s are separate choices."
            : "A dark scheme. It stays dark while the app is light — the window’s theme and the terminal’s are separate choices."
    }
}

public extension TerminalScheme {
    var magenta: String { ansi[5] }
    var brightMagenta: String { ansi[13] }

    /// The colour in a slot, by its JSON name.
    func colour(_ slot: String) -> String {
        switch slot {
        case "background": return background
        case "foreground": return foreground
        case "cursor": return cursor
        case "cursorAccent": return cursorAccent
        case "selectionBackground": return selectionBackground
        default: return TerminalScheme.ansiSlots.firstIndex(of: slot).map { ansi[$0] } ?? foreground
        }
    }

    /// `withColour`: one colour changed; a refused colour leaves the scheme as it was.
    func with(_ slot: String, _ value: String) -> TerminalScheme {
        guard let colour = TerminalColour.normalise(value) else { return self }
        var ansi = self.ansi
        if let index = TerminalScheme.ansiSlots.firstIndex(of: slot) { ansi[index] = colour }
        return TerminalScheme(id: id, name: name,
                              background: slot == "background" ? colour : background,
                              foreground: slot == "foreground" ? colour : foreground,
                              cursor: slot == "cursor" ? colour : cursor,
                              cursorAccent: slot == "cursorAccent" ? colour : cursorAccent,
                              selectionBackground: slot == "selectionBackground" ? colour : selectionBackground,
                              ansi: ansi)
    }

    func renamed(id: String? = nil, name: String) -> TerminalScheme {
        TerminalScheme(id: id ?? self.id, name: name, background: background, foreground: foreground, cursor: cursor,
                       cursorAccent: cursorAccent, selectionBackground: selectionBackground, ansi: ansi)
    }
}
