/**
 * One file's diff, exactly as git printed it.
 *
 * The other half of the `git` capability — `protocol.ts` calls it *"One file's
 * diff, as git printed it. Empty when there is nothing to show."* — and this
 * screen's whole job is to render that text without becoming a second opinion
 * about it. No side-by-side reconstruction, no re-wrapping, no word-level
 * highlighting: a unified patch is a format people already read, and every
 * transformation of it on a 390-point screen is a chance to show a change that
 * is not the change git described.
 *
 * ## Why the lines do not wrap
 *
 * A diff is column-significant. Wrapping a 200-column line onto four rows puts
 * three rows on screen whose first character is not `+`, `-` or a space, and the
 * one thing a person scanning a patch does is read that column. So the text is
 * laid out at its true width in a monospaced face and the screen scrolls both
 * ways — which is also why every line is drawn at the *same* width: a tinted
 * background that stopped at the end of each line's own text would turn a
 * horizontal scroll into a ragged green-and-red coastline.
 *
 * ## Read-only, like everything else behind this capability
 *
 * No stage-this-hunk, no revert, no apply. `protocol.ts`, on `git`: *"Status and
 * a diff, never a commit."* The verb for a diff you disagree with is a session
 * with the agent that wrote it, which is the app this screen is inside.
 */

import SwiftUI
import UIKit

struct DiffView: View {
    let model: DeckModel
    /// The folder `git.diff` is asked about — the same one the status came from.
    let path: String
    let file: GitFileChange
    /// Index-against-HEAD rather than working-tree-against-index. The row that
    /// pushed this screen knows which side it was on, because a file that has
    /// been staged and then edited again legitimately appears on both.
    let staged: Bool

    /// This file's patch, or nil while the request is in flight. All four fields
    /// are checked, not just the name: the staged and unstaged patches for one
    /// file are two different answers and only one of them belongs on screen.
    private var patch: String? {
        guard let latest = model.gitPatch,
              latest.path == path,
              latest.file == file.path,
              latest.staged == staged else { return nil }
        return latest.patch
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            content
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: file.id) { model.gitDiff(path, file: file.path, staged: staged) }
    }

    @ViewBuilder
    private var content: some View {
        if let patch {
            if patch.isEmpty {
                empty
            } else {
                patchBody(DiffText.parse(patch))
            }
        } else {
            ProgressView().controlSize(.regular)
        }
    }

    // MARK: - The patch

    private func patchBody(_ document: DiffText) -> some View {
        VStack(spacing: 0) {
            summary(document)
            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(document.lines) { line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(ink(line.kind))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 1)
                            // Every row the same width, so the tints read as
                            // bands rather than as a coastline. See the header.
                            .frame(width: document.width, alignment: .leading)
                            .background(wash(line.kind))
                    }
                    if document.truncated {
                        Text("This patch is longer than \(DiffText.maxLines) lines and is shown to there.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.faint)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                    }
                }
                .padding(.vertical, 8)
            }
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .accessibilityIdentifier("git.patch")
    }

    /// What the patch adds up to, above it — counted from the patch itself
    /// rather than from the status row, because the two can disagree: `insertions`
    /// on a `GitFile` is *"null until a numstat pass fills it in"*, and this
    /// screen has the actual text in front of it.
    private func summary(_ document: DiffText) -> some View {
        HStack(spacing: 12) {
            Text(staged ? "Staged" : "Working tree")
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(Theme.faint)
                .textCase(.uppercase)
            Spacer(minLength: 8)
            if document.added > 0 {
                Text("+\(document.added)")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.positive)
            }
            if document.removed > 0 {
                Text("−\(document.removed)")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Theme.critical)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(staged ? "Staged" : "Working tree"), \(document.added) added, \(document.removed) removed")
    }

    // MARK: - Nothing to show

    /**
     * An empty patch, said as the fact it is rather than as a failure.
     *
     * `readFileDiff` returns `''` rather than throwing *"so a click on a
     * vanished file cannot take the panel down"*, which means empty covers
     * several true situations. Two of them are worth separating here because a
     * person can act on the difference: a file git is not tracking has nothing to
     * be compared against, and a binary file has nothing git will print.
     */
    private var empty: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "text.append")
                .font(.system(size: 19, weight: .light))
                .foregroundStyle(Theme.secondary)
            Text(emptyReason)
                .font(.system(size: 15))
                .foregroundStyle(Theme.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .accessibilityIdentifier("git.patch.empty")
    }

    private var emptyReason: String {
        if file.binary { return "This is a binary file. git has no text to show for it." }
        if file.kind == .untracked || file.group == .untracked {
            return "This file is not tracked yet, so there is nothing to compare it against."
        }
        if file.kind == .deleted && staged { return "This file was deleted, and the deletion is staged." }
        return "git has no diff for this file."
    }

    private var name: String {
        let last = (file.path as NSString).lastPathComponent
        return last.isEmpty ? file.path : last
    }

    // MARK: - Colour

    /// Added and removed get the palette's own two status colours. A hunk header
    /// is muted because it is scaffolding — the `@@ -1,7 +1,9 @@` is how you
    /// find your place, not something that changed.
    private func ink(_ kind: DiffText.Kind) -> Color {
        switch kind {
        case .added: return Theme.positive
        case .removed: return Theme.critical
        case .hunk: return Theme.faint
        case .meta: return Theme.faint
        case .context: return Theme.primary
        }
    }

    /// A wash under the changed lines, at a tenth strength.
    ///
    /// The tinted *text* is what the brief asks for and it is not quite enough on
    /// its own: at 12 points the difference between a green line and a red one is
    /// two strokes of hue on a thin glyph, and the thing a person actually does
    /// with a patch is find the changed region at a glance. The palette carries
    /// no green or red surface, so this is the ink's own colour at a strength
    /// that stays under the text in both appearances rather than a new hex.
    private func wash(_ kind: DiffText.Kind) -> Color {
        switch kind {
        case .added: return Theme.positive.opacity(0.1)
        case .removed: return Theme.critical.opacity(0.1)
        default: return .clear
        }
    }
}

/**
 * A unified patch, split into lines that know what they are.
 *
 * A struct rather than work done inside the view body, because the classification
 * and the width measurement are done once per patch and a `body` runs whenever
 * anything on the model moves.
 */
struct DiffText {
    enum Kind {
        case meta
        case hunk
        case added
        case removed
        case context
    }

    struct Line: Identifiable {
        let id: Int
        let kind: Kind
        let text: String
    }

    let lines: [Line]
    /// The width every row is drawn at, so the tints line up. Measured from the
    /// longest line, which in a monospaced face is exactly the one with the most
    /// characters.
    let width: CGFloat
    let added: Int
    let removed: Int
    let truncated: Bool

    /**
     * A cap, because a patch has no upper bound and a phone does.
     *
     * `git diff` on a lockfile or a generated bundle is routinely six figures of
     * lines, and a `LazyVStack` is lazy about *drawing* rows, not about holding
     * them. Cut here and say so on screen — a patch that silently stopped would
     * be worse than one that admits where it stops.
     */
    static let maxLines = 4000

    static func parse(_ patch: String) -> DiffText {
        var kept: [Line] = []
        var added = 0
        var removed = 0
        var longest = 0
        var truncated = false

        // `omittingEmptySubsequences: false` matters: a blank context line in the
        // middle of a hunk is a real line of the file, and dropping it would
        // shift every line after it against the hunk header's own count.
        for raw in patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if kept.count >= maxLines {
                truncated = true
                break
            }
            // A patch git produced on Windows arrives with the carriage return
            // still attached, and a stray CR renders as a box at the end of
            // every line.
            let text = String(raw.hasSuffix("\r") ? raw.dropLast() : raw)
            let kind = classify(text)
            if kind == .added { added += 1 }
            if kind == .removed { removed += 1 }
            longest = max(longest, text.count)
            kept.append(Line(id: kept.count, kind: kind, text: text))
        }

        // A trailing newline is a property of the text, not a line of the patch.
        if kept.last?.text.isEmpty == true { kept.removeLast() }

        return DiffText(lines: kept,
                        width: measure(columns: longest),
                        added: added,
                        removed: removed,
                        truncated: truncated)
    }

    /**
     * What a line is.
     *
     * Order is the whole of it: the file headers `--- a/x` and `+++ b/x` begin
     * with the same characters a removed and an added line do, so they have to be
     * recognised first or every diff opens with one red line and one green one
     * that are not changes at all.
     */
    private static func classify(_ text: String) -> Kind {
        if text.hasPrefix("@@") { return .hunk }
        if text.hasPrefix("---") || text.hasPrefix("+++") { return .meta }
        for prefix in metaPrefixes where text.hasPrefix(prefix) { return .meta }
        if text.hasPrefix("+") { return .added }
        if text.hasPrefix("-") { return .removed }
        // "\ No newline at end of file" belongs to the hunk above it and is not
        // a line of either version of the file.
        if text.hasPrefix("\\") { return .meta }
        return .context
    }

    private static let metaPrefixes = [
        "diff --git",
        "index ",
        "new file mode",
        "deleted file mode",
        "old mode",
        "new mode",
        "similarity index",
        "dissimilarity index",
        "rename from",
        "rename to",
        "copy from",
        "copy to",
        "Binary files",
        "GIT binary patch",
    ]

    /**
     * The width of `columns` monospaced characters, plus the horizontal padding
     * the rows carry.
     *
     * One measurement of one character, multiplied — which is only correct
     * because the face is monospaced, and is the reason this does not walk the
     * lines with `boundingRect`. `.system(size:design:.monospaced)` resolves to
     * the same face `UIFont.monospacedSystemFont` returns, so the advance
     * measured here is the advance SwiftUI will lay out with.
     */
    private static func measure(columns: Int) -> CGFloat {
        let font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let advance = ("0" as NSString).size(withAttributes: [.font: font]).width
        return CGFloat(columns) * advance + 24
    }
}
