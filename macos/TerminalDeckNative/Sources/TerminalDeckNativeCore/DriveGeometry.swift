import Foundation

// Where a box goes: driving/geometry.ts, driving/terminal-region.ts and
// shared/quote-match.ts (finding a quote in a terminal's lines and turning it into
// a rectangle), and driving/dim-budget.ts (how dark the dim may be) — ported one
// for one. Rectangles are in the window's coordinates, top-left origin.

public struct DriveRect: Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var hasArea: Bool { width > 0 && height > 0 }
}

/// Which sides of a clipped box are its own (true) rather than cut by the viewport.
public struct DriveEdges: Equatable, Sendable {
    public var top: Bool, right: Bool, bottom: Bool, left: Bool
    public static let all = DriveEdges(top: true, right: true, bottom: true, left: true)
    public init(top: Bool, right: Bool, bottom: Bool, left: Bool) {
        self.top = top; self.right = right; self.bottom = bottom; self.left = left
    }
    public var isAll: Bool { top && right && bottom && left }
}

public enum DriveGeometry {
    /// Padding around a terminal quote, an anchor, the page; and the corner radii.
    public static let padTerminal = 3.0, padAnchor = 4.0, padPage = 0.0
    public static let radiusDefault = 6.0, radiusPage = 0.0

    public static func same(_ a: DriveRect?, _ b: DriveRect?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        let e = 0.5
        return abs(a.x - b.x) < e && abs(a.y - b.y) < e && abs(a.width - b.width) < e && abs(a.height - b.height) < e
    }

    public static func union(_ rects: [DriveRect]) -> DriveRect? {
        var out: DriveRect?
        for rect in rects where rect.hasArea {
            guard let o = out else { out = rect; continue }
            let left = min(o.x, rect.x), top = min(o.y, rect.y)
            let right = max(o.x + o.width, rect.x + rect.width), bottom = max(o.y + o.height, rect.y + rect.height)
            out = DriveRect(x: left, y: top, width: right - left, height: bottom - top)
        }
        return out
    }

    public static func pad(_ r: DriveRect, _ p: Double) -> DriveRect {
        DriveRect(x: r.x - p, y: r.y - p, width: r.width + p * 2, height: r.height + p * 2)
    }

    public static func clip(_ r: DriveRect, to b: DriveRect) -> (rect: DriveRect, edges: DriveEdges)? {
        let left = max(r.x, b.x), top = max(r.y, b.y)
        let right = min(r.x + r.width, b.x + b.width), bottom = min(r.y + r.height, b.y + b.height)
        if right <= left || bottom <= top { return nil }
        return (DriveRect(x: left, y: top, width: right - left, height: bottom - top),
                DriveEdges(top: r.y >= b.y, right: r.x + r.width <= b.x + b.width,
                           bottom: r.y + r.height <= b.y + b.height, left: r.x >= b.x))
    }

    /// Whether every painted rect stays clear of `keepClear`.
    public static func outside(_ paint: [DriveRect], _ keepClear: DriveRect) -> Bool {
        paint.allSatisfy { r in
            !r.hasArea || r.x + r.width <= keepClear.x || r.x >= keepClear.x + keepClear.width
                || r.y + r.height <= keepClear.y || r.y >= keepClear.y + keepClear.height
        }
    }

    /// The four bands of an outline drawn just outside a rect.
    public static func outlineBands(_ r: DriveRect, weight w: Double) -> [DriveRect] {
        [DriveRect(x: r.x - w, y: r.y - w, width: r.width + w * 2, height: w),
         DriveRect(x: r.x - w, y: r.y + r.height, width: r.width + w * 2, height: w),
         DriveRect(x: r.x - w, y: r.y, width: w, height: r.height),
         DriveRect(x: r.x + r.width, y: r.y, width: w, height: r.height)]
    }

    /// Corner radii (top-left, top-right, bottom-right, bottom-left): rounded only where both sides are the box's own.
    public static func corners(_ edges: DriveEdges, radius: Double) -> (Double, Double, Double, Double) {
        func c(_ a: Bool, _ b: Bool) -> Double { radius == 0 ? 0 : (a && b ? radius : 0) }
        return (c(edges.top, edges.left), c(edges.top, edges.right), c(edges.bottom, edges.right), c(edges.bottom, edges.left))
    }
}

// MARK: - A quote in a terminal (terminal-region.ts, quote-match.ts)

public struct TerminalMetrics: Equatable, Sendable {
    /// The terminal's screen area in the window.
    public var screen: DriveRect
    public var cols: Int
    public var rows: Int
    public init(screen: DriveRect, cols: Int, rows: Int) { self.screen = screen; self.cols = cols; self.rows = rows }
}

public struct BufferRegion: Equatable, Sendable {
    public var line: Int
    public var lines: Int
    public var startCol: Int
    public var endCol: Int
}

/// The lines of a terminal's buffer, as `locateQuote` reads them.
public protocol TerminalBufferReader {
    /// The first line still held.
    var first: Int { get }
    /// One past the last line.
    var end: Int { get }
    var cols: Int { get }
    func line(_ index: Int) -> String?
}

public enum QuoteMatch {
    public static let needleChars = 64
    /// How far back a quote is looked for, and how many lines a box may cover.
    public static let searchBack = 4000
    public static let maxRegionLines = 40

    /// Control characters to spaces, runs of space to one, trimmed.
    public static func normalizeLine(_ text: String) -> String {
        var out = ""
        var lastSpace = false
        for scalar in text.unicodeScalars {
            let v = scalar.value
            let control = (v <= 0x08) || (v >= 0x0b && v <= 0x1f) || (v >= 0x7f && v <= 0x9f)
            let space = control || CharacterSet.whitespacesAndNewlines.contains(scalar)
            if space {
                if !lastSpace { out.append(" ") }
                lastSpace = true
            } else {
                out.unicodeScalars.append(scalar)
                lastSpace = false
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// The first non-empty line of a quote, cut to 64 characters.
    public static func needle(_ quote: String) -> String {
        for line in quote.components(separatedBy: "\n") {
            let clean = normalizeLine(line)
            if !clean.isEmpty { return String(clean.prefix(needleChars)) }
        }
        return ""
    }

    public static func contains(_ haystack: String, quote: String) -> Bool {
        let n = needle(quote)
        if n.isEmpty { return false }
        if haystack.components(separatedBy: "\n").contains(where: { normalizeLine($0).contains(n) }) { return true }
        return normalizeLine(haystack).contains(n)
    }

    /// `locateQuote`: the newest place the quote's lines appear, as a block of whole lines.
    public static func locate(_ reader: TerminalBufferReader, quote: String) -> BufferRegion? {
        let n = needle(quote)
        if n.isEmpty { return nil }
        let quoted = quote.components(separatedBy: "\n").map(normalizeLine).filter { !$0.isEmpty }
        let wanted = min(quoted.count, maxRegionLines)
        let floor = max(reader.first, reader.end - searchBack)
        var index = reader.end - 1
        while index >= floor {
            defer { index -= 1 }
            guard let text = reader.line(index), normalizeLine(text).contains(n) else { continue }
            var covered = 1, matched = 1, cursor = index + 1
            while matched < wanted && cursor < reader.end && covered < maxRegionLines {
                guard let next = reader.line(cursor) else { break }
                let clean = normalizeLine(next)
                if clean.isEmpty { covered += 1; cursor += 1; continue }
                if !clean.contains(quoted[matched]) && !quoted[matched].contains(clean) { break }
                matched += 1; covered += 1; cursor += 1
            }
            var widest = 0
            for i in index..<(index + covered) {
                if let line = reader.line(i) {
                    var trimmed = Substring(line)
                    while let last = trimmed.last, last.isWhitespace { trimmed = trimmed.dropLast() }
                    widest = max(widest, trimmed.count)
                }
            }
            return BufferRegion(line: index, lines: covered, startCol: 0, endCol: min(reader.cols, max(8, widest + 1)))
        }
        return nil
    }

    /// `regionRect`: a found block on screen, clipped to the terminal.
    public static func rect(_ region: BufferRegion, viewportY: Int, metrics: TerminalMetrics) -> (rect: DriveRect, edges: DriveEdges)? {
        guard metrics.cols > 0, metrics.rows > 0, metrics.screen.hasArea else { return nil }
        let cw = metrics.screen.width / Double(metrics.cols), ch = metrics.screen.height / Double(metrics.rows)
        let row = Double(region.line - viewportY)
        let raw = DriveRect(x: metrics.screen.x + Double(region.startCol) * cw, y: metrics.screen.y + row * ch,
                            width: Double(max(0, region.endCol - region.startCol)) * cw, height: Double(max(1, region.lines)) * ch)
        return DriveGeometry.clip(raw, to: metrics.screen)
    }

    /// `stripAnsi`: OSC, CSI and other escapes out of raw terminal text.
    public static func stripAnsi(_ raw: String) -> String {
        var s = raw
        for pattern in ["\u{1b}\\][\\s\\S]*?(?:\u{07}|\u{1b}\\\\)", "\u{1b}\\[[0-?]*[ -/]*[@-~]", "\u{1b}[ -/]*[0-~]"] {
            s = s.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return s
    }
}

// MARK: - How dark the dim may be (dim-budget.ts)

public enum DimBudget {
    public typealias Rgb = (Double, Double, Double)
    public static let minContrast = 3.0
    public static let minFocusContrast = 4.5
    public static let maxLuminanceKept = 0.62
    public static let minLuminanceKept = 0.3

    public static func parse(_ value: String) -> (rgb: Rgb, alpha: Double)? {
        let t = value.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("#"), t.count == 7, let n = Int(t.dropFirst(), radix: 16) {
            return ((Double((n >> 16) & 255), Double((n >> 8) & 255), Double(n & 255)), 1)
        }
        let pattern = #"^rgba?\(\s*([0-9]+)\s*,\s*([0-9]+)\s*,\s*([0-9]+)\s*(?:,\s*([0-9.]+)\s*)?\)$"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) else { return nil }
        func g(_ i: Int) -> String? { Range(m.range(at: i), in: t).map { String(t[$0]) } }
        guard let r = g(1).flatMap(Double.init), let gr = g(2).flatMap(Double.init), let b = g(3).flatMap(Double.init) else { return nil }
        return ((r, gr, b), g(4).flatMap(Double.init) ?? 1)
    }

    public static func composite(_ over: (rgb: Rgb, alpha: Double), _ under: Rgb) -> Rgb {
        let a = over.alpha
        return (over.rgb.0 * a + under.0 * (1 - a), over.rgb.1 * a + under.1 * (1 - a), over.rgb.2 * a + under.2 * (1 - a))
    }

    public static func luminance(_ c: Rgb) -> Double {
        func ch(_ v: Double) -> Double {
            let s = v / 255
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * ch(c.0) + 0.7152 * ch(c.1) + 0.0722 * ch(c.2)
    }

    public static func contrast(_ a: Rgb, _ b: Rgb) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    public static func dimmedContrast(fg: String, bg: String, scrim: String) -> Double? {
        guard let veil = parse(scrim), let f = parse(fg), let b = parse(bg) else { return nil }
        return contrast(composite(veil, f.rgb), composite(veil, b.rgb))
    }

    public static func luminanceKept(_ colour: String, scrim: String) -> Double? {
        guard let base = parse(colour), let veil = parse(scrim) else { return nil }
        let before = luminance(base.rgb)
        if before == 0 { return 1 }
        return luminance(composite(veil, base.rgb)) / before
    }
}

// MARK: - Resolving a target to a box (focus-target.ts `measure`)

/// A terminal as the focus layer reads it: lane T's native terminal provides this.
public struct DriveTerminalView {
    public var reader: TerminalBufferReader
    public var metrics: TerminalMetrics
    /// The buffer line at the top of the screen.
    public var viewportY: Int
    public var alternateBuffer: Bool
    /// Laid out and on screen.
    public var rendered: Bool
    public init(reader: TerminalBufferReader, metrics: TerminalMetrics, viewportY: Int, alternateBuffer: Bool, rendered: Bool) {
        self.reader = reader; self.metrics = metrics; self.viewportY = viewportY
        self.alternateBuffer = alternateBuffer; self.rendered = rendered
    }
}

public enum DriveResolution: Equatable, Sendable {
    case drawn(rect: DriveRect, edges: DriveEdges, radius: Double)
    case failed(FocusFailure)

    public var rect: DriveRect? { if case .drawn(let r, _, _) = self { return r }; return nil }
}

public enum DriveFocusResolver {
    /// - Parameters:
    ///   - viewport: the window's content area.
    ///   - frame: an anchor's frame by its id, nil when nothing registered it.
    ///   - page: the browser page's frame, if one is on screen.
    ///   - terminal: a session's terminal, nil when no terminal is registered for it.
    ///   - cached: the last place the quote was found, kept while it still holds the text.
    public static func resolve(_ target: FocusTarget, viewport: DriveRect, frame: (String) -> DriveRect?, page: DriveRect?,
                               terminal: (String) -> DriveTerminalView?, cached: inout BufferRegion?) -> DriveResolution {
        switch target {
        case .page:
            guard let page, page.hasArea else { return .failed(.noPage) }
            return .drawn(rect: DriveGeometry.pad(page, DriveGeometry.padPage), edges: .all, radius: DriveGeometry.radiusPage)
        case .anchor(let anchor):
            guard let found = frame(anchor.id) else { return .failed(.anchorMissing) }
            let padded = DriveGeometry.pad(found, DriveGeometry.padAnchor)
            if !padded.hasArea { return .failed(.anchorMissing) }
            guard let clipped = DriveGeometry.clip(padded, to: viewport) else { return .failed(.offScreen) }
            return .drawn(rect: clipped.rect, edges: clipped.edges, radius: DriveGeometry.radiusDefault)
        case .terminal(let sessionId, let quote):
            guard let view = terminal(sessionId) else { cached = nil; return .failed(.notRegistered) }
            if view.alternateBuffer { return .failed(.alternateBuffer) }
            if !view.rendered { return .failed(.notRendered) }
            var region: BufferRegion?
            if let held = cached, held.line >= 0, held.line < view.reader.end,
               let text = view.reader.line(held.line), QuoteMatch.normalizeLine(text).contains(QuoteMatch.needle(quote)) {
                region = held
            } else {
                region = QuoteMatch.locate(view.reader, quote: quote)
            }
            guard let region else { cached = nil; return .failed(.quoteNotFound) }
            cached = region
            guard let placed = QuoteMatch.rect(region, viewportY: view.viewportY, metrics: view.metrics) else { return .failed(.offScreen) }
            let padded = DriveGeometry.clip(DriveGeometry.pad(placed.rect, DriveGeometry.padTerminal), to: view.metrics.screen)
            return .drawn(rect: padded?.rect ?? placed.rect, edges: placed.edges, radius: DriveGeometry.radiusDefault)
        }
    }

    /// `scrollToFocus`: the line to scroll a terminal to so an off-screen quote shows,
    /// with three lines of headroom; nil when no scroll would help.
    public static let scrollHeadroom = 3

    public static func scrollLine(for quote: String, in view: DriveTerminalView) -> Int? {
        guard let region = QuoteMatch.locate(view.reader, quote: quote) else { return nil }
        return max(0, region.line - scrollHeadroom)
    }
}
