import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

@MainActor final class DeployBoardPersistenceTests: XCTestCase {
    func testNearbyChangesShareBackgroundSaveAndLatestLedgerWins() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/part53-test-scratch/" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let board = DeployBoard()
        board.configure(dataRoot: root)
        for index in 0..<15 { board.change { $0.imports.append("run-\(index)") } }
        XCTAssertEqual(board.ledger.imports.count, 15)
        XCTAssertEqual(board.saveCount, 0)
        await board.waitForSave()
        XCTAssertEqual(board.saveCount, 1)
        let file = root.appendingPathComponent(DeployLedgerFile.name)
        XCTAssertEqual(DeployLedgerFile.load(file).ledger, board.ledger)
        board.change { $0.imports.append("last") }
        await board.waitForSave()
        XCTAssertEqual(board.saveCount, 2)
        XCTAssertEqual(DeployLedgerFile.load(file).ledger.imports.last, "last")
    }
}
