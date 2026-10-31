import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// 27 Oct walk (g): a start from the person's own phone is the Mac's last folder too, as its New session dialog's is.
final class PhoneStartFolderTests: XCTestCase {
    func testAPhoneStartIsTheMacsLastFolder() throws {
        let suite = "td-phone-start-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        NativePhoneStart.rememberFolder("/Users/someone/Projects/App", defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: NativeNewSessionEffects.lastFolderKey), "/Users/someone/Projects/App")
        // Never a relative, multi-line or oversized path: the last good folder stays.
        for unusable in ["Projects/App", "/a\nb", "/" + String(repeating: "x", count: 1100)] {
            NativePhoneStart.rememberFolder(unusable, defaults: defaults)
            XCTAssertEqual(defaults.string(forKey: NativeNewSessionEffects.lastFolderKey), "/Users/someone/Projects/App")
        }
    }

    /// 28 Oct phone review: the New session form listed "Shell" twice (both ticked) and one login kept twice twice.
    func testThePhonesNewSessionListsShellOnceAndOneRowPerLogin() async throws {
        let lists = await NativePhoneStart.choices(folder: nil) { channel, _ in
            switch channel {
            case "providers:detect":
                return .object([.init("claude", .bool(true)), .init("codex", .bool(true)), .init("gemini", .bool(false)), .init("shell", .bool(true))])
            case "profiles:list":
                return .object([.init("profiles", .array([
                    .object([.init("id", .string("system")), .init("name", .string("Default")), .init("provider", .string("claude")), .init("system", .bool(true))]),
                    .object([.init("id", .string("kept-1")), .init("name", .string("app@example.com")), .init("provider", .string("claude"))]),
                    .object([.init("id", .string("kept-2")), .init("name", .string("App@example.com")), .init("provider", .string("claude"))]),
                    .object([.init("id", .string("codex-1")), .init("name", .string("app@example.com")), .init("provider", .string("codex"))])])),
                    .init("vault", .object([.init("kept-1", .object([.init("keptBy", .string("app"))])), .init("kept-2", .object([.init("keptBy", .string("app"))])),
                                            .init("codex-1", .object([.init("keptBy", .string("app"))]))]))])
            default: throw NativeRPCError(code: "unavailable", message: "not in this test")
            }
        }
        let providers = (lists["providers"].elements ?? []).compactMap { $0["id"].string }
        XCTAssertEqual(providers.filter { $0 == "shell" }.count, 1, "Shell once")
        XCTAssertEqual(Set(providers).count, providers.count, "every AI once")
        XCTAssertEqual((lists["accounts"].elements ?? []).compactMap { $0["id"].string }, ["system", "kept-1", "codex-1"],
                       "one login kept twice is one row; the same address under Codex is Codex's own")
    }

    /// Reviewer 28 Oct (SHOULD 1): the phone folds and names New session's logins on the same live sign-in facts as
    /// the Mac's own dialog: this Mac's own sign-in and its kept copy are one row; a stale saved name hides nothing.
    func testThePhonesNewSessionAccountsUseTheMacsLiveSignInFacts() async throws {
        let live: [String: String] = ["system": "app@example.com", "kept-1": "new@example.com", "kept-2": "app@example.com", "codex-1": "app@example.com"]
        let lists = await NativePhoneStart.choices(folder: nil) { channel, arguments in
            switch channel {
            case "providers:detect": return .object([.init("claude", .bool(true)), .init("codex", .bool(true))])
            case "profiles:list":
                return .object([.init("profiles", .array([
                    .object([.init("id", .string("system")), .init("name", .string("Default")), .init("provider", .string("claude")), .init("system", .bool(true))]),
                    .object([.init("id", .string("kept-1")), .init("name", .string("app@example.com")), .init("provider", .string("claude"))]),
                    .object([.init("id", .string("kept-2")), .init("name", .string("app@example.com")), .init("provider", .string("claude"))]),
                    .object([.init("id", .string("codex-1")), .init("name", .string("app@example.com")), .init("provider", .string("codex"))])]))])
            case "profiles:signin":
                let id = arguments.first?.string ?? ""
                return .object([.init("state", .string("signed-in")), .init("account", live[id].map(NativeRPCValue.string) ?? .null), .init("detail", .string("Signed in."))])
            case "profiles:effective":
                // This folder starts Claude with the kept copy: that row stays, this Mac's own folds into it.
                return arguments.first?["provider"].string == "claude" ? .object([.init("accountId", .string("kept-2"))]) : .object([])
            default: throw NativeRPCError(code: "unavailable", message: "not in this test")
            }
        }
        let rows = lists["accounts"].elements ?? []
        XCTAssertEqual(rows.compactMap { $0["id"].string }, ["kept-1", "kept-2", "codex-1"],
                       "kept-1's saved name is stale: it is another login and stays; this Mac's own folds into kept-2")
        XCTAssertEqual(rows.compactMap { $0["name"].string }, ["new@example.com", "app@example.com", "app@example.com"], "named as the Mac names them")
        let claude = (lists["providers"].elements ?? []).first { $0["id"].string == "claude" }
        XCTAssertEqual(claude?["defaultAccount"].string, "kept-2")
    }
}
