import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Real app T11 (11 Oct): Codex prints a server's env map in a new key order on every `mcp list --json`, so the
/// agent-settings launch saw "changed during launch" every time and a Codex agent never started.
final class L8CodexExportOrderTests: XCTestCase {
    private func export(_ env: [(String, String)], args: [String] = ["a", "b"]) throws -> NativeRPCValue {
        let pairs = env.map { "\"\($0.0)\":\"\($0.1)\"" }.joined(separator: ",")
        let json = #"[{"name":"node_repl","enabled":true,"disabled_reason":null,"auth_status":"unsupported","startup_timeout_sec":null,"tool_timeout_sec":null,"transport":{"type":"stdio","command":"node","args":["# + args.map { "\"\($0)\"" }.joined(separator: ",") + #"],"env":{"# + pairs + #"}}},{"name":"idea","enabled":true,"auth_status":"oauth","transport":{"type":"streamable_http","url":"http://x"}}]"#
        return try BackendAGSSelectedAccountFacts.codexServers(try NativeRPCValue.parseJSON(Data(json.utf8)))
    }
    func testTheSameServersInAnotherKeyOrderAreTheSameInventory() throws {
        let first = try export([("A", "1"), ("B", "2"), ("C", "3")]), second = try export([("C", "3"), ("A", "1"), ("B", "2")])
        XCTAssertEqual(first, second)
        XCTAssertEqual(try first.encodedJSON(), try second.encodedJSON(), "the fingerprint is taken from the encoded form")
    }
    func testARealChangeIsStillSeen() throws {
        XCTAssertNotEqual(try export([("A", "1")]), try export([("A", "2")]))
        XCTAssertNotEqual(try export([("A", "1")], args: ["a", "b"]), try export([("A", "1")], args: ["b", "a"]), "argument order still counts")
    }
}
