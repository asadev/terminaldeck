import Foundation
import XCTest
@testable import TerminalDeckNativeCore

final class CloudConversationProjectionTests: XCTestCase {
  func testClaudeMapsOnlyMetadataAndPreservesConversationAndMessageText() throws {
    let raw = Data("{\"sessionId\":\"same-id\",\"cwd\":\"/source/app\",\"message\":{\"content\":\"keep /source/app exact\"}}\n".utf8)
    let result = try CloudConversationProjection.project(raw, provider: .claude, conversationID: "same-id", oldPath: "/source/app", newPath: "/dest/app", jsonLines: true)
    let value = try NativeRPCValue.parseJSON(result.bytes)
    XCTAssertEqual(value["cwd"].string, "/dest/app")
    XCTAssertEqual(value["sessionId"].string, "same-id")
    XCTAssertEqual(value["message"]["content"].string, "keep /source/app exact")
    XCTAssertEqual(result.rawHash, CloudSyncBytes.hash(raw))
  }
  func testCodexMapsMetadataAndTurnContextWithoutRewritingMessages() throws {
    let raw = Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"same-id\",\"cwd\":\"/source/app\"}}\n{\"type\":\"turn_context\",\"payload\":{\"cwd\":\"/source/app\"}}\n{\"type\":\"response_item\",\"payload\":{\"text\":\"/source/app\"}}\n".utf8)
    let result = try CloudConversationProjection.project(raw, provider: .codex, conversationID: "same-id", oldPath: "/source/app", newPath: "/dest/app", jsonLines: true)
    let lines = try result.bytes.split(separator: 10).map { try NativeRPCValue.parseJSON(Data($0)) }
    XCTAssertEqual(lines[0]["payload"]["id"].string, "same-id")
    XCTAssertEqual(lines[0]["payload"]["cwd"].string, "/dest/app")
    XCTAssertEqual(lines[1]["payload"]["cwd"].string, "/dest/app")
    XCTAssertEqual(lines[2]["payload"]["text"].string, "/source/app")
  }
  func testGeminiRewriteKeepsIDAndMessagesAndChangesOnlyProjectHash() throws {
    let raw = Data("{\"sessionId\":\"same-id\",\"projectHash\":\"\(CloudSyncBytes.hash(Data("/source/app".utf8)))\",\"messages\":[{\"text\":\"/source/app\"}]}".utf8)
    let result = try CloudConversationProjection.project(raw, provider: .gemini, conversationID: "same-id", oldPath: "/source/app", newPath: "/dest/app", jsonLines: false)
    let value = try NativeRPCValue.parseJSON(result.bytes), original = try NativeRPCValue.parseJSON(raw)
    XCTAssertEqual(value["sessionId"].string, "same-id")
    XCTAssertEqual(value["messages"], original["messages"])
    XCTAssertEqual(value["projectHash"].string, CloudSyncBytes.hash(Data("/dest/app".utf8)))
  }
  func testWrongIdentityAndOversizedProjectionRefuseRatherThanStartFresh() {
    XCTAssertThrowsError(try CloudConversationProjection.project(Data("{\"sessionId\":\"other\"}".utf8), provider: .claude,
      conversationID: "wanted", oldPath: "/a", newPath: "/b", jsonLines: true))
    XCTAssertThrowsError(try CloudConversationProjection.project(Data(repeating: 65, count: CloudWire.maximumPlainChunkBytes + 1), provider: .claude,
      conversationID: "wanted", oldPath: "/a", newPath: "/b", jsonLines: true))
  }
}
