import Foundation

/// What in a boot file can RUN a command, GRANT tools or CHANGE what an agent may do once an AI tool loads it.
/// Such a file still travels as text; on the receiving Mac it is listed and written only when the person accepts
/// it there. Reading too much as "can run" is the safe direction and is accepted. Nothing here runs or opens anything.
///
/// The header check is DEFAULT-DENY (Security review M1): a header passes without a click only when every key in it
/// is on `harmlessHeaderKeys`, written in the plain form this small reader fully accounts for. Anything else (another
/// key, an escape, an anchor, an alias, a tag, a merge key, a flow `{…}`/`[…]`, an explicit `? key`, a `...` line,
/// a tab, a line it cannot read) makes the file wait.
public extension CloudBootFilesRules {
    /// The only header keys a file may carry and still apply by itself. Each only names or describes the file.
    static let harmlessHeaderKeys: Set<String> = [
        "name", "description", "argument-hint", "when_to_use", "color", "version", "license", "user-invocable", "disable-model-invocation"
    ]
    /// Text an AI tool runs while it loads the file: Claude's `` !`…` `` and fenced ```` ```! ```` blocks, Gemini's `!{…}`.
    static let inlineCommandMarks = ["!`", "```!", "!{"]
    /// The reason a header the reader cannot fully account for gets.
    static let unclearHeader = "header:unclear"

    /// The header lines (after the first `---` line, up to the next `---` line), as written. nil when the text has
    /// none. A header that never closes runs to the end of the text. `...` does NOT end it (Claude Code's reader
    /// ends only at `---`); `headerReasons` makes such a line wait.
    static func headerLines(_ text: String) -> [Substring]? {
        var body = Substring(text)
        if body.unicodeScalars.first == "\u{FEFF}" { body = body.dropFirst() }
        let lines = body.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
        guard let first = lines.first, first.hasPrefix("---") else { return nil }
        var block: [Substring] = []
        // `--- {…}` or `---x`: not a plain opening line. Read as an unclear header (the caller sees it first).
        if first.trimmingCharacters(in: .whitespaces) != "---" { block.append(first) }
        // Security look (13 Nov): only a `---` at the very start of a line ends the header. An indented `  ---` does
        // not end it here; it stays in the header and makes it unclear (`headerReasons`).
        for line in lines.dropFirst() {
            if line.hasPrefix("---"), line.trimmingCharacters(in: .whitespaces) == "---" { break }
            block.append(line)
        }
        return block
    }

    /// Why this header waits, as short codes: `header:<key>` for each key not on `harmlessHeaderKeys`, and
    /// `header:unclear` once when any line is not in the plain form. Empty = every key harmless and plainly written.
    static func headerReasons(_ text: String) -> [String] {
        guard let lines = headerLines(text) else { return [] }
        var reasons: [String] = []
        var unclear = false
        func add(_ reason: String) { if !reasons.contains(reason) { reasons.append(reason) } }
        // What the lines below the last key may be: nothing, list items, or the body of a `|` / `>` block.
        enum Below { case nothing, list, block }
        var below = Below.nothing
        for (index, line) in lines.enumerated() {
            if index == 0, line.hasPrefix("---") { unclear = true; continue }
            if !line.unicodeScalars.allSatisfy(headerScalar) { unclear = true; continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            let indented = line.first == " "
            // An indented `---` (security look, 13 Nov): another reader may end the header there; it waits for a click.
            if indented, trimmed.hasPrefix("---") { unclear = true; continue }
            if below == .block, indented { continue }
            if trimmed == "..." || trimmed.hasPrefix("%") { unclear = true; continue }
            if !indented, trimmed.hasPrefix("#") { below = .nothing; continue }
            if below == .list, trimmed.hasPrefix("- ") || trimmed == "-" {
                if trimmed != "-", !plainValue(trimmed.dropFirst(2)) { unclear = true }
                continue
            }
            below = .nothing
            guard !indented, let entry = keyLine(line) else { unclear = true; continue }
            if !harmlessHeaderKeys.contains(entry.key.lowercased()) { add("header:" + entry.key.lowercased()) }
            let value = entry.value.trimmingCharacters(in: .whitespaces)
            if value.isEmpty || value.hasPrefix("#") { below = .list }
            else if ["|", "|-", "|+", ">", ">-", ">+"].contains(value) { below = .block }
            else if !plainValue(Substring(value)) { unclear = true }
        }
        if unclear { add(unclearHeader) }
        return reasons
    }

    /// No escapes, no tabs, no control, invisible or line-separating characters anywhere in a header.
    private static func headerScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value < 0x20 || (0x7f...0x9f).contains(value) || scalar == "\\" { return false }
        if (0x200b...0x200f).contains(value) || (0x2028...0x202e).contains(value) || (0x2060...0x2069).contains(value) || value == 0xfeff { return false }
        return true
    }

    /// `key: value` (or `key:`) at the start of a line. The key is plain (`[A-Za-z][A-Za-z0-9_-]*`), or exactly that
    /// inside one pair of `"` or `'`; the colon follows at once and is followed by a blank or the line's end.
    private static func keyLine(_ line: Substring) -> (key: String, value: Substring)? {
        var rest = line
        var quote: Character?
        if let first = rest.first, first == "\"" || first == "'" { quote = first; rest = rest.dropFirst() }
        var key = ""
        while let next = rest.first, next.isASCII, next.isLetter || next.isNumber || next == "-" || next == "_" {
            key.append(next)
            rest = rest.dropFirst()
        }
        guard let lead = key.first, lead.isLetter else { return nil }
        if let quote {
            guard rest.first == quote else { return nil }
            rest = rest.dropFirst()
        }
        guard rest.first == ":" else { return nil }
        rest = rest.dropFirst()
        guard rest.isEmpty || rest.first == " " else { return nil }
        return (key, rest)
    }

    /// A value that is only text: one line, quoted once (closing on the same line, no quote inside), or plain and
    /// not starting with a YAML sign (anchor, alias, tag, flow, block, explicit key, directive).
    private static func plainValue(_ value: Substring) -> Bool {
        guard let first = value.first else { return true }
        if first == "\"" || first == "'" {
            let inner = value.dropFirst()
            guard let close = inner.firstIndex(of: first) else { return false }
            let after = inner[inner.index(after: close)...].trimmingCharacters(in: .whitespaces)
            return after.isEmpty || after.hasPrefix("#")
        }
        return !"&*!{}[]|>%@`?,-".contains(first)
    }

    /// `@` imports that reach OUTSIDE the place (Security review M2): Claude Code expands `@path` in `CLAUDE.md`
    /// and commands, Gemini in `GEMINI.md`. An import that starts with `/`, `~` or `$`, names a drive, contains
    /// `..`, a backslash or `://`, is outside. Every `@` is looked at (code blocks too): over-matching is safe.
    /// Returns each such import once, as written (non-plain characters shown as `\u{…}`, at most 80 characters).
    static func outsideImports(_ text: String) -> [String] {
        var found: [String] = []
        var rest = Substring(text)
        while let at = rest.firstIndex(of: "@") {
            rest = rest[rest.index(after: at)...]
            let token = rest.prefix(while: { !$0.isWhitespace })
            guard importLeavesThePlace(token) else { continue }
            var shown = ""
            for scalar in token.unicodeScalars {
                if shown.count >= 80 { shown += "…"; break }
                shown += (0x21...0x7e).contains(scalar.value) ? String(scalar) : "\\u{" + String(scalar.value, radix: 16) + "}"
            }
            if !found.contains(shown) { found.append(shown) }
            if found.count == 5 { break }
        }
        return found
    }

    static func importLeavesThePlace(_ token: Substring) -> Bool {
        // A surrounding bracket or quote is not part of the path.
        let path = token.drop(while: { "([{<\"'`".contains($0) })
        guard let first = path.first else { return false }
        if "/~$\\".contains(first) { return true }
        if path.contains("..") || path.contains("\\") || path.contains("://") { return true }
        let scalars = Array(path.unicodeScalars)
        if scalars.count >= 2, scalars[1] == ":", ("a"..."z").contains(scalars[0]) || ("A"..."Z").contains(scalars[0]) { return true }
        return false
    }

    /// Why this file waits for the person, as short codes; empty = plain text that applies by itself.
    /// The three instruction files at the top of a place (`CLAUDE.md`, `AGENTS.md`, `GEMINI.md`) are text an AI
    /// reads: they wait only for an `@` import that reaches outside the place.
    static func runReasons(relative: String, bytes: Data) -> [String] {
        guard let pieces = parts(relative), let name = pieces.last else { return ["path"] }
        guard let text = String(data: bytes, encoding: .utf8) else { return ["not-text"] }
        let imports = outsideImports(text).map { "import:" + $0 }
        if pieces.count == 1 { return imports }
        var reasons: [String] = []
        let lower = name.lowercased()
        // Anything that is not Markdown or plain text is a script or a settings-like file.
        if !(lower.hasSuffix(".md") || lower.hasSuffix(".markdown") || lower.hasSuffix(".txt")) { reasons.append("script-or-settings") }
        if text.hasPrefix("#!") { reasons.append("script") }
        reasons += headerReasons(text)
        if inlineCommandMarks.contains(where: { text.contains($0) }) { reasons.append("inline-command") }
        return reasons + imports
    }

    /// What the accept sheet shows of a file (security review M3), taken from the exact bytes `accept` writes: the
    /// header with its `---` lines, every line holding an inline command or an `@` (and the whole of a ```` ```! ````
    /// block), and the first 40 lines of a script (a file that is not Markdown or text, or starts with `#!`).
    /// In file order, numbered from 1; at most 400 lines of at most 500 characters. The text is as written: the sheet
    /// escapes it before showing it.
    static func shownLines(relative: String, bytes: Data) -> [CloudBootFilesShownLine] {
        guard let text = String(data: bytes, encoding: .utf8) else { return [] }
        var body = Substring(text)
        if body.unicodeScalars.first == "\u{FEFF}" { body = body.dropFirst() }
        let lines = body.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
        var show = Set<Int>()
        let lower = (parts(relative)?.last ?? relative).lowercased()
        let markdown = lower.hasSuffix(".md") || lower.hasSuffix(".markdown") || lower.hasSuffix(".txt")
        if !markdown || body.hasPrefix("#!") { show.formUnion(0..<min(40, lines.count)) }
        if let first = lines.first, first.hasPrefix("---") {
            var end = lines.count - 1
            for index in 1..<lines.count where lines[index].trimmingCharacters(in: .whitespaces) == "---" { end = index; break }
            show.formUnion(0...end)
        }
        var fenced = false
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if fenced {
                show.insert(index)
                if trimmed.hasPrefix("```") { fenced = false }
                continue
            }
            if trimmed.hasPrefix("```!") { fenced = true }
            if line.contains("@") || inlineCommandMarks.contains(where: { line.contains($0) }) { show.insert(index) }
        }
        return show.sorted().prefix(400).map { index in
            CloudBootFilesShownLine(number: index + 1, text: String(lines[index].prefix(500)))
        }
    }
}

/// One line of a file as the accept sheet shows it.
public struct CloudBootFilesShownLine: Sendable, Equatable {
    /// From 1.
    public let number: Int
    public let text: String
    public init(number: Int, text: String) { self.number = number; self.text = text }
}
