import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// 2 Nov (install #25): the list reads Hoot's row without building its conversation, each tool result is cleaned once,
/// and the compiled-once secret cleaning gives exactly what the old per-call version gave.
final class AWAgentsWatchRefreshTests: XCTestCase {
    private func object(_ json: String) throws -> NativeRPCValue { try .parseJSON(Data(json.utf8)) }
    private func snapshot(secret: String = "sk-ant-api03-PRIVATEPRIVATEPRIVATE") throws -> NativeRPCValue {
        let values: [HootChatRecord] = [.text(.user, id: "ask", "Look"), .text(.textDelta, id: "message", "Hello "),
            .text(.message, id: "message", "Hello there!"),
            .init(.toolCall, id: "tool", value: try object(#"{"name":"Read","input":{"file_path":"/project/file"}}"#)),
            .init(.toolResult, id: "tool", value: .object([.init("output", .string("key: \(secret)\nok")), .init("isError", .bool(false))])),
            .init(.toolCall, id: "running", value: try object(#"{"name":"mcp__deck-control__sessions_list","input":{}}"#))]
        let events = values.enumerated().map { index, record in
            HootChatEvent(conversationID: "conversation", turnID: "turn", sequence: index + 1, provider: .claude, record: record, at: Double(index + 10))
        }
        return try object(#"{"conversationId":"conversation","provider":"claude","busy":true,"pending":[]}"#)
            .setting("events", .array(events.map(\.wireValue)))
    }

    func testListRowIsTheSameRowWithoutTheConversation() throws {
        for state in [try snapshot(), try snapshot().setting("pending", .array([.object([])])),
                      try snapshot().setting("busy", .bool(false)).setting("alive", .bool(false))] {
            XCTAssertEqual(try AWAgentsWatchHoot.agents(state), try AWAgentsWatchHoot.project(state).agents)
        }
        XCTAssertEqual(try AWAgentsWatchHoot.agents(try snapshot()).first?.state, .working)
        let wrong = HootChatEvent(conversationID: "other", turnID: "turn", sequence: 1, provider: .claude, record: .text(.message, "Wrong"))
        XCTAssertThrowsError(try AWAgentsWatchHoot.agents(try snapshot().setting("events", .array([wrong.wireValue]))))
    }

    func testEachToolResultIsCleanedOnceAndStaysClean() throws {
        let secret = "sk-ant-api03-" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let cache = AWAgentsWatchHoot.Cleaned.shared
        let first = try AWAgentsWatchHoot.project(try snapshot(secret: secret)).entries
        let misses = cache.misses, hits = cache.hits
        let again = try AWAgentsWatchHoot.project(try snapshot(secret: secret)).entries
        XCTAssertEqual(first, again)
        XCTAssertEqual(cache.misses, misses)                    // nothing cleaned a second time
        XCTAssertGreaterThan(cache.hits, hits)
        let result = try XCTUnwrap(again.first { $0.kind == .result })
        XCTAssertFalse(result.text.contains(secret))
        XCTAssertTrue(result.text.contains("[redacted]"))
        XCTAssertEqual(first.map(\.kind), [.message, .message, .tool, .result, .tool])
    }

    func testStructuredHootListUsesTheRowOnlyReader() async throws {
        let row = try XCTUnwrap(try AWAgentsWatchHoot.agents(try snapshot()).first)
        let full = BackendDeckCoreSecurityTestBox<Int>(0)
        let hoot = AWAgentsWatchNativeSource.StructuredHoot(require: { _ in }, read: { _ in
            full.edit { $0 += 1 }; return ([row], [])
        }, readAgents: { _ in [row] })
        let caller = AWWatchCaller.app(.init(caller: .nativeApp, ownerID: "test"))
        let paced = try await hoot.agents(caller)
        XCTAssertEqual(paced, [row])
        XCTAssertEqual(full.get(), 0)
        let older = AWAgentsWatchNativeSource.StructuredHoot(require: { _ in }, read: { _ in full.edit { $0 += 1 }; return ([row], []) })
        let fallback = try await older.agents(caller)
        XCTAssertEqual(fallback, [row])
        XCTAssertEqual(full.get(), 1)
    }

    func testCompiledOnceCleaningMatchesThePerCallVersion() {
        let corpus = [
            "-----BEGIN RSA PRIVATE KEY-----\nMIIEow\n-----END RSA PRIVATE KEY----- and -----BEGIN OPENSSH KEY-----\nabc\n-----END OPENSSH KEY-----",
            "clone https://alice:hunter2pass@github.com/o/r.git then git://u:p@host/x",
            #"{"Authorization": "Bearer abcdefghijklmnop", "cookie":"a=b", "x-api-key" : "zzz"}"#,
            "authorization: Basic dXNlcjpwYXNz\nX-Auth-Token: 12345678\nAuthor: Someone",
            #"api_key = "quoted value" password='x\'y' client_secret: plain-value, session_key=abc;"#,
            "token=[redacted] secret: already",
            "Bearer abcdefgh12345678 token ABCDEFGH ApiKey zzzzzzzzzzzz",
            "USER=alice USERNAME: bob LOGNAME=carol",
            "sk-ant-api03-abcdefghijk sk-proj-abcdefghijklmnopqr ghp_abcdefghijklmnop1234 github_pat_ABCDEFGHIJKLMNOPQRSTUV",
            "glpat-abcdefghijklmnop xoxb-1234567890-abc xapp-1-ABCDEFGHIJK https://hooks.slack.com/services/T0/B0/XYZ",
            "AKIAABCDEFGHIJKLMNOP AIzaSyA1234567890abcdefghijklmnopqrstu ya29.a0AfH6SMBabc sk_live_abcdefghij1234",
            "npm_abcdefghijklmnopqrstuvwxyz123456 dop_v1_" + String(repeating: "ab12", count: 11) + " hf_abcdefghijklmnopqrstu",
            "sbp_0123456789abcdef0123 shpat_0123456789abcdef0123 SG.abcdefghijklmnop.qrstuvwxyzABCDEFGH",
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N",
            "entropy Zx9Kq2Lm8Np4Rt6Vw1Yb3Cd5Fg7Hj0Ks and lowentropy aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa1",
            "uuid 123e4567-e89b-12d3-a456-426614174000 and 123E4567-E89B-12D3-A456-426614174000",
            "dashes a1-b2-c3-d4-e5-f6g7h8i9j0k1l2m3n4o5p6q7r8s9 underscores Ab1_Cd2_Ef3_Gh4Ij5Kl6Mn7Op8Qr9St0Uv",
            "/Users/alice/Projects/app and /home/bob/x and C:\\Users\\Carol\\Desktop and c:\\users\\dave\\x",
            "~alice/ x alice/y @alice\nalice/start /x/alice 'alice' alicex/ path:alice/",
            "",
            "plain text with nothing secret in it",
        ]
        for home in ["", "/Users/alice", FileManager.default.homeDirectoryForCurrentUser.path] {
            for text in corpus {
                XCTAssertEqual(BackendGitHubSecretRedaction.redact(text, home: home), Self.perCall(text, home: home), "home \(home): \(text)")
            }
        }
        XCTAssertEqual(BackendGitHubSecretRedaction.redact(corpus[6]), Self.perCall(corpus[6], home: FileManager.default.homeDirectoryForCurrentUser.path))
    }

    /// The version before 2 Nov, verbatim, as the reference (it compiled every pattern on every call).
    private static func perCall(_ value: String, home: String) -> String {
        var out = value
        func replace(_ pattern: String, _ template: String, options: NSRegularExpression.Options = []) {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            out = expression.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: template)
        }
        let key = #"[A-Za-z0-9_.\[\]-]*(?:token|secret|passwd|password|pwd|api[_-]?key|access[_-]?key|apikey|credential|auth(?!or)|bearer|private[_-]?key|client[_-]?secret|signature|session[_-]?key)[A-Za-z0-9_.\[\]-]*"#
        let headers = "authorization|proxy-authorization|www-authenticate|x-api-key|api-key|apikey|x-auth-token|x-access-token|cookie|set-cookie|x-csrf-token"
        replace(#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#, "-----BEGIN PRIVATE KEY-----[redacted]-----END PRIVATE KEY-----")
        replace(#"-----BEGIN (?:OPENSSH|PGP|RSA|EC|DSA) [A-Z ]*-----[\s\S]*?-----END [A-Z ]*-----"#, "-----BEGIN KEY-----[redacted]-----END KEY-----")
        replace(#"\b([a-z][a-z0-9+.-]*://)[^/\s:@]+:[^/\s@]+@"#, "$1[redacted]@", options: .caseInsensitive)
        replace("(\"(?:" + headers + ")\"\\s*:\\s*)\"[^\"]*\"", "$1\"[redacted]\"", options: .caseInsensitive)
        replace("\\b((?:" + headers + ")\\s*:\\s*)[^\\r\\n\"']+", "$1[redacted]", options: .caseInsensitive)
        replace("\\b(" + key + #")("?\s*[:=]\s*)(["'])(?:\\.|(?!\3)[^\\])*\3"#, "$1$2$3[redacted]$3", options: .caseInsensitive)
        replace("\\b(" + key + #")(\s*[:=]\s*)(?!\[redacted\])([^\s,;)}\]"']+)"#, "$1$2[redacted]", options: .caseInsensitive)
        replace(#"\b(Bearer|Basic|Token|ApiKey)\s+[A-Za-z0-9._~+/=-]{8,}"#, "$1 [redacted]", options: .caseInsensitive)
        replace(#"\b(USER|USERNAME|LOGNAME)(\s*[:=]\s*)([A-Za-z0-9._-]+)"#, "$1$2<user>")
        let tokenPatterns = [#"\bsk-ant-[A-Za-z0-9_-]{10,}"#, #"\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{16,}"#, #"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{16,}"#, #"\bgithub_pat_[A-Za-z0-9_]{20,}"#, #"\bglpat-[A-Za-z0-9_-]{16,}"#, #"\bxox[abprse]-[A-Za-z0-9-]{10,}"#, #"\bxapp-[0-9]-[A-Za-z0-9-]{10,}"#, #"https://hooks\.slack\.com/services/[A-Za-z0-9/]+"#, #"\b(?:AKIA|ASIA|AGPA|AIDA|AROA)[0-9A-Z]{16}\b"#, #"\bAIza[A-Za-z0-9_-]{30,}"#, #"\bya29\.[A-Za-z0-9_-]{10,}"#, #"\b[sprk]k_(?:live|test)_[A-Za-z0-9]{10,}"#, #"\bnpm_[A-Za-z0-9]{30,}"#, #"\bdop_v1_[a-f0-9]{40,}"#, #"\bhf_[A-Za-z0-9]{20,}"#, #"\bsbp_[a-f0-9]{20,}"#, #"\bshp(?:at|ca|pa|ss)_[a-f0-9]{20,}"#, #"\bSG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}"#, #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{4,}"#]
        for pattern in tokenPatterns { replace(pattern, "[redacted]") }
        if let regex = try? NSRegularExpression(pattern: #"[A-Za-z0-9+=_-]{32,}"#) {
            for match in regex.matches(in: out, range: NSRange(out.startIndex..., in: out)).reversed() {
                guard let range = Range(match.range, in: out) else { continue }
                let candidate = String(out[range])
                guard !BackendGitHubRules.matches(candidate, #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#),
                      BackendGitHubRules.matches(candidate, "[0-9]"), BackendGitHubRules.matches(candidate, "[A-Za-z]"), candidate.filter({ $0 == "-" || $0 == "_" }).count <= 2 else { continue }
                let counts = candidate.reduce(into: [Character: Int]()) { $0[$1, default: 0] += 1 }
                let entropy = counts.values.reduce(0.0) { let p = Double($1) / Double(candidate.count); return $0 - p * log2(p) }
                if entropy >= 3 { out.replaceSubrange(range, with: "[redacted]") }
            }
        }
        if !home.isEmpty { out = out.replacingOccurrences(of: home, with: "~") }
        replace(#"(/Users/|/home/)[A-Za-z0-9._-]+"#, "$1<user>")
        replace(#"([A-Za-z]:\\Users\\)[A-Za-z0-9._-]+"#, "$1<user>", options: .caseInsensitive)
        let username = URL(fileURLWithPath: home).lastPathComponent
        if username.count >= 2 { replace("(?:(?<=^|[\\s/\\\\:~@])" + NSRegularExpression.escapedPattern(for: username) + "(?=[/\\\\@]))|(?:(?<=[/\\\\~@])" + NSRegularExpression.escapedPattern(for: username) + "(?=$|[/\\\\@\\s'\"]))", "<user>", options: .anchorsMatchLines) }
        return out
    }
}
