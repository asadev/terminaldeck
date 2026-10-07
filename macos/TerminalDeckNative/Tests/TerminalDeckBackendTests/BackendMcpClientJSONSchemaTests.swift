import XCTest
import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Source-derived cases, never a generated/differential execution transcript.
/// SDK v1.27.1 provider options: strict:false, validateFormats:true,
/// validateSchema:false, allErrors:true; addFormats defaults to full.
/// The live lockfile pins SDK1.30.0/Ajv8.20.0/ajv-formats3.0.1.
/// Draft2020 cases explicitly test the requested native dialect support,
/// rather than claiming the SDK's default draft07 Ajv constructor provides it.
/// Primary sources and review notes: BackendMcpClientJSONSchema-REVIEW.md.
@MainActor
final class BackendMcpClientJSONSchemaTests: XCTestCase {
    private let draft07 = "http://json-schema.org/draft-07/schema#"
    private let draft2020 = "https://json-schema.org/draft/2020-12/schema"
    private func json(_ text: String) throws -> NativeRPCValue { try NativeRPCValue.parseJSON(Data(text.utf8)) }
    private func result(_ schema: String, _ value: String, dialect: String? = nil) async throws -> String? {
        var compiled = try json(schema)
        if let dialect { compiled = compiled.setting("$schema", .string(dialect)) }
        return try await BackendMcpClientJSONSchemaValidator().validate(schema: compiled, value: json(value))
    }
    private func check(_ schema: String, _ value: String, _ expected: String?, dialect: String? = nil,
                       file: StaticString = #filePath, line: UInt = #line) async throws {
        let actual = try await result(schema, value, dialect: dialect)
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
    private func refuses(_ schema: String, containing: String, value: String = "null", dialect: String? = nil,
                         file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await result(schema, value, dialect: dialect); XCTFail("Invalid/unresolved schema was accepted", file: file, line: line) }
        catch { XCTAssertTrue(error.localizedDescription.contains(containing), "\(error.localizedDescription)", file: file, line: line) }
    }

    func testJSONTypesAndUnionDoNotCoerce() async throws {
        for (type, value) in [("string", #""text""#), ("number", "1.5"), ("integer", "2"), ("boolean", "true"), ("null", "null"), ("object", "{}"), ("array", "[]")] {
            try await check(#"{"type":"\#(type)"}"#, value, nil, dialect: draft07)
        }
        try await check(#"{"type":"integer"}"#, "1.5", "data must be integer")
        try await check(#"{"type":"integer"}"#, #""2""#, "data must be integer")
        try await check(#"{"type":"number"}"#, "true", "data must be number")
        try await check(#"{"type":["number","string"]}"#, "false", "data must be number,string")
        try await check(#"{"type":["number","string"]}"#, #""2""#, nil)
        try await check(#"{"type":"object"}"#, "[]", "data must be object")
    }
    func testSingleTypeDiagnosticCanFollowGeneralRulesWhenTypeGroupHasRules() async throws {
        try await check(#"{"type":"number","const":1,"minimum":2}"#, #""bad""#,
                        "data must be equal to constant, data must be number")
        try await check(#"{"type":"number","const":1}"#, #""bad""#,
                        "data must be number, data must be equal to constant")
    }
    func testNullableDoesNotChangeEnumOrConst() async throws {
        try await check(#"{"type":"string","nullable":true}"#, "null", nil)
        try await check(#"{"type":"string","nullable":true,"enum":["s"]}"#, "null", "data must be equal to one of the allowed values")
        try await check(#"{"type":"string","nullable":true,"const":"s"}"#, "null", "data must be equal to constant")
    }
    func testRequiredAdditionalAndPropertyErrorsAllRemainInVocabularyOrder() async throws {
        let schema = #"{"type":"object","properties":{"b":{"type":"string"},"a":{"type":"integer"}},"required":["a","c"],"additionalProperties":false}"#
        try await check(schema, #"{"b":2,"extra":true}"#,
            "data must have required property 'a', data must have required property 'c', data must NOT have additional properties, data/b must be string")
        try await check(#"{"type":"object","properties":{"x":{"type":"integer"}},"additionalProperties":{"type":"string"}}"#,
                        #"{"x":1,"extra":false}"#, "data/extra must be string")
        try await check(#"{"required":["x"]}"#, #""not an object""#, nil)
    }
    func testEscapedInstancePointersKeepPropertyMessageAtParent() async throws {
        let schema = #"{"properties":{"a/b~c":{"type":"array","items":{"properties":{"x/y~z":{"type":"integer"}},"required":["x/y~z"]}}}}"#
        try await check(schema, #"{"a/b~c":[{"x/y~z":"wrong"},{}]}"#,
            "data/a~1b~0c/0/x~1y~0z must be integer, data/a~1b~0c/1 must have required property 'x/y~z'")
        try await check(#"{"required":["a/b~c"]}"#, "{}", "data must have required property 'a/b~c'")
    }
    func testPatternPropertiesAreUnanchoredAndDoNotCountAsAdditional() async throws {
        let schema = #"{"properties":{"fixed":{"type":"boolean"}},"patternProperties":{"p":{"type":"integer"}},"additionalProperties":false}"#
        try await check(schema, #"{"fixed":true,"apple":3}"#, nil)
        try await check(schema, #"{"fixed":true,"apple":"bad"}"#, "data/apple must be integer")
        try await check(schema, #"{"fixed":true,"other":3}"#, "data must NOT have additional properties")
    }
    func testObjectEnumConstAndUniqueItemsIgnoreObjectFieldOrder() async throws {
        let reversed = #"{"b":2,"a":1}"#
        try await check(#"{"enum":[{"a":1,"b":2}]}"#, reversed, nil)
        try await check(#"{"const":{"a":1,"b":2}}"#, reversed, nil)
        try await check(#"{"const":{"a":1,"b":2}}"#, #"{"a":1,"b":3}"#, "data must be equal to constant")
        try await check(#"{"const":"é"}"#, #""e\u0301""#, "data must be equal to constant")
        let duplicates = try await result(#"{"uniqueItems":true}"#, #"[{"a":1,"b":2},{"b":2,"a":1}]"#)
        XCTAssertNotNil(duplicates); XCTAssertTrue(duplicates?.contains("must NOT have duplicate items") == true)
        try await check(#"{"uniqueItems":true}"#, #"[{"a":1},{"a":"1"}]"#, nil)
    }
    func testTupleAndHomogeneousItemsDraft07() async throws {
        try await check(#"{"items":{"type":"integer"}}"#, #"[1,"bad",false]"#,
                        "data/1 must be integer, data/2 must be integer", dialect: draft07)
        let tuple = #"{"type":"array","items":[{"type":"integer"},{"type":"string"}],"additionalItems":false}"#
        try await check(tuple, #"[1,"s"]"#, nil, dialect: draft07)
        try await check(tuple, #"[1,"s",true]"#, "data must NOT have more than 2 items", dialect: draft07)
        try await check(tuple, #"["bad",false]"#, "data/0 must be integer, data/1 must be string", dialect: draft07)
        // additionalItems is inert without tuple-form items in this dialect.
        try await check(#"{"items":{"type":"integer"},"additionalItems":false}"#, "[1,2]", nil, dialect: draft07)
        try await check(##"{"items":{"type":"integer"},"additionalItems":{"$ref":"#/ignored"}}"##, "[1,2]", nil, dialect: draft07)
    }
    func testPrefixAndTailItemsDraft2020() async throws {
        let schema = #"{"type":"array","prefixItems":[{"type":"integer"},{"type":"string"}],"items":{"type":"boolean"}}"#
        try await check(schema, #"[1,"s",true,false]"#, nil, dialect: draft2020)
        try await check(schema, #"["bad",2,3]"#, "data/0 must be integer, data/1 must be string, data/2 must be boolean", dialect: draft2020)
        try await check(#"{"prefixItems":[{"type":"integer"}],"items":false}"#, "[1,2]", "data must NOT have more than 1 items", dialect: draft2020)
    }
    func testNumericBoundsAndDefaultFloatingPointMultipleOf() async throws {
        try await check(#"{"maximum":2,"minimum":4,"exclusiveMaximum":2,"exclusiveMinimum":4,"multipleOf":2}"#, "3",
                        "data must be <= 2, data must be >= 4, data must be < 2, data must be > 4, data must be multiple of 2")
        try await check(#"{"minimum":2,"maximum":2}"#, "2", nil)
        try await check(#"{"exclusiveMinimum":2}"#, "2", "data must be > 2")
        try await check(#"{"multipleOf":0.1}"#, "0.3", "data must be multiple of 0.1")
        try await check(#"{"multipleOf":0.25}"#, "0.5", nil)
        try await check(#"{"minimum":100}"#, #""a string""#, nil)
    }
    func testLengthsCountUnicodeCodepointsInsteadOfUTF16OrGraphemes() async throws {
        try await check(#"{"minLength":1,"maxLength":1}"#, #""😀""#, nil)
        try await check(#"{"minLength":2}"#, #""😀""#, "data must NOT have fewer than 2 characters")
        try await check(#"{"minLength":2}"#, #""e\u0301""#, nil)
        try await check(#"{"maxLength":1}"#, #""e\u0301""#, "data must NOT have more than 1 characters")
        try await check(#"{"maxLength":1}"#, #""👩‍👩‍👧‍👦""#, "data must NOT have more than 1 characters")
    }
    func testJavaScriptUnicodePatternSemanticsAndSubstringMatching() async throws {
        try await check(#"{"pattern":"a"}"#, #""cat""#, nil)
        try await check(#"{"pattern":"^a$"}"#, #""cat""#, #"data must match pattern "^a$""#)
        try await check(#"{"pattern":"^.$"}"#, #""😀""#, nil)
        try await check(#"{"pattern":"^\\w+$"}"#, #""é""#, #"data must match pattern "^\w+$""#)
        try await check(#"{"pattern":"^\\d+$"}"#, #""١""#, #"data must match pattern "^\d+$""#)
        try await check(#"{"pattern":"^a$"}"#, #""a\n""#, #"data must match pattern "^a$""#)
        try await check(#"{"pattern":"(?<letter>a)\\k<letter>"}"#, #""zaaz""#, nil)
        await refuses(#"{"pattern":"\\a"}"#, containing: "Invalid")
    }
    func testAnyOfSuccessDiscardsEveryFailedBranchError() async throws {
        try await check(##"{"anyOf":[true,{"$ref":"#/ignored"}]}"##, "null", nil, dialect: draft07)
        try await check(#"{"anyOf":[{"type":"integer"},{"type":"string"}]}"#, #""ok""#, nil)
        let schema = #"{"anyOf":[{"type":"string","minLength":5,"pattern":"^z"},{"type":"number"}]}"#
        try await check(schema, #""a""#,
                        #"data must NOT have fewer than 5 characters, data must match pattern "^z", data must be number, data must match a schema in anyOf"#)
    }
    func testOneOfCountsSuccessfulBranchesAndRollsBackOnlyWhenExactlyOnePasses() async throws {
        try await check(#"{"oneOf":[{"minimum":10},{"maximum":8}]}"#, "5", nil)
        try await check(#"{"oneOf":[{"minimum":10},{"maximum":0}]}"#, "5",
                        "data must be >= 10, data must be <= 0, data must match exactly one schema in oneOf")
        try await check(#"{"oneOf":[{"type":"number"},{"minimum":0}]}"#, "5", "data must match exactly one schema in oneOf")
        try await check(#"{"oneOf":[{"type":"string"},{"type":"number"},{"minimum":0}]}"#, "5",
                        "data must be string, data must match exactly one schema in oneOf")
    }
    func testAllOfNotAndFalseSchemas() async throws {
        try await check(#"{"allOf":[{"minimum":5},{"maximum":1}]}"#, "3", "data must be >= 5, data must be <= 1")
        try await check(#"{"not":{"type":"integer","minimum":5}}"#, "3", nil)
        try await check(#"{"not":{"type":"integer","minimum":5}}"#, "6", "data must NOT be valid")
        try await check(#"{"properties":{"x":false}}"#, #"{"x":1}"#, "data/x boolean schema is false")
        try await check(#"{"properties":{"x":true}}"#, #"{"x":{"any":"value"}}"#, nil)
    }
    func testLocalDefinitionsAndDefsAndEscapedRefPointers() async throws {
        try await check(##"{"definitions":{"n":{"type":"integer"}},"$ref":"#/definitions/n"}"##, "2", nil, dialect: draft07)
        try await check(##"{"$defs":{"a/b~c":{"type":"integer"}},"$ref":"#/$defs/a~1b~0c"}"##, #""bad""#, "data must be integer", dialect: draft2020)
        try await check(##"{"$defs":{"a b":{"type":"string"}},"$ref":"#/$defs/a%20b"}"##, #""ok""#, nil)
        try await check(##"{"$defs":{"n":{"minimum":5}},"$ref":"#/$defs/n","maximum":1}"##, "3", "data must be >= 5, data must be <= 1", dialect: draft07)
    }
    func testProductiveRecursiveTreeRefsKeepNestedPathsAndAnyOfRollback() async throws {
        let schema = ##"{"$defs":{"node":{"type":"object","properties":{"value":{"type":"integer"},"next":{"anyOf":[{"$ref":"#/$defs/node"},{"type":"null"}]}},"required":["value"]}},"$ref":"#/$defs/node"}"##
        try await check(schema, #"{"value":1,"next":{"value":2,"next":null}}"#, nil)
        try await check(schema, #"{"value":1,"next":{"value":"bad","next":null}}"#,
                        "data/next/value must be integer, data/next must be null, data/next must match a schema in anyOf")
        try await check(##"{"type":"object","propertyNames":{"$ref":"#"}}"##, #"{"x":1}"#,
                        "data must be object, data property name must be valid")
        try await check(##"{"propertyNames":{"$ref":"#"}}"##, #"{"x":1}"#, nil)
    }
    func testUnresolvedLocalAndExternalRefsThrowRatherThanReturnValid() async {
        await refuses(##"{"$ref":"#/$defs/missing"}"##, containing: "can't resolve reference #/$defs/missing")
        await refuses(#"{"$ref":"https://example.invalid/remote-schema"}"#, containing: "reference")
        // Native bounded safety behavior for an unproductive cycle; never silently valid.
        do { _ = try await result(##"{"$ref":"#"}"##, "null"); XCTFail("Nonproductive self-reference accepted") }
        catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    }
    func testKeywordValueTypesStillRejectWhenMetaSchemaValidationIsOff() async {
        await refuses(#"{"required":"x"}"#, containing: #"required value must be ["array"]"#)
        await refuses(#"{"maximum":"2"}"#, containing: #"maximum value must be ["number"]"#)
        await refuses(#"{"pattern":1}"#, containing: #"pattern value must be ["string"]"#)
        await refuses(#"{"properties":[]}"#, containing: #"properties value must be ["object"]"#)
        await refuses(#"{"enum":[]}"#, containing: "enum must have non-empty array")
        await refuses("3", containing: "schema must be object or boolean")
    }
    func testValidateSchemaFalseAndStrictFalseDoNotBecomeStrictMetaValidation() async throws {
        // The keyword accepts a numeric schema value; the disabled meta-schema
        // does not forbid a negative bound or vendor annotations.
        try await check(#"{"maxLength":-1}"#, #""x""#, "data must NOT have more than -1 characters")
        try await check(#"{"x-vendor":{"type":"banana"},"default":{"type":"banana"}}"#, #"{"ok":true}"#, nil)
    }
    func testKnownFormatsFullModeUnknownFormatsAndWrongValueTypes() async throws {
        let cases: [(String, String, Bool)] = [
            ("date", #""2024-02-29""#, true), ("date", #""2023-02-29""#, false),
            ("time", #""12:34:56Z""#, true), ("time", #""12:34:56""#, false),
            ("date-time", #""2024-02-29T12:34:56+04:00""#, true), ("date-time", #""2023-02-29T12:34:56Z""#, false),
            ("email", #""a@example.com""#, true), ("email", #""no-at-symbol""#, false),
            ("hostname", #""example.com""#, true), ("hostname", #""-bad.example""#, false),
            ("ipv4", #""192.0.2.1""#, true), ("ipv4", #""256.0.0.1""#, false),
            ("ipv6", #""2001:db8::1""#, true), ("ipv6", #""not-an-address""#, false),
            ("uri", #""https://example.com/a""#, true), ("uri", #""relative/path""#, false),
            ("uri-reference", #""relative/path""#, true), ("uri-reference", #""bad space""#, false),
            ("uuid", #""123e4567-e89b-12d3-a456-426614174000""#, true), ("uuid", #""bad""#, false),
            ("json-pointer", #""/a~1b~0c""#, true), ("json-pointer", #""/a~2b""#, false),
            ("relative-json-pointer", #""0/a""#, true), ("relative-json-pointer", #""01/a""#, false),
            ("regex", #""^a+$""#, true), ("regex", #""[""#, false),
            ("byte", #""YQ==""#, true), ("byte", #""***""#, false)
        ]
        for (format, value, valid) in cases {
            try await check(#"{"format":"\#(format)"}"#, value, valid ? nil : "data must match format \"\(format)\"")
        }
        try await check(#"{"format":"a-vendor-format"}"#, #""anything""#, nil)
        try await check(#"{"format":"email"}"#, "3", nil)
        try await check(#"{"format":"int32"}"#, "2147483648", #"data must match format "int32""#)
        try await check(#"{"format":"int64"}"#, "9007199254740992", nil)
        try await check(#"{"format":"int64"}"#, "1.5", #"data must match format "int64""#)
        try await check(#"{"format":"float"}"#, "1e100", nil)
    }
    func testValidationDoesNotInsertDefaultsRemoveFieldsOrMutateInput() async throws {
        let schema = try json(#"{"type":"object","required":["defaulted"],"properties":{"defaulted":{"type":"integer","default":7}},"additionalProperties":false}"#)
        let input = try json(#"{"extra":"kept"}"#), before = input.compact
        let validator = BackendMcpClientJSONSchemaValidator()
        let first = try await validator.validate(schema: schema, value: input)
        XCTAssertEqual(first, "data must have required property 'defaulted', data must NOT have additional properties")
        XCTAssertEqual(input.compact, before)
        let valid = try await validator.validate(schema: schema, value: json(#"{"defaulted":7}"#))
        XCTAssertNil(valid)
        let again = try await validator.validate(schema: schema, value: input)
        XCTAssertEqual(again, first, "A previous successful call must not leak/reset the wrong diagnostics")
    }
    func testIfErrorsAreDiscardedButSelectedBranchFailuresRemain() async throws {
        try await check(##"{"if":{"$ref":"#/ignored"},"then":true,"else":{}}"##, "null", nil)
        try await check(##"{"then":{"$ref":"#/ignored"}}"##, "null", nil)
        let schema = #"{"if":{"properties":{"mode":{"const":"x"}},"required":["mode"]},"then":{"required":["x"]},"else":{"required":["y"]}}"#
        try await check(schema, #"{"mode":"x","x":1}"#, nil)
        try await check(schema, #"{"mode":"other","y":1}"#, nil)
        try await check(schema, #"{"mode":"x"}"#, #"data must have required property 'x', data must match "then" schema"#)
        try await check(schema, #"{"mode":"other"}"#, #"data must have required property 'y', data must match "else" schema"#)
    }
    func testContainsRollsBackFailedItemErrorsOnSuccess() async throws {
        // Ajv's source marks the whole array evaluated for nontrivial contains.
        try await check(#"{"contains":{"type":"integer"},"unevaluatedItems":false}"#, #"[1,"bad"]"#, nil, dialect: draft2020)
        try await check(#"{"contains":{"type":"integer"}}"#, #"["bad",2]"#, nil, dialect: draft07)
        let fail = try await result(#"{"contains":{"type":"integer"}}"#, #"["bad",false]"#, dialect: draft07)
        XCTAssertTrue(fail?.hasPrefix("data/0 must be integer, data/1 must be integer, ") == true)
        XCTAssertTrue(fail?.contains("must contain at least 1 valid item(s)") == true)
        try await check(#"{"contains":{"type":"integer"},"minContains":0,"maxContains":1}"#, #"["bad"]"#, nil, dialect: draft2020)
        let tooMany = try await result(#"{"contains":{"type":"integer"},"minContains":0,"maxContains":1}"#, "[1,2]", dialect: draft2020)
        XCTAssertNotNil(tooMany)
    }
    func testDependentPropertiesAndSchemas() async throws {
        let schema = #"{"dependencies":{"card":["billing"],"mode":{"required":["details"]}}}"#
        try await check(schema, #"{"card":1,"billing":1,"mode":true,"details":1}"#, nil, dialect: draft07)
        let missing = try await result(schema, #"{"card":1}"#, dialect: draft07)
        XCTAssertTrue(missing?.contains("billing") == true); XCTAssertTrue(missing?.contains("card") == true)
        try await check(#"{"dependentRequired":{"card":["billing"]},"dependentSchemas":{"mode":{"required":["details"]}}}"#,
                        #"{"card":1,"billing":1,"mode":true,"details":1}"#, nil, dialect: draft2020)
        let modern = try await result(#"{"dependentSchemas":{"mode":{"required":["details"]}}}"#, #"{"mode":true}"#, dialect: draft2020)
        XCTAssertEqual(modern, "data must have required property 'details'")
    }
    func testUnevaluatedAnnotationsUseOnlySuccessfulAnyOfBranches() async throws {
        let schema = #"{"anyOf":[{"properties":{"a":{"type":"integer"}}},{"properties":{"b":{"type":"string"}}}],"unevaluatedProperties":false}"#
        try await check(schema, #"{"a":1,"b":"s"}"#, nil, dialect: draft2020)
        try await check(schema, #"{"a":1,"b":2}"#, "data must NOT have unevaluated properties", dialect: draft2020)
        try await check(#"{"prefixItems":[{"type":"integer"}],"unevaluatedItems":false}"#, "[1]", nil, dialect: draft2020)
        let extra = try await result(#"{"prefixItems":[{"type":"integer"}],"unevaluatedItems":false}"#, "[1,2]", dialect: draft2020)
        XCTAssertNotNil(extra); XCTAssertTrue(extra?.contains("must NOT have more than 1 items") == true)
    }
}
