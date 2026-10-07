import Foundation
import TerminalDeckNativeCore

/// ajv-formats 3.0.1 full mode, the version pinned in package-lock.json.
/// The MIT-licensed source regexp table is preserved as data and run only by
/// Apple's isolated ECMAScript regexp engine; calendar/numeric rules are Swift.
/// https://github.com/ajv-validator/ajv-formats/blob/v3.0.1/src/formats.ts
/// https://github.com/ajv-validator/ajv-formats/blob/v3.0.1/src/index.ts
/// addFormats defaults to full mode. Unknown formats fail open with strict:false.
///
/// Package evidence: SDK ^1.27.1 resolves to 1.30.0, Ajv to 8.20.0, and
/// ajv-formats to 3.0.1. The requested SDK v1.27.1 provider uses strict:false,
/// validateFormats:true, validateSchema:false, allErrors:true and addFormats().
/// Its v1.30.0 GitHub tag was not retrievable during this source-only port; the
/// helper implements the actual locked Ajv/Formats tables and explicit task
/// settings rather than claiming the absent SDK tag was inspected.
public enum BackendMcpClientJSONSchemaFormats {
    public static let knownFormats: Set<String> = ["date", "time", "date-time", "iso-time", "iso-date-time", "duration", "uri", "uri-reference", "uri-template", "url", "email", "hostname", "ipv4", "ipv6", "regex", "uuid", "json-pointer", "json-pointer-uri-fragment", "relative-json-pointer", "byte", "int32", "int64", "float", "double", "password", "binary"]

    /// Nil means an unknown format, ignored by the default non-strict Ajv.
    /// Known format validators apply only to their declared type. A wrong type
    /// passes this keyword; the schema's independent type keyword decides it.
    public static func check(_ format: String, value: NativeRPCValue) throws -> Bool? {
        guard knownFormats.contains(format) else { return nil }
        if ["password", "binary"].contains(format) { return true }
        if ["int32", "int64", "float", "double"].contains(format) {
            guard case .number(let number) = value else { return true }
            if format == "float" || format == "double" { return true }
            guard number.isFinite, number.rounded(.towardZero) == number else { return false }
            // The source's Int64 rule is merely Number.isInteger. It expressly
            // does not apply Int64/safe-integer bounds to a JavaScript number.
            return format == "int64" || (number >= -2_147_483_648 && number <= 2_147_483_647)
        }
        guard let string = value.string else { return true }
        switch format {
        case "date": return try date(string)
        case "time": return try time(string, strictTimeZone: true)
        case "iso-time": return try time(string, strictTimeZone: false)
        case "date-time": return try dateTime(string, strictTimeZone: true)
        case "iso-date-time": return try dateTime(string, strictTimeZone: false)
        case "uri":
            guard try BackendMcpClientJSONSchemaPattern.test(#"/|:"#, value: string) else { return false }
            return try BackendMcpClientJSONSchemaPattern.test(uri, flags: "i", value: string)
        case "regex":
            // ajv-formats is deliberately no-u here, and additionally refuses
            // an unescaped \Z preceded by a non-backslash character. Even the
            // unusual leading-\Z exception follows its exact source rule.
            if try BackendMcpClientJSONSchemaPattern.test(#"[^\\]\\Z"#, value: string) { return false }
            return try BackendMcpClientJSONSchemaPattern.validNonUnicodeExpression(string)
        default:
            guard let definition = expressions[format] else { throw NativeRPCError(code: "unavailable", message: "The known JSON Schema format \(format) has no native implementation.") }
            return try BackendMcpClientJSONSchemaPattern.test(definition.pattern, flags: definition.flags, value: string)
        }
    }

    private static func date(_ value: String) throws -> Bool {
        guard let found = try BackendMcpClientJSONSchemaPattern.captures(#"^(\d\d\d\d)-(\d\d)-(\d\d)$"#, value: value), found.count == 3,
              let year = Int(found[0] ?? ""), let month = Int(found[1] ?? ""), let day = Int(found[2] ?? ""),
              (1...12).contains(month), day >= 1 else { return false }
        let days = [0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        return day <= (month == 2 && leap ? 29 : days[month])
    }
    private static func time(_ value: String, strictTimeZone: Bool) throws -> Bool {
        guard let found = try BackendMcpClientJSONSchemaPattern.captures(#"^(\d\d):(\d\d):(\d\d(?:\.\d+)?)(z|([+-])(\d\d)(?::?(\d\d))?)?$"#, flags: "i", value: value), found.count == 7,
              let hour = Int(found[0] ?? ""), let minute = Int(found[1] ?? ""), let second = Double(found[2] ?? "") else { return false }
        let zoneHour = Int(found[5] ?? "0") ?? 0, zoneMinute = Int(found[6] ?? "0") ?? 0
        let sign = found[4] == "-" ? -1 : 1
        if zoneHour > 23 || zoneMinute > 59 || (strictTimeZone && found[3] == nil) { return false }
        if hour <= 23 && minute <= 59 && second < 60 { return true }
        let utcMinute = minute - zoneMinute * sign
        let utcHour = hour - zoneHour * sign - (utcMinute < 0 ? 1 : 0)
        // Preserves the source's exact leap-second arithmetic, including its
        // acceptance of unusual local hour/minute values mapping to this pair.
        return (utcHour == 23 || utcHour == -1) && (utcMinute == 59 || utcMinute == -1) && second < 61
    }
    private static func dateTime(_ value: String, strictTimeZone: Bool) throws -> Bool {
        // Equivalent to str.split(/t|\s/i). Character.isWhitespace is broader
        // than ECMAScript and treats CRLF as one Character, so use the exact
        // WhiteSpace/LineTerminator code points and preserve empty components.
        var parts: [String] = [], current = ""
        for scalar in value.unicodeScalars {
            if scalar.value == 0x74 || scalar.value == 0x54 || jsWhitespace(scalar.value) { parts.append(current); current = "" }
            else { current.unicodeScalars.append(scalar) }
        }
        parts.append(current)
        guard parts.count == 2 else { return false }
        return try date(parts[0]) && time(parts[1], strictTimeZone: strictTimeZone)
    }
    private static func jsWhitespace(_ value: UInt32) -> Bool {
        (0x09...0x0D).contains(value) || (0x2000...0x200A).contains(value) ||
            [0x20, 0xA0, 0x1680, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF].contains(value)
    }
    private struct Expression: Sendable {
        let pattern: String, flags: String
        init(_ pattern: String, _ flags: String = "") { self.pattern = pattern; self.flags = flags }
    }
    private static let expressions: [String: Expression] = [
        "duration": Expression(#"^P(?!$)((\d+Y)?(\d+M)?(\d+D)?(T(?=\d)(\d+H)?(\d+M)?(\d+S)?)?|(\d+W)?)$"#),
        "uri-reference": Expression(#"^(?:[a-z][a-z0-9+\-.]*:)?(?:\/?\/(?:(?:[a-z0-9\-._~!$&'()*+,;=:]|%[0-9a-f]{2})*@)?(?:\[(?:(?:(?:(?:[0-9a-f]{1,4}:){6}|::(?:[0-9a-f]{1,4}:){5}|(?:[0-9a-f]{1,4})?::(?:[0-9a-f]{1,4}:){4}|(?:(?:[0-9a-f]{1,4}:){0,1}[0-9a-f]{1,4})?::(?:[0-9a-f]{1,4}:){3}|(?:(?:[0-9a-f]{1,4}:){0,2}[0-9a-f]{1,4})?::(?:[0-9a-f]{1,4}:){2}|(?:(?:[0-9a-f]{1,4}:){0,3}[0-9a-f]{1,4})?::[0-9a-f]{1,4}:|(?:(?:[0-9a-f]{1,4}:){0,4}[0-9a-f]{1,4})?::)(?:[0-9a-f]{1,4}:[0-9a-f]{1,4}|(?:(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d\d?))|(?:(?:[0-9a-f]{1,4}:){0,5}[0-9a-f]{1,4})?::[0-9a-f]{1,4}|(?:(?:[0-9a-f]{1,4}:){0,6}[0-9a-f]{1,4})?::)|[Vv][0-9a-f]+\.[a-z0-9\-._~!$&'()*+,;=:]+)\]|(?:(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d\d?)|(?:[a-z0-9\-._~!$&'"()*+,;=]|%[0-9a-f]{2})*)(?::\d*)?(?:\/(?:[a-z0-9\-._~!$&'"()*+,;=:@]|%[0-9a-f]{2})*)*|\/(?:(?:[a-z0-9\-._~!$&'"()*+,;=:@]|%[0-9a-f]{2})+(?:\/(?:[a-z0-9\-._~!$&'"()*+,;=:@]|%[0-9a-f]{2})*)*)?|(?:[a-z0-9\-._~!$&'"()*+,;=:@]|%[0-9a-f]{2})+(?:\/(?:[a-z0-9\-._~!$&'"()*+,;=:@]|%[0-9a-f]{2})*)*)?(?:\?(?:[a-z0-9\-._~!$&'"()*+,;=:@/?]|%[0-9a-f]{2})*)?(?:#(?:[a-z0-9\-._~!$&'"()*+,;=:@/?]|%[0-9a-f]{2})*)?$"#, "i"),
        "uri-template": Expression(#"^(?:(?:[^\x00-\x20"'<>%\\^`{|}]|%[0-9a-f]{2})|\{[+#./;?&=,!@|]?(?:[a-z0-9_]|%[0-9a-f]{2})+(?::[1-9][0-9]{0,3}|\*)?(?:,(?:[a-z0-9_]|%[0-9a-f]{2})+(?::[1-9][0-9]{0,3}|\*)?)*\})*$"#, "i"),
        "url": Expression(#"^(?:https?|ftp):\/\/(?:\S+(?::\S*)?@)?(?:(?!(?:10|127)(?:\.\d{1,3}){3})(?!(?:169\.254|192\.168)(?:\.\d{1,3}){2})(?!172\.(?:1[6-9]|2\d|3[0-1])(?:\.\d{1,3}){2})(?:[1-9]\d?|1\d\d|2[01]\d|22[0-3])(?:\.(?:1?\d{1,2}|2[0-4]\d|25[0-5])){2}(?:\.(?:[1-9]\d?|1\d\d|2[0-4]\d|25[0-4]))|(?:(?:[a-z0-9\u{00a1}-\u{ffff}]+-)*[a-z0-9\u{00a1}-\u{ffff}]+)(?:\.(?:[a-z0-9\u{00a1}-\u{ffff}]+-)*[a-z0-9\u{00a1}-\u{ffff}]+)*(?:\.(?:[a-z\u{00a1}-\u{ffff}]{2,})))(?::\d{2,5})?(?:\/[^\s]*)?$"#, "iu"),
        "email": Expression(#"^[a-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[a-z0-9!#$%&'*+/=?^_`{|}~-]+)*@(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$"#, "i"),
        "hostname": Expression(#"^(?=.{1,253}\.?$)[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[-0-9a-z]{0,61}[0-9a-z])?)*\.?$"#, "i"),
        "ipv4": Expression(#"^(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$"#),
        "ipv6": Expression(#"^((([0-9a-f]{1,4}:){7}([0-9a-f]{1,4}|:))|(([0-9a-f]{1,4}:){6}(:[0-9a-f]{1,4}|((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3})|:))|(([0-9a-f]{1,4}:){5}(((:[0-9a-f]{1,4}){1,2})|:((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3})|:))|(([0-9a-f]{1,4}:){4}(((:[0-9a-f]{1,4}){1,3})|((:[0-9a-f]{1,4})?:((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}))|:))|(([0-9a-f]{1,4}:){3}(((:[0-9a-f]{1,4}){1,4})|((:[0-9a-f]{1,4}){0,2}:((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}))|:))|(([0-9a-f]{1,4}:){2}(((:[0-9a-f]{1,4}){1,5})|((:[0-9a-f]{1,4}){0,3}:((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}))|:))|(([0-9a-f]{1,4}:){1}(((:[0-9a-f]{1,4}){1,6})|((:[0-9a-f]{1,4}){0,4}:((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}))|:))|(:(((:[0-9a-f]{1,4}){1,7})|((:[0-9a-f]{1,4}){0,5}:((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(\.(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)){3}))|:)))$"#, "i"),
        "uuid": Expression(#"^(?:urn:uuid:)?[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$"#, "i"),
        "json-pointer": Expression(#"^(?:\/(?:[^~/]|~0|~1)*)*$"#),
        "json-pointer-uri-fragment": Expression(#"^#(?:\/(?:[a-z0-9_\-.!$&'()*+,;:=@]|%[0-9a-f]{2}|~0|~1)*)*$"#, "i"),
        "relative-json-pointer": Expression(#"^(?:0|[1-9][0-9]*)(?:#|(?:\/(?:[^~/]|~0|~1)*)*)$"#),
        // .test() against this fresh /gm expression preserves source behavior:
        // it may match one valid line (including an empty line) within a blob.
        "byte": Expression(#"^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$"#, "gm")
    ]
    private static let uri = #"^(?:[a-z][a-z0-9+\-.]*:)(?:\/?\/(?:(?:[a-z0-9\-._~!$&'()*+,;=:]|%[0-9a-f]{2})*@)?(?:\[(?:(?:(?:(?:[0-9a-f]{1,4}:){6}|::(?:[0-9a-f]{1,4}:){5}|(?:[0-9a-f]{1,4})?::(?:[0-9a-f]{1,4}:){4}|(?:(?:[0-9a-f]{1,4}:){0,1}[0-9a-f]{1,4})?::(?:[0-9a-f]{1,4}:){3}|(?:(?:[0-9a-f]{1,4}:){0,2}[0-9a-f]{1,4})?::(?:[0-9a-f]{1,4}:){2}|(?:(?:[0-9a-f]{1,4}:){0,3}[0-9a-f]{1,4})?::[0-9a-f]{1,4}:|(?:(?:[0-9a-f]{1,4}:){0,4}[0-9a-f]{1,4})?::)(?:[0-9a-f]{1,4}:[0-9a-f]{1,4}|(?:(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d\d?))|(?:(?:[0-9a-f]{1,4}:){0,5}[0-9a-f]{1,4})?::[0-9a-f]{1,4}|(?:(?:[0-9a-f]{1,4}:){0,6}[0-9a-f]{1,4})?::)|[Vv][0-9a-f]+\.[a-z0-9\-._~!$&'()*+,;=:]+)\]|(?:(?:25[0-5]|2[0-4]\d|[01]?\d\d?)\.){3}(?:25[0-5]|2[0-4]\d|[01]?\d\d?)|(?:[a-z0-9\-._~!$&'()*+,;=]|%[0-9a-f]{2})*)(?::\d*)?(?:\/(?:[a-z0-9\-._~!$&'()*+,;=:@]|%[0-9a-f]{2})*)*|\/(?:(?:[a-z0-9\-._~!$&'()*+,;=:@]|%[0-9a-f]{2})+(?:\/(?:[a-z0-9\-._~!$&'()*+,;=:@]|%[0-9a-f]{2})*)*)?|(?:[a-z0-9\-._~!$&'()*+,;=:@]|%[0-9a-f]{2})+(?:\/(?:[a-z0-9\-._~!$&'()*+,;=:@]|%[0-9a-f]{2})*)*)(?:\?(?:[a-z0-9\-._~!$&'()*+,;=:@/?]|%[0-9a-f]{2})*)?(?:#(?:[a-z0-9\-._~!$&'()*+,;=:@/?]|%[0-9a-f]{2})*)?$"#
}
