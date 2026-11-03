import SwiftUI
import TerminalDeckNativeCore

private struct NativeGHDiffRow: Identifiable {
    let id: Int
    let kind: GitDiffLineKind
    let text: String
    let oldLine: Int?
    let newLine: Int?
    var commentLine: Int? { kind == .del ? oldLine : newLine }
    var side: String { kind == .del ? "LEFT" : "RIGHT" }
}

/// Uses the same unified-diff parser and semantic fills as NativeGitScreen.
/// A GitHub patch adds numbered hunk coordinates for native review comments.
struct NativeGHDiff: View {
    let patch: String
    let comment: (Int, String) -> Void
    @State private var limit = 1000

    private var rows: [NativeGHDiffRow] {
        var old = 0
        var new = 0
        var inHunk = false
        return GitRules.parseUnifiedDiff(patch).enumerated().compactMap { index, line in
            if line.kind == .meta { return nil }
            if line.kind == .hunk {
                let fields = line.text.split(separator: " ")
                if fields.count >= 3,
                   let before = Int(fields[1].dropFirst().split(separator: ",").first ?? ""),
                   let after = Int(fields[2].dropFirst().split(separator: ",").first ?? "") {
                    old = before
                    new = after
                    inHunk = true
                } else { inHunk = false }
                return NativeGHDiffRow(id: index, kind: line.kind, text: line.text, oldLine: nil, newLine: nil)
            }
            let oldNumber = inHunk && line.kind != .add && old > 0 ? old : nil
            let newNumber = inHunk && line.kind != .del && new > 0 ? new : nil
            if line.kind != .add { old += 1 }
            if line.kind != .del { new += 1 }
            return NativeGHDiffRow(id: index, kind: line.kind, text: line.text, oldLine: oldNumber, newLine: newNumber)
        }
    }

    var body: some View {
        let all = rows
        let shown = Array(all.prefix(limit))
        GeometryReader { viewport in
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { row in
                        HStack(spacing: 0) {
                            Text(row.oldLine.map(String.init) ?? "").foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
                            Text(row.newLine.map(String.init) ?? "").foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
                            Group {
                                if let line = row.commentLine {
                                    Button { comment(line, row.side) } label: {
                                        Image(systemName: "plus.bubble").font(.system(size: 11)).frame(width: 26, height: 20)
                                    }
                                    .buttonStyle(.borderless)
                                    .foregroundStyle(.secondary)
                                    .help("Comment on \(row.side == "LEFT" ? "old" : "new") line \(line)")
                                    .accessibilityLabel("Comment on \(row.side == "LEFT" ? "old" : "new") line \(line)")
                                } else { Color.clear.frame(width: 26, height: 20) }
                            }
                            Text(row.kind == .add ? "+" : row.kind == .del ? "−" : " ")
                                .foregroundStyle(tint(row.kind)).frame(width: 18)
                                .accessibilityHidden(true)
                            Text(row.text.isEmpty ? " " : row.text)
                                .foregroundStyle(row.kind == .hunk ? Color.secondary : Color.primary)
                                .fixedSize(horizontal: true, vertical: false)
                            Spacer(minLength: 12)
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.vertical, 1)
                        .background(fill(row.kind))
                    }
                    if all.count > shown.count {
                        Button("Show next \(min(1000, all.count - shown.count)) lines") { limit += 1000 }
                            .font(.callout).padding(12)
                    }
                }
                .textSelection(.enabled)
                .frame(minWidth: viewport.size.width, minHeight: viewport.size.height, alignment: .topLeading)
            }
        }
        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 8))
        .clipShape(.rect(cornerRadius: 8))
        .onChange(of: patch) { _, _ in limit = 1000 }
    }

    private func tint(_ kind: GitDiffLineKind) -> Color {
        switch kind { case .add: .green; case .del: .red; default: .secondary }
    }
    private func fill(_ kind: GitDiffLineKind) -> Color {
        switch kind { case .add: Color.green.opacity(0.14); case .del: Color.red.opacity(0.14); default: .clear }
    }
}
