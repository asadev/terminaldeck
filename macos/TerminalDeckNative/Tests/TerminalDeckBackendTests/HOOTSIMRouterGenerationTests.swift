import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private actor HOOTSIMDelayedChatLoad {
    private var chat = "old-chat"
    private var loads = 0
    private var held: [Int: CheckedContinuation<Void, Never>] = [:]
    private var receipts: [(Int, CheckedContinuation<Void, Never>)] = []
    let oldID = UUID().uuidString, newID = UUID().uuidString
    func identity() -> String { chat }
    func switchChat() { chat = "new-chat" }
    func load() async -> [NativeRPCValue] {
        let captured = chat, id = chat == "old-chat" ? oldID : newID, index = loads
        loads += 1
        for receipt in receipts where receipt.0 <= loads { receipt.1.resume() }
        receipts.removeAll { $0.0 <= loads }
        // Intentionally ignore cancellation: a slow storage callback can return
        // its prior chat's rows after the coordinator has moved to another chat.
        await withCheckedContinuation(isolation: self) { held[index] = $0 }
        return [.object([.init("id", .string(id)), .init("revision", .string(UUID().uuidString)),
            .init("conversationId", .string(captured)), .init("state", .string("pending")), .init("status", .string("pending"))])]
    }
    func waitForLoads(_ count: Int) async {
        if loads >= count { return }
        await withCheckedContinuation(isolation: self) { receipts.append((count, $0)) }
    }
    func release(_ index: Int) { held.removeValue(forKey: index)?.resume() }
}
final class HOOTSIMRouterGenerationTests: XCTestCase, @unchecked Sendable {
    func testChangingTheUnderlyingChatDuringOneLoadRejectsItWithoutAnotherRead() async throws {
        let loader = HOOTSIMDelayedChatLoad()
        let routing = BackendHOOTSIMRouting(.init(require: { _ in }, conversationID: { await loader.identity() },
            load: { await loader.load() }, append: { _ in }, resolve: { _, _ in .object([]) },
            authorize: { _, _ in XCTFail("Read never asks") }, dispatch: { _, _ in XCTFail("Read never sends"); return .null }))
        let caller = BackendMCPCallContext(sessionID: "fixture", machineID: "", projectRoot: nil, attended: true,
            allowedTools: [], allowedTiers: [.read], cancellation: .init())
        let old = Task { try await routing.read(caller) }
        await loader.waitForLoads(1)
        await loader.switchChat()
        await loader.release(0)
        do { _ = try await old.value; XCTFail("An old load became a successful new-chat read") } catch {}
        let fresh = Task { try await routing.read(caller) }
        await loader.waitForLoads(2)
        await loader.release(1)
        let current = try await fresh.value
        let expected = await loader.newID
        XCTAssertEqual(current["proposals"].elements?.first?["id"].string, expected)
        await routing.stop()
    }
    func testOldUncancellableLoadCannotFinishNewChatsInitialization() async throws {
        let loader = HOOTSIMDelayedChatLoad()
        let routing = BackendHOOTSIMRouting(.init(require: { _ in }, conversationID: { await loader.identity() },
            load: { await loader.load() }, append: { _ in }, resolve: { _, _ in .object([]) },
            authorize: { _, _ in XCTFail("Read never asks") }, dispatch: { _, _ in XCTFail("Read never sends"); return .null }))
        let caller = BackendMCPCallContext(sessionID: "fixture", machineID: "", projectRoot: nil, attended: true,
            allowedTools: [], allowedTiers: [.read], cancellation: .init())
        let old = Task { try await routing.read(caller) }
        await loader.waitForLoads(1)
        await loader.switchChat()
        let fresh = Task { try await routing.read(caller) }
        await loader.waitForLoads(2)
        await loader.release(0)
        do { _ = try await old.value; XCTFail("Old load was accepted for the new chat") } catch {}
        await loader.release(1)
        let current = try await fresh.value
        XCTAssertEqual(current["proposals"].elements?.count, 1)
        let expected = await loader.newID
        XCTAssertEqual(current["proposals"].elements?.first?["id"].string, expected)
        let next = try await routing.read(caller)
        XCTAssertEqual(next, current)
        await routing.stop()
    }
}
