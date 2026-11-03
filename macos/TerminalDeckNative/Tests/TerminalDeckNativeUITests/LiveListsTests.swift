import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Part 25: windows, choices and lists stay live (review items in each test's name comment).
@MainActor
final class LiveListsTests: XCTestCase {
    private func source(_ file: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/" + file), encoding: .utf8)
    }
    private func slice(_ text: String, from start: String, to end: String) throws -> Substring {
        let a = try XCTUnwrap(text.range(of: start), start)
        let b = try XCTUnwrap(text.range(of: end, range: a.upperBound..<text.endIndex), end)
        return text[a.lowerBound..<b.lowerBound]
    }

    /// #42: the @ list and "N sessions available" are read again when sessions start, end or change.
    func testMentionListFollowsSessionsAndAgents() throws {
        for event in ["session:created", "session:exit", "session:removed", "session:renamed", "tasks:changed"] {
            XCTAssertTrue(NativeHootChatModel.mentionEvents.contains(event), event)
        }
        let load = try slice(try source("TerminalDeckNative/NativeHootChat.swift"),
                             from: "private func loadContextMentionCatalogue() async {", to: "func projectReferenceRoot()")
        XCTAssertTrue(load.contains("Self.mentionEvents.map"), "the catalogue listens to the pushes it depends on")
        XCTAssertTrue(load.contains("mentionReload?.cancel()"), "a burst of pushes reads the list once")
    }

    /// #46: quick open asks for the file list on every open; the cache is only the first picture.
    func testQuickOpenReadsFilesOnEveryOpen() throws {
        let load = try slice(try source("TerminalDeckNative/NativeCommandPalette.swift"),
                             from: "private func loadFiles() {", to: "private func searchSessions()")
        XCTAssertFalse(load.contains("if let cached = Self.fileCache[root] {"), "a cached list never ends the load early")
        XCTAssertTrue(load.contains("EngineBridge.shared.invoke(\"search:files\""))
        XCTAssertTrue(load.contains("Self.fileCache[root] = list"))
    }
}
