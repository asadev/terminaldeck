import SwiftUI
import TerminalDeckNativeCore

/// Asad (12 Oct): "we struggle to understand which part is telling that these things are done, which part is asking
/// some permissions or decisions … if there are any decisions pending from us … with small box around it … if some part
/// is about things which are done … a little green". Hoot marks those parts with a plain container that survives copying
/// and any AI (`:::needs-you` … `:::`); the chat draws them as calm boxes. Unknown or broken markers stay plain text.
enum HootCallout {
    enum Kind: String, CaseIterable, Equatable {
        case needsYou = "needs-you", done, waiting, headsUp = "heads-up"
        var title: String {
            switch self { case .needsYou: "Needs you"; case .done: "Done"; case .waiting: "Waiting on"; case .headsUp: "Heads-up" }
        }
        var symbol: String {
            switch self { case .needsYou: "hand.raised"; case .done: "checkmark.circle"; case .waiting: "hourglass"; case .headsUp: "exclamationmark.triangle" }
        }
        var color: Color {
            switch self { case .needsYou: .orange; case .done: .green; case .waiting: .teal; case .headsUp: .red }
        }
        /// The words an AI may use for each kind.
        static func named(_ raw: String) -> Kind? {
            let name = raw.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: " ", with: "-")
            switch name {
            case "needs-you", "needsyou", "decision", "decisions", "question", "questions", "approval", "needs-your-ok": return .needsYou
            case "waiting-on-you": return .needsYou
            case "done", "completed", "finished": return .done
            case "waiting", "waiting-on", "waitingon", "blocked": return .waiting
            case "heads-up", "headsup", "warning", "risk": return .headsUp
            case "waiting-on-others": return .waiting
            default: return nil
            }
        }
    }
    enum Part: Equatable {
        case text(String)
        case box(Kind, String)
    }

    /// The reply in parts. A box opens on a line `:::kind` and closes on a line `:::`. Inside a code fence nothing is a
    /// marker. A box that never closes stays plain text, unless the reply is still being written (then it is shown as
    /// a box so it does not flash as raw text).
    static func parts(_ text: String, streaming: Bool = false) -> [Part] {
        guard text.contains(":::") else { return labelled(text) }
        var parts: [Part] = [], plain: [String] = [], inside: (kind: Kind, opener: String, lines: [String])?
        var fence = false
        func flushPlain() {
            let joined = plain.joined(separator: "\n")
            if !joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append(.text(joined)) }
            plain = []
        }
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fence.toggle() }
            if !fence, trimmed.hasPrefix(":::") {
                let name = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                if let open = inside, name.isEmpty {
                    flushPlain()
                    parts.append(.box(open.kind, open.lines.joined(separator: "\n").trimmingCharacters(in: .newlines)))
                    inside = nil; continue
                }
                if inside == nil, let kind = Kind.named(name) { flushPlain(); inside = (kind, line, []); continue }
            }
            if inside != nil { inside!.lines.append(line) } else { plain.append(line) }
        }
        if let open = inside {
            if streaming { flushPlain(); parts.append(.box(open.kind, open.lines.joined(separator: "\n").trimmingCharacters(in: .newlines))) }
            else {
                // Never closed: plain text, joined back onto the words before it exactly as they were written.
                if case .text(let before)? = parts.last { parts.removeLast(); plain = before.components(separatedBy: "\n") }
                plain.append(open.opener); plain += open.lines
            }
        }
        flushPlain()
        if parts.isEmpty { parts = [.text(text)] }
        // Any AI may still write a part as a bold or quoted label ("**Needs you:** …", "> **Done:** …"): the same box.
        return parts.flatMap { part -> [Part] in if case .text(let words) = part { return labelled(words) }; return [part] }
    }

    /// A paragraph that starts with a known label ("Needs you:", "**Done:**", "> **Waiting on:**") is that box;
    /// everything else stays text exactly as written. Not inside a code block.
    static func labelled(_ text: String) -> [Part] {
        guard text.range(of: #"(?im)^\s*(>\s*)?(\*\*|__)?(needs you|decisions?|questions?|done|completed|waiting( on)?|heads-up|warning)(\*\*|__)?\s*:"#, options: .regularExpression) != nil,
              !text.contains("```") else { return [.text(text)] }
        var parts: [Part] = [], plain: [String] = []
        func flush() { let joined = plain.joined(separator: "\n\n"); if !joined.isEmpty { parts.append(.text(joined)) }; plain = [] }
        for paragraph in text.components(separatedBy: "\n\n") {
            let lines = paragraph.components(separatedBy: "\n").map { line -> String in
                var bare = line.trimmingCharacters(in: .whitespaces)
                if bare.hasPrefix(">") { bare = String(bare.dropFirst()).trimmingCharacters(in: .whitespaces) }
                return bare
            }
            guard let first = lines.first(where: { !$0.isEmpty }),
                  let match = first.range(of: #"^(\*\*|__)?([A-Za-z -]+?)(\*\*|__)?\s*:(\*\*|__)?\s*"#, options: .regularExpression) else { plain.append(paragraph); continue }
            let label = String(first[match]).replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: ":", with: "").trimmingCharacters(in: .whitespaces)
            guard let kind = Kind.named(label) else { plain.append(paragraph); continue }
            var rest = lines
            let index = rest.firstIndex(of: first)!
            rest[index] = String(first[match.upperBound...])
            flush()
            parts.append(.box(kind, rest.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        flush()
        return parts
    }

    /// What Copy puts on the clipboard: the same text with each box as a plain labelled part ("Needs you:", "Done:").
    static func plain(_ text: String) -> String {
        let pieces = parts(text)
        guard pieces.contains(where: { if case .box = $0 { true } else { false } }) else { return text }
        return pieces.map { part in
            switch part {
            case .text(let words): words.trimmingCharacters(in: .newlines)
            case .box(let kind, let words): kind.title + ":\n" + words
            }
        }.joined(separator: "\n\n")
    }

    /// The numbered lines of a box ("1. Ship tonight?"), for the reply prefill.
    static func numbers(_ text: String) -> [Int] {
        text.components(separatedBy: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let dot = trimmed.firstIndex(where: { $0 == "." || $0 == ")" }), let number = Int(trimmed[..<dot]) else { return nil }
            return number
        }
    }
}

/// Hoot's reply: plain Markdown as before, with its marked parts as boxes.
struct HootReplyText: View {
    let text: String
    var streaming = false
    /// A Needs-you box with numbered items offers "Reply by number": the numbers go into the message box.
    var onReply: ((String) -> Void)? = nil
    var body: some View {
        let parts = HootCallout.parts(text, streaming: streaming)
        let single: String? = { if parts.count == 1, case .text(let words) = parts[0] { return words }; return nil }()
        if let single {
            NativeChatMarkdown(text: single)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    switch part {
                    case .text(let words): NativeChatMarkdown(text: words)
                    case .box(let kind, let words): HootCalloutBox(kind: kind, text: words, onReply: onReply)
                    }
                }
            }
        }
    }
}

struct HootCalloutBox: View {
    let kind: HootCallout.Kind
    let text: String
    var onReply: ((String) -> Void)? = nil
    var body: some View {
        let strong = kind == .needsYou
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: kind.symbol).foregroundStyle(kind.color)
                Text(kind.title).fontWeight(.semibold)
                Spacer(minLength: 8)
                let numbers = HootCallout.numbers(text)
                if kind == .needsYou, let onReply, !numbers.isEmpty {
                    Button {
                        onReply(numbers.map { "\($0). " }.joined(separator: "\n"))
                    } label: { Label("Reply by number", systemImage: "arrowshape.turn.up.left").font(.system(size: 11.5)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Reply to these by number")
                }
            }
            .font(.system(size: 12))
            NativeChatMarkdown(text: text)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(kind.color.opacity(strong ? 0.12 : 0.07), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(kind.color.opacity(strong ? 0.55 : 0.25), lineWidth: strong ? 1 : 0.75))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10).fill(kind.color.opacity(0.85)).frame(width: 3)
        }
        .accessibilityElement(children: .contain).accessibilityLabel(kind.title)
    }
}
