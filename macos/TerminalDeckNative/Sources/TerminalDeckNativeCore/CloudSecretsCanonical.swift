import Foundation
import JavaScriptCore

/// RFC 8785 uses ECMAScript's own string and number encodings. Keep this in V's
/// prefix until the shared CloudWire formatter is corrected by its owner.
///
/// Secrets pass through here (the root-carrying device and recovery bodies,
/// every secret record). So:
/// - Everything is native Swift: strings, booleans, null, arrays, objects and
///   numbers. Output is byte-identical to the ECMAScript formatter (UTF-16 key
///   order, JSON.stringify string escapes, Number::toString for numbers, built
///   from Swift's shortest round-trip digits). No JavaScript engine is started
///   per record (cookie expiry times are fractional; round-4 review S4).
/// - JavaScriptCore remains only as a fallback if a number's digits cannot be
///   read (not expected), in a throwaway virtual machine for that one call,
///   and as the reference the tests compare against.
/// - The intermediate UTF-8 buffers are zeroed. Swift `String` values parsed
///   from them cannot be zeroed; they are released when the call ends.
public enum CloudSecretsCanonical {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        var encoded = try JSONEncoder().encode(value)
        defer { encoded.resetBytes(in: 0..<encoded.count) }
        // Preserve the contract's duplicate-key/depth/size checks.
        _ = try CloudWire.decode(CloudValue.self, from: encoded, maximumBytes: CloudWire.maximumBlobBytes)
        let parsed = try NativeRPCValue.parseJSON(encoded, maximumBytes: CloudWire.maximumBlobBytes)
        var output = Data()
        output.reserveCapacity(encoded.count)
        if emit(parsed, into: &output) { return output }
        output.resetBytes(in: 0..<output.count)
        return try isolatedRender(encoded)
    }

    /// Native RFC 8785. Returns false (caller falls back) only if a number's
    /// shortest digits cannot be read.
    static func emit(_ value: NativeRPCValue, into output: inout Data) -> Bool {
        switch value {
        case .null: output.append(contentsOf: Array("null".utf8)); return true
        case .bool(let flag): output.append(contentsOf: Array((flag ? "true" : "false").utf8)); return true
        case .number(let number):
            guard let text = ecmaScript(number) else { return false }
            output.append(contentsOf: Array(text.utf8))
            return true
        case .string(let text): string(text, into: &output); return true
        case .array(let items):
            output.append(UInt8(ascii: "["))
            for (index, item) in items.enumerated() {
                if index > 0 { output.append(UInt8(ascii: ",")) }
                guard emit(item, into: &output) else { return false }
            }
            output.append(UInt8(ascii: "]")); return true
        case .object(let fields):
            // ECMAScript Array.prototype.sort on keys: UTF-16 code unit order.
            let sorted = fields.sorted { $0.key.utf16.lexicographicallyPrecedes($1.key.utf16) }
            output.append(UInt8(ascii: "{"))
            for (index, field) in sorted.enumerated() {
                if index > 0 { output.append(UInt8(ascii: ",")) }
                string(field.key, into: &output)
                output.append(UInt8(ascii: ":"))
                guard emit(field.value, into: &output) else { return false }
            }
            output.append(UInt8(ascii: "}")); return true
        case .bytes, .missing: return false
        }
    }
    /// ECMAScript Number::toString (ES2023 §6.1.6.1.20) from Swift's shortest
    /// round-trip digits. Numbers are never secret; nil only if unreadable.
    static func ecmaScript(_ number: Double) -> String? {
        guard number.isFinite else { return nil }
        if number == 0 { return "0" } // also -0
        let text = abs(number).description // e.g. "1.5", "1e-07", "1.2345e+20", "100.0"
        let parts = text.split(separator: "e", omittingEmptySubsequences: false)
        guard parts.count <= 2, let exponent = parts.count == 2 ? Int(parts[1]) : 0 else { return nil }
        let mantissa = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard mantissa.count <= 2, mantissa.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return nil }
        let whole = String(mantissa[0]), fraction = mantissa.count == 2 ? String(mantissa[1]) : ""
        var digits = Array(whole + fraction)
        var point = whole.count + exponent // value = 0.digits × 10^point
        while digits.first == "0" { digits.removeFirst(); point -= 1 }
        while digits.last == "0" { digits.removeLast() }
        guard !digits.isEmpty else { return nil }
        let k = digits.count, n = point, d = String(digits)
        let body: String
        if k <= n && n <= 21 { body = d + String(repeating: "0", count: n - k) }
        else if 0 < n && n <= 21 { body = String(digits[0..<n]) + "." + String(digits[n...]) }
        else if -6 < n && n <= 0 { body = "0." + String(repeating: "0", count: -n) + d }
        else {
            let e = n - 1, sign = e < 0 ? "-" : "+"
            body = (k == 1 ? d : String(digits[0]) + "." + String(digits[1...])) + "e" + sign + String(abs(e))
        }
        return (number < 0 ? "-" : "") + body
    }
    /// JSON.stringify string form, copied byte by byte. Every escape is ASCII,
    /// and multi-byte UTF-8 bytes are all ≥ 0x80, so bytes need no decoding.
    /// Swift strings hold no lone surrogates.
    private static func string(_ text: String, into output: inout Data) {
        output.append(UInt8(ascii: "\""))
        for byte in text.utf8 {
            switch byte {
            case 0x22: output.append(contentsOf: [0x5C, 0x22])
            case 0x5C: output.append(contentsOf: [0x5C, 0x5C])
            case 0x08: output.append(contentsOf: [0x5C, UInt8(ascii: "b")])
            case 0x0C: output.append(contentsOf: [0x5C, UInt8(ascii: "f")])
            case 0x0A: output.append(contentsOf: [0x5C, UInt8(ascii: "n")])
            case 0x0D: output.append(contentsOf: [0x5C, UInt8(ascii: "r")])
            case 0x09: output.append(contentsOf: [0x5C, UInt8(ascii: "t")])
            case 0x00..<0x20:
                let hex = Array("0123456789abcdef".utf8)
                output.append(contentsOf: [0x5C, UInt8(ascii: "u"), 0x30, 0x30, hex[Int(byte >> 4)], hex[Int(byte & 0x0F)]])
            default: output.append(byte)
            }
        }
        output.append(UInt8(ascii: "\""))
    }

    /// ECMAScript formatter in a throwaway virtual machine for this call only.
    /// Internal so tests can compare it with the native path byte for byte.
    static func isolatedRender(_ input: Data) throws -> Data {
        try autoreleasepool {
            guard let machine = JSVirtualMachine(), let context = JSContext(virtualMachine: machine),
                  let serializer = context.evaluateScript(#"""
                  (function(input) {
                      const item = JSON.parse(input);
                      function emit(value) {
                          if (value === null || typeof value !== 'object') return JSON.stringify(value);
                          if (Array.isArray(value)) return '[' + value.map(emit).join(',') + ']';
                          const names = Object.keys(value).sort();
                          return '{' + names.map(name => JSON.stringify(name) + ':' + emit(value[name])).join(',') + '}';
                      }
                      return emit(item);
                  })
                  """#) else { throw CloudFailure.unavailable }
            defer { JSGarbageCollect(context.jsGlobalContextRef) }
            guard let result = serializer.call(withArguments: [String(decoding: input, as: UTF8.self)]), context.exception == nil,
                  result.isString, let text = result.toString() else { throw CloudFailure.invalidRequest }
            return Data(text.utf8)
        }
    }
}
