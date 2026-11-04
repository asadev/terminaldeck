import Foundation
import XCTest
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

final class AgentStartFolderFenceTests: XCTestCase {
    func testOtherSpellingsOfABusyFolderKeepTheSameRefusal() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("agent-folder-fence-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let folder = scratch.appendingPathComponent("project"), alias = scratch.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
        let row = NativeRPCValue.object([.init("id", .string("busy")), .init("cwd", .string(folder.path)), .init("exitCode", .null)])
        for path in [folder.path, folder.path + "/", folder.path + "/.", alias.path] {
            XCTAssertThrowsError(try BackendDeckCoreCatalogueBuiltins.requireStartRoom(cwd: path, sessions: [row], startedByCaller: { _ in true })) { error in
                XCTAssertTrue(error.localizedDescription.contains("separate git worktree"))
            }
        }
        XCTAssertNoThrow(try BackendDeckCoreCatalogueBuiltins.requireStartRoom(cwd: scratch.appendingPathComponent("another").path,
            sessions: [row], startedByCaller: { _ in true }))
        XCTAssertNoThrow(try BackendAgentStartSelection.requireSafeFolder("/fixture/data/workspaces/owned/subfolder", storageRoot: "/fixture/data",
            workspaceFolders: ["/fixture/data/workspaces/owned"]))
        XCTAssertThrowsError(try BackendAgentStartSelection.requireSafeFolder("/fixture/data/private", storageRoot: "/fixture/data",
            workspaceFolders: ["/fixture/data/workspaces/owned"]))
    }
}
