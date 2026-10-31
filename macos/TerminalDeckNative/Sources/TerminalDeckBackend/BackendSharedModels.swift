import Foundation

public struct BackendSharedModelRow: Equatable, Sendable {
    public var alias: String
    public var name: String
    public var model: String
    public var note: String
    public var current: Bool
    public var recommended: Bool
    public init(alias: String, name: String, model: String, note: String = "", current: Bool = false, recommended: Bool = false) {
        self.alias = alias; self.name = name; self.model = model; self.note = note; self.current = current; self.recommended = recommended
    }
}

/// shared/model-catalog.ts. Frozen lists are fallback source data; live rows are
/// accepted only from the CLI's complete model picker.
public enum BackendSharedModelCatalog {
    public static let fallbackModels: [BackendSharedModelRow] = [
        .init(alias: "opus[1m]", name: "Opus (1M context)", model: "Opus 5 with 1M context", note: "Best for everyday, complex tasks", recommended: true),
        .init(alias: "opus", name: "Opus", model: "Opus 5", note: "Best for everyday, complex tasks"),
        .init(alias: "fable", name: "Fable", model: "Fable 5", note: "Most capable for your hardest and longest-running tasks"),
        .init(alias: "sonnet", name: "Sonnet", model: "Sonnet 5", note: "Efficient for routine tasks"),
        .init(alias: "haiku", name: "Haiku", model: "Haiku 4.5", note: "Fastest for quick answers"),
        .init(alias: "opusplan", name: "Opus Plan", model: "Opus in plan mode, else Sonnet"),
    ]
    public static let previousModels: [BackendSharedModelRow] = [
        .init(alias: "claude-opus-4-8", name: "Opus 4.8", model: "Opus 4.8"),
        .init(alias: "claude-opus-4-5", name: "Opus 4.5", model: "Opus 4.5"),
        .init(alias: "claude-sonnet-4-6", name: "Sonnet 4.6", model: "Sonnet 4.6"),
    ]
    private static func removeFirstTick(_ text: String) -> String {
        guard let range = text.range(of: "[✔✓√]", options: .regularExpression) else { return text }
        return text.replacingCharacters(in: range, with: "")
    }
    public static func aliasForRow(_ name: String) -> String {
        let bare = BackendSharedText.trim(removeFirstTick(name).replacingOccurrences(of: #"(?i)\((?:recommended|default)\)"#, with: "", options: .regularExpression))
        let long = BackendSharedText.matches(bare, #"(?i)\(1m context\)$"#)
        let base = BackendSharedText.trim(bare.replacingOccurrences(of: #"(?i)\(1m context\)$"#, with: "", options: .regularExpression))
            .lowercased().replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        return long ? base + "[1m]" : base
    }
    public static func readModelPicker(_ screen: String) -> [BackendSharedModelRow]? {
        let lines = screen.components(separatedBy: "\n").map { $0.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression) }.filter { !BackendSharedText.trim($0).isEmpty }
        guard lines.contains(where: { BackendSharedText.matches(BackendSharedText.trim($0), #"(?i)^Select model$"#) }),
              let regex = try? NSRegularExpression(pattern: BackendSharedText.javascriptPattern(#"^\s*[❯>]?\s*(\d+)\.\s+(\S.*?)\s{2,}(\S.*?)\s*$"#)) else { return nil }
        var rows: [BackendSharedModelRow] = []
        for line in lines {
            let ns = line as NSString
            guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let rawName = ns.substring(with: match.range(at: 2)), detail = ns.substring(with: match.range(at: 3))
            let name = BackendSharedText.trim(removeFirstTick(rawName).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression))
            if name.isEmpty { continue }
            let dot = detail.firstIndex(of: "·")
            let model = BackendSharedText.trim(dot.map { String(detail[..<$0]) } ?? detail)
            let note = dot.map { BackendSharedText.trim(String(detail[detail.index(after: $0)...])) } ?? ""
            rows.append(.init(alias: aliasForRow(rawName), name: name, model: model, note: note, current: BackendSharedText.matches(rawName, "[✔✓√]"), recommended: BackendSharedText.matches(rawName, #"(?i)\(recommended\)"#)))
        }
        return rows.count >= 2 ? rows : nil
    }
    public static func foldDefaultRow(_ rows: [BackendSharedModelRow]) -> [BackendSharedModelRow] {
        guard let pointer = rows.firstIndex(where: { aliasForRow($0.name) == "default" }) else { return rows }
        guard let twin = rows.indices.first(where: { $0 != pointer && rows[$0].model == rows[pointer].model }) else {
            var output = rows; output[pointer].name = output[pointer].model; return output
        }
        return rows.indices.filter { $0 != pointer }.map { index in
            var row = rows[index]
            if index == twin { row.recommended = true; row.current = row.current || rows[pointer].current }
            return row
        }
    }
    public static func isTypeableModelValue(_ value: String) -> Bool { value.unicodeScalars.allSatisfy(\.isASCII) && BackendSharedText.matches(value, #"(?i)^[a-z0-9][a-z0-9.-]*(\[1m\])?$"#) }
}
