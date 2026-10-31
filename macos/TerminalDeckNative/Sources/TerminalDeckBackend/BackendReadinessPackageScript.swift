import Foundation

/// U120 (#72): a readiness fix sets one script in package.json's own text. Key order, spacing and line ends
/// stay exactly as the person wrote them; only the one script line is added or its value replaced.
enum BackendReadinessPackageScript {
    /// `source` with `scripts[script]` set to `body`, or nil when the text is not one JSON object whose
    /// `scripts`, when present, is an object.
    static func setting(_ script: String, to body: String, in source: String) -> String? {
        let scan = Scan(bytes: Array(source.utf8))
        guard let key = encoded(script), let value = encoded(body),
              let top = scan.object(at: scan.space(0)), scan.space(top.close + 1) == scan.bytes.count else { return nil }
        let eol = source.contains("\r\n") ? "\r\n" : "\n", line = key + ": " + value
        let unit = top.members.first.flatMap { scan.indent($0.keyStart) }.flatMap { $0.isEmpty ? nil : $0 } ?? "  "
        let edit: (Range<Int>, String)
        if let scripts = top.members.last(where: { $0.key == "scripts" }) {
            guard let object = scan.object(at: scripts.valueStart) else { return nil }
            if let existing = object.members.last(where: { $0.key == script }) {
                edit = (existing.valueStart..<existing.valueEnd, value)
            } else if let last = object.members.last {
                edit = (last.valueEnd..<last.valueEnd, scan.indent(last.keyStart).map { "," + eol + $0 + line } ?? ", " + line)
            } else {
                let outer = scan.indent(scripts.keyStart) ?? ""
                edit = (object.open + 1..<object.close, eol + outer + unit + line + eol + outer)
            }
        } else if let last = top.members.last {
            let block = scan.indent(last.keyStart).map { "," + eol + $0 + "\"scripts\": {" + eol + $0 + unit + line + eol + $0 + "}" }
            edit = (last.valueEnd..<last.valueEnd, block ?? ", \"scripts\": {" + line + "}")
        } else {
            edit = (top.open + 1..<top.close, eol + unit + "\"scripts\": {" + eol + unit + unit + line + eol + unit + "}" + eol)
        }
        var bytes = scan.bytes
        bytes.replaceSubrange(edit.0, with: Array(edit.1.utf8))
        return String(decoding: bytes, as: UTF8.self)
    }

    /// `text` as one JSON string, quotes included.
    private static func encoded(_ text: String) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes]) else { return nil }
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    /// Just enough JSON reading to find where members start and end; JSON's structure is all ASCII.
    private struct Scan {
        struct Member { let key: String, keyStart: Int, valueStart: Int, valueEnd: Int }
        struct Object { let open: Int, close: Int, members: [Member] }
        let bytes: [UInt8]

        func space(_ index: Int) -> Int {
            var index = index
            while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
            return index
        }
        /// Just after the string opening at `index`.
        func string(_ index: Int) -> Int? {
            guard index < bytes.count, bytes[index] == 0x22 else { return nil }
            var at = index + 1
            while at < bytes.count {
                if bytes[at] == 0x5C { at += 2; continue }
                if bytes[at] == 0x22 { return at + 1 }
                at += 1
            }
            return nil
        }
        /// Just after the value starting at `index`.
        func value(_ index: Int) -> Int? {
            guard index < bytes.count else { return nil }
            switch bytes[index] {
            case 0x22: return string(index)
            case 0x7B, 0x5B:
                var depth = 0, at = index
                while at < bytes.count {
                    switch bytes[at] {
                    case 0x22: guard let end = string(at) else { return nil }; at = end; continue
                    case 0x7B, 0x5B: depth += 1
                    case 0x7D, 0x5D: depth -= 1; if depth == 0 { return at + 1 }
                    default: break
                    }
                    at += 1
                }
                return nil
            default:
                var at = index
                while at < bytes.count, ![0x2C, 0x7D, 0x5D, 0x20, 0x09, 0x0A, 0x0D].contains(bytes[at]) { at += 1 }
                return at > index ? at : nil
            }
        }
        func object(at index: Int) -> Object? {
            guard index < bytes.count, bytes[index] == 0x7B else { return nil }
            var members: [Member] = [], at = space(index + 1)
            if at < bytes.count, bytes[at] == 0x7D { return Object(open: index, close: at, members: []) }
            while true {
                guard let keyEnd = string(at) else { return nil }
                var next = space(keyEnd)
                guard next < bytes.count, bytes[next] == 0x3A else { return nil }
                next = space(next + 1)
                guard let end = value(next) else { return nil }
                members.append(Member(key: String(decoding: bytes[(at + 1)..<(keyEnd - 1)], as: UTF8.self), keyStart: at, valueStart: next, valueEnd: end))
                at = space(end)
                guard at < bytes.count else { return nil }
                if bytes[at] == 0x2C { at = space(at + 1); continue }
                return bytes[at] == 0x7D ? Object(open: index, close: at, members: members) : nil
            }
        }
        /// The spaces and tabs before `index` when nothing else comes before it on its line.
        func indent(_ index: Int) -> String? {
            var start = index
            while start > 0, bytes[start - 1] == 0x20 || bytes[start - 1] == 0x09 { start -= 1 }
            guard start > 0, bytes[start - 1] == 0x0A || bytes[start - 1] == 0x0D else { return nil }
            return String(decoding: bytes[start..<index], as: UTF8.self)
        }
    }
}
