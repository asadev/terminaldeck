import Foundation

/// Live narration of a phone recording — the pure half (lane NARR, 9 Oct 2026).
///
/// Asad: "it breaks our words by frames or pages where we are, it keeps tagging and
/// converting to text in real time in front, so we know it's attaching to the point
/// we want to explain, and it sends you only video and that text."
///
/// While a recording runs, his words arrive with their own times (seconds of the
/// video). Every time the phone moves to a different screen a new segment starts,
/// with that screen's name and one picture of it. A word belongs to the segment
/// that was on show when he started saying it. All times are seconds from the
/// start of the video.

// MARK: - Words

public struct NarrationWord: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = max(start, end)
        self.text = text
    }

    /// Spread a phrase's words evenly over the time it was spoken (a provider that
    /// answers a phrase at a time gives no times per word).
    public static func spread(_ phrase: String, from start: Double, to end: Double) -> [NarrationWord] {
        let tokens = phrase.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }
        let step = max(0, end - start) / Double(tokens.count)
        return tokens.enumerated().map { index, token in
            NarrationWord(start: start + step * Double(index), end: start + step * Double(index + 1), text: token)
        }
    }

    /// Words as one line: spaces between them, none before punctuation.
    public static func join(_ words: [NarrationWord]) -> String {
        var out = ""
        for word in words {
            let token = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            if !out.isEmpty, let first = token.unicodeScalars.first,
               !CharacterSet(charactersIn: ".,!?;:%)]}…'’”").contains(first) { out += " " }
            out += token
        }
        return out
    }
}

// MARK: - Segments

public struct NarrationSegment: Equatable, Sendable, Identifiable {
    /// 1, 2, 3… in the order the screens were visited.
    public var id: Int
    public var start: Double
    /// Nil while it is the screen on show.
    public var end: Double?
    /// The screen's title or accessible name, when it could be read.
    public var name: String?
    /// The picture of this screen, saved on the Mac.
    public var keyframe: String?
    /// His own wording, once he edits it on the card; the heard words otherwise.
    public var edited: String?

    public init(id: Int, start: Double, end: Double? = nil, name: String? = nil, keyframe: String? = nil, edited: String? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.name = name
        self.keyframe = keyframe
        self.edited = edited
    }

    /// "Listing details", or "Screen 2" when no name could be read.
    public var title: String {
        let named = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return named.isEmpty ? "Screen \(id)" : named
    }

    public func contains(_ time: Double) -> Bool {
        time >= start && time < (end ?? .infinity)
    }
}

public struct NarrationTimeline: Equatable, Sendable {
    /// A screen shown for less than this, with nothing said on it, was a transition:
    /// the next screen takes its place instead of adding one.
    public static let minimumDwell = 1.0

    public private(set) var segments: [NarrationSegment] = []
    /// Words the engine will not change any more.
    public private(set) var settled: [NarrationWord] = []
    /// The words still being worked out (the end of what he is saying now).
    public private(set) var volatile: [NarrationWord] = []
    public private(set) var finished = false

    public init() {}

    /// The recording started on this screen.
    public mutating func begin(name: String? = nil, keyframe: String? = nil) {
        segments = [NarrationSegment(id: 1, start: 0, name: name, keyframe: keyframe)]
        settled = []
        volatile = []
        finished = false
    }

    public var current: NarrationSegment? { finished ? nil : segments.last }

    /// The phone moved to a different screen at `time`. Returns the id of the segment
    /// now on show (a new one, or the last one reused when that was only a moment).
    @discardableResult
    public mutating func newScreen(at time: Double, name: String? = nil, keyframe: String? = nil) -> Int {
        guard !finished else { return segments.last?.id ?? 0 }
        guard var last = segments.last else {
            begin(name: name, keyframe: keyframe)
            return 1
        }
        let at = max(time, last.start)
        if at - last.start < Self.minimumDwell, words(in: last).isEmpty, segments.count > 1 {
            // A screen passed through on the way: this one takes its place.
            last.name = name
            last.keyframe = keyframe
            segments[segments.count - 1] = last
            return last.id
        }
        last.end = at
        segments[segments.count - 1] = last
        let next = NarrationSegment(id: last.id + 1, start: at, name: name, keyframe: keyframe)
        segments.append(next)
        return next.id
    }

    /// The name of a screen, read after its segment started.
    public mutating func name(_ id: Int, _ name: String?) {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[index].name = name
    }

    public mutating func keyframe(_ id: Int, _ path: String?) {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[index].keyframe = path
    }

    /// Words the engine is sure of, for the time `from..<to` (nil: the words' own span).
    /// They replace what was heard for that time before.
    public mutating func heard(final words: [NarrationWord], from: Double? = nil, to: Double? = nil) {
        let sorted = words.sorted { $0.start < $1.start }
        let low = from ?? sorted.first?.start ?? 0
        let high = to ?? sorted.map(\.end).max().map { $0 + 0.0001 } ?? low
        settled.removeAll { $0.start >= low && $0.start < high }
        settled.append(contentsOf: sorted)
        settled.sort { $0.start < $1.start }
        volatile.removeAll { $0.start < high }
    }

    /// The words still changing; each call replaces the last.
    public mutating func heard(volatile words: [NarrationWord]) {
        volatile = words.sorted { $0.start < $1.start }
    }

    /// The recording stopped at `time`. What was still changing is kept as heard.
    public mutating func finish(at time: Double) {
        guard !finished else { return }
        if !volatile.isEmpty {
            settled.append(contentsOf: volatile)
            settled.sort { $0.start < $1.start }
            volatile = []
        }
        if var last = segments.last {
            last.end = max(last.start, time)
            segments[segments.count - 1] = last
        }
        finished = true
    }

    /// The words said while this segment was on show. Words before the first screen
    /// (the microphone starts a moment before the video) count as the first.
    public func words(in segment: NarrationSegment) -> [NarrationWord] {
        let isFirst = segment.id == segments.first?.id
        let isLast = segment.id == segments.last?.id
        return (settled + volatile).filter { word in
            (word.start >= segment.start || isFirst) && (word.start < (segment.end ?? .infinity) || isLast)
        }.sorted { $0.start < $1.start }
    }

    /// The segment's words as text: his edit when he made one.
    public func text(of id: Int) -> String {
        guard let segment = segments.first(where: { $0.id == id }) else { return "" }
        if let edited = segment.edited { return edited }
        return NarrationWord.join(words(in: segment))
    }

    /// He changed a segment's words on the card. Setting it back to what was heard clears the edit.
    public mutating func edit(_ id: Int, text: String) {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[index].edited = nil
        let heard = NarrationWord.join(words(in: segments[index]))
        segments[index].edited = text == heard ? nil : text
    }

    /// The last line or so being said now, for the caption strip.
    public func caption(maxCharacters: Int = 140) -> String {
        guard let current = segments.last else { return "" }
        let line = text(of: current.id)
        guard line.count > maxCharacters else { return line }
        return "…" + line.suffix(maxCharacters)
    }

    /// "Listing details · 0:12": the screen his words are going to now, and how long it has been on show.
    public func tag(now: Double) -> String {
        guard let current = segments.last else { return "" }
        return "\(current.title) · \(Self.clock(max(0, now - current.start)))"
    }

    public static func clock(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

// MARK: - Is it a different screen?

/// The decision behind "a new segment": the picture settled after changing.
/// The screen's name decides when both names are known (a scroll keeps its title);
/// without names, the top band (where a title sits) must have changed too — a list
/// scrolling under a fixed bar is not a new screen.
public enum NarrationScreenChange {
    /// The share of the picture that must be new before a name is even read.
    public static let candidateShare = 0.25

    public static func isCandidate(from anchor: ScreenSignature, to now: ScreenSignature) -> Bool {
        share(anchor, now) > candidateShare
    }

    public static func isNewScreen(from anchor: ScreenSignature, to now: ScreenSignature,
                                   anchorName: String?, nowName: String?) -> Bool {
        let a = normalized(anchorName), b = normalized(nowName)
        if let a, let b { return a != b }
        if a == nil, b != nil { return true }
        // A pushed screen, a sheet or another app changes where the title sits; a scroll does not.
        return share(anchor, now) > candidateShare && share(anchor, now, rows: topBand(anchor.rows)) > 0.15
    }

    /// The rows under the status bar where a screen's title sits (about 4%–18% down).
    static func topBand(_ rows: Int) -> Range<Int> {
        let low = max(0, Int((Double(rows) * 0.04).rounded(.up)))
        let high = max(low + 1, min(rows, Int((Double(rows) * 0.18).rounded(.up))))
        return low..<high
    }

    /// The share of samples (optionally in some rows only) that moved by more than `step`.
    public static func share(_ a: ScreenSignature, _ b: ScreenSignature, rows: Range<Int>? = nil, step: Int = 24) -> Double {
        guard a.columns == b.columns, a.rows == b.rows, a.samples.count == b.samples.count, a.columns > 0 else { return 1 }
        let band = rows ?? 0..<a.rows
        var moved = 0, total = 0
        for row in band where row < a.rows {
            for column in 0..<a.columns {
                let index = row * a.columns + column
                total += 1
                if abs(Int(a.samples[index]) - Int(b.samples[index])) > step { moved += 1 }
            }
        }
        return total == 0 ? 0 : Double(moved) / Double(total)
    }

    static func normalized(_ name: String?) -> String? {
        let flat = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return flat.isEmpty ? nil : flat
    }
}

// MARK: - The screen's name

/// The name a person would give the screen on show, from its accessibility outline:
/// the navigation bar's title, else a heading near the top, else the topmost text
/// under the status bar. Nil when nothing fits.
public enum NarrationScreenName {
    public static func name(root: DeviceNode?, reported: String? = nil) -> String? {
        if let reported = clean(reported) { return reported }
        guard let root else { return nil }
        let nodes = DeviceTreeQuery.flatten(root).filter { $0.hidden != true }

        // 1. A navigation bar / toolbar: its own name, else the text inside it.
        for bar in nodes where isBar(bar.role) {
            if let own = clean(bar.title) ?? clean(bar.label), !isNoise(own) { return own }
            let inside = DeviceTreeQuery.flatten(bar).dropFirst().compactMap { node -> (Double, String)? in
                guard isText(node.role) || isHeading(node.role) else { return nil }
                guard let words = clean(node.text) ?? clean(node.label) ?? clean(node.value), !isNoise(words) else { return nil }
                return (node.frame.map { abs(($0.x + $0.width / 2) - 0.5) } ?? 1, words)
            }
            if let centred = inside.min(by: { $0.0 < $1.0 }) { return centred.1 }
        }
        // 2. A heading in the top third.
        let headings = nodes.compactMap { node -> (Double, String)? in
            guard isHeading(node.role), let frame = node.frame, frame.y < 0.33,
                  let words = clean(node.label) ?? clean(node.text) ?? clean(node.value), !isNoise(words) else { return nil }
            return (frame.y, words)
        }
        if let top = headings.min(by: { $0.0 < $1.0 }) { return top.1 }
        // 3. The topmost text under the status bar, in the top fifth.
        let texts = nodes.compactMap { node -> (Double, String)? in
            guard isText(node.role), let frame = node.frame, frame.y >= 0.05, frame.y < 0.2,
                  let words = clean(node.text) ?? clean(node.label) ?? clean(node.value), !isNoise(words) else { return nil }
            return (frame.y, words)
        }
        return texts.min(by: { $0.0 < $1.0 })?.1
    }

    static func clean(_ text: String?) -> String? {
        let flat = (text ?? "").split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !flat.isEmpty else { return nil }
        return flat.count > 60 ? String(flat.prefix(60)) + "…" : flat
    }

    /// The clock, the battery, a lone symbol: never a screen's name.
    static func isNoise(_ text: String) -> Bool {
        if text.count < 2 { return true }
        if text.range(of: #"^\d{1,2}:\d{2}( ?[AP]M)?$"#, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        if text.range(of: #"^\d{1,3} ?%$"#, options: .regularExpression) != nil { return true }
        let lower = text.lowercased()
        return ["back", "close", "cancel", "done", "more", "menu", "navigate up"].contains(lower)
    }

    static func role(_ role: String?) -> String { (role ?? "").lowercased() }
    static func isBar(_ value: String?) -> Bool {
        let r = role(value)
        return r.contains("navigationbar") || r.contains("navigation bar") || r.hasSuffix("toolbar") || r.contains("actionbar")
    }
    static func isHeading(_ value: String?) -> Bool {
        let r = role(value)
        return r.contains("heading") || r.contains("header")
    }
    static func isText(_ value: String?) -> Bool {
        let r = role(value)
        return r.contains("statictext") || r.contains("static text") || r.contains("textview") || r == "text" || r.hasSuffix(".text")
    }
}

// MARK: - What Send says

/// The two ways a recording is made, and the message each sends to the session.
public enum NarrationPayload {
    /// One screen's block, as sent.
    public struct Screen: Equatable, Sendable {
        public var number: Int
        public var title: String
        public var start: Double
        public var end: Double
        public var picture: String?
        public var words: String
        public init(number: Int, title: String, start: Double, end: Double, picture: String?, words: String) {
            self.number = number
            self.title = title
            self.start = start
            self.end = end
            self.picture = picture
            self.words = words
        }
    }

    /// The timeline's segments as the blocks Send writes, with his edits.
    public static func screens(_ timeline: NarrationTimeline) -> [Screen] {
        timeline.segments.map { segment in
            Screen(number: segment.id, title: segment.title, start: segment.start, end: segment.end ?? segment.start,
                   picture: segment.keyframe, words: timeline.text(of: segment.id))
        }
    }

    /// "3 screens with your words" / "Video, 0:42": what the card says will be sent.
    public static func summary(narrated: Bool, screens: Int, seconds: Double) -> String {
        narrated ? "\(screens) screen\(screens == 1 ? "" : "s") with your words" : "Video, \(NarrationTimeline.clock(seconds))"
    }

    /// Talk while recording: the pictures (one per screen) and his words per screen.
    /// The video stays on the Mac and is only named, as a reference.
    public static func narrated(screens: [Screen], videoPath: String, seconds: Double, kind: String,
                                deviceName: String, note: String) -> String {
        let device = deviceName.isEmpty ? "" : " of \"\(Handoff.flat(deviceName))\""
        let count = "\(screens.count) screen\(screens.count == 1 ? "" : "s")"
        var lines: [String] = []
        let lead = Handoff.flat(note)
        if !lead.isEmpty { lines.append(lead) }
        lines.append("[\(Handoff.flat(kind)) walkthrough\(device): \(count) over \(NarrationTimeline.clock(seconds)), "
                     + "a picture of each screen with what I said on it. The video is kept at \(videoPath)]")
        for screen in screens {
            let span = "\(NarrationTimeline.clock(screen.start))–\(NarrationTimeline.clock(screen.end))"
            let picture = screen.picture.map { "picture: \($0)" } ?? "no picture"
            let words = Handoff.flat(screen.words)
            lines.append("Screen \(screen.number) \"\(Handoff.flat(screen.title))\" (\(span), \(picture)): "
                         + (words.isEmpty ? "(nothing said)" : words))
        }
        return lines.joined(separator: "\n")
    }

    /// Plain recording: the video as it is, with his typed note.
    public static func plain(videoPath: String, width: Int, height: Int, seconds: Double, kind: String,
                             deviceName: String, note: String) -> String {
        let device = deviceName.isEmpty ? "" : " of \"\(Handoff.flat(deviceName))\""
        let context = "[\(Handoff.flat(kind)) screen recording\(device): \(videoPath) (\(width) x \(height), \(String(format: "%.1f s", seconds)))]"
        let lead = Handoff.flat(note)
        return lead.isEmpty ? context : "\(lead) \(context)"
    }
}

// MARK: - Phrases for a provider that answers a phrase at a time

/// Cuts the microphone into phrases at his pauses, from loudness alone: a phrase ends
/// after `pause` seconds of quiet once he has spoken, or at `longest` seconds.
public struct NarrationPhraseCutter: Equatable, Sendable {
    public var threshold: Float
    public var pause: Double
    public var longest: Double
    public private(set) var phraseStart: Double?
    private var spoke = false
    private var quietSince: Double?

    public init(threshold: Float = 0.015, pause: Double = 0.7, longest: Double = 12) {
        self.threshold = threshold
        self.pause = pause
        self.longest = longest
    }

    /// One slice of audio, `from..<to` seconds, at loudness `level` (root mean square).
    /// Returns the phrase that just ended, when one did.
    public mutating func feed(level: Float, from: Double, to: Double) -> ClosedRange<Double>? {
        if phraseStart == nil { phraseStart = from }
        let loud = level >= threshold
        if loud { spoke = true; quietSince = nil } else if quietSince == nil { quietSince = from }
        guard let start = phraseStart else { return nil }
        let pausedLongEnough = spoke && (quietSince.map { to - $0 >= pause } ?? false)
        if pausedLongEnough || to - start >= longest {
            let hadSpeech = spoke
            phraseStart = nil; spoke = false; quietSince = nil
            return hadSpeech ? start...to : nil
        }
        return nil
    }

    /// The end of the recording: what is left, when he said something in it.
    public mutating func flush(at time: Double) -> ClosedRange<Double>? {
        defer { phraseStart = nil; spoke = false; quietSince = nil }
        guard let start = phraseStart, spoke, time > start else { return nil }
        return start...time
    }
}
