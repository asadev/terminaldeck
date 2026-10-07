import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// Fixture rules read from ajv-formats v3.0.1 fullFormats and its Swift port.
/// Source-only migration batch: these tests were written, never run.
@MainActor final class BackendMcpClientJSONSchemaFormatsTests: XCTestCase {
    private func check(_ format: String, accepts: [String], rejects: [String], file: StaticString = #filePath, line: UInt = #line) throws {
        for value in accepts { XCTAssertEqual(try BackendMcpClientJSONSchemaFormats.check(format, value: .string(value)), true, "\(format) should accept \(value.debugDescription)", file: file, line: line) }
        for value in rejects { XCTAssertEqual(try BackendMcpClientJSONSchemaFormats.check(format, value: .string(value)), false, "\(format) should refuse \(value.debugDescription)", file: file, line: line) }
    }
    func testUnknownAndWrongValueTypesAreIgnored() throws {
        XCTAssertNil(try BackendMcpClientJSONSchemaFormats.check("publisher-format", value: .string("anything")))
        XCTAssertNil(try BackendMcpClientJSONSchemaFormats.check("DATE", value: .string("not a date")))
        XCTAssertEqual(BackendMcpClientJSONSchemaFormats.knownFormats.count, 26)
        let irrelevant: [NativeRPCValue] = [.null, .bool(false), .array([]), .object([])]
        for format in BackendMcpClientJSONSchemaFormats.knownFormats {
            for value in irrelevant { XCTAssertEqual(try BackendMcpClientJSONSchemaFormats.check(format, value: value), true) }
        }
        for format in ["int32", "int64", "float", "double"] { XCTAssertEqual(try BackendMcpClientJSONSchemaFormats.check(format, value: .string("not a number")), true) }
        XCTAssertEqual(try BackendMcpClientJSONSchemaFormats.check("email", value: .number(9)), true)
        XCTAssertEqual(try BackendMcpClientJSONSchemaFormats.check("password", value: .string("")), true)
        XCTAssertEqual(try BackendMcpClientJSONSchemaFormats.check("binary", value: .bytes(Data([0x00, 0xFF]))), true)
    }
    func testNumericBoundsAreTheSourceBounds() throws {
        for value in [-2_147_483_648.0, 0, 2_147_483_647] { XCTAssertEqual(try BackendMcpClientJSONSchemaFormats.check("int32", value: .number(value)), true) }
        for value in [-2_147_483_649.0, 2_147_483_648, 1.5, .infinity, .nan] { XCTAssertEqual(try BackendMcpClientJSONSchemaFormats.check("int32", value: .number(value)), false) }
        // int64 does not enforce Int64.max or Number.MAX_SAFE_INTEGER.
        for value in [9_007_199_254_740_992.0, 1e100, -1e100, -0.0] { XCTAssertEqual(try BackendMcpClientJSONSchemaFormats.check("int64", value: .number(value)), true) }
        for value in [1.125, Double.infinity, Double.nan] { XCTAssertEqual(try BackendMcpClientJSONSchemaFormats.check("int64", value: .number(value)), false) }
        for format in ["float", "double"] {
            for value in [1e300, 1e-300, Double.infinity, Double.nan] { XCTAssertEqual(try BackendMcpClientJSONSchemaFormats.check(format, value: .number(value)), true) }
        }
    }
    #if canImport(JavaScriptCore)
    func testFullDateIncludesLeapYearAndSourceAnchorBehavior() throws {
        try check("date", accepts: ["2024-02-29", "2000-02-29", "0000-02-29"], rejects: ["1900-02-29", "2023-02-29", "2024-04-31", "2024-00-01", "2024-01-00", "24-01-01", "２０２４-01-01", "2024-01-01\n"])
    }
    func testStrictAndIsoTimesKeepTimezoneAndLeapRules() throws {
        try check("time", accepts: ["12:34:56Z", "12:34:56.123+02:30", "12:34:56-0230", "12:34:56+02", "23:59:60Z", "00:59:60+01:00", "00:00:60+00:01", "23:60:00+00:01"], rejects: ["12:34:56", "24:00:00Z", "12:00:60Z", "23:59:61Z", "12:34:56+24:00", "12:34:56+00:60", "1:34:56Z", "12:34:56z\n"])
        try check("iso-time", accepts: ["12:34:56", "12:34:56Z", "23:59:60", "12:34:56.12"], rejects: ["24:00:00", "12:00:60", "12:34", "12:34:56+24:00"])
    }
    func testDateTimeSplitsExactEcmaWhitespace() throws {
        try check("date-time", accepts: ["2024-02-29T12:34:56Z", "2024-02-29t12:34:56+02", "2024-02-29 12:34:56Z", "2024-02-29\u{FEFF}12:34:56Z"], rejects: ["2024-02-29T12:34:56", "2024-02-30T12:34:56Z", "2024-02-29  12:34:56Z", "2024-02-29\r\n12:34:56Z", "2024-02-29\u{0085}12:34:56Z"])
        try check("iso-date-time", accepts: ["2024-02-29T12:34:56", "2024-02-29 12:34:56Z"], rejects: ["2024-02-30T12:34:56", "2024-02-29T12:34"])
    }
    func testDurationKeepsTheWholeSourceGrammar() throws {
        try check("duration", accepts: ["P0D", "P2W", "P1Y2M3DT4H5M6S", "PT12H", "PT0S"], rejects: ["P", "PT", "P1.5D", "PT1.5S", "P1W1D", "P1D5H", "-P1D"])
    }
    func testUriAndReferenceAreDifferentFormats() throws {
        try check("uri", accepts: ["urn:isbn:0451450523", "mailto:a@example.com", "https://example.com/a%20b?q=x#fragment", "http://[2001:db8::1]:8080/a"], rejects: ["relative/path", "../file", "1scheme:abc", "https://example.com/a b", "https://example.com/%ZZ", "https://[invalid]/x"])
        try check("uri-reference", accepts: ["", "relative/path", "../file?q=x#part", "/a%20b", "#fragment", "https://example.com"], rejects: ["relative\\path", "bad%ZZ", "https://[invalid]/x"])
    }
    func testUriTemplateVariablesAreValidated() throws {
        try check("uri-template", accepts: ["https://example.com/{id}", "{+path}/here{?x,y}", "{list*}", "{name:4}", "a%20b", ""], rejects: ["{unclosed", "{name:0}", "{name:10000}", "{not a name}", "literal space", "bad%ZZ"])
    }
    func testUrlKeepsSourcePublicHostAndProtocolRules() throws {
        try check("url", accepts: ["https://example.com", "ftp://user:password@example.com:2121/file", "http://8.8.8.8/path", "https://münich.example/"], rejects: ["http://localhost", "http://127.0.0.1", "http://10.0.0.1", "http://172.16.0.1", "http://192.168.1.1", "http://[::1]", "mailto:a@example.com", "https://example.com?q=x"])
    }
    func testEmailHostnameAndAddressRules() throws {
        try check("email", accepts: ["first.last+tag@example.com", "X@example.co.uk"], rejects: ["x@localhost", ".x@example.com", "x..y@example.com", "a b@example.com", "a@-example.com", "ü@example.com"])
        try check("hostname", accepts: ["localhost", "example.com.", "xn--mnich-kva.example", String(repeating: "a", count: 63) + ".com"], rejects: ["-bad.example", "bad-.example", "a..b", String(repeating: "a", count: 64) + ".com", "münich.example"])
        try check("ipv4", accepts: ["0.0.0.0", "127.0.0.1", "255.255.255.255"], rejects: ["256.1.1.1", "01.2.3.4", "1.2.3", "1.2.3.4.5", "1.2.3.-1"])
        try check("ipv6", accepts: ["::", "::1", "2001:db8::1", "::ffff:192.0.2.1", "1:2:3:4:5:6:7:8"], rejects: ["1:2:3", "2001:db8::zz", "1:2:3:4:5:6:7:8:9", "fe80::1%en0", "[::1]"])
    }
    func testUuidAndPointerVocabularies() throws {
        try check("uuid", accepts: ["00000000-0000-0000-0000-000000000000", "URN:UUID:123e4567-e89b-12d3-a456-426614174000"], rejects: ["{123e4567-e89b-12d3-a456-426614174000}", "123e4567e89b12d3a456426614174000", "not a uuid"])
        try check("json-pointer", accepts: ["", "/a~1b/~0", "/", "/a\nb"], rejects: ["a/b", "#/a", "/bad~2", "/bad~"])
        try check("json-pointer-uri-fragment", accepts: ["#", "#/a~1b/%20", "#/a%2Fb"], rejects: ["/a", "#/bad~2", "#/bad%ZZ", "#/has space"])
        try check("relative-json-pointer", accepts: ["0", "0#", "12/a~1b", "2/"], rejects: ["01/a", "-1/a", "#/a", "1/bad~2"])
    }
    func testByteIsSourceMultilineExpressionNotStrictDecoder() throws {
        try check("byte", accepts: ["", "AAAA", "AA==", "AAA=", "SGVsbG8=", "not-base64@@\nAAAA", "@@@@\n"], rejects: ["a", "AA===", "SGVsbG8", "@@@@"])
    }
    func testRegexFormatUsesNoUnicodeFlagAndExtraZRule() throws {
        try check("regex", accepts: ["", "a+", #"\q"#, #"\Z"#, "{literal}", #"(?<word>a)\k<word>"#], rejects: ["[", "(", "*x", #"a\Z"#])
        XCTAssertThrowsError(try BackendMcpClientJSONSchemaPattern.validate(#"\q"#))
        XCTAssertThrowsError(try BackendMcpClientJSONSchemaPattern.validate("{literal}"))
    }
    func testPatternUnanchoredUnicodeAndJavascriptLanguage() throws {
        XCTAssertTrue(try BackendMcpClientJSONSchemaPattern.matches("abc", value: "before-abc-after"))
        XCTAssertFalse(try BackendMcpClientJSONSchemaPattern.matches("^abc$", value: "before-abc-after"))
        XCTAssertFalse(try BackendMcpClientJSONSchemaPattern.matches("^a$", value: "a\n"))
        XCTAssertTrue(try BackendMcpClientJSONSchemaPattern.matches("^.$", value: "😀"))
        XCTAssertFalse(try BackendMcpClientJSONSchemaPattern.matches("^..$", value: "😀"))
        XCTAssertTrue(try BackendMcpClientJSONSchemaPattern.matches(#"^\p{Letter}+$"#, value: "Éλληνικά"))
        XCTAssertFalse(try BackendMcpClientJSONSchemaPattern.matches(#"^\d+$"#, value: "١٢٣"))
        XCTAssertTrue(try BackendMcpClientJSONSchemaPattern.matches(#"(?<=a)b"#, value: "ab"))
        XCTAssertTrue(try BackendMcpClientJSONSchemaPattern.matches(#"^(?<word>[a-z]+)-\k<word>$"#, value: "same-same"))
        XCTAssertThrowsError(try BackendMcpClientJSONSchemaPattern.validate("["))
        XCTAssertThrowsError(try BackendMcpClientJSONSchemaPattern.validate(#"\1"#))
        XCTAssertThrowsError(try BackendMcpClientJSONSchemaPattern.validate("(?i)abc")) // ICU accepts this; ECMAScript does not.
        let long = String(repeating: "a", count: 600)
        XCTAssertNoThrow(try BackendMcpClientJSONSchemaPattern.validate(long)) // Browser-helper 512 cap must not leak here.
    }
    func testPatternInputIsDataAndCaptureResultsStayLocal() throws {
        let text = "'); globalThis.owned = true; //"
        XCTAssertTrue(try BackendMcpClientJSONSchemaPattern.matches("^.*$", value: text))
        guard let captures = try BackendMcpClientJSONSchemaPattern.captures(#"^(a)?(b)$"#, value: "b") else { return XCTFail("No captures returned") }
        XCTAssertEqual(captures.count, 2); XCTAssertNil(captures[0]); XCTAssertEqual(captures[1], "b")
    }
    #else
    func testUnavailableJavascriptEngineDoesNotSubstituteAnotherMatcher() {
        XCTAssertThrowsError(try BackendMcpClientJSONSchemaPattern.validate("abc")) { error in XCTAssertEqual((error as? NativeRPCError)?.code, "unavailable") }
        XCTAssertThrowsError(try BackendMcpClientJSONSchemaFormats.check("date", value: .string("2024-01-01")))
    }
    #endif
}
