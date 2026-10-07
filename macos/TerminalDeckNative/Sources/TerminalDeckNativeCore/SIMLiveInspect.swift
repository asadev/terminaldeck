import CoreGraphics
import Foundation

/// Inspect on the LIVE screen — the pure half (lane SIM, 7 Oct 2026).
///
/// Asad: inspecting a simulator or phone must never freeze it. The video keeps
/// playing; the element tree is read in the background whenever the picture
/// settles after a change (or right after input is sent), a read that started
/// before a newer change is let go, and every marker keeps the frame the person
/// saw when they clicked, so it survives the screen moving on.

// MARK: - When to read the tree again

/// The debounce and stale-drop for background tree reads. Times are seconds on
/// any steady clock. One read at a time; a change while one is on its way
/// schedules the next.
public struct LiveTreeSchedule: Equatable, Sendable {
    /// One read: the screen generation it started on and when.
    public struct Token: Equatable, Sendable {
        public let generation: Int
        public let startedAt: Double
        public init(generation: Int, startedAt: Double) {
            self.generation = generation
            self.startedAt = startedAt
        }
    }

    /// Quiet this long after the last change means the screen has settled.
    public static let settle = 0.4
    /// A screen that never stops moving is still read this often.
    public static let maxWait = 2.0
    /// A reading this old is replaced even by one the screen moved on from — better than none.
    public static let maxStale = 2.5

    /// Bumped on every change: the picture moved, or input went to the device.
    public private(set) var generation = 0
    public private(set) var reading: Token?
    /// The reading on show.
    public private(set) var shown: Token?
    private var due: Double?
    private var firstUnread: Double?

    public init() {}

    public var isReading: Bool { reading != nil }
    /// When the next read should start; nil while one is on its way or nothing is new.
    public var dueAt: Double? { reading == nil ? due : nil }
    /// The reading on show is of the screen as it is now.
    public var isFresh: Bool { shown != nil && shown?.generation == generation }

    /// The picture changed, or a touch, swipe, key or button went to the device.
    public mutating func change(at now: Double) {
        generation += 1
        let first = firstUnread ?? now
        firstUnread = first
        due = min(now + Self.settle, first + Self.maxWait)
    }

    /// Read as soon as possible — Inspect just turned on, or Read again.
    public mutating func request(at now: Double) {
        if firstUnread == nil { firstUnread = now }
        due = now
    }

    /// Start the read that is due. Nil when none is due yet or one is on its way.
    public mutating func begin(at now: Double) -> Token? {
        guard reading == nil, let due, due <= now + 0.001 else { return nil }
        let token = Token(generation: generation, startedAt: now)
        reading = token
        self.due = nil
        firstUnread = nil
        return token
    }

    /// The read came back. True when its answer should be shown: the screen has
    /// not changed since it started, or nothing (recent) is on show.
    public mutating func finish(_ token: Token, at now: Double) -> Bool {
        guard reading == token else { return false }
        reading = nil
        let fresh = token.generation == generation
        let overdue = shown.map { now - $0.startedAt >= Self.maxStale } ?? true
        guard fresh || overdue else { return false }
        shown = token
        return true
    }

    /// The read failed; the next change or a Read again tries again.
    public mutating func fail(_ token: Token) {
        guard reading == token else { return }
        reading = nil
    }

    /// Inspect turned off. The generation keeps counting, so nothing from before is taken for now.
    public mutating func reset() {
        due = nil
        reading = nil
        shown = nil
        firstUnread = nil
    }
}

// MARK: - Did the picture change?

/// A cheap fingerprint of one video frame: one brightness sample per grid cell.
public struct ScreenSignature: Equatable, Sendable {
    public static let columns = 24
    public static let rows = 48

    public var columns: Int
    public var rows: Int
    public var samples: [UInt8]

    public init(columns: Int, rows: Int, samples: [UInt8]) {
        self.columns = columns
        self.rows = rows
        self.samples = samples
    }

    /// The sample at the centre of every cell of a grid laid over a `width` × `height` picture.
    public static func sample(width: Int, height: Int, columns: Int = ScreenSignature.columns,
                              rows: Int = ScreenSignature.rows,
                              read: (_ x: Int, _ y: Int) -> UInt8) -> ScreenSignature? {
        guard width > 0, height > 0, columns > 0, rows > 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(columns * rows)
        for row in 0..<rows {
            let y = min(height - 1, (row * 2 + 1) * height / (rows * 2))
            for column in 0..<columns {
                out.append(read(min(width - 1, (column * 2 + 1) * width / (columns * 2)), y))
            }
        }
        return ScreenSignature(columns: columns, rows: rows, samples: out)
    }

    /// More than `share` of the samples moved by more than `step`. A blinking caret
    /// touches a sample or two; a scroll, a new screen or a sheet touches many.
    public func differs(from other: ScreenSignature, step: Int = 24, share: Double = 0.01) -> Bool {
        guard columns == other.columns, rows == other.rows, samples.count == other.samples.count else { return true }
        var moved = 0
        for index in samples.indices where abs(Int(samples[index]) - Int(other.samples[index])) > step { moved += 1 }
        return Double(moved) > share * Double(samples.count)
    }
}

/// Compares each frame with the last one that counted as a change, so a slow
/// fade adds up instead of slipping under the threshold frame by frame.
public struct ScreenChangeDetector: Sendable {
    public private(set) var reference: ScreenSignature?

    public init() {}

    /// True when this frame differs enough from the last change (the first frame only sets the reference).
    public mutating func observe(_ signature: ScreenSignature) -> Bool {
        guard let reference else {
            self.reference = signature
            return false
        }
        guard signature.differs(from: reference) else { return false }
        self.reference = signature
        return true
    }

    public mutating func reset() { reference = nil }
}

// MARK: - The element under the pointer, on the live picture

public enum LiveInspect {
    /// Two pictures show the screen the same way up and the same shape (within `tolerance`).
    public static func sameShape(_ a: CGSize, _ b: CGSize, tolerance: Double = 0.02) -> Bool {
        guard a.width > 0, a.height > 0, b.width > 0, b.height > 0 else { return false }
        let ra = Double(a.width / a.height), rb = Double(b.width / b.height)
        return abs(ra - rb) <= tolerance * max(ra, rb)
    }

    /// The element under a normalised point of the live picture. The tree's frames are
    /// fractions of the picture it was read against; they hold for the video only while
    /// both have the same shape (a turned device has not been read again yet: nothing).
    public static func elementAt(_ point: CGPoint, in nodes: [DeviceNode], treePicture: CGSize,
                                 video: CGSize?) -> DeviceNode? {
        if let video, !sameShape(treePicture, video) { return nil }
        return DeviceTreeQuery.elementAt(in: nodes, x: Double(point.x), y: Double(point.y))
    }
}

// MARK: - Markers that outlive the screen they were made on

/// One numbered marker, with the screen its picture was captured on and the
/// element as it was — what finds it again on a later tree.
public struct LiveMarker: Equatable, Sendable, Identifiable {
    public var annotation: Annotation
    /// The screen generation its picture was captured on; markers on one generation share one picture.
    public var picture: Int
    /// The element when it was marked, children dropped. Nil for a mark by position.
    public var node: DeviceNode?
    /// Marked by position while the elements were still being read: becomes the
    /// element under it when the reading of that same screen arrives.
    public var awaitingElement: Bool

    public var id: String { annotation.id }
    public var n: Int { annotation.n }

    public init(annotation: Annotation, picture: Int, node: DeviceNode?, awaitingElement: Bool = false) {
        self.annotation = annotation
        self.picture = picture
        self.node = node.map(LiveMarkers.bare)
        self.awaitingElement = awaitingElement
    }
}

/// Where a marker is drawn on the screen now.
public struct LivePlacement: Equatable, Sendable {
    public var marker: LiveMarker
    public var rect: NormRect
    /// The element it sits on in the current tree.
    public var ref: String?
}

public enum LiveMarkers {
    static func bare(_ node: DeviceNode) -> DeviceNode {
        var copy = node
        copy.children = []
        return copy
    }

    /// Add one, numbered after the last: on an element (its frame), or by position.
    public static func adding(_ list: [LiveMarker], id: String, node: DeviceNode?, rect: NormRect,
                              picture: Int, awaitingElement: Bool = false) -> [LiveMarker] {
        let annotation = Annotation(id: id, n: list.count + 1, rect: node?.usableFrame ?? rect,
                                    element: node.map(AnnotatedElement.init(node:)), nodeRef: node?.ref)
        return list + [LiveMarker(annotation: annotation, picture: picture, node: node,
                                  awaitingElement: node == nil && awaitingElement)]
    }

    /// Remove one and close the gap, so the numbers match the markers drawn.
    public static func removing(_ list: [LiveMarker], id: String) -> [LiveMarker] {
        list.filter { $0.id != id }.enumerated().map { index, entry in
            var copy = entry
            copy.annotation.n = index + 1
            return copy
        }
    }

    static func identity(_ node: DeviceNode) -> String? {
        [node.identifier, node.testID].compactMap { $0 }.first { !$0.isEmpty }
    }

    static func close(_ a: NormRect?, _ b: NormRect?, tolerance: Double = 0.02) -> Bool {
        guard let a, let b else { return false }
        return abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    static func distance(_ a: NormRect?, _ b: NormRect?) -> Double {
        guard let a, let b else { return .infinity }
        return abs(a.x - b.x) + abs(a.y - b.y) + abs(a.width - b.width) + abs(a.height - b.height)
    }

    /// The marked element on a tree: by its identifier (the nearest when several share
    /// it), else by its ref with the same role and the same name or place, else by the
    /// same role and name at the same place. Nil when it is not on that tree.
    public static func match(_ marker: LiveMarker, in nodes: [DeviceNode]) -> DeviceNode? {
        guard let was = marker.node else { return nil }
        let live = nodes.filter { $0.hidden != true && $0.usableFrame != nil }
        if let wanted = identity(was) {
            return live.filter { identity($0) == wanted }.min { distance($0.frame, was.frame) < distance($1.frame, was.frame) }
        }
        let name = DeviceTreeQuery.nodeName(was)
        if let same = live.first(where: { $0.ref == was.ref }), same.role == was.role,
           DeviceTreeQuery.nodeName(same) == name || close(same.frame, was.frame) {
            return same
        }
        return live.filter { $0.role == was.role && DeviceTreeQuery.nodeName($0) == name && close($0.frame, was.frame) }
            .min { distance($0.frame, was.frame) < distance($1.frame, was.frame) }
    }

    /// What the overlay draws now. Element markers: only on a fresh tree that still
    /// holds their element, where it is now. Marks by position: only while the screen
    /// is the one they were made on. Everything else stays in the side list.
    public static func placements(_ markers: [LiveMarker], nodes: [DeviceNode]?, fresh: Bool,
                                  generation: Int) -> [LivePlacement] {
        markers.compactMap { marker in
            if marker.node == nil {
                return marker.picture == generation ? LivePlacement(marker: marker, rect: marker.annotation.rect, ref: nil) : nil
            }
            guard fresh, let nodes, let hit = match(marker, in: nodes) else { return nil }
            return LivePlacement(marker: marker, rect: hit.usableFrame ?? marker.annotation.rect, ref: hit.ref)
        }
    }

    /// A reading arrived that started on screen `generation`: marks by position made on
    /// that screen while it was being read become the element under them; ones made on
    /// an earlier screen stop waiting and stay marks by position.
    public static func upgrading(_ markers: [LiveMarker], nodes: [DeviceNode], generation: Int,
                                 treePicture: CGSize, video: CGSize?) -> [LiveMarker] {
        markers.map { marker in
            guard marker.awaitingElement else { return marker }
            var copy = marker
            if marker.picture < generation {
                copy.awaitingElement = false
            } else if marker.picture == generation {
                copy.awaitingElement = false
                let r = marker.annotation.rect
                let centre = CGPoint(x: r.x + r.width / 2, y: r.y + r.height / 2)
                if let node = LiveInspect.elementAt(centre, in: nodes, treePicture: treePicture, video: video) {
                    copy.node = bare(node)
                    copy.annotation.element = AnnotatedElement(node: node)
                    copy.annotation.nodeRef = node.ref
                    copy.annotation.rect = node.usableFrame ?? r
                }
            }
            return copy
        }
    }

    /// The distinct captured pictures, in the order of their first marker, each with its markers.
    public static func pictureGroups(_ markers: [LiveMarker]) -> [(picture: Int, markers: [Annotation])] {
        var order: [Int] = []
        var groups: [Int: [Annotation]] = [:]
        for marker in markers.sorted(by: { $0.n < $1.n }) {
            if groups[marker.picture] == nil { order.append(marker.picture) }
            groups[marker.picture, default: []].append(marker.annotation)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }
}

// MARK: - One round, several pictures

/// One saved picture of a round and the marker numbers drawn on it.
public struct RoundPicture: Equatable, Sendable {
    public var path: String
    public var width: Int
    public var height: Int
    public var markers: [Int]
    /// The app's screen it showed, when the device said.
    public var screen: String?

    public init(path: String, width: Int, height: Int, markers: [Int], screen: String? = nil) {
        self.path = path
        self.width = width
        self.height = height
        self.markers = markers
        self.screen = screen
    }

    /// No `path` while it is the round's own `picture`, which `annotate:save` is saving with it.
    public var json: [String: Any] {
        var out: [String: Any] = ["width": width, "height": height, "markers": markers]
        if !path.isEmpty { out["path"] = path }
        if let screen { out["screen"] = screen }
        return out
    }
}

extension AnnotationRound {
    /// The round as `annotate:save` reads it, plus `pictures` when its markers came from
    /// more than one screen. Additive: a reader that knows only `picture`/`frame` reads
    /// the round as before (annotate:save's sanitiser keeps its own keys and drops this one).
    public func json(pictures: [RoundPicture]) -> [String: Any] {
        var out = json
        if pictures.count > 1 { out["pictures"] = pictures.map(\.json) }
        return out
    }
}

extension Handoff {
    /// The round's one message. With one picture it is `composeRound(_:picturePath:)`
    /// word for word; with several, the head lists each picture and the numbers on it.
    public static func composeRound(_ round: AnnotationRound, pictures: [RoundPicture]) -> String {
        guard pictures.count > 1 else { return composeRound(round, picturePath: pictures.first?.path ?? "") }
        let count = "\(round.annotations.count) marked element\(round.annotations.count == 1 ? "" : "s")"
        let list = pictures.map { picture -> String in
            let numbers = picture.markers.map { "#\($0)" }.joined(separator: ", ")
            let screen = picture.screen.flatMap { $0.isEmpty || $0 == round.where_.screen ? nil : ", screen \(clip($0, 120))" } ?? ""
            return "\(picture.path) (\(picture.width) x \(picture.height)) showing \(numbers)\(screen)"
        }.joined(separator: "; ")
        let head = "[Annotate: \(count) on \(describeWhere(round.where_)); \(pictures.count) pictures with the numbered markers: \(list)]"
        let marked = round.annotations.map(describeMarker).joined(separator: "; ")
        let note = flat(round.note)
        return [head, marked.isEmpty ? "" : "\(marked).", note.isEmpty ? "" : "What should change: \(note)"]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
