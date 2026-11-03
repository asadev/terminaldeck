import Foundation
import TerminalDeckNativeCore

/// The nightly tidy-up: the only scheduled job. Once a day, when the app is quiet (or the
/// next time it is open and quiet), per seat, in the order of MEMORY-LESSONS.md change 10:
///   1. no AI: exact duplicates, a backup, the index;
///   2. one small AI question over the seat's new notes, each beside the older notes most
///      like it: true duplicates, explicit replacements, open items that are now done;
///   3. a second look at the diary ONLY where it is needed: messages where the person seemed
///      to correct something and no correction note was written;
///   4. a correction repeated on three or more days becomes a question ("Make this a top rule?").
/// Nothing is ever deleted, a card is never rewritten (a card over its size becomes a
/// question), and when the helper is unsure it leaves both notes alone and asks the person.
public enum DeckMemoryFlowTidy {
    public static let maximumNew = 60
    public static let similarPerNote = 4
    public static let maximumShown = 120

    /// What the helper proposes, in the numbers it was shown.
    public struct Plan: Sendable, Equatable {
        public struct Pair: Sendable, Equatable { public var a: Int; public var b: Int }
        public struct Replace: Sendable, Equatable { public var newer: Int; public var older: Int; public var why: String }
        public struct Close: Sendable, Equatable { public var item: Int; public var by: Int?; public var why: String }
        public struct Fresh: Sendable, Equatable { public var type: DeckMemoryNoteType; public var title: String; public var text: String }
        public struct Question: Sendable, Equatable { public var text: String; public var context: String; public var notes: [Int] }
        public var duplicates: [Pair] = []
        public var replaces: [Replace] = []
        public var closes: [Close] = []
        public var missed: [Fresh] = []
        public var repeated: [[Int]] = []
        public var questions: [Question] = []
    }

    // MARK: When

    /// The day ("2026-10-11") whose tidy-up slot has most recently opened: today once the hour
    /// has passed, otherwise yesterday.
    public static func slot(now: Date, hour: Int, calendar: Calendar) -> String {
        let today = calendar.startOfDay(for: now)
        let opens = calendar.date(byAdding: .hour, value: min(23, max(0, hour)), to: today) ?? today
        let day = now >= opens ? today : (calendar.date(byAdding: .day, value: -1, to: today) ?? today)
        return name(day, calendar: calendar)
    }
    /// A tidy-up is due when the newest slot has not been done. Missed days are made up in one run.
    public static func isDue(now: Date, lastSlot: String?, hour: Int, calendar: Calendar) -> Bool {
        lastSlot != slot(now: now, hour: hour, calendar: calendar)
    }
    /// The next moment a slot opens, strictly after `now`.
    public static func nextOpening(after now: Date, hour: Int, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        let opens = calendar.date(byAdding: .hour, value: min(23, max(0, hour)), to: today) ?? today
        return opens > now ? opens : (calendar.date(byAdding: .day, value: 1, to: opens) ?? opens.addingTimeInterval(86_400))
    }
    public static func name(_ day: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: The question

    /// - `notes`: in the order they are numbered; the first `fresh` are the new ones.
    /// - `missed`: the person's messages that look like a correction with no correction note near them.
    public static func prompt(owner: String, notes: [DeckMemoryNote], fresh: Int, missed: String, checklist: String,
                              prompts: DeckMemoryFlowPrompts = .standard) -> String {
        let stamp = DateFormatter(); stamp.dateFormat = "yyyy-MM-dd HH:mm"; stamp.locale = Locale(identifier: "en_US_POSIX")
        let listed = notes.isEmpty ? "None." : notes.enumerated().map { index, note in
            // The list goes to the helper AI: secrets and private parts out, as for every helper question.
            let body = String(DeckMemoryRedaction.forSharing(note.body).prefix(900)).replacingOccurrences(of: "\n", with: " ")
            let who = note.source == "user" ? "written by the person" : "written by " + note.source
            return "\(index + 1). \(index < fresh ? "NEW · " : "")\(note.type.rawValue) · \(stamp.string(from: note.labels.date)) · \(who)\n   \(DeckMemoryRedaction.forSharing(note.title)): \(body)"
        }.joined(separator: "\n")
        return DeckMemoryFlowPrompts.fill(prompts.tidy, ["owner": owner, "notes": listed, "missed": missed.isEmpty ? "None." : missed,
                                                         "checklist": checklist.trimmingCharacters(in: .whitespacesAndNewlines)])
    }

    /// Reads the plan. Lenient about wrapping, strict about shape; the numbers are checked by `DeckMemoryFlowRules.tidy`.
    public static func parse(_ raw: String) throws -> Plan {
        let value = try DeckMemoryFlowHelperPrompt.object(in: raw)
        var plan = Plan()
        func number(_ value: NativeRPCValue) -> Int? { value.number.flatMap { $0 == $0.rounded() && abs($0) < 100_000 ? Int($0) : nil } }
        for item in (value["duplicates"].elements ?? []).prefix(60) {
            if let a = number(item["a"]), let b = number(item["b"]) { plan.duplicates.append(.init(a: a, b: b)) }
        }
        for item in (value["replace"].elements ?? []).prefix(60) {
            if let newer = number(item["newer"]), let older = number(item["older"]) {
                plan.replaces.append(.init(newer: newer, older: older, why: DeckMemoryFlowHelperPrompt.clean(item["why"].string, limit: 240)))
            }
        }
        for item in (value["close"].elements ?? []).prefix(60) {
            if let open = number(item["item"]) {
                plan.closes.append(.init(item: open, by: number(item["by"]), why: DeckMemoryFlowHelperPrompt.clean(item["why"].string, limit: 240)))
            }
        }
        for item in (value["missed"].elements ?? []).prefix(8) {
            let text = DeckMemoryFlowHelperPrompt.clean(item["text"].string, limit: 1_200)
            guard !text.isEmpty else { continue }
            var title = DeckMemoryFlowHelperPrompt.clean(item["title"].string, limit: 120)
            if title.isEmpty { title = String(text.prefix(60)) }
            plan.missed.append(.init(type: DeckMemoryFlowHelperPrompt.noteType(item["type"].string), title: title, text: text))
        }
        for item in (value["repeated"].elements ?? []).prefix(8) {
            let numbers = (item["notes"].elements ?? []).compactMap(number)
            if numbers.count >= 3 { plan.repeated.append(numbers) }
        }
        for item in (value["questions"].elements ?? []).prefix(8) {
            let text = DeckMemoryFlowHelperPrompt.clean(item["text"].string, limit: 300)
            guard !text.isEmpty else { continue }
            plan.questions.append(.init(text: text, context: DeckMemoryFlowHelperPrompt.clean(item["context"].string, limit: 400),
                                        notes: (item["notes"].elements ?? []).compactMap(number)))
        }
        return plan
    }
}
