import Foundation
import XCTest
@testable import TerminalDeckBackend

/// U120 (#72): "Add test script" adds one line to package.json; every other byte stays as the person wrote it.
final class ReadinessPackageScriptTests: XCTestCase {
    func testAddingAScriptChangesOneLineAndKeepsKeyOrder() throws {
        let source = """
        {
          "name": "zeta",
          "version": "1.0.0",
          "scripts": {
            "start": "node index.js",
            "build": "tsc"
          },
          "dependencies": { "b": "1", "a": "2" }
        }

        """
        let result = try XCTUnwrap(BackendReadinessPackageScript.setting("test", to: "vitest run", in: source))
        XCTAssertEqual(result, source.replacingOccurrences(of: "\"build\": \"tsc\"\n", with: "\"build\": \"tsc\",\n    \"test\": \"vitest run\"\n"))
    }

    func testThePlaceholderIsReplacedInPlace() throws {
        let source = "{\n\t\"name\": \"x\",\n\t\"scripts\": {\n\t\t\"test\": \"echo \\\"Error: no test specified\\\" && exit 1\",\n\t\t\"z\": \"a\"\n\t}\n}"
        let result = try XCTUnwrap(BackendReadinessPackageScript.setting("test", to: "node --test", in: source))
        XCTAssertEqual(result, "{\n\t\"name\": \"x\",\n\t\"scripts\": {\n\t\t\"test\": \"node --test\",\n\t\t\"z\": \"a\"\n\t}\n}")
    }

    func testAMissingOrEmptyScriptsObjectIsAddedInTheFilesOwnStyle() throws {
        let none = "{\r\n    \"name\": \"x\",\r\n    \"private\": true\r\n}\r\n"
        XCTAssertEqual(BackendReadinessPackageScript.setting("lint", to: "eslint .", in: none),
                       "{\r\n    \"name\": \"x\",\r\n    \"private\": true,\r\n    \"scripts\": {\r\n        \"lint\": \"eslint .\"\r\n    }\r\n}\r\n")
        let empty = "{\n  \"scripts\": {},\n  \"name\": \"x\"\n}\n"
        XCTAssertEqual(BackendReadinessPackageScript.setting("test", to: "jest", in: empty),
                       "{\n  \"scripts\": {\n    \"test\": \"jest\"\n  },\n  \"name\": \"x\"\n}\n")
        XCTAssertEqual(BackendReadinessPackageScript.setting("test", to: "jest", in: #"{"name":"x","scripts":{"a":"b"}}"#),
                       #"{"name":"x","scripts":{"a":"b", "test": "jest"}}"#)
    }

    func testTextThatIsNotOnePackageObjectIsLeftAlone() {
        for source in ["", "[]", "{\"scripts\": \"oops\"}", "{\"name\": \"x\"} trailing", "{\"name\": \"x\""] {
            XCTAssertNil(BackendReadinessPackageScript.setting("test", to: "jest", in: source), source)
        }
    }
}
