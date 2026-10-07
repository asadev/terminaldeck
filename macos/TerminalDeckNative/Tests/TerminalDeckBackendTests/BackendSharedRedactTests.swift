import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendSharedRedactTests: XCTestCase {
    private let options = BackendSharedRedactOptions(home: "/Users/testuser", username: "testuser")
    func testStructureWeakPasswordsAndKnownShapes() {
        for text in ["password=hunter2", "\"apiKey\": \"hunter2\"", "GITHUB_TOKEN='hunter2'", "Cookie: session=abc; theme=dark", "Authorization: Bearer correcthorsebatterystaple"] {
            let redacted = BackendSharedRedact.redact(text, options: options)
            XCTAssertTrue(redacted.contains("[redacted]")); XCTAssertFalse(redacted.contains("hunter2")); XCTAssertFalse(redacted.contains("session=abc")); XCTAssertFalse(redacted.contains("correcthorsebatterystaple"))
        }
        let token = "ghp_" + String(repeating: "AbCd0123", count: 4)
        XCTAssertFalse(BackendSharedRedact.redact("calling \(token) now").contains(token))
        XCTAssertFalse(BackendSharedRedact.redact("é" + token).contains(token))
        XCTAssertEqual(BackendSharedRedact.redact("https://asad:hunter2@github.com/acme/repo.git", options: options), "https://[redacted]@github.com/acme/repo.git")
        let pem = "-----BEGIN RSA PRIVATE KEY-----\nprivate bytes\n-----END RSA PRIVATE KEY-----"
        XCTAssertFalse(BackendSharedRedact.redact(pem).contains("private bytes"))
    }
    func testIdentityAndIdempotence() {
        XCTAssertEqual(BackendSharedRedact.redact("/Users/testuser/Projects/terminaldeck", options: options), "~/Projects/terminaldeck")
        XCTAssertEqual(BackendSharedRedact.redact("/Users/other/Logs", options: options), "/Users/<user>/Logs")
        XCTAssertEqual(BackendSharedRedact.redact("C:\\Users\\Asad\\AppData", options: options), "C:\\Users\\<user>\\AppData")
        XCTAssertEqual(BackendSharedRedact.redact("testuser@Mac-mini ~ %", options: options), "<user>@Mac-mini ~ %")
        XCTAssertEqual(BackendSharedRedact.redact("apple pie recipe", options: .init(home: "/Users/apple", username: "apple")), "apple pie recipe")
        let once = BackendSharedRedact.redact("password=hunter2\n/Users/testuser/.claude/file", options: options)
        XCTAssertEqual(BackendSharedRedact.redact(once, options: options), once)
        XCTAssertGreaterThan(BackendSharedRedact.redactWithCount("password=hunter2\n/Users/testuser/.claude/file", options: options).count, 1)
        XCTAssertEqual(BackendSharedRedact.redact("/Users/testuser/project password=hunter2", options: .init(keepIdentity: true)), "/Users/testuser/project password=[redacted]")
    }
    func testEntropyPreservesPathsProseAndUUIDs() {
        XCTAssertFalse(BackendSharedRedact.looksSecret("3f2504e0-4f89-11d3-9a0c-0305e82c3301"))
        XCTAssertFalse(BackendSharedRedact.looksSecret(String(repeating: "a", count: 40) + "1"))
        XCTAssertTrue(BackendSharedRedact.looksSecret("1a2b3c4d5e6f708192a3b4c5d6e7f80918273645"))
        for text in ["/usr/local/lib/node_modules/terminaldeck/dist/index2", "Claude Code 2.4.17 (Electron 41.10.5, node 22.9.0)", "author: Ada Lovelace <ada@example.com>", "git status found 3 modified files"] { XCTAssertEqual(BackendSharedRedact.redact(text, options: options), text) }
    }
    func testEnvironmentAndNestedSecretValues() {
        XCTAssertEqual(BackendSharedRedact.secretsFromEnv(["MY_API_TOKEN": "swordfish99xyz", "PATH": "/usr/bin", "DEBUG_TOKEN": "1"]), ["swordfish99xyz"])
        XCTAssertEqual(BackendSharedRedact.secretEnvNames(["GITHUB_TOKEN": "x", "PATH": "/usr/bin"]), ["GITHUB_TOKEN"])
        let value = NativeRPCValue.object([.init("token", .number(12345678)), .init("apiKey", .object([.init("nested", .bool(true))])), .init("theme", .string("dark"))])
        let output = BackendSharedRedact.redactValue(value)
        XCTAssertEqual(output["token"], .string("[redacted]")); XCTAssertEqual(output["apiKey"], .string("[redacted]")); XCTAssertEqual(output["theme"], .string("dark"))
        let shared = NSDictionary(dictionary: ["theme": "dark"])
        let foundation = BackendSharedRedact.redactFoundation(NSDictionary(dictionary: ["a": shared, "b": shared])) as? [String: Any]
        XCTAssertEqual((foundation?["a"] as? [String: String])?["theme"], "dark")
        XCTAssertEqual((foundation?["b"] as? [String: String])?["theme"], "dark")
    }
}
