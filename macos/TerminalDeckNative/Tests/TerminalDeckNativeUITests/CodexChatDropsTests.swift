import AppKit
import SwiftUI
import XCTest
import TerminalDeckNativeCore
import TerminalDeckBackend
@testable import TerminalDeckNative

@MainActor final class CodexChatDropsTests: XCTestCase {
  func testFinishedChatBoardInBothThemes() throws {
    let owner = DeckMemoryOwner.project("scratch-chat-drops")
    let store = NativeMemoryStore(owner: owner, fixture: true)
    let stamp = DeckMemoryStamp(owner: owner, project: "scratch-chat-drops")
    var board = DeckMemoryFlowBoard()
    _ = board.sessionSeen(.init(id: "scratch-chat", title: "Finished Codex job", provider: "codex", stamp: stamp, chat: true))
    let changes = board.sessionExited(id: "scratch-chat", code: 0)
    let doing = try XCTUnwrap(changes.updates.first { $0.id == "session:scratch-chat" }?.doing)
    XCTAssertEqual(doing, "Finished")
    store.board = [DeckMemoryBoardRow(id: "session:scratch-chat", kind: .session, title: "Finished Codex job",
      labels: .init(owner: owner, project: "scratch-chat-drops", date: Date(), type: "session"), doing: doing,
      lastResult: "The job finished successfully. Its answer is kept in the chat.", updatedAt: Date())]
    store.loaded = true
    for dark in [false, true] {
      let size = CGSize(width: 1000, height: 620)
      let view = NativeMemoryArea(owner: owner, name: "Scratch project", filledBy: "Codex", fixture: store, part: .board)
      let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light)
        .frame(width: size.width, height: size.height))
      host.sizingOptions = []
      host.frame = NSRect(origin: .zero, size: size)
      host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      host.layoutSubtreeIfNeeded()
      let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
      var out = URL(fileURLWithPath: #filePath)
      for _ in 0..<4 { out.deleteLastPathComponent() }
      out.appendPathComponent("design-2026-10-10/built.noindex/codex-chat-drops")
      try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
      try png.write(to: out.appendingPathComponent(dark ? "board-dark.png" : "board-light.png"), options: .atomic)
    }
  }
}
