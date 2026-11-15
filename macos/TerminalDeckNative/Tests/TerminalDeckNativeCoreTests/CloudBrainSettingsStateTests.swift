import Foundation
import XCTest
@testable import TerminalDeckNativeCore

final class CloudBrainSettingsStateTests: XCTestCase, @unchecked Sendable {
  private let deviceA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", deviceB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
  private let subject = String(repeating: "1", count: 64)
  private let cut = CloudSnapshotCut(snapshotId: "fixture", at: 1, watermarks: [:])

  func testS11OpenSessionsAreOnlyHistoryAndNeverImportedAsProcesses() async throws {
    let oldSession: NativeRPCValue = .object([.init("id", .string("source-session")), .init("tabKey", .string("source-tab")),
      .init("agentSessionId", .string("conversation")), .init("provider", .string("claude")), .init("pid", .number(123)), .init("socket", .string("fixture-socket"))])
    let a = NativeStateStore(initialState: .object([.init("version", .number(1)), .init("projects", .array([.object([.init("path", .string("/source/app"))])])),
      .init("openSessions", .array([oldSession])), .init("preferences", .object([.init("fontSize", .number(16))]))]))
    let destinationSession: NativeRPCValue = .object([.init("id", .string("destination-session"))])
    let b = NativeStateStore(initialState: .object([.init("openSessions", .array([destinationSession])), .init("projects", .array([.object([.init("path", .string("/dest/existing"))])]))]))
    try await a.cloudAttach(.init(subjectHash: subject, deviceID: deviceA)); try await b.cloudAttach(.init(subjectHash: subject, deviceID: deviceB))
    let beforeA = await a.getState(), beforeB = await b.getState()
    let snapshot = try await a.cloudStateSnapshot(cut: cut)
    let results = try await b.cloudStateImport(snapshot.operations)
    let afterA = await a.getState(), afterB = await b.getState()
    XCTAssertEqual(afterA, beforeA)
    XCTAssertEqual(afterB["openSessions"], beforeB["openSessions"])
    XCTAssertEqual(afterB["projects"], beforeB["projects"])
    XCTAssertEqual(afterB["preferences"]["fontSize"].number, 16, "A portable preference is shown")
    let history = try XCTUnwrap(snapshot.operations.first { $0.entityId.hasPrefix("conversation-link:") })
    XCTAssertTrue(history.payload.raw["record"]["pid"].isNullish)
    XCTAssertTrue(history.payload.raw["record"]["socket"].isNullish)
    XCTAssertEqual(history.payload.raw["record"]["agentSessionId"].string, "conversation")
    XCTAssertFalse(results.contains { $0.status == .blocked })
    let retained = try await b.cloudStateRetained(snapshot.operations)
    XCTAssertTrue(retained)
  }

  /// Finding 19d: an open session without a key keeps the same id when the list order changes.
  func testKeylessSessionIdsDoNotDependOnListOrder() {
    let one: NativeRPCValue = .object([.init("agentSessionId", .string("one")), .init("provider", .string("claude"))])
    let two: NativeRPCValue = .object([.init("agentSessionId", .string("two")), .init("provider", .string("codex"))])
    let first = CloudBrainSettingsState.records(.object([.init("openSessions", .array([one, two]))])).map(\.id)
    let swapped = CloudBrainSettingsState.records(.object([.init("openSessions", .array([two, one]))])).map(\.id)
    XCTAssertEqual(Set(first), Set(swapped))
    XCTAssertFalse(first.contains { $0.contains("origin-index") })
  }

  /// Finding 19e: a project row without a path is exported instead of failing the whole store.
  func testProjectRowWithoutPathIsStillExported() {
    let rows = CloudBrainSettingsState.records(.object([.init("projects", .array([.object([.init("name", .string("No path"))]),
      .object([.init("path", .string("/fixture/a"))])]))]))
    XCTAssertEqual(rows.filter { $0.id.hasPrefix("project:") }.count, 2)
  }
}
