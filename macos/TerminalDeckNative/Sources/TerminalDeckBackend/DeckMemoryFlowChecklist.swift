import Foundation
import TerminalDeckNativeCore

/// The helper's checklist: plain Markdown the person can edit ("what counts as worth noting").
/// One per category, in that category's template (`templates/<category>/checklist.md`), so it
/// holds for every member and every future hire. Read again before every helper run. A
/// correction from the person ("you should have noted X") is added under its own heading,
/// never twice. The default text is the one in design-2026-10-10/MEMORY-LESSONS.md, change 4.
public enum DeckMemoryFlowChecklist {
    public static let correctionsHeading = "## Corrections from you"
    public static let defaultText = """
    # What the note helper writes down

    Edit this list freely: it is read again before every run.

    ## Write a note when the new text contains
    1. A correction from the person (highest priority; quote their words).
    2. A stated preference or standing rule from the person.
    3. A decision, with the reason and what it replaced.
    4. A result: what now works or exists, where, and its state word (attempted / reported / verified). Never raise the state yourself.
    5. An open item: who is waiting for what.
    6. A lesson: a trap, its cause, how to avoid it.
    7. A how-to: how to run, test, build or release this project, once it has worked.

    ## How to write it
    - One fact per note, 15 to 80 words, understandable alone. No "it", "he", "that file".
    - Exact names, numbers, versions, paths that will still exist. Never round or generalise.
    - Dates in full. Work them out from the date stamped on the message, not from today.
    - For a change: from what, to what, why.
    - Say who: "the person said", "Hoot proposed", "the agent did".
    - State the fact, not that it was discussed.
    - Use only what the new text says. Do not borrow details from the older notes shown to you.
    - A plan with a deadline is true from the day it was said; keep the deadline in the sentence.

    ## Do not write a note for
    - Anything a search of the diary or a look at the files answers just as well: routine steps, listings, installs, status checks.
    - Line numbers, exact error text, temporary paths, ports, commit ids.
    - A proposal nobody accepted.
    - The same outcome confirmed again. Once is enough.
    - The AI repeating back what the person said.
    - A preference guessed from one passing remark.
    - Passwords, keys, tokens, ever.

    ## When unsure
    - About something the person said (a correction, a preference, a decision): write the note.
    - About routine work detail: skip it, the diary has it.

    \(correctionsHeading)
    (When you tell the app "you should have noted X", it is added here.)

    """

    /// The checklist with one more correction. Returns nil when that correction is already there or is empty.
    public static func appending(_ correction: String, to text: String, on date: Date, calendar: Calendar = .current) -> String? {
        let said = correction.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        guard !said.isEmpty else { return nil }
        var lines = text.components(separatedBy: "\n")
        let heading = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).lowercased() == correctionsHeading.lowercased() }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let line = String(format: "- %04d-%02d-%02d: ", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0) + said
        guard let heading else {
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
            return (lines + ["", correctionsHeading, line, ""]).joined(separator: "\n")
        }
        // The section runs to the next heading, or to the end of the file.
        var end = lines.count
        for index in (heading + 1)..<lines.count where lines[index].hasPrefix("#") { end = index; break }
        let already = lines[(heading + 1)..<end].contains { existing in
            guard let colon = existing.range(of: ": ") else { return false }
            return existing.hasPrefix("- ") && existing[colon.upperBound...].trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(said) == .orderedSame
        }
        if already { return nil }
        var insert = end
        while insert > heading + 1, lines[insert - 1].trimmingCharacters(in: .whitespaces).isEmpty { insert -= 1 }
        lines.insert(line, at: insert)
        if insert == lines.count - 1 { lines.append("") }
        return lines.joined(separator: "\n")
    }
}
