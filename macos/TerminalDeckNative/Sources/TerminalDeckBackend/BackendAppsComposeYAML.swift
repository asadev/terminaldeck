import Foundation
import TerminalDeckNativeCore

/// A bounded YAML 1.2 subset for compose input, not a general YAML loader.
/// Supports indentation maps/lists, plain/single/JSON-double quoted scalars and
/// JSON flow collections. Never resolves aliases, tags, includes or env values.
public enum BackendAppsComposeYAML {
    public static func parse(_ text: String) throws -> NativeRPCValue {
        guard text.utf8.count <= 1_048_576 else { throw failure("The compose file exceeds the supported size.") }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard !normalized.unicodeScalars.contains(where: { $0.value == 9 || $0.value == 13 || ($0.value < 32 && $0.value != 10) || $0.value == 127 }) else {
            throw failure("Compose YAML cannot contain tabs or raw control characters.")
        }
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw failure("The compose file is empty.") }
        // Dispatch collections directly to the bounded reader. Do not probe
        // through the display-oriented OrderedJSON parser on untrusted input.
        if trimmed.first == "{" || trimmed.first == "[" {
            var flow = BackendAppsComposeJSON(bytes: Array(trimmed.utf8), remainingNodes: 8192)
            return try flow.document(depth: 0)
        }
        var lines: [BackendAppsComposeLine] = []
        let rawLines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        guard rawLines.count <= 8192 else { throw failure("The compose file has too many lines.") }
        for (offset, raw) in rawLines.enumerated() {
            let bytes = Array(raw.utf8)
            let indent = bytes.prefix(while: { $0 == 32 }).count
            guard indent <= 128 else { throw failure("Compose YAML is nested too deeply.", line: offset + 1) }
            let content = try stripComment(Array(bytes.dropFirst(indent)), line: offset + 1)
            if content.isEmpty { continue }
            lines.append(.init(indent: indent, text: content, number: offset + 1))
        }
        if lines.first?.text == "---" { lines.removeFirst() }
        if lines.last?.text == "..." { lines.removeLast() }
        guard !lines.isEmpty, lines.first?.indent == 0 else { throw failure("Compose YAML must start with an unindented mapping.") }
        guard !lines.contains(where: { $0.text == "---" || $0.text == "..." || $0.text.hasPrefix("%") }) else {
            throw failure("YAML directives and multiple documents are not supported.")
        }
        var parser = BackendAppsComposeBlock(lines: lines)
        let value = try parser.block(indent: 0, depth: 0)
        guard parser.index == lines.count else { throw failure("Compose YAML has inconsistent indentation.", line: lines[parser.index].number) }
        return value
    }

    fileprivate static func failure(_ message: String, line: Int? = nil) -> NativeRPCError {
        BackendAppsRuntime.unavailable(message + (line.map { " Check line \($0)." } ?? "") + " Use plain mappings, lists and quoted values.")
    }

    private static func stripComment(_ bytes: [UInt8], line: Int) throws -> String {
        var quote: UInt8?
        var index = 0
        var end = bytes.count
        while index < bytes.count {
            let byte = bytes[index]
            if let active = quote {
                if active == 34, byte == 92 { index += 2; continue }
                if byte == active {
                    if active == 39, index + 1 < bytes.count, bytes[index + 1] == 39 { index += 2; continue }
                    quote = nil
                }
            } else if byte == 34 || byte == 39 { quote = byte }
            else if byte == 35, index == 0 || bytes[index - 1] == 32 { end = index; break }
            index += 1
        }
        guard quote == nil else { throw failure("A quoted YAML value is incomplete or spans multiple lines.", line: line) }
        return String(decoding: bytes.prefix(end), as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}

private struct BackendAppsComposeLine {
    let indent: Int
    let text: String
    let number: Int
    var sequence: Bool { text == "-" || text.hasPrefix("- ") }
}

private struct BackendAppsComposeBlock {
    let lines: [BackendAppsComposeLine]
    var index = 0
    var remainingNodes = 8192

    mutating func block(indent: Int, depth: Int) throws -> NativeRPCValue {
        try consume(depth)
        guard index < lines.count, lines[index].indent == indent else { throw error("Compose YAML has inconsistent indentation.") }
        if lines[index].sequence { return try sequence(indent: indent, depth: depth) }
        return try mapping(indent: indent, depth: depth)
    }

    private mutating func mapping(indent: Int, depth: Int) throws -> NativeRPCValue {
        var fields: [NativeRPCValue.Field] = []
        var keys: Set<String> = []
        while index < lines.count, lines[index].indent >= indent {
            let line = lines[index]
            guard line.indent == indent, !line.sequence else { throw error("Compose YAML mixes mapping and list indentation.") }
            let (keyText, valueText) = try entry(line.text)
            guard let key = try scalar(keyText, depth: depth + 1).string, !key.isEmpty, key != "<<", keys.insert(key).inserted else {
                throw error("Compose YAML has a duplicate, non-text or merge key.")
            }
            index += 1
            let value: NativeRPCValue
            if !valueText.isEmpty {
                value = try scalar(valueText, depth: depth + 1)
                if index < lines.count, lines[index].indent > indent { throw error("Multiline plain values are not supported.") }
            } else if index < lines.count, lines[index].indent > indent {
                value = try block(indent: lines[index].indent, depth: depth + 1)
            } else if index < lines.count, lines[index].indent == indent, lines[index].sequence {
                // YAML permits an indentationless list after a mapping key.
                try consume(depth + 1)
                value = try sequence(indent: indent, depth: depth + 1)
            } else { value = .null }
            fields.append(.init(key, value))
        }
        return .object(fields)
    }

    private mutating func sequence(indent: Int, depth: Int) throws -> NativeRPCValue {
        var values: [NativeRPCValue] = []
        while index < lines.count, lines[index].indent == indent, lines[index].sequence {
            let text = String(lines[index].text.dropFirst()).trimmingCharacters(in: .whitespaces)
            index += 1
            if !text.isEmpty {
                values.append(try scalar(text, depth: depth + 1))
                if index < lines.count, lines[index].indent > indent { throw error("Inline list mappings and multiline plain values are not supported. Use JSON flow objects for list mappings.") }
            } else if index < lines.count, lines[index].indent > indent {
                values.append(try block(indent: lines[index].indent, depth: depth + 1))
            } else { try consume(depth + 1); values.append(.null) }
        }
        return .array(values)
    }

    private func entry(_ text: String) throws -> (String, String) {
        let bytes = Array(text.utf8)
        var quote: UInt8?
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if let active = quote {
                if active == 34, byte == 92 { index += 2; continue }
                if byte == active {
                    if active == 39, index + 1 < bytes.count, bytes[index + 1] == 39 { index += 2; continue }
                    quote = nil
                }
            } else if byte == 34 || byte == 39 { quote = byte }
            else if byte == 58, index + 1 == bytes.count || bytes[index + 1] == 32 {
                let key = String(decoding: bytes.prefix(index), as: UTF8.self).trimmingCharacters(in: .whitespaces)
                let value = String(decoding: bytes.dropFirst(index + 1), as: UTF8.self).trimmingCharacters(in: .whitespaces)
                return (key, value)
            }
            index += 1
        }
        throw error("Each compose YAML mapping entry needs a key followed by a colon.")
    }

    private mutating func scalar(_ text: String, depth: Int) throws -> NativeRPCValue {
        guard text.utf8.count <= 65_536 else { throw error("A compose YAML value is too large.") }
        if text.first == "{" || text.first == "[" {
            var flow = BackendAppsComposeJSON(bytes: Array(text.utf8), remainingNodes: remainingNodes)
            let value = try flow.document(depth: depth)
            remainingNodes = flow.remainingNodes
            return value
        }
        try consume(depth)
        if text.first == "\"" {
            return .string(try BackendAppsComposeJSONString.decode(Array(text.utf8)))
        }
        if text.first == "'" {
            guard text.last == "'", text.utf8.count >= 2 else { throw error("A single-quoted YAML value is incomplete.") }
            let inner = Array(text.dropFirst().dropLast().utf8)
            var output: [UInt8] = []
            var at = 0
            while at < inner.count {
                if inner[at] == 39 {
                    guard at + 1 < inner.count, inner[at + 1] == 39 else { throw error("Single quotes inside YAML strings must be doubled.") }
                    output.append(39); at += 2
                } else { output.append(inner[at]); at += 1 }
            }
            return .string(String(decoding: output, as: UTF8.self))
        }
        guard !text.isEmpty, !["&", "*", "!", "|", ">", "@", "`", "%", "?", "]", "}", ","].contains(String(text.prefix(1))),
              text != "-", !text.hasPrefix("- "),
              !text.contains(": "), !text.hasSuffix(":"), !text.contains("\""), !text.contains("'") else {
            throw error("This YAML scalar uses unsupported syntax. Quote the value or use JSON flow collections.")
        }
        switch text.lowercased() {
        case "null", "~": return .null
        case "true": return .bool(true)
        case "false": return .bool(false)
        case ".inf", "+.inf", "-.inf", ".nan": throw error("Non-finite YAML numbers are not supported.")
        default: break
        }
        if BackendAppsComposeJSON.decimal(text) {
            guard let number = Double(text), number.isFinite else { throw error("Non-finite YAML numbers are not supported.") }
            guard number.rounded() != number || abs(number) <= 9_007_199_254_740_991 else { throw error("Quote large integer values to preserve their text exactly.") }
            return .number(number)
        }
        guard text.range(of: #"^[+-]?(?:[0-9]+|0[xXoObB][0-9a-fA-F]+|\.[0-9]+|[0-9]+\.[0-9]*|[0-9]+[eE][+-]?[0-9]+)$"#, options: .regularExpression) == nil else {
            throw error("YAML numbers must use finite JSON decimal syntax. Quote numeric-looking text.")
        }
        return .string(text)
    }

    private mutating func consume(_ depth: Int) throws {
        guard depth <= 32, remainingNodes > 0 else { throw error("The compose YAML exceeds the supported nesting or item limit.") }
        remainingNodes -= 1
    }
    private func error(_ message: String) -> NativeRPCError { BackendAppsComposeYAML.failure(message, line: index < lines.count ? lines[index].number : lines.last?.number) }
}

/// Strict JSON flow reader with bounded depth/nodes and duplicate-key checks.
private struct BackendAppsComposeJSON {
    let bytes: [UInt8]
    var at = 0
    var remainingNodes: Int

    mutating func document(depth: Int) throws -> NativeRPCValue {
        let result = try value(depth: depth)
        space()
        guard at == bytes.count else { throw error() }
        return result
    }
    private mutating func value(depth: Int) throws -> NativeRPCValue {
        guard depth <= 32, remainingNodes > 0 else { throw error("The compose file exceeds the supported nesting or item limit.") }
        remainingNodes -= 1
        space()
        guard at < bytes.count else { throw error() }
        if bytes[at] == 34 { return .string(try string()) }
        if bytes[at] == 123 {
            at += 1; space()
            var fields: [NativeRPCValue.Field] = []
            var keys: Set<String> = []
            if take(125) { return .object([]) }
            repeat {
                space()
                let key = try string()
                guard key != "<<", keys.insert(key).inserted else { throw error("The compose file has a duplicate or merge key.") }
                space(); guard take(58) else { throw error() }
                fields.append(.init(key, try value(depth: depth + 1)))
                space()
                if take(125) { return .object(fields) }
                guard take(44) else { throw error() }
            } while true
        }
        if bytes[at] == 91 {
            at += 1; space()
            var values: [NativeRPCValue] = []
            if take(93) { return .array([]) }
            repeat {
                values.append(try value(depth: depth + 1)); space()
                if take(93) { return .array(values) }
                guard take(44) else { throw error() }
            } while true
        }
        let start = at
        while at < bytes.count, ![UInt8(32), 9, 10, 13, 44, 93, 125].contains(bytes[at]) { at += 1 }
        let token = String(decoding: bytes[start..<at], as: UTF8.self)
        switch token {
        case "true": return .bool(true)
        case "false": return .bool(false)
        case "null": return .null
        default:
            guard Self.decimal(token), let number = Double(token), number.isFinite else { throw error() }
            guard number.rounded() != number || abs(number) <= 9_007_199_254_740_991 else { throw error("Quote large integer values to preserve their text exactly.") }
            return .number(number)
        }
    }
    private mutating func string() throws -> String {
        guard at < bytes.count, bytes[at] == 34 else { throw error() }
        let start = at
        at += 1
        while at < bytes.count {
            if bytes[at] == 92 { at += 2; continue }
            if bytes[at] == 34 {
                at += 1
                guard at - start <= 65_536 else { throw error() }
                return try BackendAppsComposeJSONString.decode(Array(bytes[start..<at]))
            }
            at += 1
        }
        throw error()
    }
    private mutating func space() { while at < bytes.count, [UInt8(32), 9, 10, 13].contains(bytes[at]) { at += 1 } }
    private mutating func take(_ byte: UInt8) -> Bool { guard at < bytes.count, bytes[at] == byte else { return false }; at += 1; return true }
    fileprivate static func decimal(_ text: String) -> Bool { text.range(of: #"^-?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil }
    private func error(_ message: String = "Flow collections must use valid JSON arrays or objects.") -> NativeRPCError { BackendAppsComposeYAML.failure(message) }
}

/// Reject malformed UTF-16 escapes before Foundation decoding; the core
/// display parser must never see an unchecked high/low surrogate pair.
private enum BackendAppsComposeJSONString {
    static func decode(_ bytes: [UInt8]) throws -> String {
        guard bytes.count >= 2, bytes.first == 34, bytes.last == 34 else { throw error() }
        let end = bytes.count - 1
        var at = 1
        while at < end {
            guard bytes[at] >= 32, bytes[at] != 34 else { throw error() }
            if bytes[at] != 92 { at += 1; continue }
            guard at + 1 < end else { throw error() }
            if bytes[at + 1] != 117 {
                guard [UInt8(34), 92, 47, 98, 102, 110, 114, 116].contains(bytes[at + 1]) else { throw error() }
                at += 2; continue
            }
            guard at + 5 < end, let first = hex4(bytes, at: at + 2) else { throw error() }
            if (0xD800...0xDBFF).contains(first) {
                guard at + 11 < end, bytes[at + 6] == 92, bytes[at + 7] == 117,
                      let second = hex4(bytes, at: at + 8), (0xDC00...0xDFFF).contains(second) else { throw error() }
                at += 12
            } else {
                guard !(0xDC00...0xDFFF).contains(first) else { throw error() }
                at += 6
            }
        }
        do { return try JSONDecoder().decode(String.self, from: Data(bytes)) }
        catch { throw Self.error() }
    }
    private static func hex4(_ bytes: [UInt8], at: Int) -> UInt32? {
        guard at + 3 < bytes.count else { return nil }
        var result: UInt32 = 0
        for byte in bytes[at...at + 3] {
            let nibble: UInt32
            switch byte {
            case 48...57: nibble = UInt32(byte - 48)
            case 65...70: nibble = UInt32(byte - 55)
            case 97...102: nibble = UInt32(byte - 87)
            default: return nil
            }
            result = result * 16 + nibble
        }
        return result
    }
    private static func error() -> NativeRPCError { BackendAppsComposeYAML.failure("Quoted values must use valid JSON string escapes and Unicode pairs.") }
}
