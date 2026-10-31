import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private struct BackendDeckCoreTestPortSecurityEchoPeer: BackendDeckCoreSecurityMCPExchangePeer {
    let closed: BackendDeckCoreSecurityTestBox<Int>
    let serverInfo = NativeRPCValue.object([.init("name", .string("probe")), .init("version", .string("1"))])
    func answer(method: String, parameters: NativeRPCValue, cancellation: BackendMCPCancellation) async throws -> NativeRPCValue {
        switch method {
        case "tools/list": return .object([.init("tools", .array([.object([.init("name", .string("echo")), .init("inputSchema", .object([.init("type", .string("object"))]))])]))])
        case "tools/call": return .object([.init("content", .array([.object([.init("type", .string("text")), .init("text", .string("called " + (parameters["name"].string ?? "")))])]))])
        default: throw BackendDeckCoreSecurityProtocolError(code: -32601, message: "Method not found")
        }
    }
    func close() async { closed.edit { $0 += 1 } }
}
final class BackendDeckCoreTestPortSecurityMCPExchange: BackendDeckCoreTestPortSecurityCase {
    private func factory(_ eras: BackendDeckCoreSecurityTestBox<[String]>, _ closed: BackendDeckCoreSecurityTestBox<Int>) -> BackendDeckCoreSecurityMCPExchangeFactory {
        { era in eras.edit { $0.append(era.rawValue) }; return BackendDeckCoreTestPortSecurityEchoPeer(closed: closed) }
    }
    func testMcpServeL46() {
        let headers = BackendDeckCoreSecurityServer.withStandardHeaders([:], parsed: rpc("tools/call", params: o([("name", .string("sessions_list"))])))
        XCTAssertEqual(headers["mcp-method"], "tools/call"); XCTAssertEqual(headers["mcp-name"], "sessions_list")
    }
    func testMcpServeL52() {
        let replaced = BackendDeckCoreSecurityServer.withStandardHeaders(["mcp-method": "tools/list"], parsed: rpc("tools/call", params: o([("name", .string("résumé tool"))])))
        XCTAssertEqual(replaced["mcp-method"], "tools/call"); XCTAssertEqual(replaced["mcp-name"], "=?base64?" + Data("résumé tool".utf8).base64EncodedString() + "?=")
        XCTAssertNil(BackendDeckCoreSecurityServer.withStandardHeaders([:], parsed: rpc("notifications/initialized", id: .missing))["mcp-method"])
        XCTAssertNil(BackendDeckCoreSecurityServer.withStandardHeaders([:], parsed: .array([rpc("ping")]))["mcp-method"])
    }
    func testMcpServeL67() async throws {
        let f = try rig(), server = f.server(), eras = BackendDeckCoreSecurityTestBox<[String]>([]), closed = BackendDeckCoreSecurityTestBox(0)
        let body = rpc("tools/call", params: o([("name", .string("echo")), ("arguments", .object([]))]))
        let answer = await server.serve(parsed: body, headers: headers, cancellation: .init(), factory: factory(eras, closed)), value = try response(answer)
        XCTAssertEqual(eras.get(), ["legacy"]); XCTAssertEqual(answer.status, 200); XCTAssertTrue(answer.headers["content-type"]?.hasPrefix("application/json") == true)
        assertValue(value["result"]["content"], .array([o([("type", .string("text")), ("text", .string("called echo"))])]))
        XCTAssertEqual(closed.get(), 1)
    }
    func testMcpServeL77() async throws {
        let f = try rig(), server = f.server(), eras = BackendDeckCoreSecurityTestBox<[String]>([]), closed = BackendDeckCoreSecurityTestBox(0)
        let body = rpc("tools/call", id: .number(2), params: o([("name", .string("echo")), ("arguments", .object([]))]), modern: true)
        var h = headers; h["mcp-protocol-version"] = "2026-07-28"
        let refused = await server.serve(parsed: body, headers: h, cancellation: .init(), factory: factory(eras, closed)), no = try response(refused)
        XCTAssertEqual(refused.status, 400); XCTAssertEqual(no["error"]["code"], .number(-32020)); XCTAssertTrue(eras.get().isEmpty)
        h = BackendDeckCoreSecurityServer.withStandardHeaders(h, parsed: body)
        let answer = await server.serve(parsed: body, headers: h, cancellation: .init(), factory: factory(eras, closed)), value = try response(answer)
        XCTAssertEqual(eras.get(), ["modern"]); XCTAssertEqual(answer.status, 200); XCTAssertEqual(value["result"]["content"].elements?.first?["text"], .string("called echo")); XCTAssertEqual(value["result"]["resultType"], .string("complete"))
    }
    func testMcpServeL102() async throws {
        let f = try rig(), server = f.server(), eras = BackendDeckCoreSecurityTestBox<[String]>([]), closed = BackendDeckCoreSecurityTestBox(0)
        var h = headers; h["mcp-protocol-version"] = "2026-07-28"
        let answer = await server.serve(parsed: rpc("subscriptions/listen", id: .number(3), modern: true), headers: h, cancellation: .init(), factory: factory(eras, closed))
        let value = try response(answer); XCTAssertEqual(value["id"], .number(3)); XCTAssertEqual(value["error"]["code"], .number(-32601)); XCTAssertTrue(eras.get().isEmpty)
    }
}
