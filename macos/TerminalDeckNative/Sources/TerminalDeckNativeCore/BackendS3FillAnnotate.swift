import Foundation

/// Night S3: the browser-page, selector, roundForTools and findNodes halves of
/// `src/shared/annotate.ts` and `src/shared/device-tree.ts`. Written as extensions
/// because AnnotateWhere/AnnotatedElement cannot gain stored fields from another
/// file; the `url`/`selector` ride along as arguments until integration adds the
/// stored fields (see NIGHT-REQUESTS, "for integration").
public extension Handoff {
    /// `button "Save" (id save, selector #save, component Foo, source src/A.tsx:4:2)`
    static func describeElement(_ element: AnnotatedElement?, selector: String?) -> String {
        guard let selector, !selector.isEmpty else { return describeElement(element) }
        guard let element else { return "blank space" }
        let head = [element.role.map { clip($0, 40) } ?? "", element.name.map { "\"\(clip($0))\"" } ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " ")
        var handles: [String] = []
        if let identifier = element.identifier, !identifier.isEmpty { handles.append("id \(clip(identifier))") }
        handles.append("selector \(clip(selector, 200))")
        if let component = element.component, !component.isEmpty { handles.append("component \(clip(component, 80))") }
        if let source = element.source {
            var place = "source \(clip(source.file, 200))"
            if let line = source.line, line != 0 {
                place += ":\(line)"
                if let column = source.column, column != 0 { place += ":\(column)" }
            }
            handles.append(place)
        }
        return "\(head.isEmpty ? "element" : head) (\(handles.joined(separator: ", ")))"
    }

    /// Browser rounds: `the page https://x.test/a titled "Shop"`, or `a browser page`.
    static func describeWhere(_ where_: AnnotateWhere, url: String?) -> String {
        guard where_.kind == "browser" else { return describeWhere(where_) }
        var parts = [url.flatMap { $0.isEmpty ? nil : "the page \(clip($0, 300))" } ?? "a browser page"]
        if !where_.name.isEmpty { parts.append("titled \"\(clip(where_.name))\"") }
        return parts.joined(separator: " ")
    }

    /// `roundForTools`: fields, not a sentence. Markers carry n, element, described, rect — never a note.
    static func roundForTools(_ round: AnnotationRound, sentTo: (sessionId: String, label: String, at: Double)? = nil,
                              picture: (path: String, width: Int, height: Int)? = nil) -> [String: Any] {
        func iso(_ ms: Double) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: Date(timeIntervalSince1970: ms / 1000))
        }
        return [
            "id": round.id,
            "createdAt": iso(round.createdAt),
            "where": round.where_.json,
            "note": flat(round.note),
            "picture": picture.map { ["path": $0.path, "width": $0.width, "height": $0.height] as [String: Any] } ?? NSNull(),
            "sentTo": sentTo.map { ["session": $0.label, "at": iso($0.at)] as [String: Any] } ?? NSNull(),
            "markers": round.annotations.map { entry -> [String: Any] in
                ["n": entry.n, "element": entry.element.map { $0.json as Any } ?? NSNull(),
                 "described": describeElement(entry.element), "rect": entry.rect.json]
            },
        ]
    }
}

public struct DeviceTreeFindQuery: Equatable, Sendable {
    public var name: String?, partial: Bool, role: String?, identifier: String?
    public init(name: String? = nil, partial: Bool = false, role: String? = nil, identifier: String? = nil) {
        self.name = name; self.partial = partial; self.role = role; self.identifier = identifier
    }
}

public extension DeviceTreeQuery {
    /// `findNodes`: whole-name case-insensitive match (partial on request), role in either spelling,
    /// identifier or test id; an empty query finds nothing.
    static func findNodes(_ root: DeviceNode, _ query: DeviceTreeFindQuery) -> [DeviceNode] {
        func want(_ value: String?) -> String { (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let name = want(query.name), identifier = want(query.identifier), role = want(query.role)
        guard !name.isEmpty || !identifier.isEmpty || !role.isEmpty else { return [] }
        return flatten(root).filter { node in
            if !identifier.isEmpty && want(node.identifier) != identifier && want(node.testID) != identifier { return false }
            if !role.isEmpty && want(node.role) != role && plainRole(node.role) != role { return false }
            if !name.isEmpty {
                let names = [node.label, node.title, node.text, node.value, node.placeholder].map(want)
                let hit = query.partial ? names.contains { $0.contains(name) } : names.contains { $0 == name }
                if !hit { return false }
            }
            return true
        }
    }
}
