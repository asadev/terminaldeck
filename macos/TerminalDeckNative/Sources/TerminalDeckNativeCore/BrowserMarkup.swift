import CoreGraphics
import Foundation

// Draw and Annotate — the geometry and words, ported from the web browser
// (`renderer/browser/marks.ts`, `renderer/annotate/marked-picture.ts`,
// `shared/annotate.ts`) so a picture marked here reads the same to an agent.
// Every point is a fraction of the picture (0…1), so marks survive any size.

public struct BrowserPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// One thing drawn on a screenshot.
public struct BrowserMark: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        /// Freehand — circle the thing.
        case free
        /// A rectangle round a region.
        case rect
        /// Point at one thing.
        case arrow
        /// A few words placed on the picture.
        case text
    }

    public var kind: Kind
    public var points: [BrowserPoint]
    public var text: String

    public init(kind: Kind, points: [BrowserPoint], text: String = "") {
        self.kind = kind
        self.points = points
        self.text = text
    }
}

public enum BrowserMarks {
    static let sampleStep = 0.0015
    static let minDrag = 0.004
    static let headSpread = 0.42

    public static func onFrame(_ point: BrowserPoint) -> BrowserPoint {
        BrowserPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
    }

    public static func begin(_ kind: BrowserMark.Kind, at point: BrowserPoint, text: String = "") -> BrowserMark {
        let start = onFrame(point)
        return BrowserMark(kind: kind, points: kind == .text ? [start] : [start, start], text: text)
    }

    public static func extend(_ mark: BrowserMark, to point: BrowserPoint) -> BrowserMark {
        let next = onFrame(point)
        switch mark.kind {
        case .text: return mark
        case .free:
            guard let last = mark.points.last, distance(last, next) >= sampleStep else { return mark }
            return BrowserMark(kind: .free, points: mark.points + [next])
        default:
            return BrowserMark(kind: mark.kind, points: [mark.points[0], next])
        }
    }

    /// Long enough to keep — a click is not a mark.
    public static func isDrawn(_ mark: BrowserMark) -> Bool {
        switch mark.kind {
        case .text:
            return !mark.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .free:
            var travelled = 0.0
            for i in mark.points.indices.dropFirst() { travelled += distance(mark.points[i - 1], mark.points[i]) }
            return travelled >= minDrag
        default:
            guard let first = mark.points.first, let last = mark.points.last else { return false }
            return distance(first, last) >= minDrag
        }
    }

    public static func strokeWidth(_ frameWidth: Double) -> Double { max(2, (frameWidth / 500).rounded()) }

    /// The text's size on a picture this wide.
    public static func textSize(_ frameWidth: Double) -> Double { max(14, (frameWidth / 55).rounded()) }

    public static func arrowHead(from: BrowserPoint, to: BrowserPoint, frameWidth: Double) -> (BrowserPoint, BrowserPoint) {
        let shaft = hypot(to.x - from.x, to.y - from.y)
        let angle = atan2(to.y - from.y, to.x - from.x)
        let length = min(shaft * 0.32, frameWidth * 0.035)
        return (BrowserPoint(x: to.x - length * cos(angle - headSpread), y: to.y - length * sin(angle - headSpread)),
                BrowserPoint(x: to.x - length * cos(angle + headSpread), y: to.y - length * sin(angle + headSpread)))
    }

    /// The lines to stroke for a mark on a picture `width` × `height` (pixels).
    public static func paths(_ mark: BrowserMark, width: Double, height: Double) -> [[BrowserPoint]] {
        let at = { (p: BrowserPoint) in BrowserPoint(x: p.x * width, y: p.y * height) }
        guard let firstRaw = mark.points.first, let lastRaw = mark.points.last else { return [] }
        let first = at(firstRaw), last = at(lastRaw)
        switch mark.kind {
        case .text: return []
        case .free: return [mark.points.map(at)]
        case .rect:
            return [[first, BrowserPoint(x: last.x, y: first.y), last, BrowserPoint(x: first.x, y: last.y), first]]
        case .arrow:
            let (left, right) = arrowHead(from: first, to: last, frameWidth: width)
            return [[first, last], [left, last, right]]
        }
    }

    static func distance(_ a: BrowserPoint, _ b: BrowserPoint) -> Double { hypot(b.x - a.x, b.y - a.y) }
}

// MARK: - Annotate

/// What a marker points at, as the page described it.
public struct BrowserAnnotatedElement: Equatable, Sendable {
    public var role = ""
    public var name = ""
    public var identifier = ""
    public var selector = ""

    public init(role: String = "", name: String = "", identifier: String = "", selector: String = "") {
        self.role = role
        self.name = name
        self.identifier = identifier
        self.selector = selector
    }

    /// From the page's pick (`{tag, label, id, selector}`).
    public static func read(_ raw: Any?) -> BrowserAnnotatedElement? {
        guard let fields = raw as? [String: Any] else { return nil }
        let tag = (fields["tag"] as? String) ?? ""
        let element = BrowserAnnotatedElement(role: tag.isEmpty ? "" : "<\(tag)>",
                                              name: (fields["label"] as? String) ?? "",
                                              identifier: (fields["id"] as? String) ?? "",
                                              selector: (fields["selector"] as? String) ?? "")
        return element == BrowserAnnotatedElement() ? nil : element
    }

    var json: [String: Any] {
        var out: [String: Any] = [:]
        if !role.isEmpty { out["role"] = role }
        if !name.isEmpty { out["name"] = name }
        if !identifier.isEmpty { out["identifier"] = identifier }
        if !selector.isEmpty { out["selector"] = selector }
        return out
    }
}

public struct BrowserAnnotation: Equatable, Sendable, Identifiable {
    public let id: String
    public var n: Int
    /// Fractions of the picture.
    public var rect: CGRect
    public var element: BrowserAnnotatedElement?

    public init(id: String = UUID().uuidString, n: Int = 0, rect: CGRect, element: BrowserAnnotatedElement?) {
        self.id = id
        self.n = n
        self.rect = rect
        self.element = element
    }
}

public enum BrowserAnnotate {
    public static func add(_ list: [BrowserAnnotation], _ entry: BrowserAnnotation) -> [BrowserAnnotation] {
        var next = entry
        next.n = list.count + 1
        return list + [next]
    }

    /// Remove one; the rest are numbered again from 1, so the picture and the words agree.
    public static func remove(_ list: [BrowserAnnotation], id: String) -> [BrowserAnnotation] {
        list.filter { $0.id != id }.enumerated().map { index, entry in
            var copy = entry
            copy.n = index + 1
            return copy
        }
    }

    /// A small box round a click on blank space.
    public static func boxAround(x: Double, y: Double) -> CGRect {
        let size = 0.04
        return CGRect(x: min(max(x - size / 2, 0), 1 - size), y: min(max(y - size / 2, 0), 1 - size), width: size, height: size)
    }

    /// A CSS rect in a viewport this size, as fractions, clamped to the picture.
    public static func normalise(_ box: CGRect, viewport: CGSize) -> CGRect? {
        guard viewport.width > 0, viewport.height > 0, box.width > 0 || box.height > 0 else { return nil }
        let x = min(max(box.minX / viewport.width, 0), 1)
        let y = min(max(box.minY / viewport.height, 0), 1)
        return CGRect(x: x, y: y,
                      width: min(max(box.width / viewport.width, 0), 1 - x),
                      height: min(max(box.height / viewport.height, 0), 1 - y))
    }

    static func clip(_ value: String, _ max: Int = 120) -> String {
        let one = BrowserText.oneLine(value)
        return one.count > max ? String(one.prefix(max - 1)) + "…" : one
    }

    public static func describe(_ element: BrowserAnnotatedElement?) -> String {
        guard let element else { return "blank space" }
        let head = [element.role.isEmpty ? "" : clip(element.role, 40), element.name.isEmpty ? "" : "\"\(clip(element.name))\""]
            .filter { !$0.isEmpty }.joined(separator: " ")
        var handles: [String] = []
        if !element.identifier.isEmpty { handles.append("id \(clip(element.identifier))") }
        if !element.selector.isEmpty { handles.append("selector \(clip(element.selector, 200))") }
        let named = head.isEmpty ? "element" : head
        return handles.isEmpty ? named : "\(named) (\(handles.joined(separator: ", ")))"
    }

    public static func describeWhere(url: String, title: String) -> String {
        var parts = [url.isEmpty ? "a browser page" : "the page \(clip(url, 300))"]
        if !title.isEmpty { parts.append("titled \"\(clip(title))\"") }
        return parts.joined(separator: " ")
    }

    static func percent(_ value: Double) -> String { "\(Int((min(max(value, 0), 1) * 100).rounded()))%" }

    public static func describeMarker(_ entry: BrowserAnnotation) -> String {
        let r = entry.rect
        return "#\(entry.n) \(describe(entry.element)) at \(percent(r.minX)) across, \(percent(r.minY)) down, \(percent(r.width)) x \(percent(r.height))"
    }

    /// The one line a session receives (`composeHandoff`).
    public static func compose(_ list: [BrowserAnnotation], url: String, title: String, note: String,
                               picturePath: String, width: Int, height: Int) -> String {
        let count = "\(list.count) marked element\(list.count == 1 ? "" : "s")"
        let picture = picturePath.isEmpty ? "the picture could not be saved"
            : "picture with the numbered markers: \(picturePath) (\(width) x \(height))"
        let head = "[Annotate: \(count) on \(describeWhere(url: url, title: title)); \(picture)]"
        let marked = list.map(describeMarker).joined(separator: "; ")
        let what = BrowserText.oneLine(note)
        return [head, marked.isEmpty ? "" : "\(marked).", what.isEmpty ? "" : "What should change: \(what)"]
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The round as the engine's `annotate:save` reads it (`devices/round.ts`), so
    /// agents find it with `devices.annotations` like every other round.
    public static func round(id: String, createdAt: Double, list: [BrowserAnnotation], url: String, title: String,
                             note: String, width: Int, height: Int) -> [String: Any] {
        var whereValue: [String: Any] = ["kind": "browser", "place": "browser page", "name": title]
        if !url.isEmpty { whereValue["url"] = url }
        return [
            "id": id,
            "createdAt": createdAt,
            "where": whereValue,
            "frame": ["width": width, "height": height],
            "note": note,
            "annotations": list.map { entry -> [String: Any] in
                [
                    "id": entry.id,
                    "n": entry.n,
                    "rect": ["x": Double(entry.rect.minX), "y": Double(entry.rect.minY),
                             "width": Double(entry.rect.width), "height": Double(entry.rect.height)],
                    "element": entry.element.map { $0.json as Any } ?? NSNull(),
                ]
            },
        ]
    }

    /// Where a marker's box and numbered badge go on a picture this size (pixels).
    public static func markerGeometry(_ rect: CGRect, width: Double, height: Double) -> (box: CGRect, badge: CGPoint, radius: Double, stroke: Double) {
        let short = max(1, min(width, height))
        let stroke = max(2, (short / 220).rounded())
        let r = max(9, (short / 34).rounded())
        let box = CGRect(x: rect.minX * width, y: rect.minY * height,
                         width: max(rect.width * width, 1), height: max(rect.height * height, 1))
        let cx = min(max(box.minX, r + stroke), width - r - stroke)
        let cy = min(max(box.minY, r + stroke), height - r - stroke)
        return (box, CGPoint(x: cx, y: cy), r, stroke)
    }
}
