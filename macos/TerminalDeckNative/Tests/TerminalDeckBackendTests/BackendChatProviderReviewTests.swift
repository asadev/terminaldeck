import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendChatProviderReviewTests: XCTestCase, @unchecked Sendable {
    private func json(_ text: String) throws -> NativeRPCValue { try .parseJSON(Data(text.utf8)) }

    func testNativeTargetsStayTypedAndRejectUnknownScopes() throws {
        XCTAssertEqual(try BackendChatProviderReview.target(json(#"{"target":"baseBranch","branch":"selected-base"}"#))["branch"].string, "selected-base")
        XCTAssertThrowsError(try BackendChatProviderReview.target(json(#"{"target":"commit","sha":"not a commit"}"#)))
        XCTAssertEqual(try BackendChatProviderReview.target(json(#"{"scope":"baseBranch","branch":"lane/native-full"}"#)),
                       try json(#"{"type":"baseBranch","branch":"lane/native-full"}"#))
        XCTAssertEqual(try BackendChatProviderReview.target(json(#"{"type":"commit","sha":"e21be85e"}"#))["sha"].string, "e21be85e")
        XCTAssertThrowsError(try BackendChatProviderReview.target(json(#"{"type":"commit","sha":"HEAD;touch /tmp/no"}"#)))
        XCTAssertThrowsError(try BackendChatProviderReview.target(json(#"{"type":"custom","instructions":" "}"#)))
        XCTAssertThrowsError(try BackendChatProviderReview.target(json(#"{"type":"whatever"}"#)))
    }

    func testReviewIsTrackedUntilCompletionAndOutputIsScoped() throws {
        var rpc = BackendHootChatRPC(provider: .codex, setup: .init(cwd: "/scratch"))
        let hello = try rpc.begin(id: "hello", resume: nil)
        let next = try rpc.receive(.object([.init("id", hello["id"]), .init("result", .object([]))])).send.last!
        _ = try rpc.receive(.object([.init("id", next["id"]), .init("result", json(#"{"thread":{"id":"main"}}"#))]))
        let review = try rpc.review(arguments: json(#"{"type":"baseBranch","branch":"main"}"#), id: "review")
        XCTAssertEqual(review["method"].string, "review/start")
        XCTAssertEqual(review["params"]["target"]["type"].string, "baseBranch")
        XCTAssertThrowsError(try rpc.user("must wait", attachments: [], id: "other"))
        _ = try rpc.receive(json(#"{"id":"review","result":{"turn":{"id":"r1"},"reviewThreadId":"main"}}"#))
        let output = try json(#"{"method":"item/completed","params":{"threadId":"main","turnId":"r1","item":{"id":"out","type":"exitedReviewMode","review":"{\"findings\":[{\"title\":\"Check bounds\",\"code_location\":{\"absolute_file_path\":\"/scratch/a.swift\",\"line_range\":{\"start\":2}}}]}"}}}"#)
        let records = try rpc.receive(output).records
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].value["findings"].elements?.first?["title"].string, "Check bounds")
        XCTAssertEqual(records[0].value["reviewOutput"]["type"].string, "exitedReviewMode")
        XCTAssertTrue(BackendChatProviderReview.records(output, conversation: "foreign").isEmpty)
        _ = try rpc.receive(json(#"{"method":"turn/completed","params":{"threadId":"main","turn":{"id":"r1","status":"completed"}}}"#))
        XCTAssertNoThrow(try rpc.user("next", attachments: [], id: "next"))
    }
}
