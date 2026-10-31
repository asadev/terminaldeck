import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative
@MainActor final class ChatAgentTreeTests: XCTestCase {
    func testHierarchyOrdersChildrenAndKeepsOrphansAndCyclesWithoutInventingTranscripts() async throws {
        func task(_ id: String, _ parent: String? = nil) -> NativeRPCValue { .object([.init("id", .string(id)), .init("kind", .string("agent")), .init("parentId", parent.map(NativeRPCValue.string) ?? .null)]) }
        let nodes = NativeChatAgentTree.nodes([task("child", "parent"), task("parent"), task("orphan", "outside"), task("cycleA", "cycleB"), task("cycleB", "cycleA")])
        XCTAssertEqual(nodes.count, 5); XCTAssertEqual(Set(nodes.compactMap { $0.task["id"].string }).count, 5)
        XCTAssertEqual(nodes[0].task["id"].string, "parent"); XCTAssertEqual(nodes[1].depth, 1)
        XCTAssertEqual(nodes.first { $0.task["id"].string == "orphan" }?.parent, "outside")
        XCTAssertTrue(nodes.first { $0.task["id"].string == "cycleA" }?.cycle == true)
        let deep = NativeChatAgentTree.nodes((0..<70).map { task("depth\($0)", $0 == 0 ? nil : "depth\($0 - 1)") })
        XCTAssertEqual(deep.count, 70); XCTAssertFalse(deep.contains { $0.cycle })
        XCTAssertNil(NativeChatAgentTree.source(task("parent"), events: []))
        let model = NativeHootChatModel(fixture: .object([.init("children", .array([task("parent")]))]))
        do { _ = try await model.agentTreeTool("task", request: "parent"); XCTFail("Provider IDs must not open fabricated app transcripts") } catch { }
    }
}
