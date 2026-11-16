import Foundation

/// The bodies of `WhatsAppText.format` and `WhatsAppText.split` (DESIGN-WHATSAPP.md section 4). Foundation only,
/// so Windows ports it file for file.
///
/// Lengths are counted in UTF-16 units: never more than WhatsApp's count, whether it counts characters,
/// code points or UTF-16 units, so a part that passes here is never refused as too long.
enum WhatsAppTextRules {

    // MARK: - Markdown -> WhatsApp

    static func format(_ markdown: String) -> String {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var out: [String] = []
        var fence: String?   // the opening fence's run ("```" or "~~~~") while inside a code block
        var index = 0
        func emit(_ line: String) {
            if line.isEmpty, out.last?.isEmpty ?? true { return }   // one blank line at most, none at the start
            out.append(line)
        }
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if trimmed.hasPrefix(open), trimmed.allSatisfy({ $0 == open.first }) {
                    out.append("```")
                    fence = nil
                } else {
                    out.append(line)   // code is copied exactly
                }
                index += 1
                continue
            }
            if let open = fenceRun(trimmed) {
                fence = open
                out.append("```")   // the language name is dropped: WhatsApp shows it as text
                index += 1
                continue
            }
            if trimmed.contains("|"), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
                emit(cells(trimmed).map { $0.isEmpty ? "" : "*" + inline($0, dropBold: true) + "*" }.joined(separator: " | "))
                index += 2
                while index < lines.count {
                    let row = lines[index].trimmingCharacters(in: .whitespaces)
                    guard !row.isEmpty, row.contains("|") else { break }
                    emit(cells(row).map { inline($0) }.joined(separator: " | "))
                    index += 1
                }
                continue
            }
            if !trimmed.isEmpty, index + 1 < lines.count, isSetextUnderline(lines[index + 1]), isPlainParagraph(trimmed) {
                emit(heading(trimmed))
                index += 2
                continue
            }
            emit(block(line))
            index += 1
        }
        if fence != nil { out.append("```") }
        while out.last?.isEmpty == true { out.removeLast() }
        return out.joined(separator: "\n")
    }

    private static func fenceRun(_ trimmed: String) -> String? {
        for mark in ["`", "~"] {
            let run = trimmed.prefix { String($0) == mark }
            if run.count >= 3 {
                // An info string after ``` may not contain a backtick (CommonMark); after ~~~ anything goes.
                if mark == "`", trimmed.dropFirst(run.count).contains("`") { return nil }
                return String(run)
            }
        }
        return nil
    }

    private static func block(_ line: String) -> String {
        let expanded = line.replacingOccurrences(of: "\t", with: "    ")
        let trimmed = expanded.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "" }
        if matches(trimmed, #"^([-*_])( *\1){2,} *$"#) { return "" }   // a horizontal rule
        if let groups = capture(expanded, #"^ {0,3}#{1,6}[ \t]+(.*?)[ \t]*#*[ \t]*$"#) ?? capture(expanded, #"^ {0,3}#{1,6}$"#) {
            return groups.first.map { heading($0) } ?? ""
        }
        if let groups = capture(expanded, #"^\s*>\s?(.*)$"#) {
            let inner = block(groups[0])
            return inner.isEmpty ? ">" : "> " + inner
        }
        if let groups = capture(expanded, #"^( *)[-*+][ \t]+\[([ xX])\][ \t]+(.*)$"#) {
            return groups[0] + "- " + (groups[1] == " " ? "☐ " : "☑ ") + inline(groups[2])
        }
        if let groups = capture(expanded, #"^( *)[-*+][ \t]+(.*)$"#) {
            return groups[0] + "- " + inline(groups[1])
        }
        if let groups = capture(expanded, #"^( *)([0-9]{1,9})[.)][ \t]+(.*)$"#) {
            return groups[0] + groups[1] + ". " + inline(groups[2])
        }
        return inline(trimmed)
    }

    /// A heading is one bold line; bold marks inside it are dropped so WhatsApp does not see nested stars.
    private static func heading(_ text: String) -> String {
        let body = inline(text, dropBold: true).trimmingCharacters(in: .whitespaces)
        return body.isEmpty ? "" : "*" + body + "*"
    }

    private static func isPlainParagraph(_ trimmed: String) -> Bool {
        !(matches(trimmed, #"^([-*+]|[0-9]{1,9}[.)])[ \t]"#) || trimmed.hasPrefix(">") || trimmed.hasPrefix("#")
            || fenceRun(trimmed) != nil || matches(trimmed, #"^([-*_])( *\1){2,} *$"#))
    }

    private static func isSetextUnderline(_ line: String) -> Bool { matches(line, #"^ {0,3}(=+|-+)[ \t]*$"#) }

    private static func isTableSeparator(_ line: String) -> Bool {
        line.contains("|") && matches(line, #"^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$"#)
    }

    private static func cells(_ row: String) -> [String] {
        var body = row.replacingOccurrences(of: "\\|", with: "\u{E0FE}")
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") { body.removeLast() }
        return body.components(separatedBy: "|").map {
            $0.replacingOccurrences(of: "\u{E0FE}", with: "|").trimmingCharacters(in: .whitespaces)
        }
    }

    // MARK: - Inline marks

    private static let bold = "\u{E0FF}"

    /// One line's inline marks: code spans are kept as they are; the rest is converted.
    static func inline(_ text: String, dropBold: Bool = false) -> String {
        let chars = Array(text)
        var result = "", plain = "", index = 0
        while index < chars.count {
            guard chars[index] == "`" else { plain.append(chars[index]); index += 1; continue }
            var run = 0
            while index + run < chars.count, chars[index + run] == "`" { run += 1 }
            // Find a closing run of exactly the same length.
            var probe = index + run, close: Int?
            while probe < chars.count {
                if chars[probe] == "`" {
                    var other = 0
                    while probe + other < chars.count, chars[probe + other] == "`" { other += 1 }
                    if other == run { close = probe; break }
                    probe += other
                } else {
                    probe += 1
                }
            }
            guard let end = close else {
                plain += String(chars[index..<(index + run)])
                index += run
                continue
            }
            result += convert(plain, dropBold: dropBold)
            plain = ""
            var code = String(chars[(index + run)..<end])
            if code.count > 2, code.hasPrefix(" "), code.hasSuffix(" ") { code = String(code.dropFirst().dropLast()) }
            result += code.contains("`") ? String(chars[index..<(end + run)]) : "`" + code + "`"
            index = end + run
        }
        return result + convert(plain, dropBold: dropBold)
    }

    private static let knownTags = "a|abbr|b|blockquote|br|code|del|details|div|em|h[1-6]|hr|i|img|ins|kbd|li|mark|ol|p|pre|s|small|span|strike|strong|sub|summary|sup|table|tbody|td|th|thead|tr|u|ul"

    private static func convert(_ text: String, dropBold: Bool) -> String {
        guard !text.isEmpty else { return text }
        var kept: [String] = []
        /// Text that later passes must not touch (URLs, escaped marks) waits behind a private-use token.
        func keep(_ value: String) -> String {
            kept.append(value)
            let digits = String(kept.count - 1).unicodeScalars.map { Character(UnicodeScalar(0xE010 + Int($0.value) - 48)!) }
            return "\u{E000}" + String(digits) + "\u{E001}"
        }
        var s = text
        // Backslash escapes: the character itself, never a mark.
        s = replace(s, #"\\([!-/:-@\[-`{-~])"#) { keep($0[1]) }
        // HTML that carries meaning, then the rest of the known tags go.
        s = replace(s, #"[ \t]*<br\s*/?>[ \t]*"#, options: .caseInsensitive) { _ in "\n" }
        s = replace(s, #"</?(b|strong)>"#, options: .caseInsensitive) { _ in "**" }
        s = replace(s, #"</?(i|em)>"#, options: .caseInsensitive) { _ in "_" }
        s = replace(s, #"</?(s|del|strike)>"#, options: .caseInsensitive) { _ in "~~" }
        // Links and pictures: "text (URL)", or the bare URL when the text is the URL.
        s = replace(s, #"!?\[([^\]]*)\]\(\s*<?([^\s)>]+)>?(?:\s+"[^"]*")?\s*\)"#) { groups in
            let label = groups[1].trimmingCharacters(in: .whitespaces), url = groups[2]
            let bareURL = url.replacingOccurrences(of: #"^[a-zA-Z]+://"#, with: "", options: .regularExpression)
            let bareLabel = label.replacingOccurrences(of: #"^[a-zA-Z]+://"#, with: "", options: .regularExpression)
            if label.isEmpty || bareLabel == bareURL || label == url { return keep(url) }
            return label + " (" + keep(url) + ")"
        }
        s = replace(s, #"<((?:https?|mailto):[^>\s]+)>"#) { keep($0[1]) }
        s = replace(s, #"https?://[^\s<>]*[^\s<>.,;:!?'")\]*_~]"#) { keep($0[0]) }
        s = replace(s, "</?(?:" + knownTags + ")(?:\\s[^>]*)?/?>", options: .caseInsensitive) { _ in "" }
        // Emphasis: ***x*** -> *_x_*, **x** / __x__ -> *x*, *x* -> _x_, ~~x~~ -> ~x~.
        let b = dropBold ? "" : bold
        s = replace(s, #"\*\*\*(?=\S)(.+?)(?<=\S)\*\*\*"#) { b + "_" + $0[1] + "_" + b }
        s = replace(s, #"\*\*(?=\S)(.+?)(?<=\S)\*\*"#) { b + $0[1] + b }
        s = replace(s, #"(?<![\p{L}\p{N}_])__(?=\S)(.+?)(?<=\S)__(?![\p{L}\p{N}_])"#) { b + $0[1] + b }
        s = replace(s, #"(?<![\p{L}\p{N}*])\*(?=[^\s*])(.+?)(?<=[^\s*])\*(?![\p{L}\p{N}*])"#) { "_" + $0[1] + "_" }
        s = replace(s, #"~~(?=\S)(.+?)(?<=\S)~~"#) { "~" + $0[1] + "~" }
        s = s.replacingOccurrences(of: bold, with: "*")
        // Entities the AIs sometimes write.
        for (entity, character) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: entity, with: character)
        }
        // Put the kept text back.
        s = replace(s, "\u{E000}([\u{E010}-\u{E019}]+)\u{E001}") { groups in
            let number = Int(String(groups[1].unicodeScalars.map { Character(UnicodeScalar($0.value - 0xE010 + 48)!) })) ?? -1
            return kept.indices.contains(number) ? kept[number] : ""
        }
        return s
    }

    // MARK: - Splitting

    static func units<S: StringProtocol>(_ text: S) -> Int { text.utf16.count }

    static func split(_ text: String, limit: Int) -> [String] {
        let limit = max(limit, 1)
        let clean = tidy(text)
        guard !clean.isEmpty else { return [] }
        if units(clean) <= limit { return [clean] }
        return pack(blocks(clean), limit: limit, finer: .line)
    }

    private struct Piece { var text: String; var code: Bool }
    private enum Level { case line, sentence, word, character }

    /// Leading newlines and trailing white space go; leading spaces stay (an indented list line keeps its indent).
    private static func tidy(_ text: String) -> String {
        var s = Substring(text)
        while let last = s.last, last.isWhitespace { s.removeLast() }
        while let first = s.first, first.isNewline { s.removeFirst() }
        return String(s)
    }

    /// Paragraphs (with the blank lines after them) and whole code blocks, in order; joined they are the text again.
    private static func blocks(_ text: String) -> [Piece] {
        var pieces: [Piece] = [], current = "", inCode = false
        func flush(code: Bool) { if !current.isEmpty { pieces.append(Piece(text: current, code: code)) }; current = "" }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (number, raw) in lines.enumerated() {
            let line = String(raw) + (number < lines.count - 1 ? "\n" : "")
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if inCode {
                current += line
                if trimmed.hasPrefix("```") { inCode = false; flush(code: true) }
            } else if trimmed.hasPrefix("```"), !(trimmed.count > 3 && trimmed.hasSuffix("```")) {
                flush(code: false)
                current = line
                inCode = true
            } else if trimmed.isEmpty {
                // A blank line ends a paragraph and stays with it.
                if current.isEmpty, !pieces.isEmpty { pieces[pieces.count - 1].text += line } else { current += line; flush(code: false) }
            } else {
                current += line
            }
        }
        flush(code: inCode)
        return pieces
    }

    /// Fills parts in order with whole pieces; a piece too long for a part on its own is cut finer.
    private static func pack(_ pieces: [Piece], limit: Int, finer: Level?) -> [String] {
        var parts: [String] = [], current = ""
        func flush() { let part = tidy(current); if !part.isEmpty { parts.append(part) }; current = "" }
        for piece in pieces {
            if units(tidy(current + piece.text)) <= limit { current += piece.text; continue }
            flush()
            if units(tidy(piece.text)) <= limit { current = piece.text; continue }
            if piece.code, let code = splitCode(piece.text, limit: limit) {
                parts += code
            } else if let level = finer {
                parts += cut(piece.text, limit: limit, level: level)
            } else {
                parts += hardCut(piece.text, limit: limit)
            }
        }
        flush()
        return parts
    }

    private static func cut(_ text: String, limit: Int, level: Level) -> [String] {
        let next: Level?
        let pieces: [String]
        switch level {
        case .line:
            next = .sentence
            pieces = chunks(text, #"[^\n]*\n|[^\n]+$"#)
        case .sentence:
            next = .word
            pieces = chunks(text, #"[\s\S]*?[.!?…。！？؟۔]+["')\]»”’]*(\s+|$)|[\s\S]+$"#)
        case .word:
            next = .character
            pieces = chunks(text, #"\s*\S+\s*"#)
        case .character:
            return hardCut(text, limit: limit)
        }
        if pieces.count <= 1 { return next.map { cut(text, limit: limit, level: $0) } ?? hardCut(text, limit: limit) }
        return pack(pieces.map { Piece(text: $0, code: false) }, limit: limit, finer: next)
    }

    /// Last resort for one word longer than a part: whole characters (never half an emoji or a surrogate pair).
    private static func hardCut(_ text: String, limit: Int) -> [String] {
        var parts: [String] = [], current = ""
        for character in text {
            if units(current) + units(String(character)) > limit, !current.isEmpty { parts.append(current); current = "" }
            current.append(character)
        }
        if !tidy(current).isEmpty { parts.append(current) }
        return parts.map(tidy).filter { !$0.isEmpty }
    }

    /// A code block longer than one part: closed at the end of each part and opened again at the start of the next.
    private static func splitCode(_ text: String, limit: Int) -> [String]? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.last?.isEmpty == true { lines.removeLast() }
        guard let opener = lines.first?.trimmingCharacters(in: .whitespaces) else { return nil }
        lines.removeFirst()
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") { lines.removeLast() }
        let room = limit - units(opener) - units("\n") - units("\n```")
        guard room >= 8 else { return nil }   // too small to be worth fences: cut as plain text
        var groups: [String] = [], current: String?
        func flush() { if let group = current { groups.append(group) }; current = nil }
        for line in lines {
            if units(line) > room {
                flush()
                groups += hardCodeLine(line, room: room)
                continue
            }
            if let group = current, units(group) + 1 + units(line) <= room { current = group + "\n" + line } else { flush(); current = line }
        }
        flush()
        return groups.map { opener + "\n" + $0 + "\n```" }
    }

    /// One code line longer than a part: cut after a space where there is one, else between characters.
    private static func hardCodeLine(_ line: String, room: Int) -> [String] {
        var parts: [String] = [], current = ""
        for word in chunks(line, #"\S*\s*"#) where !word.isEmpty {
            if units(current) + units(word) <= room { current += word; continue }
            if !current.isEmpty { parts.append(current); current = "" }
            if units(word) <= room { current = word; continue }
            for character in word {
                if units(current) + units(String(character)) > room, !current.isEmpty { parts.append(current); current = "" }
                current.append(character)
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    // MARK: - Regex helpers

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // Patterns are constants of this file; a bad one is a programming error caught by the tests.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        regex(pattern).firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The capture groups of the first match (unmatched groups as ""), or nil.
    private static func capture(_ text: String, _ pattern: String) -> [String]? {
        guard let match = regex(pattern).firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<max(match.numberOfRanges, 1)).map { group in
            Range(match.range(at: group), in: text).map { String(text[$0]) } ?? ""
        }
    }

    /// The pieces the pattern matches, in order; joined they are the whole text.
    private static func chunks(_ text: String, _ pattern: String) -> [String] {
        let found = regex(pattern).matches(in: text, range: NSRange(text.startIndex..., in: text))
        var pieces: [String] = [], consumed = text.startIndex
        for match in found {
            guard let range = Range(match.range, in: text), !range.isEmpty else { continue }
            if range.lowerBound > consumed { pieces.append(String(text[consumed..<range.lowerBound])) }
            pieces.append(String(text[range]))
            consumed = range.upperBound
        }
        if consumed < text.endIndex {
            if pieces.isEmpty { pieces.append(String(text[consumed...])) } else { pieces[pieces.count - 1] += text[consumed...] }
        }
        return pieces
    }

    /// Replaces every match with what `make` returns for its groups (group 0 = the whole match).
    private static func replace(_ text: String, _ pattern: String, options: NSRegularExpression.Options = [],
                                _ make: ([String]) -> String) -> String {
        let found = regex(pattern, options).matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !found.isEmpty else { return text }
        var result = "", consumed = text.startIndex
        for match in found {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[consumed..<range.lowerBound]
            let groups = (0..<match.numberOfRanges).map { group in
                Range(match.range(at: group), in: text).map { String(text[$0]) } ?? ""
            }
            result += make(groups)
            consumed = range.upperBound
        }
        return result + text[consumed...]
    }
}
