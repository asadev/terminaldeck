import Foundation

// Lane T — Hoot's rail panel and the conversation it shows: the rules of
// `components/ChatView.tsx`, `components/ChatComposer.tsx`, `chat/attach/*` and
// `copilot/driving/CopilotRailPanel.tsx` + `rail-panel.ts`, without any view.

// MARK: - Messages (`ChatMessage`, `ChatUpdate`)

public struct ChatMessage: Equatable, Sendable, Identifiable {
    public enum Role: String, Sendable { case you, agent }
    public let id: String
    public let role: Role
    public let text: String
    /// Milliseconds since 1970; 0 when the transcript did not say.
    public let at: Double

    public init(id: String, role: Role, text: String, at: Double) {
        self.id = id
        self.role = role
        self.text = text
        self.at = at
    }

    public static func decode(_ raw: Any?) -> ChatMessage? {
        guard let record = raw as? [String: Any], let id = record["id"] as? String,
              let role = (record["role"] as? String).flatMap(Role.init(rawValue:)) else { return nil }
        return ChatMessage(id: id, role: role, text: record["text"] as? String ?? "",
                           at: (record["at"] as? NSNumber)?.doubleValue ?? 0)
    }
}

/// `unattributable`: more than one session in the folder could have written it.
public struct ChatUnattributable: Equatable, Sendable {
    public let candidates: Int
    public let competing: Int
}

/// One answer from `chat:load` / `chat:tail`.
public struct ChatUpdate: Equatable, Sendable {
    public let transcriptPath: String
    public let messages: [ChatMessage]
    public let reset: Bool
    public let found: Bool
    public let startedMidFile: Bool
    public let unattributable: ChatUnattributable?

    /// Nil unless it is an object with a `messages` array (`apply`'s guard).
    public static func decode(_ raw: Any?) -> ChatUpdate? {
        guard let record = raw as? [String: Any], let list = record["messages"] as? [Any] else { return nil }
        var unattributable: ChatUnattributable?
        if let u = record["unattributable"] as? [String: Any] {
            unattributable = ChatUnattributable(candidates: (u["candidates"] as? NSNumber)?.intValue ?? 0,
                                                competing: (u["competing"] as? NSNumber)?.intValue ?? 0)
        }
        return ChatUpdate(transcriptPath: record["transcriptPath"] as? String ?? "",
                          messages: list.compactMap(ChatMessage.decode),
                          reset: record["reset"] as? Bool ?? false,
                          found: record["found"] as? Bool ?? false,
                          startedMidFile: record["startedMidFile"] as? Bool ?? false,
                          unattributable: unattributable)
    }
}

/// A message sent from the box that the transcript has not shown yet (`PendingEcho`).
public struct PendingEcho: Equatable, Sendable, Identifiable {
    public let id: String
    public let text: String
    public let at: Double
    public init(id: String, text: String, at: Double) {
        self.id = id
        self.text = text
        self.at = at
    }
}

// MARK: - The conversation's rules

public enum ChatRules {
    /// `ECHO_SLACK_MS`: a transcript turn this much older than the echo still settles it.
    public static let echoSlackMs: Double = 5000
    /// `ECHO_PATIENCE_MS`: after this, "Sending…" becomes the slow sentence.
    public static let echoPatienceMs: Double = 12000
    /// `STICK_PX`: this close to the bottom still follows new messages.
    public static let stickDistance: Double = 72
    /// `REATTRIBUTE_MS`: a transcript change asks which file is the session's at most this often.
    public static let reattributeMs: Double = 3000
    /// `refreshMs`: the tail when nothing pushes changes.
    public static let refreshMs: Double = 2000
    /// `COPIED_MS`: the copy button's tick.
    public static let copiedMs: Double = 1600
    /// `RESOLVE_COALESCE_MS`: the folder's sessions are read again this long after a sighting.
    public static let resolveCoalesceMs: Double = 250
    /// `WAIT_MS` / `RECHECK_MS` of `useSessionTranscript`.
    public static let lookupWaitMs: Double = 4000
    public static let lookupRecheckMs: Double = 12000

    /// `mergeMessages`: by id, a known one replaced in place, a new one appended.
    public static func merge(_ current: [ChatMessage], _ incoming: [ChatMessage]) -> [ChatMessage] {
        guard !incoming.isEmpty else { return current }
        var next = current
        var index: [String: Int] = [:]
        for (i, message) in next.enumerated() { index[message.id] = i }
        for message in incoming {
            if let at = index[message.id] {
                next[at] = message
            } else {
                index[message.id] = next.count
                next.append(message)
            }
        }
        return next
    }

    static func spaced(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// `settleEchoes`: drop each echo a "you" turn now says (the same words, or containing them).
    public static func settle(_ pending: [PendingEcho], against messages: [ChatMessage]) -> [PendingEcho] {
        guard !pending.isEmpty else { return pending }
        var open = pending.map { (echo: $0, text: spaced($0.text), settled: false) }
        for message in messages where message.role == .you {
            let said = spaced(message.text)
            if said.isEmpty { continue }
            if let i = open.firstIndex(where: { !$0.settled && message.at >= $0.echo.at - echoSlackMs
                && (said == $0.text || said.contains($0.text)) }) {
                open[i].settled = true
            }
        }
        let kept = open.filter { !$0.settled }.map(\.echo)
        return kept.count == pending.count ? pending : kept
    }

    /// The echo's foot: "Sending…", then the slow sentence.
    public static func echoNote(waitedMs: Double) -> String {
        waitedMs >= echoPatienceMs ? "Sent — the agent has not written it down yet" : "Sending…"
    }

    public static func isSlow(waitedMs: Double) -> Bool { waitedMs >= echoPatienceMs }

    /// `formatTime`: hours and minutes in the reader's own format, or "" when unknown.
    public static func time(_ at: Double, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        guard at > 0 else { return "" }
        let format = DateFormatter()
        format.locale = locale
        format.timeZone = timeZone
        format.setLocalizedDateFormatFromTemplate("jjmm")
        return format.string(from: Date(timeIntervalSince1970: at / 1000))
    }

    /// `dayBreak`: "Monday 6 October" above the first message of each day.
    public static func dayBreak(_ at: Double, previous: Double, locale: Locale = .current,
                                timeZone: TimeZone = .current) -> String? {
        guard at > 0 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = Date(timeIntervalSince1970: at / 1000)
        if previous > 0, calendar.isDate(Date(timeIntervalSince1970: previous / 1000), inSameDayAs: day) { return nil }
        let format = DateFormatter()
        format.locale = locale
        format.timeZone = timeZone
        format.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
        return format.string(from: day)
    }

    /// The line over a conversation entered late (`startedMidFile`).
    public static let partial = "Only the end of this conversation was read. It is on the server, and the earlier part of it was not brought across."
    public static let jump = "Jump to latest"
}

/// What was on screen per pane, so coming back draws it at once (`rememberDrawn`).
public struct ChatDrawnMemory: Sendable {
    public static let limit = 8
    private var keys: [String] = []
    private var drawn: [String: [ChatMessage]] = [:]

    public init() {}

    public mutating func remember(_ key: String, _ messages: [ChatMessage]) {
        guard !key.isEmpty else { return }
        keys.removeAll { $0 == key }
        keys.append(key)
        drawn[key] = messages
        while keys.count > Self.limit { drawn[keys.removeFirst()] = nil }
    }

    public func recall(_ key: String) -> [ChatMessage] { key.isEmpty ? [] : drawn[key] ?? [] }
}

// MARK: - The sessions in the conversation's folder (`useFolderSessions`)

public enum ChatFolder {
    /// `liveSessionIdOf`: the one given, or the folder's only live session.
    public static func liveSessionId(_ sessions: [TerminalSessionInfo], provided: String?) -> String? {
        if let provided, !provided.isEmpty { return provided }
        let live = sessions.filter { $0.exitCode == nil }
        return live.count == 1 ? live[0].id : nil
    }

    public static func exited(_ sessions: [TerminalSessionInfo], id: String) -> Bool {
        sessions.first { $0.id == id }.map { $0.exitCode != nil } ?? false
    }

    /// `siblingStarts`: the other sessions' start times (this one's skipped once), ascending.
    public static func siblingStarts(_ sessions: [TerminalSessionInfo], own: Double?) -> [Double] {
        var starts: [Double] = []
        var skipped = own == nil
        for session in sessions {
            guard let created = session.createdAt else { continue }
            if !skipped, created == own {
                skipped = true
                continue
            }
            starts.append(created)
        }
        return starts.sorted()
    }
}

// MARK: - Which state an empty pane is in (`ChatEmpty`)

public enum ChatLookup: Equatable, Sendable {
    case loading, none, unwired
    case ambiguous(candidates: Int, competing: Int)
    case ready(path: String)

    public init(_ verdict: TranscriptVerdict) {
        switch verdict {
        case .none: self = .none
        case .choice(let path, _, _): self = .ready(path: path)
        case .ambiguous(let candidates, let competing): self = .ambiguous(candidates: candidates, competing: competing)
        }
    }

    public var path: String? { if case .ready(let path) = self { return path }; return nil }
}

public enum ChatEmptyState: String, Equatable, Sendable {
    case loading, noTranscript, noSessionTranscript, ambiguous, silent, noProject, unwired, shell

    static func typeHere(_ canType: Bool) -> String {
        canType ? "Type below and it will appear here." : "Send a first message in the terminal and it will appear here."
    }

    public var title: String {
        switch self {
        case .loading: return "Reading the transcript…"
        case .noProject: return "No project open"
        case .noTranscript: return "No transcript for this project yet"
        case .noSessionTranscript: return "Nothing from this session yet"
        case .ambiguous: return "Cannot tell which conversation is this session’s"
        case .silent: return "Nothing said yet"
        case .unwired: return "Chat is not wired into this build"
        case .shell: return "This session is a shell"
        }
    }

    public func detail(canType: Bool) -> String {
        switch self {
        case .loading: return ""
        case .noProject: return "Open a folder to see the conversation for its sessions."
        case .noTranscript: return "An agent writes one as it works. \(Self.typeHere(canType))"
        case .noSessionTranscript:
            return "An agent writes a transcript once a session makes its first request. \(Self.typeHere(canType))"
        case .ambiguous:
            return "More than one session is open in this folder, and a transcript does not record which terminal wrote it — so showing one here would be a guess. The terminal view is exact. Running the second session in its own folder keeps them apart."
        case .silent:
            return "This session has a transcript but no prompts or replies in it. \(canType ? "Type below to start it." : "Type something in the terminal.")"
        case .unwired: return "The transcript reader is missing from the preload bridge."
        case .shell:
            return "A conversation is something an agent writes down as it works. A shell just runs what you type, so there is nothing here to read — the terminal is the whole session."
        }
    }

    /// `ChatView`'s `state`, in its order; nil when there is a conversation to draw.
    public static func of(shell: Bool, wired: Bool, messages: Int, scoped: Bool, hasTarget: Bool,
                          lookup: ChatLookup, key: String, found: Bool?, unattributable: Bool) -> ChatEmptyState? {
        if shell { return .shell }
        if !wired { return .unwired }
        if messages > 0 { return nil }
        if scoped && !hasTarget {
            switch lookup {
            case .loading: return .loading
            case .ambiguous: return .ambiguous
            default: return .noSessionTranscript
            }
        }
        if key.isEmpty { return .noProject }
        guard let found else { return .loading }
        if unattributable { return .ambiguous }
        if !found { return .noTranscript }
        return .silent
    }
}

// MARK: - Markdown, as the pane renders an agent's turn

/// A reply's blocks (`marked`, GFM, `breaks: false`, sanitised to the pane's tags).
public indirect enum ChatBlock: Equatable, Sendable {
    /// Inline markdown, soft breaks already turned into spaces.
    case paragraph(String)
    case heading(level: Int, text: String)
    /// Folded under its label (`<details class="cv-code">`).
    case code(language: String?, text: String)
    case list(ordered: Bool, start: Int, items: [[ChatBlock]])
    case quote([ChatBlock])
    case rule
    case table(header: [String], rows: [[String]])
}

public enum ChatMarkdown {
    public static func parse(_ text: String) -> [ChatBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\t", with: "    ")
            .components(separatedBy: "\n")
        return blocks(lines)
    }

    /// The code block's summary: `swift · 12 lines`, or `code · 1 line`.
    public static func codeLabel(language: String?, text: String) -> String {
        let lines = text.components(separatedBy: "\n").count
        let lang = (language ?? "").trimmingCharacters(in: .whitespaces)
        return "\(lang.isEmpty ? "code" : lang) · \(lines) \(lines == 1 ? "line" : "lines")"
    }

    /// Images become what the pane shows for them — their words, marked like a link
    /// whose address is only in its tooltip; nothing is fetched.
    public static func inlineSource(_ text: String) -> String {
        guard text.contains("![") else { return text }
        let pattern = #"!\[([^\]]*)\]\(([^)\s]*)(?:\s+"[^"]*")?\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        var out = ""
        var last = text.startIndex
        for match in regex.matches(in: text, range: range) {
            guard let whole = Range(match.range, in: text), let alt = Range(match.range(at: 1), in: text),
                  let href = Range(match.range(at: 2), in: text) else { continue }
            out += text[last..<whole.lowerBound]
            let words = text[alt].isEmpty ? "image" : String(text[alt])
            out += "[\(words)](\(text[href]))"
            last = whole.upperBound
        }
        out += text[last...]
        return out
    }

    // The block parser: fences, headings (ATX and setext), rules, quotes, lists,
    // GFM tables, indented code and paragraphs.

    static func indent(_ line: String) -> Int { line.prefix { $0 == " " }.count }

    static func dropIndent(_ line: String, _ count: Int) -> String {
        String(line.dropFirst(min(count, indent(line))))
    }

    struct Fence { let char: Character; let length: Int; let info: String?; let indent: Int }

    static func fence(_ line: String) -> Fence? {
        let pad = indent(line)
        guard pad <= 3 else { return nil }
        let rest = line.dropFirst(pad)
        guard let first = rest.first, first == "`" || first == "~" else { return nil }
        let run = rest.prefix { $0 == first }.count
        guard run >= 3 else { return nil }
        let info = rest.dropFirst(run).trimmingCharacters(in: .whitespaces)
        if first == "`", info.contains("`") { return nil }
        let word = info.split(separator: " ").first.map(String.init)
        return Fence(char: first, length: run, info: word, indent: pad)
    }

    static func closes(_ line: String, _ open: Fence) -> Bool {
        guard indent(line) <= 3 else { return false }
        let rest = line.trimmingCharacters(in: .whitespaces)
        return rest.count >= open.length && rest.allSatisfy { $0 == open.char }
    }

    static func heading(_ line: String) -> (Int, String)? {
        guard indent(line) <= 3 else { return nil }
        let rest = line.trimmingCharacters(in: .whitespaces)
        let hashes = rest.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let after = rest.dropFirst(hashes)
        guard after.isEmpty || after.first == " " else { return nil }
        var text = after.trimmingCharacters(in: .whitespaces)
        // A closing run of #s, when a space sets it apart.
        if let cut = text.lastIndex(where: { $0 != "#" }) {
            let tail = text[text.index(after: cut)...]
            if !tail.isEmpty, text[cut] == " " { text = String(text[..<cut]).trimmingCharacters(in: .whitespaces) }
        } else {
            text = ""
        }
        return (hashes, text)
    }

    static func isRule(_ line: String) -> Bool {
        guard indent(line) <= 3 else { return false }
        let marks = line.filter { $0 != " " }
        guard marks.count >= 3, let first = marks.first, "-*_".contains(first) else { return false }
        return marks.allSatisfy { $0 == first }
    }

    struct Marker { let ordered: Bool; let bullet: Character; let number: Int; let contentIndent: Int; let content: String }

    static func listMarker(_ line: String) -> Marker? {
        let pad = indent(line)
        guard pad <= 3 else { return nil }
        let rest = Array(line.dropFirst(pad))
        guard let first = rest.first else { return nil }
        var markerLength = 0
        var ordered = false
        var number = 1
        var bullet = first
        if "-*+".contains(first) {
            markerLength = 1
        } else if first.isASCII, first.isNumber {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            guard digits.count <= 9, digits.count < rest.count, ".)".contains(rest[digits.count]) else { return nil }
            ordered = true
            number = Int(String(digits)) ?? 1
            bullet = rest[digits.count]
            markerLength = digits.count + 1
        } else {
            return nil
        }
        let after = rest.dropFirst(markerLength)
        if after.isEmpty { return Marker(ordered: ordered, bullet: bullet, number: number, contentIndent: pad + markerLength + 1, content: "") }
        guard after.first == " " else { return nil }
        let spaces = after.prefix { $0 == " " }.count
        let gap = spaces > 4 ? 1 : spaces
        let content = String(after.dropFirst(gap))
        return Marker(ordered: ordered, bullet: bullet, number: number, contentIndent: pad + markerLength + gap, content: content)
    }

    static func cells(_ line: String) -> [String] {
        var text = line.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") { text.removeLast() }
        var out: [String] = []
        var current = ""
        var escaped = false
        for ch in text {
            if escaped {
                current.append(ch == "|" ? "|" : "\\\(ch)")
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == "|" {
                out.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(ch)
            }
        }
        if escaped { current.append("\\") }
        out.append(current.trimmingCharacters(in: .whitespaces))
        return out
    }

    static func isDelimiterRow(_ line: String, columns: Int) -> Bool {
        guard line.contains("-") else { return false }
        let row = cells(line)
        guard row.count == columns else { return false }
        return row.allSatisfy { cell in
            var c = Substring(cell)
            if c.hasPrefix(":") { c = c.dropFirst() }
            if c.hasSuffix(":") { c = c.dropLast() }
            return !c.isEmpty && c.allSatisfy { $0 == "-" }
        }
    }

    /// Starts a block of its own, so it cannot continue a paragraph lazily.
    static func interrupts(_ line: String) -> Bool {
        fence(line) != nil || heading(line) != nil || isRule(line)
            || (indent(line) <= 3 && line.trimmingCharacters(in: .whitespaces).hasPrefix(">"))
            || listMarker(line).map { !$0.content.isEmpty } == true
    }

    static func joinParagraph(_ lines: [String]) -> String {
        var out = ""
        for (i, raw) in lines.enumerated() {
            let line = String(raw.drop { $0 == " " })
            let last = i == lines.count - 1
            if last {
                out += line.trimmingCharacters(in: .whitespaces)
            } else if line.hasSuffix("  ") {
                out += line.trimmingCharacters(in: .whitespaces) + "\n"
            } else if line.hasSuffix("\\") {
                out += String(line.dropLast()) + "\n"
            } else {
                out += line.trimmingCharacters(in: .whitespaces) + " "
            }
        }
        return out
    }

    static func blocks(_ lines: [String]) -> [ChatBlock] {
        var out: [ChatBlock] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { out.append(.paragraph(joinParagraph(paragraph))) }
            paragraph = []
        }
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                flush()
                i += 1
                continue
            }
            // Fenced code: to its closing fence, or to the end.
            if let open = fence(line) {
                flush()
                var body: [String] = []
                i += 1
                while i < lines.count, !closes(lines[i], open) {
                    body.append(dropIndent(lines[i], open.indent))
                    i += 1
                }
                if i < lines.count { i += 1 }
                out.append(.code(language: open.info, text: body.joined(separator: "\n")))
                continue
            }
            // Setext heading: a paragraph underlined with = or -.
            if !paragraph.isEmpty, indent(line) <= 3, !trimmed.isEmpty,
               trimmed.allSatisfy({ $0 == "=" }) || trimmed.allSatisfy({ $0 == "-" }) {
                let level = trimmed.first == "=" ? 1 : 2
                out.append(.heading(level: level, text: joinParagraph(paragraph)))
                paragraph = []
                i += 1
                continue
            }
            // Indented code, never inside a paragraph.
            if paragraph.isEmpty, indent(line) >= 4 {
                var body: [String] = []
                while i < lines.count {
                    let l = lines[i]
                    if l.trimmingCharacters(in: .whitespaces).isEmpty {
                        body.append("")
                    } else if indent(l) >= 4 {
                        body.append(String(l.dropFirst(4)))
                    } else {
                        break
                    }
                    i += 1
                }
                while body.last == "" { body.removeLast() }
                out.append(.code(language: nil, text: body.joined(separator: "\n")))
                continue
            }
            if let (level, text) = heading(line) {
                flush()
                out.append(.heading(level: level, text: text))
                i += 1
                continue
            }
            if isRule(line) {
                flush()
                out.append(.rule)
                i += 1
                continue
            }
            // A quote: its lines without the marker, and lazy continuation lines.
            if indent(line) <= 3, trimmed.hasPrefix(">") {
                flush()
                var inner: [String] = []
                while i < lines.count {
                    let l = lines[i]
                    let t = l.trimmingCharacters(in: .whitespaces)
                    if indent(l) <= 3, t.hasPrefix(">") {
                        var rest = t.dropFirst()
                        if rest.first == " " { rest = rest.dropFirst() }
                        inner.append(String(rest))
                    } else if !t.isEmpty, !(inner.last ?? "").trimmingCharacters(in: .whitespaces).isEmpty, !interrupts(l) {
                        inner.append(l)
                    } else {
                        break
                    }
                    i += 1
                }
                out.append(.quote(blocks(inner)))
                continue
            }
            // A list: items of one kind, each item's lines parsed as blocks.
            if let first = listMarker(line), paragraph.isEmpty || !first.content.isEmpty {
                flush()
                var items: [[ChatBlock]] = []
                var current: [String] = [first.content]
                var contentIndent = first.contentIndent
                i += 1
                var blankRun = false
                while i < lines.count {
                    let l = lines[i]
                    let t = l.trimmingCharacters(in: .whitespaces)
                    if t.isEmpty {
                        blankRun = true
                        current.append("")
                        i += 1
                        continue
                    }
                    if let next = listMarker(l), indent(l) < contentIndent, next.ordered == first.ordered, next.bullet == first.bullet {
                        items.append(blocks(current))
                        current = [next.content]
                        contentIndent = next.contentIndent
                        blankRun = false
                        i += 1
                        continue
                    }
                    if indent(l) >= contentIndent {
                        current.append(dropIndent(l, contentIndent))
                        blankRun = false
                        i += 1
                        continue
                    }
                    // Lazy continuation of the item's paragraph.
                    if !blankRun, !interrupts(l), listMarker(l) == nil {
                        current.append(t)
                        i += 1
                        continue
                    }
                    break
                }
                while current.last == "" { current.removeLast() }
                items.append(blocks(current))
                out.append(.list(ordered: first.ordered, start: first.number, items: items))
                continue
            }
            // A GFM table: a row of cells over a delimiter row with as many.
            if paragraph.isEmpty, line.contains("|"), i + 1 < lines.count {
                let header = cells(line)
                if isDelimiterRow(lines[i + 1], columns: header.count) {
                    var rows: [[String]] = []
                    i += 2
                    while i < lines.count {
                        let l = lines[i]
                        let t = l.trimmingCharacters(in: .whitespaces)
                        if t.isEmpty || interrupts(l) { break }
                        var row = cells(l)
                        if row.count < header.count { row += Array(repeating: "", count: header.count - row.count) }
                        rows.append(Array(row.prefix(header.count)))
                        i += 1
                    }
                    out.append(.table(header: header, rows: rows))
                    continue
                }
            }
            paragraph.append(line)
            i += 1
        }
        flush()
        return out
    }
}

// MARK: - Attachments (`chat/attach/mentions.ts`)

public struct ChatAttachment: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case file, image, folder }
    public let path: String
    public let relPath: String
    public let kind: Kind
    public let outside: Bool
    public var id: String { path }

    public init(path: String, relPath: String, kind: Kind, outside: Bool) {
        self.path = path
        self.relPath = relPath
        self.kind = kind
        self.outside = outside
    }
}

/// A path picked, dropped or pasted, and whether it is a folder (`OutsidePick`).
public struct ChatPick: Equatable, Sendable {
    public let path: String
    public let isDirectory: Bool
    public init(path: String, isDirectory: Bool) {
        self.path = path
        self.isDirectory = isDirectory
    }
}

public enum ChatAttach {
    public static let maxAttachments = 10
    public static let imageExtensions = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "svg"]
    public static let outsideFolderCaution =
        "That folder is outside the project. The agent may refuse its listing — a file from out there is read normally."
    /// `MAX_ROWS` / `NOTICE_MS` of the composer.
    public static let maxRows = 12
    public static let noticeMs: Double = 4000
    /// `SUBMIT_GAP_MS`: between the words and the Return.
    public static let submitGapMs = 50

    public enum Scope: Sendable { case project, anywhere }
    public enum Rejection: Sendable { case notAbsolute, outsideRoot, duplicate, full }

    public static func text(_ rejection: Rejection) -> String {
        switch rejection {
        case .notAbsolute: return "That path is not absolute, so the agent could not resolve it."
        case .outsideRoot: return "Only files inside the open project can be attached."
        case .duplicate: return "That is already attached."
        case .full: return "A message can carry \(maxAttachments) attachments."
        }
    }

    static func windowsShaped(_ path: String) -> Bool {
        path.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil || path.hasPrefix("\\\\")
    }

    static func lastSeparator(_ path: String) -> String.Index? {
        path.lastIndex { $0 == "/" || $0 == "\\" }
    }

    static func comparable(_ path: String) -> String {
        windowsShaped(path) ? path.replacingOccurrences(of: "\\", with: "/").lowercased() : path
    }

    public static func isAbsolute(_ path: String) -> Bool {
        let target = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return target.hasPrefix("/") || windowsShaped(target)
    }

    public static func normalise(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 1 { return trimmed }
        if trimmed.range(of: #"^[A-Za-z]:[\\/]+$"#, options: .regularExpression) != nil { return String(trimmed.prefix(3)) }
        var stripped = trimmed
        while let last = stripped.last, last == "/" || last == "\\" { stripped.removeLast() }
        return stripped.isEmpty ? trimmed : stripped
    }

    public static func samePath(_ a: String, _ b: String) -> Bool { comparable(normalise(a)) == comparable(normalise(b)) }

    public static func insideRoot(_ root: String, _ path: String) -> Bool {
        let base = normalise(root)
        let target = normalise(path)
        guard !base.isEmpty, isAbsolute(base), isAbsolute(target) else { return false }
        let top = comparable(base)
        let inner = comparable(target)
        if inner == top { return true }
        return inner.hasPrefix(top.hasSuffix("/") ? top : top + "/")
    }

    public static func basename(_ path: String) -> String {
        let target = normalise(path)
        guard let cut = lastSeparator(target) else { return target }
        return String(target[target.index(after: cut)...])
    }

    public static func relative(to root: String, _ path: String) -> String {
        let base = normalise(root)
        let target = normalise(path)
        if comparable(target) == comparable(base) { return basename(base) }
        return String(target.dropFirst(base.count + 1))
    }

    public static func isImage(_ path: String) -> Bool {
        let name = basename(path).lowercased()
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        return imageExtensions.contains(String(name[name.index(after: dot)...]))
    }

    public static func kind(_ path: String, isDirectory: Bool) -> ChatAttachment.Kind {
        isDirectory ? .folder : isImage(path) ? .image : .file
    }

    /// `mentionFor`: `@"/path"`, a folder with its separator after it.
    public static func mention(_ attachment: ChatAttachment) -> String {
        let path = normalise(attachment.path)
        guard attachment.kind == .folder else { return "@\"\(path)\"" }
        let separator = windowsShaped(path) && path.contains("\\") ? "\\" : "/"
        return "@\"\(path)\(separator)\""
    }

    /// `composeMessage`: the mentions, then the words.
    public static func compose(_ attachments: [ChatAttachment], typed: String) -> String {
        let body = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !attachments.isEmpty else { return body }
        let mentions = attachments.map(mention).joined(separator: " ")
        return body.isEmpty ? mentions : "\(mentions) \(body)"
    }

    /// `terminalPayload`: a space after a message with a mention, so the agent's
    /// file picker closes before the Return.
    public static func terminalPayload(_ message: String) -> String {
        message.contains("@") ? message + " " : message
    }

    /// `terminalWrites`: the words, then the Return.
    public static func terminalWrites(_ message: String) -> [String] { [terminalPayload(message), "\r"] }

    /// `appendSpoken`: words added to what is typed, a space between.
    public static func append(_ existing: String, _ addition: String) -> String {
        let words = addition.trimmingCharacters(in: .whitespacesAndNewlines)
        if words.isEmpty { return existing }
        if existing.isEmpty { return words }
        return existing.last.map { $0.isWhitespace } == true ? existing + words : "\(existing) \(words)"
    }

    public enum Added: Equatable, Sendable {
        case ok([ChatAttachment])
        case refused(Rejection)
    }

    public static func add(_ current: [ChatAttachment], root: String, path: String, isDirectory: Bool,
                           scope: Scope = .project) -> Added {
        let target = normalise(path)
        guard isAbsolute(target) else { return .refused(.notAbsolute) }
        let inside = insideRoot(root, target)
        if !inside, scope == .project { return .refused(.outsideRoot) }
        if current.contains(where: { samePath($0.path, target) }) { return .refused(.duplicate) }
        if current.count >= maxAttachments { return .refused(.full) }
        return .ok(current + [ChatAttachment(path: target, relPath: inside ? relative(to: root, target) : target,
                                             kind: kind(target, isDirectory: isDirectory), outside: !inside)])
    }

    /// `addAttachments`: every one that fits, and the first refusal (else the folder caution).
    public static func add(_ current: [ChatAttachment], root: String, picks: [ChatPick],
                           scope: Scope = .project) -> (attachments: [ChatAttachment], notice: String?) {
        var list = current
        var refusal: String?
        var caution: String?
        for pick in picks {
            switch add(list, root: root, path: pick.path, isDirectory: pick.isDirectory, scope: scope) {
            case .refused(let why):
                if refusal == nil { refusal = text(why) }
            case .ok(let next):
                list = next
                if let added = list.last, added.outside, added.kind == .folder { caution = outsideFolderCaution }
            }
        }
        return (list, refusal ?? caution)
    }

    public static func remove(_ current: [ChatAttachment], path: String) -> [ChatAttachment] {
        current.filter { !samePath($0.path, path) }
    }

    /// The chip's tooltip and its kind mark.
    public static func chipHelp(_ attachment: ChatAttachment) -> String {
        let kind = attachment.kind == .folder ? "a folder" : attachment.kind == .image ? "an image" : "a file"
        return attachment.outside
            ? "\(attachment.path) — outside this project, sent as \(kind) reference"
            : "\(attachment.relPath) — sent as \(kind) reference"
    }

    public static func chipMark(_ kind: ChatAttachment.Kind) -> String {
        kind == .folder ? "/" : kind == .image ? "▣" : "·"
    }
}

// MARK: - The attach menu (`AttachMenu`)

public enum ChatAttachMenu {
    public enum Surface: String, Sendable { case file, folder, image }

    public struct Item: Equatable, Sendable {
        public let surface: Surface
        public let label: String
        public let hint: String
    }

    /// Mention mode for an agent; path mode for a shell.
    public static func items(pathMode: Bool) -> [Item] {
        pathMode
            ? [Item(surface: .file, label: "Insert a file path", hint: "Quoted, so a space cannot split the command"),
               Item(surface: .folder, label: "Insert a folder path", hint: "Quoted, so a space cannot split the command")]
            : [Item(surface: .file, label: "Add files", hint: "Opens the file browser"),
               Item(surface: .folder, label: "Add folder", hint: "Opens the file browser"),
               Item(surface: .image, label: "Add an image", hint: "Opens the file browser, images only")]
    }

    public static func word(pathMode: Bool) -> String { pathMode ? "Path" : "Add" }

    public static func label(pathMode: Bool) -> String {
        pathMode ? "Insert a file or folder path into the command line" : "Add files, folders or images to this message"
    }

    public static func title(pathMode: Bool) -> String {
        pathMode ? "Insert a path into the command line" : "Attach to this message"
    }

    public static let opening = "Opening the file browser…"
}

// MARK: - Files from outside the session's folder (`chat/attach/outside.ts`)

public struct ChatAttachBoundary: Equatable, Sendable {
    public let confined: Bool
    public let folder: String
    public let projects: [String]
    public static let unconfined = ChatAttachBoundary(confined: false, folder: "", projects: [])

    public static func decode(_ raw: Any?) -> ChatAttachBoundary {
        guard let body = raw as? [String: Any], body["confined"] as? Bool == true else { return .unconfined }
        return ChatAttachBoundary(confined: true, folder: body["folder"] as? String ?? "",
                                  projects: (body["projects"] as? [Any])?.compactMap { $0 as? String } ?? [])
    }

    /// `readableOn`.
    public func readable(_ path: String) -> Bool {
        guard confined else { return true }
        if !folder.isEmpty, ChatAttach.insideRoot(folder, path) { return true }
        return projects.contains { ChatAttach.insideRoot($0, path) }
    }

    /// `splitByBoundary`.
    public func split(_ picks: [ChatPick]) -> (allowed: [ChatPick], refused: [ChatPick]) {
        var allowed: [ChatPick] = []
        var refused: [ChatPick] = []
        for pick in picks {
            if readable(pick.path) { allowed.append(pick) } else { refused.append(pick) }
        }
        return (allowed, refused)
    }

    /// `browseStart`: the project, unless the session cannot read it.
    public func browseStart(root: String) -> String {
        guard confined else { return root }
        if !root.isEmpty, readable(root) { return root }
        return folder
    }
}

public enum ChatOutside {
    /// `readPicks`.
    public static func picks(_ raw: Any?) -> [ChatPick] {
        guard let list = raw as? [Any] else { return [] }
        return list.compactMap { value in
            guard let row = value as? [String: Any], let path = row["path"] as? String, !path.isEmpty else { return nil }
            return ChatPick(path: path, isDirectory: row["isDirectory"] as? Bool == true)
        }
    }

    public enum Pasted: Equatable, Sendable {
        case picked([ChatPick])
        case nothing
        case failed(String)
    }

    /// `readPaste` (`attach:paste`).
    public static func pasted(_ raw: Any?) -> Pasted {
        guard let body = raw as? [String: Any] else { return .failed("Pasting a file is not available in this build.") }
        if body["ok"] as? Bool == true {
            let list = picks(body["picks"])
            return list.isEmpty ? .nothing : .picked(list)
        }
        if body["reason"] as? String == "nothing" { return .nothing }
        if let detail = body["detail"] as? String, !detail.isEmpty { return .failed("That image could not be saved: \(detail)") }
        return .failed("That could not be pasted.")
    }

    /// `bringInside` from the answer of `attach:bring-in`: the copies, in the picks' order.
    public static func broughtIn(_ raw: Any?, picks: [ChatPick]) -> (picks: [ChatPick], refused: Int) {
        guard let body = raw as? [String: Any] else { return ([], 0) }
        var landed: [String: String] = [:]
        for entry in body["brought"] as? [Any] ?? [] {
            guard let row = entry as? [String: Any], let from = row["from"] as? String,
                  let path = row["path"] as? String, !path.isEmpty else { continue }
            landed[from] = path
        }
        let refused = (body["refused"] as? NSNumber)?.intValue ?? 0
        return (picks.compactMap { landed[$0.path].map { ChatPick(path: $0, isDirectory: false) } }, refused)
    }

    /// `bringInRefusal`.
    public static func refusal(_ refused: Int) -> String {
        guard refused > 0 else { return "" }
        return refused == 1 ? "One file did not come in." : "\(refused) files did not come in."
    }

    public static let unreadableDrop = "That could not be read as a file on this machine."
}

// MARK: - The composer's words

public enum ChatComposerText {
    public static let idle = "Open a session to write to it"
    public static let agent = "Message the agent…"
    public static let shell = "Run a command in this shell…"
    public static let send = "Send — Enter sends, Shift+Enter starts a new line"

    public static func placeholder(idle: Bool, shell: Bool) -> String {
        idle ? Self.idle : shell ? Self.shell : agent
    }

    /// The box's spoken name: its placeholder without the ellipsis.
    public static func label(shell: Bool) -> String {
        let text = shell ? Self.shell : agent
        return text.hasSuffix("…") ? String(text.dropLast()) : text
    }
}

// MARK: - The rail panel (`rail-panel.ts`, `CopilotRailPanel`)

public enum RailPanelState: String, Sendable { case panel, folded, away }

public enum RailPanelRules {
    /// `railPanelState`: a drive that is not idle, on the browser tab in front.
    /// While a tour plays the drive is withheld (DriveHost publishes null).
    public static func state(drive: DriveNow?, frontTab: String?, folded: Bool, touring: Bool) -> RailPanelState {
        guard !touring, let drive, drive.state != .idle else { return .away }
        guard let frontTab, !frontTab.isEmpty, frontTab == drive.tabId else { return .away }
        return folded ? .folded : .panel
    }

    /// The session a browser tab is bound to (`useWindowBinding`).
    public static func boundSession(_ bindings: BrowserBindings, tabId: String) -> BrowserDriverSession? {
        for (key, windows) in bindings.windows where windows.contains(where: { $0.tabID == tabId }) {
            let parts = key.split(separator: "\u{0}", maxSplits: 1, omittingEmptySubsequences: false)
            guard let first = parts.first, !first.isEmpty else { continue }
            return BrowserDriverSession(sessionId: String(first), machineId: parts.count > 1 ? String(parts[1]) : "")
        }
        return nil
    }

    /// `sendPayload`: trimmed, with a Return when it submits; "" sends nothing.
    public static func payload(_ text: String, submit: Bool) -> String {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.isEmpty { return "" }
        return submit ? typed + "\r" : typed
    }

    public static func label(name: String) -> String {
        name.isEmpty ? "This page’s session" : "\(name) — this page"
    }

    public static let fold = "Fold this into the Commander row"
    public static let nobody = "Nothing is connected to this page, so there is no conversation to show. Connect a session to it from the browser’s toolbar."

    public static func elsewhere(name: String, machine: String?) -> String {
        let place = (machine ?? "").isEmpty ? "another machine" : machine!
        return "\(name) runs on \(place). Its conversation is written on that machine, so it cannot be read here — but what you type below still reaches it."
    }
}
