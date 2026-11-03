import Foundation

/// The phone → Mac half of copy and paste for an Android device (#56/#57). Android blocks apps from
/// reading the clipboard in the background, but adb's shell may (READ_CLIPBOARD_IN_BACKGROUND), so the
/// panel asks the clipboard service directly:
///   adb -s <serial> shell service call clipboard 4 s16 com.android.shell s16 '' i32 0 i32 0
/// (IClipboard.getPrimaryClip). The answer is a printed Parcel. This reads the clip's text out of it:
/// the first string after the clip's MIME types, written as UTF-8 (Android 12+) or UTF-16 (older).
/// Nothing on the clipboard, a refusal, or a clip that is not text gives nil.
public enum AndroidClipParcel {
    /// The adb arguments that print the phone's clip.
    public static func arguments(serial: String) -> [String] {
        ["-s", serial, "shell", "service", "call", "clipboard", "4", "s16", "com.android.shell", "s16", "''", "i32", "0", "i32", "0"]
    }

    /// The bytes of a printed Parcel ("Result: Parcel(0x00000000: 00000000 00000001 … '…')"), little-endian words.
    public static func bytes(_ printed: String) -> [UInt8] {
        var out: [UInt8] = []
        for line in printed.components(separatedBy: "\n") {
            // Only the hex words: after the "0x…:" offset (when there is one), before the quoted text column.
            var body = Substring(line)
            if let colon = body.range(of: ": ") , body.contains("0x") { body = body[colon.upperBound...] }
            else if let open = body.range(of: "Parcel(") { body = body[open.upperBound...] }
            if let quote = body.firstIndex(of: "'") { body = body[..<quote] }
            for word in body.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                guard word.count == 8, let value = UInt32(word, radix: 16) else { continue }
                out += [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24 & 0xFF)]
            }
        }
        return out
    }

    /// The clip's text, or nil.
    public static func text(_ printed: String) -> String? {
        let data = bytes(printed)
        guard data.count >= 8, int(data, 0) == 0, int(data, 4) != 0 else { return nil } // no exception; a clip is there
        // The MIME types are UTF-16 strings; the text comes after the last of them.
        var at = 8, afterMime: Int?
        while at + 4 <= data.count {
            if let (value, next) = utf16(data, at), value.contains("/"), value.range(of: #"^[a-z]+/[a-z0-9.+*-]+$"#, options: .regularExpression) != nil {
                afterMime = next; at = next; continue
            }
            at += 4
        }
        guard var at = afterMime else { return nil }
        while at + 4 <= data.count {
            if let (value, _) = utf8(data, at) ?? utf16(data, at), !value.isEmpty { return value }
            at += 4
        }
        return nil
    }

    private static func int(_ data: [UInt8], _ at: Int) -> Int32 {
        guard at + 4 <= data.count else { return 0 }
        return Int32(bitPattern: UInt32(data[at]) | UInt32(data[at + 1]) << 8 | UInt32(data[at + 2]) << 16 | UInt32(data[at + 3]) << 24)
    }

    /// writeString8: length, the bytes, a NUL, padded to 4. Only text with no control characters counts.
    private static func utf8(_ data: [UInt8], _ at: Int) -> (String, Int)? {
        let length = Int(int(data, at))
        guard length > 0, length < 1 << 20, at + 4 + length < data.count, data[at + 4 + length] == 0 else { return nil }
        let raw = Array(data[(at + 4)..<(at + 4 + length)])
        guard let text = String(bytes: raw, encoding: .utf8), printable(text) else { return nil }
        return (text, at + 4 + (length + 1 + 3) / 4 * 4)
    }

    /// writeString16: length in UTF-16 units, the units, a 0 unit, padded to 4.
    private static func utf16(_ data: [UInt8], _ at: Int) -> (String, Int)? {
        let length = Int(int(data, at))
        let end = at + 4 + length * 2
        guard length > 0, length < 1 << 19, end + 2 <= data.count, data[end] == 0, data[end + 1] == 0 else { return nil }
        var units: [UInt16] = []
        for i in stride(from: at + 4, to: end, by: 2) { units.append(UInt16(data[i]) | UInt16(data[i + 1]) << 8) }
        let text = String(decoding: units, as: UTF16.self)
        guard !text.contains("\u{FFFD}"), printable(text) else { return nil }
        return (text, at + 4 + (length * 2 + 2 + 3) / 4 * 4)
    }

    private static func printable(_ text: String) -> Bool {
        !text.unicodeScalars.contains { $0.value < 0x20 && $0 != "\n" && $0 != "\t" && $0 != "\r" }
    }
}
