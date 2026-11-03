import AppKit
import TerminalDeckBackend
import TerminalDeckNativeCore

enum NativeChatDiffReview {
    struct Hunk: Equatable { let header: String; let oldLine: Int; let newLine: Int; var lines: [String] }
    static func hunks(_ diff: String) -> [Hunk] {
        let pattern = try! NSRegularExpression(pattern: #"^@@ -([0-9]+)(?:,[0-9]+)? \+([0-9]+)(?:,[0-9]+)? @@"#)
        var result: [Hunk] = []
        for line in diff.prefix(262_144).components(separatedBy: "\n").prefix(5000) {
            if line.hasPrefix("@@") {
                let ns = line as NSString
                guard let match = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)), let old = Int(ns.substring(with: match.range(at: 1))), let new = Int(ns.substring(with: match.range(at: 2))) else { continue }
                result.append(.init(header: line, oldLine: old, newLine: new, lines: []))
            } else if !result.isEmpty, line.hasPrefix("+") || line.hasPrefix("-") || line.hasPrefix(" ") { result[result.count - 1].lines.append(line) }
        }
        return result
    }
    struct Entry { let id: String; let card: BackendChatDiffs.Card; let detail: String }
    static func entries(_ rows: [HootChatRow]) -> [Entry] {
        BackendChatDiffs.cards(rows).flatMap { card -> [Entry] in
            let source = rows.first { $0.id == card.rowID }, changes = source?.value["input"]["changes"].elements ?? []
            let patch = changes.first { $0["path"].string == card.path }?["diff"].string ?? ""
            let parsed = hunks(patch)
            if !parsed.isEmpty { return parsed.enumerated().map { n, hunk in .init(id: card.id + "#" + String(n), card: card, detail: hunk.header + "\n" + hunk.lines.prefix(200).joined(separator: "\n") + (hunk.lines.count > 200 ? "\nPreview limited to 200 hunk lines." : "")) } }
            return [.init(id: card.id, card: card, detail: (card.known ? "Recorded before/after preview; absolute hunk line numbers unreported." : "Before version unavailable; change counts are unknown.") + "\n" + card.lines.prefix(200).map { $0.kind.mark + $0.text }.joined(separator: "\n") + (card.truncated || card.lines.count > 200 ? "\nPreview truncated." : ""))]
        }
    }
}
extension NativeHootChatModel {
    func diffReviewTool(_ action: String, request: String?, text: String?) async throws -> NativeRPCValue {
        featurePanel("diffs", action)
        let entries = NativeChatDiffReview.entries(rows)
        if ["comment", "details", "reveal"].contains(action) {
            guard let entry = entries.first(where: { $0.id == request }) else { throw NativeRPCError.invalidArguments("Choose a current recorded diff/hunk ID.") }
            if action == "comment" {
                guard (text ?? "").utf8.count <= 4096 else { throw NativeRPCError.invalidArguments("Keep the review comment under 4 KiB.") }
                let comment = "Review recorded diff \(entry.id)\nFile: \(entry.card.path)\n\(entry.detail)\n\nComment: \(text ?? "")"
                try setDraftText(composerDraft.text.isEmpty ? comment : composerDraft.text + "\n\n" + comment)
            }
            if action == "details" { _ = try detailTool("open", query: nil, recordID: entry.card.rowID) }
            if action == "reveal" {
                let root = URL(fileURLWithPath: try await projectReferenceRoot()).standardizedFileURL
                let file = entry.card.path.hasPrefix("/") ? URL(fileURLWithPath: entry.card.path).standardizedFileURL : root.appendingPathComponent(entry.card.path).standardizedFileURL
                guard file.path.hasPrefix(root.path + "/"), FileManager.default.fileExists(atPath: file.path) else { throw NativeRPCError.invalidArguments("The reported file is not present inside this Chat project.") }
                if !fixtureMode { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            }
        }
        return NativeChatPanel.state("Recorded file changes and hunks", "These are emitted change previews and can describe edits already made. Comments prepare a draft. Existing permission requests still own approval; Provider → Conditional file changes offers version-checked Apply/Reject when an exact supported text change can be established.", entries.map { entry in
            NativeChatPanel.row(entry.id, entry.card.path, entry.detail, [NativeChatPanel.action("Draft review comment", "comment", entry.id), NativeChatPanel.action("Show source event", "details", entry.id), NativeChatPanel.action("Reveal project file", "reveal", entry.id)])
        })
    }
}
