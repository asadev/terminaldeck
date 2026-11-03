import Foundation
import Testing
@testable import TerminalDeckNativeCore

/// U1 (#21): a state.json that does not read is kept as a .damaged copy before the defaults are saved over it.
@Suite("Damaged state file is kept")
struct DamagedStateFileTests {
    @Test func anUnreadableStateFileIsCopiedBeforeTheFirstSave() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("state.json"), original = Data(#"{"projects":[{"path":"/work/a"}"#.utf8)
        try original.write(to: file)
        let store = try NativeStateStore(file: file, ownership: .exclusive)
        #expect(await store.getProjects().isEmpty)
        try await store.setQuitBehavior(.keep)
        let copies = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("state.json" + DamagedFile.marker) }
        #expect(copies.count == 1)
        #expect(try Data(contentsOf: folder.appendingPathComponent(copies[0])) == original)
        #expect(try Data(contentsOf: file) != original)
        await store.close()
    }
}
