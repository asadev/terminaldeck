import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendAppsComposeYAMLTests: XCTestCase {
    func testOrdinarySingleServiceComposeReachesSafePlan() throws {
        let text = """
        services:
          web:
            build:
              context: .
              dockerfile: Dockerfile
            environment:
              FOO: bar
              PUBLIC_URL: https://example.com/path
            command:
              - npm
              - start
            expose:
              - "3000"
            restart: unless-stopped
        """
        let value = try BackendAppsComposeYAML.parse(text)
        let plan = try BackendAppsDeployPlan.compose(value, service: "web", port: 3000)
        XCTAssertEqual(plan.context, ".")
        XCTAssertEqual(plan.dockerfile, "Dockerfile")
        XCTAssertEqual(plan.environment, ["FOO": "bar", "PUBLIC_URL": "https://example.com/path"])
        XCTAssertEqual(plan.command, .array([.string("npm"), .string("start")]))
        XCTAssertEqual(plan.port, 3000)
    }

    func testCommentsQuotedHashesAndEscapesArePreserved() throws {
        let text = #"""
        # Ordinary compose comments
        services:
          web:
            build: . # local build
            environment:
              PASSWORD: 'it''s # private' # comment
              URL: "https://example.com/#fragment"
              MESSAGE: "hello \"world\" \u263a"
              HASH: abc#def
        """#
        let value = try BackendAppsComposeYAML.parse(text)
        let env = value["services"]["web"]["environment"]
        XCTAssertEqual(env["PASSWORD"].string, "it's # private")
        XCTAssertEqual(env["URL"].string, "https://example.com/#fragment")
        XCTAssertEqual(env["MESSAGE"].string, "hello \"world\" ☺")
        XCTAssertEqual(env["HASH"].string, "abc#def")
    }

    func testIndentationlessListAndCRLFCompose() throws {
        let text = "services:\r\n  web:\r\n    build: .\r\n    expose:\r\n    - '3000'\r\n    restart: always\r\n"
        let value = try BackendAppsComposeYAML.parse(text)
        let plan = try BackendAppsDeployPlan.compose(value, service: "web", port: 3000)
        XCTAssertEqual(plan.port, 3000)
        XCTAssertEqual(value["services"]["web"]["restart"].string, "always")
    }

    func testFiniteScalarTypesAndJSONFlowCollections() throws {
        let value = try BackendAppsComposeYAML.parse("""
        values:
          enabled: true
          disabled: FALSE
          unset: null
          empty: ~
          count: 12
          fraction: -0.25
          exponent: 1e2
          text: "0123"
          list: ["a", 2, false, null, {"nested": "value"}]
          object: {"array": [1, 2], "text": "ok"}
        """)
        let values = value["values"]
        XCTAssertEqual(values["enabled"], .bool(true))
        XCTAssertEqual(values["disabled"], .bool(false))
        XCTAssertEqual(values["unset"], .null)
        XCTAssertEqual(values["empty"], .null)
        XCTAssertEqual(values["count"], .number(12))
        XCTAssertEqual(values["fraction"], .number(-0.25))
        XCTAssertEqual(values["exponent"], .number(100))
        XCTAssertEqual(values["text"], .string("0123"))
        XCTAssertEqual(values["list"].elements?.last?["nested"].string, "value")
        XCTAssertEqual(values["object"]["array"], .array([.number(1), .number(2)]))
    }

    func testJSONDocumentAndSingleYAMLDocumentMarkers() throws {
        let json = #"{"services":{"web":{"build":".","expose":["3000"]}}}"#
        let value = try BackendAppsComposeYAML.parse(json)
        XCTAssertEqual(try BackendAppsDeployPlan.compose(value, service: "web", port: 3000).port, 3000)
        let yaml = "---\nservices:\n  web:\n    build: .\n...\n"
        XCTAssertEqual(try BackendAppsComposeYAML.parse(yaml)["services"]["web"]["build"], .string("."))
    }

    func testDuplicateKeysAreRejectedBeforeAnyLastValueWins() {
        for text in [
            "services:\n  web:\n    build: .\n    build: ../outside",
            "services:\n  web:\n    environment:\n      TOKEN: first\n      'TOKEN': leaked-secret-value",
            "value: {\"key\": 1, \"key\": 2}",
            "{\"services\": {}, \"services\": {\"web\": {\"build\": \".\"}}}"
        ] {
            XCTAssertThrowsError(try BackendAppsComposeYAML.parse(text)) { error in
                XCTAssertEqual((error as? NativeRPCError)?.code, "unavailable")
                XCTAssertFalse(error.localizedDescription.contains("leaked-secret-value"))
                XCTAssertFalse(error.localizedDescription.contains("../outside"))
            }
        }
    }

    func testAliasesTagsMergeKeysAndExternalSyntaxAreUnavailable() {
        for text in [
            "services: &defaults {}", "services: *defaults", "services: !!map {}", "services: !include /etc/passwd",
            "services:\n  <<: {}", "value: {\"<<\": {}}", "%YAML 1.2\nservices: {}",
            "services: {}\n---\nservices: {}", "services:\n\tweb: {}", "value: |\n  secret",
            "value: >-\n  secret", "value: plain\n  continuation", "value: {unquoted: 1}", "value: [one, two]",
            "value: 'incomplete", "value: \"bad\\Nescape\"", "value: .inf", "value: 1e309", "value: 0x10", "value: 0123",
            "value: - malformed", "value: ]", "value: }", "value: ,", "value: 9007199254740993",
            "value:\n  - name: inline-mapping", "services:\n  web: {}\n    unexpected: nested"
        ] {
            XCTAssertThrowsError(try BackendAppsComposeYAML.parse(text), text) { error in
                XCTAssertEqual((error as? NativeRPCError)?.code, "unavailable")
                XCTAssertFalse(error.localizedDescription.contains("/etc/passwd"))
            }
        }
    }

    func testUnsafeServiceResourcesRemainRejectedAfterYAMLParsing() throws {
        for setting in ["privileged: true", "network_mode: host", "pid: host", "ports: [\"80:3000\"]", "volumes: [\"/var/run/docker.sock:/var/run/docker.sock\"]", "env_file: /etc/environment", "depends_on: [\"db\"]"] {
            let parsed = try BackendAppsComposeYAML.parse("services:\n  web:\n    build: .\n    " + setting)
            XCTAssertThrowsError(try BackendAppsDeployPlan.compose(parsed, service: "web", port: 3000), setting)
        }
        let twoServices = try BackendAppsComposeYAML.parse("services:\n  web:\n    build: .\n  db:\n    build: .")
        XCTAssertThrowsError(try BackendAppsDeployPlan.compose(twoServices, service: "web", port: 3000))
        let escapedPath = try BackendAppsComposeYAML.parse("services:\n  web:\n    build: '../outside'")
        XCTAssertThrowsError(try BackendAppsDeployPlan.compose(escapedPath, service: "web", port: 3000))
    }

    func testNestingInputLineAndScalarBounds() {
        var deep = ""
        for depth in 0..<40 { deep += String(repeating: " ", count: depth * 2) + "key:\n" }
        deep += String(repeating: " ", count: 80) + "value: end\n"
        XCTAssertThrowsError(try BackendAppsComposeYAML.parse(deep))
        XCTAssertThrowsError(try BackendAppsComposeYAML.parse("value: " + String(repeating: "a", count: 65_537)))
        XCTAssertThrowsError(try BackendAppsComposeYAML.parse(String(repeating: "# comment\n", count: 8193)))
        XCTAssertThrowsError(try BackendAppsComposeYAML.parse(String(repeating: "a", count: 1_048_577)))
        let flow = "value: " + String(repeating: "[", count: 40) + "null" + String(repeating: "]", count: 40)
        XCTAssertThrowsError(try BackendAppsComposeYAML.parse(flow))
    }

    func testMalformedUTF16EscapesNeverReachDisplayParser() throws {
        for text in [
            #"{"services":{"web":{"build":"\uD800\u0000"}}}"#,
            #"value: "\uD800\u0000""#,
            #"value: ["\uD800"]"#,
            #"value: {"text":"\uDC00"}"#,
            #"value: "\uD800\uFFFF""#
        ] {
            XCTAssertThrowsError(try BackendAppsComposeYAML.parse(text)) { error in XCTAssertEqual((error as? NativeRPCError)?.code, "unavailable") }
        }
        XCTAssertEqual(try BackendAppsComposeYAML.parse(#"value: "\uD83D\uDE00""#)["value"].string, "😀")
    }
}
