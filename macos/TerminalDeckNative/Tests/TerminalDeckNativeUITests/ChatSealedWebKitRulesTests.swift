import Foundation
import WebKit
import XCTest
@testable import TerminalDeckNativeCore

@MainActor
final class ChatSealedWebKitRulesTests: XCTestCase {
    func testProductionContentRulesCompileInWebKit() async throws {
        // ICU accepts alternation; WebKit's restricted rule compiler does not.
        // Exercise the real compiler so rejected rules cannot blank every visual.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("td-chat-rule-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try XCTUnwrap(WKContentRuleListStore(url: directory))
        let result = try await store.compileContentRuleList(forIdentifier: "sealed-production-rules", encodedContentRuleList: NativeChatSealedDocument.contentRules)
        let compiled = try XCTUnwrap(result)
        XCTAssertEqual(compiled.identifier, "sealed-production-rules")
    }
}
