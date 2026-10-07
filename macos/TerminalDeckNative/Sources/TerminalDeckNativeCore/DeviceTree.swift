import Foundation

/// What is on a device's screen, as a tree — the Swift reading of
/// `src/shared/device-tree.ts`, and the same three questions asked of it.
///
/// The tree arrives from `devices:freeze` (the engine's accessibility snapshot,
/// or a React Native app's component tree). The rules for "which element is
/// under this point" are copied rule for rule from the shared TypeScript file,
/// so the native inspector, the web page's Annotate and the `devices.*` tools
/// all point at the same element for the same point.
///
/// Coordinates are **normalised**: 0..1 across the screen both ways, the unit
/// input is sent in.
public struct NormRect: Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isUsable: Bool { width > 0 && height > 0 }
    public var area: Double { width * height }

    public func contains(_ px: Double, _ py: Double) -> Bool {
        px >= x && py >= y && px <= x + width && py <= y + height
    }

    /// Wholly outside the screen: scrolled away, or parked off it.
    public var isOffScreen: Bool { x >= 1 || y >= 1 || x + width <= 0 || y + height <= 0 }

    /// As JSON for the bridge.
    public var json: [String: Any] { ["x": x, "y": y, "width": width, "height": height] }

    public init?(json: Any?) {
        guard let row = json as? [String: Any] else { return nil }
        x = DeviceJSON.number(row["x"])
        y = DeviceJSON.number(row["y"])
        width = DeviceJSON.number(row["width"])
        height = DeviceJSON.number(row["height"])
    }
}

public struct SourceLocation: Equatable, Hashable, Sendable {
    public var file: String
    public var line: Int?
    public var column: Int?

    public init(file: String, line: Int? = nil, column: Int? = nil) {
        self.file = file
        self.line = line
        self.column = column
    }

    /// `src/Home.tsx:42:7`
    public var text: String {
        var out = file
        if let line { out += ":\(line)" }
        if line != nil, let column { out += ":\(column)" }
        return out
    }
}

public struct DeviceNode: Equatable, Hashable, Sendable, Identifiable {
    /// Valid for the snapshot it came from only. Made unique while reading, so a
    /// list can key on it even when the engine left it out or repeated it.
    public var ref: String
    public var role: String?
    public var label: String?
    public var value: String?
    /// True when the value is a password and was left out on purpose.
    public var valueRedacted: Bool = false
    public var identifier: String?
    public var title: String?
    public var placeholder: String?
    public var enabled: Bool?
    public var hidden: Bool?
    public var focused: Bool?
    public var component: String?
    public var componentPath: [String] = []
    public var testID: String?
    public var text: String?
    public var sourceLocation: SourceLocation?
    public var frame: NormRect?
    public var children: [DeviceNode] = []

    public var id: String { ref }

    public init(ref: String, role: String? = nil, label: String? = nil, value: String? = nil,
                identifier: String? = nil, title: String? = nil, placeholder: String? = nil,
                enabled: Bool? = nil, hidden: Bool? = nil, focused: Bool? = nil,
                text: String? = nil, testID: String? = nil,
                frame: NormRect? = nil, children: [DeviceNode] = []) {
        self.ref = ref
        self.role = role
        self.label = label
        self.value = value
        self.identifier = identifier
        self.title = title
        self.placeholder = placeholder
        self.enabled = enabled
        self.hidden = hidden
        self.focused = focused
        self.text = text
        self.testID = testID
        self.frame = frame
        self.children = children
    }

    /// The frame, only when it has an area — what every question here measures with.
    public var usableFrame: NormRect? {
        guard let frame, frame.isUsable else { return nil }
        return frame
    }

    /// Read a tree node as the engine bridge delivers it (JSON). Nil when it is not one.
    public static func read(_ json: Any?) -> DeviceNode? {
        var seen = Set<String>()
        var counter = 0
        return read(json, depth: 0, seen: &seen, counter: &counter)
    }

    private static func read(_ json: Any?, depth: Int, seen: inout Set<String>, counter: inout Int) -> DeviceNode? {
        // A depth bound rather than trust: the tree comes from another process.
        guard depth <= 200, let row = json as? [String: Any] else { return nil }
        func string(_ key: String) -> String? {
            guard let value = row[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        counter += 1
        var ref = string("ref") ?? "node-\(counter)"
        if seen.contains(ref) { ref = "\(ref)#\(counter)" }
        seen.insert(ref)
        var node = DeviceNode(ref: ref)
        node.role = string("role")
        node.label = string("label")
        node.value = string("value")
        node.identifier = string("identifier")
        node.title = string("title")
        node.placeholder = string("placeholder")
        node.component = string("component")
        node.testID = string("testID")
        node.text = string("text")
        if row["valueRedacted"] as? Bool == true {
            node.valueRedacted = true
            node.value = nil
        }
        node.enabled = row["enabled"] as? Bool
        node.hidden = row["hidden"] as? Bool
        node.focused = row["focused"] as? Bool
        node.componentPath = (row["componentPath"] as? [Any])?.compactMap { $0 as? String } ?? []
        if let source = row["sourceLocation"] as? [String: Any], let file = source["file"] as? String {
            node.sourceLocation = SourceLocation(file: file,
                                                 line: (source["line"] as? NSNumber)?.intValue,
                                                 column: (source["column"] as? NSNumber)?.intValue)
        }
        if let frame = row["frame"] as? [String: Any] {
            node.frame = NormRect(json: frame["normalized"])
        }
        if let children = row["children"] as? [Any] {
            node.children = children.compactMap { read($0, depth: depth + 1, seen: &seen, counter: &counter) }
        }
        return node
    }
}

public struct DeviceTree: Equatable, Sendable {
    /// Where it was read from — `core-simulator-ax`, `react-native-fiber`, …
    public var source: String
    public var capturedAt: String
    public var root: DeviceNode
    public var nodeCount: Int
    public var truncated: Bool

    public init(source: String, capturedAt: String = "", root: DeviceNode, nodeCount: Int = 0, truncated: Bool = false) {
        self.source = source
        self.capturedAt = capturedAt
        self.root = root
        self.nodeCount = nodeCount
        self.truncated = truncated
    }

    public init?(json: Any?) {
        guard let row = json as? [String: Any], let root = DeviceNode.read(row["root"]) else { return nil }
        self.source = row["source"] as? String ?? "unknown"
        self.capturedAt = row["capturedAt"] as? String ?? ""
        self.root = root
        let counted = Int(DeviceJSON.number(row["nodeCount"]))
        self.nodeCount = counted > 0 ? counted : DeviceTreeQuery.flatten(root).count
        self.truncated = row["truncated"] as? Bool ?? false
    }
}

/// The questions asked of a tree. Pure, and the same answers as `device-tree.ts`.
public enum DeviceTreeQuery {
    public static func findNodes(_ root: DeviceNode, name: String? = nil, partial: Bool = false,
                                 role: String? = nil, identifier: String? = nil) -> [DeviceNode] {
        func want(_ value: String?) -> String { (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let name = want(name), role = want(role), identifier = want(identifier)
        guard !name.isEmpty || !role.isEmpty || !identifier.isEmpty else { return [] }
        return flatten(root).filter { node in
            if !identifier.isEmpty, want(node.identifier) != identifier, want(node.testID) != identifier { return false }
            if !role.isEmpty, want(node.role) != role, plainRole(node.role) != role { return false }
            if !name.isEmpty {
                let names = [node.label, node.title, node.text, node.value, node.placeholder].map(want)
                if !(partial ? names.contains { $0.contains(name) } : names.contains(name)) { return false }
            }
            return true
        }
    }
    /// Every node, parents before children, at most 200 deep.
    public static func flatten(_ root: DeviceNode) -> [DeviceNode] {
        var out: [DeviceNode] = []
        func visit(_ node: DeviceNode, _ depth: Int) {
            if depth > 200 { return }
            out.append(node)
            for child in node.children { visit(child, depth + 1) }
        }
        visit(root, 0)
        return out
    }

    /// Roles that are scaffolding rather than something a person points at.
    static let scaffold: Set<String> = [
        "AXApplication", "AXWindow", "AXGroup", "AXUnknown", "AXScrollArea", "AXLayoutArea", "AXOther",
        "android.widget.FrameLayout", "android.widget.LinearLayout", "android.view.View", "android.view.ViewGroup",
    ]

    static func hasName(_ node: DeviceNode) -> Bool {
        [node.label, node.identifier, node.title, node.testID, node.text, node.value].contains { ($0 ?? "").isEmpty == false }
    }

    /// The element a person meant by a point: the smallest *named* element whose
    /// frame holds it, or — when nothing named does — the smallest of whatever does.
    public static func elementAt(_ root: DeviceNode, x: Double, y: Double) -> DeviceNode? {
        elementAt(in: flatten(root), x: x, y: y)
    }

    /// The same, over a tree already flattened — for a pointer moving over one reading.
    public static func elementAt(in nodes: [DeviceNode], x: Double, y: Double) -> DeviceNode? {
        var best: DeviceNode?
        var bestArea = Double.infinity
        var fallback: DeviceNode?
        var fallbackArea = Double.infinity
        for node in nodes {
            guard let rect = node.usableFrame, node.hidden != true, rect.contains(x, y) else { continue }
            let area = rect.area
            let meaningful = hasName(node) && !scaffold.contains(node.role ?? "")
            if meaningful && area < bestArea {
                best = node
                bestArea = area
            }
            if area < fallbackArea {
                fallback = node
                fallbackArea = area
            }
        }
        return best ?? fallback
    }

    /// A role a person can read: `AXButton` → `button`, `android.widget.TextView` → `text view`.
    public static func plainRole(_ role: String?) -> String {
        guard var bare = role, !bare.isEmpty else { return "" }
        if bare.hasPrefix("AX") { bare.removeFirst(2) }
        if let dot = bare.lastIndex(of: ".") { bare = String(bare[bare.index(after: dot)...]) }
        var out = ""
        var previous: Character?
        for char in bare {
            if let previous, previous.isLowercase, previous.isASCII, char.isUppercase, char.isASCII { out.append(" ") }
            out.append(char)
            previous = char
        }
        return out.lowercased()
    }

    /// The name a node goes by, the way a person would say it.
    public static func nodeName(_ node: DeviceNode) -> String {
        let first = [node.label, node.title, node.text, node.identifier, node.testID, node.placeholder]
            .lazy.compactMap { $0 }.first { !$0.isEmpty } ?? ""
        return first.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The centre of a node, which is where a tap on it goes.
    public static func centre(of node: DeviceNode) -> (x: Double, y: Double)? {
        guard let rect = node.usableFrame else { return nil }
        func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
        return (clamp(rect.x + rect.width / 2), clamp(rect.y + rect.height / 2))
    }

    public static func node(ref: String, in root: DeviceNode) -> DeviceNode? {
        flatten(root).first { $0.ref == ref }
    }

    /// The refs from the root down to (not including) the node — what has to be
    /// open in the outline for it to show. Empty when it is not in the tree.
    public static func ancestors(of ref: String, in root: DeviceNode) -> [String] {
        var path: [String] = []
        func walk(_ node: DeviceNode, _ depth: Int) -> Bool {
            if depth > 200 { return false }
            if node.ref == ref { return true }
            path.append(node.ref)
            for child in node.children where walk(child, depth + 1) { return true }
            path.removeLast()
            return false
        }
        return walk(root, 0) ? path : []
    }

    /// One row of the outline: the node, how deep it sits, and whether it can open.
    public struct OutlineRow: Equatable, Sendable, Identifiable {
        public let node: DeviceNode
        public let depth: Int
        public var id: String { node.ref }
        public var hasChildren: Bool { !node.children.isEmpty }
    }

    /// The rows an outline shows, given which nodes are open. Parents before children.
    public static func outlineRows(_ root: DeviceNode, expanded: Set<String>) -> [OutlineRow] {
        var rows: [OutlineRow] = []
        func visit(_ node: DeviceNode, _ depth: Int) {
            if depth > 200 { return }
            rows.append(OutlineRow(node: node, depth: depth))
            guard expanded.contains(node.ref) else { return }
            for child in node.children { visit(child, depth + 1) }
        }
        visit(root, 0)
        return rows
    }

    /// The nodes to open first: everything in a small tree, the top three levels of a big one.
    public static func initiallyExpanded(_ root: DeviceNode, smallTree: Int = 300) -> Set<String> {
        let all = flatten(root)
        if all.count <= smallTree { return Set(all.filter { !$0.children.isEmpty }.map(\.ref)) }
        var open = Set<String>()
        func visit(_ node: DeviceNode, _ depth: Int) {
            guard depth < 3, !node.children.isEmpty else { return }
            open.insert(node.ref)
            for child in node.children { visit(child, depth + 1) }
        }
        visit(root, 0)
        return open
    }
}

/// Small readers for the bridge's JSON.
public enum DeviceJSON {
    public static func number(_ value: Any?) -> Double {
        // A JSON `true` is an NSNumber too; it is not a number here.
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return 0 }
        let double = number.doubleValue
        return double.isFinite ? double : 0
    }

    public static func strings(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { $0 as? String } ?? []
    }

    /// The bytes of a `data:<type>;base64,<…>` URL, or nil.
    public static func dataURL(_ value: Any?) -> Data? {
        guard let text = value as? String, text.hasPrefix("data:"), let comma = text.firstIndex(of: ",") else { return nil }
        let head = text[..<comma]
        guard head.hasSuffix(";base64") else { return nil }
        return Data(base64Encoded: String(text[text.index(after: comma)...]))
    }
}
