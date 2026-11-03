import Foundation
import SwiftTerm

// 27 Oct (Asad: "This kind of problem is very common in both applications, mobile and Mac, when we are using a
// terminal session"; his iLoop Claude Code session on the phone: lines on top of each other, red rows smeared,
// words cut at the left edge, "Called deck-control 5 times" painted into the middle of other lines).
//
// Two causes, both "a terminal drawing bytes that were written for a different terminal":
//
// 1. Sizes. The Mac's terminal and the phone's each set the session's size when they appear, and the last one
//    won. Claude Code then drew every frame for that one size, and the other viewer, at its own size, wrapped
//    each 160-column row over the rows below it. One running program can only draw at one size, so exactly one
//    device owns it (`BackendTerminalViewers`: since 28 Oct the one where it was chosen last); every other device shows a
//    panel that offers to take it back ("Move back here"), never a terminal re-wrapped for another width.
//
// 2. The history a late viewer gets. It was the last 4,000 raw reads of the session. Claude Code's full-screen
//    view draws only what changed since its last frame, so those reads are changes laid over a frame that is
//    no longer in them (and the switch into the full screen, the mouse and paste modes went with it).
//    `BackendTerminalRemount` writes the session's terminal as it is now instead, from the terminal the
//    session's owner has parsed every byte into at the session's real size, plus the modes the program set.

/// A session's size, in cells.
public struct BackendTerminalSize: Hashable, Sendable, Codable {
    public let cols: Int
    public let rows: Int
    public init(cols: Int, rows: Int) { self.cols = cols; self.rows = rows }
}

/// Who owns one session's size (Asad, 28 Oct: "As soon as I click on the session in my phone's side panel, it
/// automatically comes to my phone. That click is the trigger."; "I'm okay with that" to one size per session):
/// - The device where the session was CHOSEN last owns it. This Mac: clicked in its session list or tab strip, or
///   "Move back here" on its panel (`session:use`). A phone (or another Mac): opened the session (`attach` with a
///   size) or "Move back here" (`take`). Typing is not choosing.
/// - This Mac owns it from the start. It stays with the device that chose it last, even while that device is away
///   (a phone in a pocket keeps it, so coming back is instant); the size it gave stays applied meanwhile.
/// A device that is showing the session when another one takes it shows "Open on <name>" with "Move back here"
/// instead of a terminal drawn for another screen. This replaces the 27 Oct rule (the Mac owned it while it was
/// on screen, a phone otherwise, shown as a picture).
public struct BackendTerminalViewers: Sendable, Equatable {
    /// A phone or another Mac attached to the session, at its size.
    public struct Claim: Sendable, Equatable {
        /// The device (its id: the same phone keeps the session across reconnects).
        public let viewer: String
        public let size: BackendTerminalSize
        /// How the device named itself, and its platform ("ios"), for the other devices' panels.
        public let name: String
        public let platform: String
        public init(viewer: String, size: BackendTerminalSize, name: String = "", platform: String = "") {
            self.viewer = viewer; self.size = size; self.name = name; self.platform = platform
        }
    }
    public enum Owner: Sendable, Equatable { case mac, viewer(String) }
    /// Where the session was chosen last.
    public var owner: Owner = .mac
    /// The owner's name and platform while it is not this Mac.
    public var ownerName = ""
    public var ownerPlatform = ""
    /// This Mac's terminal for the session, at its size, as it last said.
    public var mac: BackendTerminalSize?
    /// The phones and other Macs attached to the session, at their sizes.
    public var claims: [Claim] = []
    /// What was last given to the session's program here.
    public var applied: BackendTerminalSize?
    /// Counts owner changes across all sessions, so an answer and an event that cross are put in order. 0: nobody
    /// chose the session since this app started.
    public var turn: UInt64 = 0
    public init() {}
    /// The size the owner wants, or nil when it is not known (an owner away keeps the size it gave).
    public var wanted: BackendTerminalSize? {
        switch owner {
        case .mac: return mac
        case .viewer(let viewer): return claims.last { $0.viewer == viewer }?.size
        }
    }
    /// The session was chosen on that device: it owns the size from now on.
    mutating func used(by user: Owner, name: String = "", platform: String = "", turn next: UInt64) {
        guard owner != user || ownerName != name else { return }
        owner = user; ownerName = name; ownerPlatform = platform; turn = next
    }
    /// Decides after a change: the size to give the program now, if it changed.
    mutating func settle() -> BackendTerminalSize? {
        guard let wanted, wanted != applied else { return nil }
        applied = wanted
        return wanted
    }
}

/// The modes a program set on its terminal that change how a viewer must behave (keys, mouse, paste, cursor),
/// read off the session's own output as it passes. A terminal parser keeps them too, but SwiftTerm does not
/// publish most of them; this reads the same sequences and nothing else.
public struct BackendTerminalModes: Sendable, Equatable {
    private enum State: Sendable { case ground, escape, escapeIntermediate, csi, osc, oscEscape, string, stringEscape }
    private var state = State.ground
    private var sequence: [UInt8] = []
    private var oversized = false
    private var oscText: [UInt8] = []
    public private(set) var privateModes: [Int: Bool] = [:]
    /// Mouse tracking (9, 1000, 1001, 1002, 1003) is one setting, not five: the last one set is the one on, and
    /// turning any of them off turns tracking off (as SwiftTerm and xterm do).
    public private(set) var mouseTracking: Int?
    static let mouseTrackingModes: Set<Int> = [9, 1000, 1001, 1002, 1003]
    public private(set) var ansiModes: [Int: Bool] = [:]
    public private(set) var keypadApplication = false
    public private(set) var keyboardFlags: [Int] = []
    public private(set) var modifyOtherKeys: String?
    public private(set) var cursorStyle: Int?
    public private(set) var title: String?
    /// Whether the program is in its full screen (1049, 1047, 47), or nil while no switch was seen.
    public private(set) var alternate: Bool?
    /// Where (byte offset in what was scanned) the last full repaint began: a clear of the whole screen, a reset,
    /// or a switch into the full screen. What follows it draws the screen without needing what came before.
    public private(set) var lastFullRepaint: Int?
    /// Bytes scanned so far, and where the sequence being read began.
    private var scanned = 0
    private var escapeAt = 0

    public init() {}

    /// DEC private modes that are a viewer's behaviour, not the screen's contents. Everything that moves the
    /// cursor, switches screens (1049/1047/47), resizes (3), or only spans a moment (2026) is left out.
    /// Mouse tracking is replayed on its own (`mouseTracking`).
    static let replayed: Set<Int> = [1, 5, 8, 12, 25, 45, 66, 67, 1004, 1005, 1006, 1007,
                                     1015, 1016, 1034, 1035, 1036, 1037, 1039, 2004, 2031]

    /// Runs on every read of every session in the session host, so plain text costs one `memchr` per read:
    /// outside a sequence, everything up to the next ESC is skipped unread.
    public mutating func scan(_ data: Data) {
        data.withUnsafeBytes { raw in scan(raw) }
    }
    public mutating func scan(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { raw in scan(raw) }
    }
    private mutating func scan(_ raw: UnsafeRawBufferPointer) {
        guard let base = raw.baseAddress else { return }
        let start = scanned
        defer { scanned = start + raw.count }
        var index = 0
        while index < raw.count {
            if state == .ground {
                guard let found = memchr(base + index, 0x1b, raw.count - index) else { return }
                index = base.distance(to: UnsafeRawPointer(found))
            }
            if raw[index] == 0x1b { escapeAt = start + index }
            step(raw[index])
            index += 1
        }
    }

    private mutating func step(_ byte: UInt8) {
        switch state {
        case .ground:
            if byte == 0x1b { state = .escape }
        case .escape:
            switch byte {
            case 0x5b: state = .csi; sequence.removeAll(keepingCapacity: true); oversized = false
            case 0x5d: state = .osc; oscText.removeAll(keepingCapacity: true)
            case 0x50, 0x58, 0x5e, 0x5f: state = .string
            case 0x63: reset(); alternate = false; lastFullRepaint = escapeAt; state = .ground
            case 0x3d: keypadApplication = true; state = .ground
            case 0x3e: keypadApplication = false; state = .ground
            case 0x1b: state = .escape
            case 0x20...0x2f: state = .escapeIntermediate
            default: state = .ground
            }
        case .escapeIntermediate:
            switch byte {
            case 0x20...0x2f: break
            case 0x1b: state = .escape
            default: state = .ground
            }
        case .csi:
            switch byte {
            case 0x20...0x3f:
                if sequence.count < 64 { sequence.append(byte) } else { oversized = true }
            case 0x40...0x7e:
                if !oversized { dispatch(final: byte) }
                state = .ground
            case 0x1b: state = .escape
            case 0x18, 0x1a: state = .ground
            default: break // a control inside a sequence runs and the sequence goes on
            }
        case .osc:
            switch byte {
            case 0x07: finishOSC(); state = .ground
            case 0x1b: state = .oscEscape
            default: if oscText.count < 1024 { oscText.append(byte) }
            }
        case .oscEscape:
            if byte == 0x5c { finishOSC(); state = .ground } else { state = .escape; step(byte) }
        case .string:
            switch byte {
            case 0x1b: state = .stringEscape
            case 0x07: state = .ground
            default: break
            }
        case .stringEscape:
            if byte == 0x5c { state = .ground } else { state = .escape; step(byte) }
        }
    }

    private mutating func reset() {
        privateModes.removeAll(); ansiModes.removeAll(); keypadApplication = false; mouseTracking = nil
        keyboardFlags.removeAll(); modifyOtherKeys = nil; cursorStyle = nil; title = nil
    }

    private mutating func dispatch(final: UInt8) {
        var body = sequence[...]
        var marker: UInt8 = 0
        if let first = body.first, (0x3c...0x3f).contains(first) { marker = first; body = body.dropFirst() }
        let intermediate: UInt8 = body.first { (0x20...0x2f).contains($0) } ?? 0
        let text = String(decoding: body.filter { !(0x20...0x2f).contains($0) }, as: UTF8.self)
        let numbers: [Int?] = text.split(separator: ";", omittingEmptySubsequences: false).map { part in
            part.split(separator: ":").first.flatMap { Int($0) }
        }
        func number(_ index: Int, _ fallback: Int) -> Int { index < numbers.count ? numbers[index] ?? fallback : fallback }
        switch (marker, intermediate, final) {
        case (0x3f, 0, 0x68), (0x3f, 0, 0x6c):
            for case let mode? in numbers {
                if Self.mouseTrackingModes.contains(mode) { mouseTracking = final == 0x68 ? mode : nil }
                else { privateModes[mode] = final == 0x68 }
                if [47, 1047, 1049].contains(mode) {
                    alternate = final == 0x68
                    if final == 0x68 { lastFullRepaint = escapeAt }
                }
            }
        case (0, 0, 0x4a) where number(0, 0) == 2: // the whole screen cleared
            lastFullRepaint = escapeAt
        case (0, 0, 0x68), (0, 0, 0x6c):
            for case let mode? in numbers where mode == 4 || mode == 20 { ansiModes[mode] = final == 0x68 }
        case (0, 0x21, 0x70): // DECSTR, a soft reset
            for mode in [1, 6, 66] { privateModes[mode] = false }
            privateModes[25] = true; privateModes[7] = true; ansiModes[4] = false; keypadApplication = false
        case (0x3e, 0, 0x75): // push keyboard flags
            keyboardFlags.append(number(0, 0)); if keyboardFlags.count > 16 { keyboardFlags.removeFirst() }
        case (0x3c, 0, 0x75): // pop keyboard flags
            keyboardFlags.removeLast(min(keyboardFlags.count, max(1, number(0, 1))))
        case (0x3d, 0, 0x75): // set the current keyboard flags
            let flags = number(0, 0), current = keyboardFlags.last ?? 0
            let next: Int
            switch number(1, 1) { case 2: next = current | flags; case 3: next = current & ~flags; default: next = flags }
            if keyboardFlags.isEmpty { keyboardFlags.append(next) } else { keyboardFlags[keyboardFlags.count - 1] = next }
        case (0x3e, 0, 0x6d): // modifyOtherKeys and friends: `CSI > 4 ; 2 m`
            if number(0, -1) == 4 { modifyOtherKeys = numbers.count > 1 ? text : nil }
        case (0, 0x20, 0x71): // cursor shape
            cursorStyle = number(0, 0)
        default: break
        }
    }

    private mutating func finishOSC() {
        let text = String(decoding: oscText, as: UTF8.self)
        if text.hasPrefix("0;") || text.hasPrefix("2;") {
            title = String(text.dropFirst(2).prefix(256).filter { !$0.isASCII || $0.asciiValue! >= 0x20 })
        }
    }

    /// The sequences that put these modes back on a fresh terminal: each mode as the program last left it, and
    /// only the one mouse tracking mode that is on.
    public func restore() -> String {
        var out = ""
        let modes = privateModes.filter { Self.replayed.contains($0.key) }
        for mode in modes.filter({ !$0.value }).keys.sorted() { out += "\u{1b}[?\(mode)l" }
        for mode in modes.filter({ $0.value }).keys.sorted() { out += "\u{1b}[?\(mode)h" }
        if let mouseTracking { out += "\u{1b}[?\(mouseTracking)h" }
        for (mode, on) in ansiModes.sorted(by: { $0.key < $1.key }) { out += "\u{1b}[\(mode)\(on ? "h" : "l")" }
        if keypadApplication { out += "\u{1b}=" }
        if let flags = keyboardFlags.last, flags != 0 { out += "\u{1b}[>\(flags)u" }
        if let modifyOtherKeys { out += "\u{1b}[>\(modifyOtherKeys)m" }
        if let cursorStyle { out += "\u{1b}[\(cursorStyle) q" }
        if let title { out += "\u{1b}]2;\(title)\u{07}" }
        return out
    }

    /// Whether the program turned automatic wrapping off (it is on unless it did).
    public var wrapsAtTheEdge: Bool { privateModes[7] ?? true }
    /// Whether the program addresses rows inside its scroll region (DECOM).
    public var originMode: Bool { privateModes[6] ?? false }
}

/// The bytes that draw a terminal as it is now on a fresh terminal: the main screen and its history as lines
/// (so a narrower viewer wraps them instead of losing them), a full-screen program's screen cell by cell at the
/// rows it drew them on, its colours and styles, the scroll region, the modes and the cursor.
public enum BackendTerminalRemount {
    public static func render(_ terminal: Terminal, modes: BackendTerminalModes) -> String {
        let (cols, rows) = terminal.getDims()
        let buffer = terminal.buffer
        var out = ""
        let cursorRow = min(max(buffer.y, 0), rows - 1), cursorCol = min(max(buffer.x, 0), cols - 1)
        let region = buffer.scrollTop != 0 || buffer.scrollBottom != rows - 1
        // A full screen is painted from the viewer's top row, so its rows are the program's rows: the cursor goes
        // to its row and column. The main screen's rows land wherever the history pushes them in a viewer of
        // another height, so there the cursor is moved from the last line written, never placed by row number.
        var absoluteCursor = modes.originMode
        if terminal.isCurrentBufferAlternate {
            // What the main screen held before the full-screen program started: its history, as plain lines.
            // An unwritten cell reads as NUL, which a terminal skips; it is a blank column here.
            var lines = String(decoding: terminal.getBufferAsData(kind: .normal), as: UTF8.self)
                .replacingOccurrences(of: "\u{0}", with: " ").components(separatedBy: "\n")
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            out += lines.joined(separator: "\r\n")
            // The full-screen program's screen, row under row from the top (a line break between rows, so what reads
            // the text, like the permission desk, still sees lines). Wrapping is off while it is painted, so a
            // viewer narrower than the session cuts a row short instead of spilling it over the next one.
            out += "\u{1b}[?1049h\u{1b}[H\u{1b}[2J\u{1b}[?7l"
            var painted: [String] = []
            for row in 0..<rows {
                guard let line = terminal.getLine(row: row) else { painted.append(""); continue }
                painted.append(Self.cells(line, terminal: terminal, through: Self.paintedLength(line, terminal: terminal)))
            }
            while let last = painted.last, last.isEmpty { painted.removeLast() }
            out += painted.map { $0.isEmpty ? $0 : $0 + "\u{1b}[0m" }.joined(separator: "\r\n")
            absoluteCursor = true
        } else {
            out += "\u{1b}[?7h"
            var lines: [BufferLine] = []
            var index = buffer.totalLinesTrimmed
            while let line = terminal.getScrollInvariantLine(row: index) { lines.append(line); index += 1 }
            let screenTop = max(0, lines.count - rows)
            let cursorLine = min(lines.count - 1, screenTop + cursorRow)
            // With history above it, the screen is written whole, so its rows land where the program put them.
            // With none, blank rows under the cursor and the paint are left off.
            var last = screenTop > 0 ? lines.count - 1 : cursorLine
            if screenTop == 0 {
                for (offset, line) in lines.enumerated().reversed() where offset > cursorLine {
                    if Self.paintedLength(line, terminal: terminal) > 0 { last = offset; break }
                }
            }
            if last >= 0 {
                for offset in 0...last {
                    let line = lines[offset]
                    let continues = offset < last && lines[offset + 1].isWrapped
                    // A row that the next one continues is written to its last column, so the wrap falls where it
                    // fell; any other row ends where its paint ends and a line break starts the next.
                    out += Self.cells(line, terminal: terminal, through: continues ? cols : Self.paintedLength(line, terminal: terminal))
                    if !continues { out += "\u{1b}[0m"; if offset < last { out += "\r\n" } }
                }
                if !absoluteCursor {
                    if last > cursorLine { out += "\u{1b}[\(last - cursorLine)A" }
                    out += "\u{1b}[\(cursorCol + 1)G"
                }
            }
        }
        out += "\u{1b}[0m"
        // Setting the scroll region sends the cursor home; around it the cursor is saved and put back.
        if region { out += "\u{1b}7\u{1b}[\(buffer.scrollTop + 1);\(buffer.scrollBottom + 1)r\u{1b}8" }
        out += modes.restore()
        out += modes.wrapsAtTheEdge ? "\u{1b}[?7h" : "\u{1b}[?7l"
        if modes.originMode { out += "\u{1b}[?6h" }
        if absoluteCursor {
            let row = modes.originMode ? cursorRow - buffer.scrollTop : cursorRow
            out += "\u{1b}[\(max(row, 0) + 1);\(cursorCol + 1)H"
        }
        return out
    }

    /// Cells up to the last one that shows anything: a character, a background, or a line drawn under or through.
    /// Never past the terminal's width: a line keeps its old cells after the terminal narrows, out of sight.
    static func paintedLength(_ line: BufferLine, terminal: Terminal) -> Int {
        var index = min(line.count, terminal.getDims().cols) - 1
        while index >= 0 {
            let cell = line[index]
            if Self.visible(cell, terminal: terminal) { return index + 1 }
            index -= 1
        }
        return 0
    }

    private static func visible(_ cell: CharData, terminal: Terminal) -> Bool {
        let character = terminal.getCharacter(for: cell)
        if character != "\0" && character != " " { return true }
        let attribute = cell.attribute
        return attribute.bg != .defaultColor && attribute.bg != .defaultInvertedColor
            || attribute.style.contains(.inverse) || attribute.style.contains(.underline) || attribute.style.contains(.crossedOut)
    }

    private static func cells(_ line: BufferLine, terminal: Terminal, through end: Int) -> String {
        var out = ""
        var pen = Attribute.empty
        var penSet = false
        var column = 0
        let limit = min(end, line.count, terminal.getDims().cols)
        while column < limit {
            let cell = line[column]
            if !penSet || cell.attribute != pen {
                out += Self.sgr(cell.attribute); pen = cell.attribute; penSet = true
            }
            let character = terminal.getCharacter(for: cell)
            out.append(character == "\0" ? " " : character)
            // A wide character covers the cell after it, which holds nothing of its own.
            column += cell.width == 2 ? 2 : 1
        }
        return out
    }

    static func sgr(_ attribute: Attribute) -> String {
        var codes = ["0"]
        let style = attribute.style
        if style.contains(.bold) { codes.append("1") }
        if style.contains(.dim) { codes.append("2") }
        if style.contains(.italic) { codes.append("3") }
        if style.contains(.underline) { codes.append("4") }
        if style.contains(.blink) { codes.append("5") }
        if style.contains(.inverse) { codes.append("7") }
        if style.contains(.invisible) { codes.append("8") }
        if style.contains(.crossedOut) { codes.append("9") }
        if let fg = Self.color(attribute.fg, base: 30, bright: 90, extended: 38) { codes.append(fg) }
        if let bg = Self.color(attribute.bg, base: 40, bright: 100, extended: 48) { codes.append(bg) }
        return "\u{1b}[" + codes.joined(separator: ";") + "m"
    }

    private static func color(_ color: Attribute.Color, base: Int, bright: Int, extended: Int) -> String? {
        switch color {
        case .ansi256(let code) where code < 8: return String(base + Int(code))
        case .ansi256(let code) where code < 16: return String(bright + Int(code) - 8)
        case .ansi256(let code): return "\(extended);5;\(code)"
        case .trueColor(let red, let green, let blue): return "\(extended);2;\(red);\(green);\(blue)"
        case .defaultColor, .defaultInvertedColor: return nil
        }
    }
}

/// Test seam: a fresh terminal of the same engine every viewer draws with, fed bytes in order, read back as rows.
final class BackendTerminalProbe: TerminalDelegate {
    private(set) var terminal: Terminal!
    init(cols: Int, rows: Int, scrollback: Int = 4_000) {
        terminal = Terminal(delegate: self, options: TerminalOptions(cols: cols, rows: rows, termName: "xterm-256color", scrollback: scrollback))
    }
    func feed(_ data: Data) { terminal.feed(byteArray: Array(data)) }
    func feed(_ text: String) { terminal.feed(text: text) }
    func resize(cols: Int, rows: Int) { terminal.resize(cols: cols, rows: rows) }
    /// The visible rows as they read on screen: only the terminal's width, an unwritten cell as a blank,
    /// trailing blanks trimmed.
    var rows: [String] {
        let cols = terminal.getDims().cols
        return (0..<terminal.getDims().rows).map { row in
            let text = terminal.getLine(row: row)?.translateToString(trimRight: true, endCol: min(cols, terminal.getLine(row: row)?.count ?? 0),
                                                                    skipNullCellsFollowingWide: true) ?? ""
            return String(String(text.replacingOccurrences(of: "\u{0}", with: " ").reversed().drop { $0 == " " }).reversed())
        }
    }
    /// Cells on a visible row painted with a background colour.
    func backgrounds(row: Int) -> Int {
        guard let line = terminal.getLine(row: row) else { return 0 }
        return (0..<min(line.count, terminal.getDims().cols)).filter { let bg = line[$0].attribute.bg; return bg != .defaultColor && bg != .defaultInvertedColor }.count
    }
    /// The main screen and its history as text, one line per row.
    var history: [String] {
        String(decoding: terminal.getBufferAsData(kind: .normal), as: UTF8.self).components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: "\u{0}", with: " ").trimmingCharacters(in: .whitespaces) }
    }
    var cursor: (col: Int, row: Int) { (terminal.buffer.x, terminal.buffer.y) }
    var fullScreen: Bool { terminal.isCurrentBufferAlternate }
    var reportsMouse: Bool { terminal.mouseMode != .off }
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}
