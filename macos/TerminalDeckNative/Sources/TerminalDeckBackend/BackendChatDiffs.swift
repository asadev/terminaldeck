import Foundation
import TerminalDeckNativeCore

public enum BackendChatDiffs {
    public struct Card: Identifiable, Sendable {
        public let id: String
        public let rowID: String
        public let path: String
        public let lines: [ArtifactsDiff.Line]
        public let known: Bool
        public let truncated: Bool
        public var plus: Int { lines.filter { $0.kind == .add }.count }
        public var minus: Int { lines.filter { $0.kind == .del }.count }
        public var wire: NativeRPCValue {
            .object([.init("id", .string(id)), .init("path", .string(path)), .init("known", .bool(known)),
                .init("plus", known ? .number(Double(plus)) : .null), .init("minus", known ? .number(Double(minus)) : .null),
                .init("truncated", .bool(truncated)), .init("lines", .array(lines.prefix(300).map {
                    .object([.init("kind", .string($0.kind.rawValue)), .init("text", .string($0.text))])
                }))])
        }
    }
    public static func isEdit(_ row: HootChatRow) -> Bool {
        row.kind == .toolCall && ["Edit", "MultiEdit", "Write", "fileChange", "file_change", "apply_patch", "write_file", "replace"].contains(row.value["name"].string ?? "")
    }
    public static func cards(_ rows: [HootChatRow]) -> [Card] {
        rows.filter(isEdit).flatMap { row -> [Card] in
            let input = row.value["input"], details = row.value["details"]
            if let changes = input["changes"].elements {
                return changes.enumerated().compactMap { index, change in
                    guard let path = change["path"].string else { return nil }
                    let lines = GitRules.parseUnifiedDiff(change["diff"].string ?? "").filter { $0.kind != .meta }.map {
                        ArtifactsDiff.Line($0.kind == .add ? .add : $0.kind == .del ? .del : .same, $0.text)
                    }
                    return Card(id: row.id + ":" + String(index), rowID: row.id, path: path, lines: lines, known: change["diff"].string != nil, truncated: lines.count > 300)
                }
            }
            guard let path = input["file_path"].string ?? input["path"].string ?? details["filePath"].string else { return [] }
            let edits = input["edits"].elements ?? [input]
            var lines: [ArtifactsDiff.Line] = [], known = false, truncated = false
            for edit in edits {
                if let before = edit["old_string"].string ?? details["oldString"].string ?? details["originalFile"].string,
                   let after = edit["new_string"].string ?? details["newString"].string ?? edit["content"].string {
                    let diff = ArtifactsDiff.diff(before: before, after: after)
                    lines += diff.lines; known = true; truncated = truncated || diff.truncated
                } else if let text = edit["content"].string {
                    lines += ArtifactsDiff.splitLines(text).map { ArtifactsDiff.Line(.same, $0) }
                }
            }
            return [Card(id: row.id, rowID: row.id, path: path, lines: lines, known: known, truncated: truncated || lines.count > 300)]
        }
    }
}
