import Foundation

// The Overview grid: src/renderer/dashboard/layout.ts one for one (12 columns,
// widget specs, add / remove / move / resize / parse / serialise), plus the part
// gridstack did for the page — float:false packing and pushing widgets out of a
// dragged one's way — so the native grid settles exactly where the page's would.

public enum WidgetType: String, Equatable, Sendable, CaseIterable, Codable {
    case sessions, cost, git, readiness, github
}

public struct WidgetSpec: Equatable, Sendable {
    public let type: WidgetType
    public let w: Int, h: Int
    public let minW: Int, minH: Int
    public let allowMultiple: Bool
}

public struct DashboardWidget: Equatable, Sendable, Identifiable {
    public var id: String
    public var type: WidgetType
    public var x: Int, y: Int, w: Int, h: Int
    public init(id: String, type: WidgetType, x: Int, y: Int, w: Int, h: Int) {
        self.id = id; self.type = type; self.x = x; self.y = y; self.w = w; self.h = h
    }
}

public struct DashboardLayout: Equatable, Sendable {
    public var version: Int
    public var projectPath: String
    public var columns: Int
    public var widgets: [DashboardWidget]
}

public struct WidgetPlacement: Equatable, Sendable {
    public var id: String
    public var x: Int?, y: Int?, w: Int?, h: Int?
    public init(id: String, x: Int? = nil, y: Int? = nil, w: Int? = nil, h: Int? = nil) {
        self.id = id; self.x = x; self.y = y; self.w = w; self.h = h
    }
}

public enum DashboardRules {
    public static let version = 1
    public static let columns = 12
    static let maxColumns = 48
    public static let maxWidgetRows = 64
    public static let maxRow = 1024
    public static let maxWidgets = 200
    static let scanBudget = 20_000
    /// Grid geometry the page draws with (gridstack's cellHeight and margin).
    public static let cellHeight = 56.0
    public static let gridMargin = 8.0
    public static let saveDelay: Duration = .milliseconds(500)

    public static let specs: [WidgetType: WidgetSpec] = [
        .sessions: WidgetSpec(type: .sessions, w: 6, h: 6, minW: 3, minH: 3, allowMultiple: false),
        .cost: WidgetSpec(type: .cost, w: 6, h: 6, minW: 3, minH: 3, allowMultiple: false),
        .git: WidgetSpec(type: .git, w: 6, h: 6, minW: 3, minH: 3, allowMultiple: false),
        .readiness: WidgetSpec(type: .readiness, w: 8, h: 7, minW: 4, minH: 4, allowMultiple: false),
        .github: WidgetSpec(type: .github, w: 6, h: 6, minW: 3, minH: 3, allowMultiple: true),
    ]

    public static let retired: [WidgetType] = [.sessions]

    // MARK: Widget definitions (widgets.tsx WIDGET_DEFINITIONS)

    public static func title(_ type: WidgetType) -> String {
        switch type {
        case .sessions: return "Sessions"
        case .cost: return "Usage"
        case .git: return "Git"
        case .readiness: return "AI Readiness"
        case .github: return "GitHub"
        }
    }

    public static func description(_ type: WidgetType) -> String {
        switch type {
        case .sessions: return "Agent sessions running in this project, and what each one is doing."
        case .cost: return "Tokens, cache hit rate and context-window pressure, read from your agents’ own session records."
        case .git: return "Branch, ahead/behind, and every file the working tree has touched."
        case .readiness: return "Whether this project gives an agent what it needs: docs, tests, lint, clean tree."
        case .github: return "Open pull requests and issues for the repo, via the local gh CLI."
        }
    }

    /// The picker's list: every type that is not retired, in order.
    public static func pickable() -> [WidgetType] { WidgetType.allCases.filter { !retired.contains($0) } }

    /// `features.widgetOn(type)`: the feature that owns a widget, read from the
    /// page's own `features.v2` record (usage → cost, github, readiness). A widget
    /// no feature owns is always on; a feature defaults to on.
    public static func widgetOn(_ type: WidgetType, features: [String: String]) -> Bool {
        let owner: String?
        switch type {
        case .cost: owner = "usage"
        case .github: owner = "github"
        case .readiness: owner = "readiness"
        case .sessions, .git: owner = nil
        }
        guard let owner else { return true }
        return (features[owner] ?? "on") == "on"
    }

    /// The `features.v2` text as stored by the page.
    public static func featureState(_ json: String?) -> [String: String] {
        guard let json, let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object.compactMapValues { value in
            guard let s = value as? String, ["on", "off", "uninstalled"].contains(s) else { return nil }
            return s
        }
    }

    // MARK: Helpers

    nonisolated(unsafe) private static var idCounter = 0

    public static func makeWidgetId(_ type: WidgetType) -> String {
        idCounter += 1
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        let rand = String((0..<6).map { _ in alphabet[Int.random(in: 0..<36)] })
        return "\(type.rawValue)-\(String(idCounter, radix: 36))\(rand)"
    }

    static func clampInt(_ value: Int?, _ minimum: Int, _ maximum: Int, _ fallback: Int? = nil) -> Int {
        if maximum < minimum { return minimum }
        return min(maximum, max(minimum, value ?? fallback ?? minimum))
    }

    static func clampHeight(_ value: Int?, _ minH: Int, _ fallback: Int) -> Int { clampInt(value, minH, maxWidgetRows, fallback) }
    static func clampRow(_ value: Int?, _ fallback: Int) -> Int { clampInt(value, 0, maxRow, fallback) }

    public static func overlaps(_ a: DashboardWidget, _ b: DashboardWidget) -> Bool {
        a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
    }

    static func collides(_ rects: [DashboardWidget], _ rect: DashboardWidget) -> Bool { rects.contains { overlaps($0, rect) } }

    static func probe(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> DashboardWidget {
        DashboardWidget(id: "", type: .cost, x: x, y: y, w: w, h: h)
    }

    public static func rows(_ layout: DashboardLayout) -> Int { layout.widgets.reduce(0) { max($0, $1.y + $1.h) } }

    public static func canAdd(_ layout: DashboardLayout, _ type: WidgetType) -> Bool {
        guard let spec = specs[type] else { return false }
        return spec.allowMultiple || !layout.widgets.contains { $0.type == type }
    }

    public static func readingOrder(_ layout: DashboardLayout) -> [DashboardWidget] {
        layout.widgets.sorted { $0.y == $1.y ? $0.x < $1.x : $0.y < $1.y }
    }

    // MARK: Building

    public static func createLayout(_ projectPath: String, columns: Int = DashboardRules.columns) -> DashboardLayout {
        DashboardLayout(version: version, projectPath: projectPath, columns: clampInt(columns, 1, maxColumns, DashboardRules.columns), widgets: [])
    }

    public static func defaultLayout(_ projectPath: String) -> DashboardLayout {
        var layout = createLayout(projectPath)
        layout = add(layout, type: .cost, id: "cost-default", x: 0, y: 0)
        layout = add(layout, type: .git, id: "git-default", x: 6, y: 0)
        return layout
    }

    public static func findFreeSlot(_ layout: DashboardLayout, w: Int, h: Int, ignoreId: String? = nil, fromY: Int? = nil) -> (x: Int, y: Int) {
        let width = clampInt(w, 1, layout.columns)
        let height = clampHeight(h, 1, 1)
        let others = layout.widgets.filter { $0.id != ignoreId }
        let startY = clampRow(fromY ?? 0, 0)
        let lastRow = max(startY, others.reduce(0) { max($0, $1.y + $1.h) })
        var steps = 0
        for y in startY...lastRow {
            var x = 0
            while x + width <= layout.columns {
                if steps >= scanBudget { return (0, lastRow) }
                steps += 1
                if !collides(others, probe(x, y, width, height)) { return (x, y) }
                x += 1
            }
        }
        return (0, lastRow)
    }

    public static func add(_ layout: DashboardLayout, type: WidgetType, id: String? = nil, x: Int? = nil, y: Int? = nil,
                           w: Int? = nil, h: Int? = nil) -> DashboardLayout {
        guard let spec = specs[type] else { return layout }
        if !spec.allowMultiple && layout.widgets.contains(where: { $0.type == type }) { return layout }
        let id = id ?? makeWidgetId(type)
        if layout.widgets.contains(where: { $0.id == id }) { return layout }
        let w = clampInt(w, spec.minW, layout.columns, spec.w)
        let h = clampHeight(h, spec.minH, spec.h)
        let explicit = x != nil && y != nil
        let px = clampInt(x, 0, layout.columns - w, 0)
        let py = clampRow(y, 0)
        let placed = explicit && !collides(layout.widgets, probe(px, py, w, h))
            ? (x: px, y: py) : findFreeSlot(layout, w: w, h: h, fromY: explicit ? py : 0)
        var next = layout
        next.widgets.append(DashboardWidget(id: id, type: type, x: placed.x, y: placed.y, w: w, h: h))
        return next
    }

    public static func remove(_ layout: DashboardLayout, id: String) -> DashboardLayout {
        guard layout.widgets.contains(where: { $0.id == id }) else { return layout }
        var next = layout
        next.widgets.removeAll { $0.id == id }
        return next
    }

    public static func move(_ layout: DashboardLayout, id: String, x: Int, y: Int) -> DashboardLayout {
        guard let widget = layout.widgets.first(where: { $0.id == id }) else { return layout }
        let nx = clampInt(x, 0, layout.columns - widget.w, 0)
        let ny = clampRow(y, 0)
        let others = layout.widgets.filter { $0.id != id }
        let target = collides(others, probe(nx, ny, widget.w, widget.h))
            ? findFreeSlot(layout, w: widget.w, h: widget.h, ignoreId: id, fromY: ny) : (x: nx, y: ny)
        if target.x == widget.x && target.y == widget.y { return layout }
        var next = layout
        next.widgets = layout.widgets.map { $0.id == id ? DashboardWidget(id: $0.id, type: $0.type, x: target.x, y: target.y, w: $0.w, h: $0.h) : $0 }
        return next
    }

    public static func resize(_ layout: DashboardLayout, id: String, w: Int, h: Int) -> DashboardLayout {
        guard let widget = layout.widgets.first(where: { $0.id == id }), let spec = specs[widget.type] else { return layout }
        let nw = clampInt(w, spec.minW, layout.columns - widget.x, widget.w)
        let nh = clampHeight(h, spec.minH, widget.h)
        if nw == widget.w && nh == widget.h { return layout }
        let rect = probe(widget.x, widget.y, nw, nh)
        if collides(layout.widgets.filter { $0.id != id }, rect) { return layout }
        var next = layout
        next.widgets = layout.widgets.map { $0.id == id ? DashboardWidget(id: $0.id, type: $0.type, x: widget.x, y: widget.y, w: nw, h: nh) : $0 }
        return next
    }

    public static func applyPlacements(_ layout: DashboardLayout, _ placements: [WidgetPlacement]) -> DashboardLayout {
        if placements.isEmpty { return layout }
        var byId: [String: WidgetPlacement] = [:]
        for placement in placements where !placement.id.isEmpty { byId[placement.id] = placement }
        var changed = false
        let widgets = layout.widgets.map { widget -> DashboardWidget in
            guard let p = byId[widget.id] else { return widget }
            let spec = specs[widget.type]
            let w = clampInt(p.w, spec?.minW ?? 1, layout.columns, widget.w)
            let h = clampHeight(p.h, spec?.minH ?? 1, widget.h)
            let x = clampInt(p.x, 0, layout.columns - w, widget.x)
            let y = clampRow(p.y, widget.y)
            let next = DashboardWidget(id: widget.id, type: widget.type, x: x, y: y, w: w, h: h)
            if next != widget { changed = true }
            return next
        }
        if !changed { return layout }
        var next = layout
        next.widgets = widgets
        return next
    }

    public static func serialise(_ layout: DashboardLayout) -> [String: Any] {
        [
            "version": version,
            "projectPath": layout.projectPath,
            "columns": layout.columns,
            "widgets": layout.widgets.map { ["id": $0.id, "type": $0.type.rawValue, "x": $0.x, "y": $0.y, "w": $0.w, "h": $0.h] as [String: Any] },
        ]
    }

    private static func int(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, !(value is Bool), n.doubleValue.isFinite else { return nil }
        return Int(n.doubleValue.rounded(.towardZero))
    }

    public static func parse(_ raw: Any?, projectPath: String) -> DashboardLayout {
        guard let source = raw as? [String: Any], let entries = source["widgets"] as? [Any] else { return defaultLayout(projectPath) }
        var layout = createLayout(projectPath)
        var seen = Set<String>()
        for entry in entries {
            if layout.widgets.count >= maxWidgets { break }
            guard let candidate = entry as? [String: Any], let type = (candidate["type"] as? String).flatMap(WidgetType.init(rawValue:)),
                  let spec = specs[type] else { continue }
            let rawId = (candidate["id"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            let id = !rawId.isEmpty && !seen.contains(rawId) ? rawId : makeWidgetId(type)
            seen.insert(id)
            let w = clampInt(int(candidate["w"]), spec.minW, layout.columns, spec.w)
            let h = clampHeight(int(candidate["h"]), spec.minH, spec.h)
            let x = clampInt(int(candidate["x"]), 0, layout.columns - w, 0)
            let y = clampRow(int(candidate["y"]), 0)
            var rect = probe(x, y, w, h)
            if collides(layout.widgets, rect) {
                let slot = findFreeSlot(layout, w: w, h: h, fromY: y)
                rect = probe(slot.x, slot.y, w, h)
            }
            layout.widgets.append(DashboardWidget(id: id, type: type, x: rect.x, y: rect.y, w: w, h: h))
        }
        return layout
    }

    // MARK: Gridstack's part (float: false)

    /// Push every widget that overlaps `anchorId` (and, in turn, whatever those
    /// overlap) down below it, then float everything up as far as it will go — the
    /// grid the page shows after a drag, a resize or any change.
    public static func settle(_ layout: DashboardLayout, anchor anchorId: String? = nil) -> DashboardLayout {
        var widgets = layout.widgets
        if let anchorId, let anchor = widgets.firstIndex(where: { $0.id == anchorId }) {
            var queue = [anchor]
            var guardSteps = 0
            while let index = queue.first, guardSteps < 10_000 {
                queue.removeFirst()
                guardSteps += 1
                let blocker = widgets[index]
                for other in widgets.indices where other != index && other != anchor && overlaps(widgets[other], blocker) {
                    widgets[other].y = blocker.y + blocker.h
                    queue.append(other)
                }
            }
        }
        // Pack: in reading order (the anchor first among equals), each widget rises
        // while the row above it is free of the widgets already placed.
        let order = widgets.indices.sorted { a, b in
            let wa = widgets[a], wb = widgets[b]
            if wa.y != wb.y { return wa.y < wb.y }
            if wa.id == anchorId { return true }
            if wb.id == anchorId { return false }
            return wa.x < wb.x
        }
        var placed: [DashboardWidget] = []
        for index in order {
            var widget = widgets[index]
            while widget.y > 0 {
                var up = widget
                up.y -= 1
                if collides(placed, up) { break }
                widget = up
            }
            // A pushed-down widget may still overlap one placed earlier in the same row band.
            while collides(placed, widget) { widget.y += 1 }
            placed.append(widget)
            widgets[index] = widget
        }
        var next = layout
        next.widgets = widgets
        return next
    }

    /// The grid while a widget is dragged to `x, y` or resized to `w, h` — where the
    /// page's placeholder would sit, with everything else moved out of its way.
    public static func preview(_ layout: DashboardLayout, id: String, x: Int, y: Int, w: Int, h: Int) -> DashboardLayout {
        guard let index = layout.widgets.firstIndex(where: { $0.id == id }), let spec = specs[layout.widgets[index].type] else { return layout }
        var next = layout
        let nw = clampInt(w, spec.minW, layout.columns, layout.widgets[index].w)
        let nh = clampHeight(h, spec.minH, layout.widgets[index].h)
        next.widgets[index].w = nw
        next.widgets[index].h = nh
        next.widgets[index].x = clampInt(x, 0, layout.columns - nw, 0)
        next.widgets[index].y = clampRow(y, 0)
        return settle(next, anchor: id)
    }
}
