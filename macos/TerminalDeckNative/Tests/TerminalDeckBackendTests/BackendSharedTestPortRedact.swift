import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendSharedTestPortRedact: XCTestCase {
    private let options = BackendSharedRedactOptions(home: "/Users/testuser", username: "testuser")
    private func gone(_ output: String, secret: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(output.contains(secret), file: file, line: line)
        XCTAssertTrue(output.contains(BackendSharedRedact.redacted), file: file, line: line)
    }
    func testEverySourceTokenInLogJSONAndShell() {
        for (name, secret) in BackendSharedTestPortRedactFixtures.tokens {
            let log = "2026-08-12 INFO [net] calling api with \(secret) now"
            let json = NativeRPCValue.object([.init("nested", .object([.init("value", .string(secret))]))]).compact
            let shell = "curl -H 'Authorization: Bearer \(secret)' https://api.example.com"
            for text in [log, json, shell] { gone(BackendSharedRedact.redact(text, options: options), secret: secret); XCTAssertFalse(BackendSharedRedact.redact(text, options: options).contains(secret), name) }
        }
        let a = "ghp_16" + "C7e42F2" + "92c6912" + "E7710c" + "838347A" + "e178B4a"
        let b = "sk-ant-api" + "03-Zx8kQm2" + "LpR7vNw4TgH" + "1sYbF6dJcE" + "0aUiOx9PlKm" + "QnR3tVzWyXs"
        let both = BackendSharedRedact.redact("GH=\(a) ANTHROPIC=\(b) done", options: options)
        XCTAssertFalse(both.contains(a)); XCTAssertFalse(both.contains(b))
    }
    func testEveryStructuralAssignmentAndHeader() {
        gone(BackendSharedRedact.redact("Authorization: Bearer correcthorsebatterystaple"), secret: "correcth" + "orsebatt" + "erystaple")
        gone(BackendSharedRedact.redact("{\"headers\":{\"Authorization\":\"Basic YWxhZGRpbjpvcGVuc2VzYW1l\"}}"), secret: "YWxhZGRp" + "bjpvcGVu" + "c2VzYW1l")
        gone(BackendSharedRedact.redact("Cookie: session=abc; theme=dark"), secret: "session=abc")
        gone(BackendSharedRedact.redact("password=hunter2"), secret: "hunter2")
        for text in ["ANTHROPIC_API_KEY=letmein-please", "api_key: letmein-please", "\"apiKey\": \"letmein-please\"", "GITHUB_TOKEN='letmein-please'", "client_secret = letmein-please", "MY_APP_ACCESS_KEY:letmein-please", "private_key=letmein-please"] { gone(BackendSharedRedact.redact(text), secret: "letmein-please") }
        let credentials = BackendSharedRedact.redact("https://asad:hunter2@github.com/asadev/terminaldeck.git")
        XCTAssertFalse(credentials.contains("hunter2")); XCTAssertTrue(credentials.contains("github.com/asadev/terminaldeck.git"))
        let pem = "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEAxGZm9" + "v0aB1cD2eF3gH4iJ5kL6m" + "N7oP8qR9sT0uV1wX2yZ3aB\n" + "c4dE5fG6hI7jK8lM9nO0p" + "Q1rS2tU3vW4xY5zA6bC7d" + "E8fG9hI0jK1lM2nO3pQ4rS\n-----END RSA PRIVATE KEY-----"
        let redacted = BackendSharedRedact.redact("key follows\n\(pem)\nend")
        XCTAssertFalse(redacted.contains("MIIEowIBAAKCAQEA")); XCTAssertTrue(redacted.contains("end"))
        XCTAssertFalse(BackendSharedRedact.redact("-----BEGIN RSA PRIVATE KEY-----\u{85}private bytes\u{85}-----END RSA PRIVATE KEY-----").contains("private bytes"))
        let hookTail = "T00000000/B0000" + "0000/XXXXXXXXXXXXXXXXXXXXXXXX"
        gone(BackendSharedRedact.redact("posting to https://hooks.slack.com/services/" + hookTail), secret: "XXXXXXXX" + "XXXXXXXX" + "XXXXXXXX")
    }
    func testExactSurvivorsPathsAndBareBlob() {
        for text in ["Claude Code 2.4.17 (Electron 41.10.5, node 22.9.0)", "git status found 3 modified files in src/main and 1 in src/renderer", "/opt/homebrew/bin:/usr/local/bin:/usr/bin", "hanken-grotes" + "k-v4-latin-reg" + "ular-400.woff2"] { XCTAssertEqual(BackendSharedRedact.redact(text, options: options), text) }
        XCTAssertTrue(BackendSharedRedact.redact("author: Ada Lovelace <ada@example.com>").contains("Ada Lovelace"))
        let id = "3f2504e0-4f8" + "9-11d3-9a0c-" + "0305e82c3301"
        XCTAssertTrue(BackendSharedRedact.redact("session \(id) started").contains(id))
        for path in ["/usr/local/lib/node_modules/terminaldeck/dist/index2", "/Users/<user>/Projects/terminaldeck/src/renderer/components/DebugPanel2", "src/renderer/components/DebugPanel2/index", "/opt/homebrew/Cellar/node/22.9.0/lib/node_modules"] { XCTAssertEqual(BackendSharedRedact.redact(path, options: .init(home: "/Users/nobody", username: "nobody")), path) }
        let blob = "YmF6cXV4abc123DEF456ghi789JKL012mno345PQR678/Zm9vYmFyabc123DEF456ghi789JKL012"
        XCTAssertFalse(BackendSharedRedact.redact("blob \(blob) end").contains("Zm9vYmFyab" + "c123DEF456g" + "hi789JKL012"))
    }
    func testEntropyExactSourceCandidates() {
        XCTAssertFalse(BackendSharedRedact.looksSecret("abc123abc" + "123abc123a" + "bc123abc12"))
        XCTAssertFalse(BackendSharedRedact.looksSecret("abcdefghijkl" + "mnopqrstuvwx" + "yzabcdefghij"))
        XCTAssertFalse(BackendSharedRedact.looksSecret("3f2504e0-4f8" + "9-11d3-9a0c-" + "0305e82c3301"))
        XCTAssertTrue(BackendSharedRedact.looksSecret("1a2b3c4d5e6f7" + "08192a3b4c5d6" + "e7f80918273645"))
        XCTAssertFalse(BackendSharedRedact.looksSecret(String(repeating: "a", count: 40) + "1"))
    }
    func testIdentityLiteralsEnvironmentAndEmptyInvariants() {
        XCTAssertEqual(BackendSharedRedact.redact("/home/deploy/app", options: options), "/home/<user>/app")
        XCTAssertTrue(BackendSharedRedact.redact("USER=testuser", options: options).contains("<user>"))
        XCTAssertFalse(BackendSharedRedact.redact("the hook token is swordfish99 today", options: .init(extraSecrets: ["swordfish99"])).contains("swordfish99"))
        XCTAssertEqual(BackendSharedRedact.secretsFromEnv(["DEBUG_TOKEN": "1", "API_KEY": "yes"]), [])
        let token = "sk-ant-api" + "03-Zx8kQm2" + "LpR7vNw4TgH" + "1sYbF6dJcE" + "0aUiOx9PlKm" + "QnR3tVzWyXs"
        let github = "ghp_16" + "C7e42F2" + "92c6912" + "E7710c" + "838347A" + "e178B4a"
        let sample = "Authorization: Bearer \(token)\nGITHUB_TOKEN=\(github)\ndb=postgres://user:hunter2@db.example.com:5432/app\n/Users/testuser/.claude/.credentials.json"
        let once = BackendSharedRedact.redact(sample, options: options)
        XCTAssertEqual(BackendSharedRedact.redact(once, options: options), once)
        XCTAssertGreaterThan(BackendSharedRedact.redactWithCount(sample).count, 3)
        XCTAssertEqual(BackendSharedRedact.redact(""), ""); XCTAssertEqual(BackendSharedRedact.redact("   "), "   ")
    }
    func testNestedArraysSharedReferencesAndRealCycle() {
        let github = "ghp_16" + "C7e42F2" + "92c6912" + "E7710c" + "838347A" + "e178B4a"
        let value = NativeRPCValue.object([.init("items", .array([.object([.init("password", .string("hunter2"))]), .string(github)]))])
        let json = BackendSharedRedact.redactValue(value).compact
        XCTAssertFalse(json.contains("hunter2")); XCTAssertFalse(json.contains("ghp_16C7"))
        let shared = NSArray(array: [1, 2])
        let output = BackendSharedRedact.redactFoundation(NSDictionary(dictionary: ["a": shared, "b": shared])) as? [String: Any]
        XCTAssertEqual(output?["a"] as? [Int], [1, 2]); XCTAssertEqual(output?["b"] as? [Int], [1, 2])
        let node = NSMutableDictionary(dictionary: ["name": "a"]); node["self"] = node
        defer { node.removeObject(forKey: "self") }
        let circular = BackendSharedRedact.redactFoundation(node) as? [String: Any]
        XCTAssertEqual(circular?["self"] as? String, "[circular]")
    }
}
