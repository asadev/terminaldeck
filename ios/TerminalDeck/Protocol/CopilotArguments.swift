/**
 * The arguments of a pending confirmation, **verbatim and in the order the tool
 * wrote them**.
 *
 * This file exists because of one sentence in `COPILOT-REMOTE.md` §4.3 and the
 * failure it names: *a consent prompt without enough context becomes a reflex
 * Yes, and a gate that is always answered yes is worse than no gate, because it
 * looks like protection.* `CopilotConsentQuestion.args` is the field that turns
 * the prompt from a shape into a decision, so how it is rendered is not a
 * presentation detail — it is the whole difference between showing somebody what
 * they are approving and showing them something that resembles it.
 *
 * ## Why Foundation's JSON reader is not enough on its own
 *
 * Two reasons, and both of them are wrong answers rather than missing ones.
 *
 * **Order is lost.** `JSONSerialization` hands back an `NSDictionary`, which has
 * no order at all; the keys come out in hash order and that order is not even
 * stable between runs of the same build. The desktop composes `args` in the
 * tool's own declaration order, which is the order the desktop's own dialog
 * shows and the order the tool's documentation lists — so a phone that sorted
 * them, or worse left them in hash order, would be showing the same question in
 * a different shape from the machine, and two renderings of one consent prompt
 * is exactly how somebody approves one thing having read another.
 *
 * **Values render as Swift's debug description.** `String(describing:)` on the
 * `NSDictionary` a nested argument decodes to prints `{ key = value; }`, on an
 * `NSNumber` holding a JSON `true` prints `1`, and on `NSNull` prints `<null>`.
 * None of those is what the desktop sent. On a screen whose entire job is
 * *verbatim*, a boolean drawn as `1` is a misquote.
 *
 * So the frame is read a second time by the small parser below, which keeps the
 * key order and keeps every value as the text it arrived as. It runs only for
 * `copilot.ask` — at most three outstanding questions, arriving at human speed —
 * and never on the output path, where the cost would matter.
 *
 * ## What it deliberately does not do
 *
 * It does not summarise, truncate to a line, or re-word. A long argument is a
 * long argument; the sheet scrolls. `WireCodec.displayLine` — which flattens and
 * cuts at 200 characters — is right for a dev server's status line and would be
 * a way of hiding the second half of a command from the person approving it.
 * The one bound is on a single value's length, it is generous, and a value that
 * meets it is cut **and says so** — see `maxValueChars`. There is no bound on
 * how many arguments are drawn, for the reason given beside that constant.
 */

import Foundation

/// One argument, as the sheet draws it: the name the tool gave it, and the value
/// as JSON text.
///
/// `value` is a **string's own text** when the argument is a string — quoting
/// `"light"` on screen would be showing somebody JSON rather than showing them
/// what is about to happen — and the JSON spelling of anything else, so a
/// boolean reads `true`, a null reads `null`, and a nested object reads as the
/// object. That split is the one place this type is not literally verbatim, and
/// it is the place where being literal would be less honest.
struct CopilotArgument: Equatable, Identifiable {
    let name: String
    let value: String

    var id: String { name }

    /// Whether the value wants a line of its own. A path, a command or a
    /// paragraph is unreadable squeezed against a label on a phone; a `true` or
    /// a number is unreadable given its own paragraph.
    var isBlock: Bool { value.count > 32 || value.contains("\n") }
}

enum CopilotArguments {

    /**
     * How much argument text one question may carry, in characters.
     *
     * Not a protocol constant. The desktop bounds the whole frame at
     * `MAX_MESSAGE_BYTES`, which is 64 KiB, and says nothing about how much of
     * it may be one field — so this is the phone deciding what it will draw. It
     * is generous on purpose: cutting an argument is cutting the thing being
     * approved, so the cap is high enough that no real call reaches it and low
     * enough that a host cannot make this sheet render 64 KiB of text under a
     * two-minute countdown.
     *
     * A value that would exceed it is cut **and says so**, which is the same
     * rule `CopilotChatMessage.truncated` follows and for a sharper reason: a
     * shortened argument that does not announce itself is a consent prompt that
     * misquotes the request it is asking about.
     */
    static let maxValueChars = 4 * 1024

    /*
     * There is deliberately **no cap on the number of arguments.**
     *
     * One was written here and taken out again, because a cap on the count is a
     * cap on what a person is shown before they approve something — and the
     * honest ways to have one are both worse than not having one: silently
     * drawing a prefix hides part of the request, and saying "and 3 more" is a
     * consent prompt admitting it did not show the request. The bound that
     * matters already exists one layer out: the whole frame is limited to
     * `MAX_MESSAGE_BYTES`, 64 KiB, by the desktop and by the sealed envelope, so
     * a host cannot make this sheet render more than that however it composes
     * the object. What is capped here is the *length of one value*, which is a
     * different question and is answered — visibly — by `maxValueChars`.
     */

    /**
     * The `args` of a `copilot.ask`, from the raw frame, in document order.
     *
     * Nil when the frame is not one, when there is no `args` object in it, or
     * when the text will not parse — never a partial answer, because the caller
     * has a fallback that is honest about being one and a half-read argument
     * list is not.
     */
    static func fromAsk(rawFrame: String) -> [CopilotArgument]? {
        guard case let .object(frame)? = OrderedJSON.parse(rawFrame),
              case let .object(question)? = frame.first(where: { $0.name == "question" })?.value,
              case let .object(args)? = question.first(where: { $0.name == "args" })?.value else {
            return nil
        }
        return args.map { member in
            CopilotArgument(name: member.name, value: render(member.value))
        }
    }

    /**
     * The same list from an already-parsed dictionary, **sorted by name**.
     *
     * The fallback, for a frame the ordered reader could not take a second look
     * at — a host that sent something structurally odd, or a caller that has the
     * object and not the text. It is deliberately sorted rather than left in the
     * dictionary's own order: hash order is not stable between runs, so the same
     * question would draw differently twice, and a consent screen that reshuffles
     * itself is one somebody stops reading.
     *
     * The sheet says which of the two it is showing. *Ordered as the tool wrote
     * them* and *ordered by name* are different claims and only one of them is
     * true at a time.
     */
    static func sorted(_ args: [String: Any]) -> [CopilotArgument] {
        args.keys.sorted().map { name in
            CopilotArgument(name: name, value: render(foundation: args[name]))
        }
    }

    // MARK: - Rendering

    private static func render(_ value: OrderedJSON) -> String {
        cut(value.rendered)
    }

    /// A value that came through `JSONSerialization` rather than the reader
    /// below. Re-serialised rather than described, because `String(describing:)`
    /// on the objects that reader produces prints Objective-C debug output —
    /// `{ key = value; }` for a nested argument and `1` for a boolean — and this
    /// is a screen where a boolean drawn as `1` is a misquote.
    private static func render(foundation value: Any?) -> String {
        if value == nil || value is NSNull { return "null" }
        if let text = value as? String { return cut(text) }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return cut(number.stringValue)
        }
        guard JSONSerialization.isValidJSONObject(value as Any),
              let data = try? JSONSerialization.data(withJSONObject: value as Any,
                                                     options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            // Unreachable for anything that arrived as JSON. A described value is
            // still better than a blank row, because a blank row would read as
            // "this argument is empty" rather than "this build could not draw
            // it" — and those are different things to approve.
            return cut(String(describing: value ?? "null"))
        }
        return cut(text)
    }

    /// Long values are cut **and say so**. See `maxValueChars`.
    private static func cut(_ text: String) -> String {
        guard text.count > maxValueChars else { return text }
        return String(text.prefix(maxValueChars)) + "\n… shortened — the whole value is on the machine."
    }
}

/**
 * JSON, with object keys in the order they were written.
 *
 * A parser here rather than `JSONSerialization` for the two reasons this file's
 * header gives, and written to be boring: recursive descent, no reflection, no
 * partial results, and a depth limit so a hostile frame is a refusal rather than
 * a stack overflow on a socket callback. Everything it produces is either a
 * whole value or nil.
 *
 * It is **not** a general replacement for the codec's reader and must not become
 * one. `WireCodec.decode` runs on every frame including terminal output, where
 * Foundation's reader is both faster and already trusted; this runs on the one
 * frame whose field order is part of what it means.
 */
indirect enum OrderedJSON: Equatable {

    struct Member: Equatable {
        let name: String
        let value: OrderedJSON
    }

    case object([Member])
    case array([OrderedJSON])
    case string(String)
    /**
     * The number as it was written, not as a `Double`.
     *
     * `1e3` and `1000` are the same number and are not the same text, and a
     * consent screen showing an argument the tool wrote as `0.1` as `0.1000000…`
     * would be inventing precision nobody asked for. Nothing here does
     * arithmetic on it.
     */
    case number(String)
    case bool(Bool)
    case null

    /// How deep a value may nest. Sixty-four is far past anything a tool's
    /// arguments contain and far short of what a recursive parser can survive on
    /// a socket callback's stack.
    static let maxDepth = 64

    static func parse(_ text: String) -> OrderedJSON? {
        var reader = Reader(Array(text.unicodeScalars))
        guard let value = reader.value(depth: 0) else { return nil }
        reader.skipSpace()
        // Trailing anything means this was not one document, and a parser that
        // ignores the tail is one that accepts two frames concatenated.
        return reader.done ? value : nil
    }

    /// What the sheet draws. A string is its own text; everything else is its
    /// JSON spelling. See `CopilotArgument.value`.
    var rendered: String {
        switch self {
        case let .string(text): return text
        default: return json
        }
    }

    /// The JSON spelling of this value, keys in their original order.
    var json: String {
        switch self {
        case let .object(members):
            return "{" + members.map { "\(OrderedJSON.quote($0.name)):\($0.value.json)" }
                .joined(separator: ",") + "}"
        case let .array(values):
            return "[" + values.map(\.json).joined(separator: ",") + "]"
        case let .string(text): return OrderedJSON.quote(text)
        case let .number(text): return text
        case let .bool(flag): return flag ? "true" : "false"
        case .null: return "null"
        }
    }

    private static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    /// The scanner. A struct over a scalar array rather than a `String.Index`
    /// walk, because indexing a `String` by grapheme while parsing JSON escapes
    /// is a way to split a surrogate pair without noticing.
    private struct Reader {
        private let scalars: [Unicode.Scalar]
        private var at = 0

        init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }

        var done: Bool { at >= scalars.count }

        mutating func skipSpace() {
            while at < scalars.count {
                switch scalars[at] {
                case " ", "\t", "\n", "\r": at += 1
                default: return
                }
            }
        }

        mutating func value(depth: Int) -> OrderedJSON? {
            guard depth <= OrderedJSON.maxDepth else { return nil }
            skipSpace()
            guard at < scalars.count else { return nil }
            switch scalars[at] {
            case "{": return object(depth: depth)
            case "[": return array(depth: depth)
            case "\"": return string().map { .string($0) }
            case "t": return literal("true").map { _ in .bool(true) }
            case "f": return literal("false").map { _ in .bool(false) }
            case "n": return literal("null").map { _ in .null }
            default: return number()
            }
        }

        private mutating func object(depth: Int) -> OrderedJSON? {
            at += 1  // {
            var members: [Member] = []
            skipSpace()
            if at < scalars.count, scalars[at] == "}" {
                at += 1
                return .object(members)
            }
            while true {
                skipSpace()
                guard let name = string() else { return nil }
                skipSpace()
                guard at < scalars.count, scalars[at] == ":" else { return nil }
                at += 1
                guard let value = value(depth: depth + 1) else { return nil }
                // Last one wins, matching every JSON reader in this product
                // including Foundation's — and a duplicate key is not silently
                // drawn twice on a consent sheet.
                members.removeAll { $0.name == name }
                members.append(Member(name: name, value: value))
                skipSpace()
                guard at < scalars.count else { return nil }
                if scalars[at] == "," { at += 1; continue }
                if scalars[at] == "}" { at += 1; return .object(members) }
                return nil
            }
        }

        private mutating func array(depth: Int) -> OrderedJSON? {
            at += 1  // [
            var values: [OrderedJSON] = []
            skipSpace()
            if at < scalars.count, scalars[at] == "]" {
                at += 1
                return .array(values)
            }
            while true {
                guard let value = value(depth: depth + 1) else { return nil }
                values.append(value)
                skipSpace()
                guard at < scalars.count else { return nil }
                if scalars[at] == "," { at += 1; continue }
                if scalars[at] == "]" { at += 1; return .array(values) }
                return nil
            }
        }

        private mutating func string() -> String? {
            guard at < scalars.count, scalars[at] == "\"" else { return nil }
            at += 1
            var out = String.UnicodeScalarView()
            while at < scalars.count {
                let scalar = scalars[at]
                at += 1
                if scalar == "\"" { return String(out) }
                if scalar != "\\" {
                    // A raw control character is not legal JSON, and accepting
                    // one would let a host put a carriage return into an
                    // argument name.
                    if scalar.value < 0x20 { return nil }
                    out.append(scalar)
                    continue
                }
                guard at < scalars.count else { return nil }
                let escape = scalars[at]
                at += 1
                switch escape {
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "/": out.append("/")
                case "b": out.append(Unicode.Scalar(8))
                case "f": out.append(Unicode.Scalar(12))
                case "n": out.append("\n")
                case "r": out.append("\r")
                case "t": out.append("\t")
                case "u":
                    guard let unit = hex4() else { return nil }
                    // A high surrogate is only half a character. Pairing them
                    // here is what keeps an emoji in an argument from arriving
                    // as two replacement characters.
                    if unit >= 0xD800, unit <= 0xDBFF {
                        guard at + 1 < scalars.count, scalars[at] == "\\", scalars[at + 1] == "u" else {
                            return nil
                        }
                        at += 2
                        guard let low = hex4(), low >= 0xDC00, low <= 0xDFFF else { return nil }
                        let combined = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                        guard let scalar = Unicode.Scalar(combined) else { return nil }
                        out.append(scalar)
                    } else if unit >= 0xDC00, unit <= 0xDFFF {
                        return nil
                    } else {
                        guard let scalar = Unicode.Scalar(unit) else { return nil }
                        out.append(scalar)
                    }
                default: return nil
                }
            }
            return nil
        }

        private mutating func hex4() -> UInt32? {
            guard at + 3 < scalars.count else { return nil }
            var value: UInt32 = 0
            for _ in 0 ..< 4 {
                let scalar = scalars[at]
                at += 1
                guard let digit = scalar.hexDigit else { return nil }
                value = value << 4 | digit
            }
            return value
        }

        private mutating func number() -> OrderedJSON? {
            let start = at
            if at < scalars.count, scalars[at] == "-" { at += 1 }
            guard at < scalars.count, scalars[at].isASCIIDigit else { return nil }
            /*
             * A leading zero is not a number, and this loop used to accept one.
             *
             * JSON's grammar is `0` **or** a digit 1-9 followed by any digits;
             * `01` is two tokens, not one, and a parser that swallows both reads
             * a malformed frame as a valid one. `testMalformedInputIsRefusedRatherThanGuessedAt`
             * has always asserted this and was red against the old loop, which
             * counted digits and asked no more.
             *
             * Refusing the second digit rather than the whole token is what
             * makes it visible: `0` parses, `1` is left over, and the top-level
             * `parse` refuses trailing input — so the answer is nil, arrived at
             * by the same route as `{"a":1} {"b":2}`.
             */
            if scalars[at] == "0" {
                at += 1
            } else {
                while at < scalars.count, scalars[at].isASCIIDigit { at += 1 }
            }
            if at < scalars.count, scalars[at] == "." {
                at += 1
                var fraction = 0
                while at < scalars.count, scalars[at].isASCIIDigit { at += 1; fraction += 1 }
                guard fraction > 0 else { return nil }
            }
            if at < scalars.count, scalars[at] == "e" || scalars[at] == "E" {
                at += 1
                if at < scalars.count, scalars[at] == "+" || scalars[at] == "-" { at += 1 }
                var exponent = 0
                while at < scalars.count, scalars[at].isASCIIDigit { at += 1; exponent += 1 }
                guard exponent > 0 else { return nil }
            }
            return .number(String(String.UnicodeScalarView(scalars[start ..< at])))
        }

        private mutating func literal(_ word: String) -> Bool? {
            for expected in word.unicodeScalars {
                guard at < scalars.count, scalars[at] == expected else { return nil }
                at += 1
            }
            return true
        }
    }
}

private extension Unicode.Scalar {
    var isASCIIDigit: Bool { self >= "0" && self <= "9" }

    var hexDigit: UInt32? {
        if self >= "0" && self <= "9" { return value - 0x30 }
        if self >= "a" && self <= "f" { return value - 0x61 + 10 }
        if self >= "A" && self <= "F" { return value - 0x41 + 10 }
        return nil
    }
}
