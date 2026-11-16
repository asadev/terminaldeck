import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class CloudConversationProjectionWriterTests: XCTestCase, @unchecked Sendable {
  private typealias Fixture = CloudConversationFixture
  private func seed(_ files: [(String, Data)], provider: CloudConversationProvider, base: URL, prefix: String = "") async throws -> BackendCloudConversationArchive {
    let sourceRoot = base.appendingPathComponent("a")
    for (relative, raw) in files { try CloudBrainAgentsFixture.write(raw, to: sourceRoot.appendingPathComponent(relative)) }
    let content = CloudConversationFixtureContent()
    let archive = try Fixture.archive(base, content: content)
    _ = try await Fixture.transfer(roots: [Fixture.root(provider, directory: sourceRoot, prefix: prefix)], base: base, archive: archive, content: content)
    return archive
  }
  private func manifest(_ archive: BackendCloudConversationArchive, relative: String) async throws -> String {
    let rows = try await archive.manifests(limit: 200)
    return try XCTUnwrap(rows.first { $0.payload.raw["relativePath"].string == relative }?.opId)
  }
  private func staging(_ base: URL) -> URL { Fixture.account(base).appendingPathComponent("branches") }
  func testLongClaudeConversationStreamsBeyondWholeFileCapAndKeepsSourceAndMessages() async throws {
    let base = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: base) }
    let id = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    let header = "{\"sessionId\":\"\(id)\",\"cwd\":\"/source/app\"}\n"
    let line = "{\"type\":\"assistant\",\"message\":{\"content\":\"/source/app " + String(repeating: "x", count: 800) + "\"}}\n"
    let raw = Data((header + String(repeating: line, count: 10_000)).utf8)
    XCTAssertGreaterThan(raw.count, CloudWire.maximumPlainChunkBytes)
    let archive = try await seed([("project/\(id).jsonl", raw)], provider: .claude, base: base)
    let staging = staging(base)
    try CloudBrainAgentsFixture.write(Data("keep".utf8), to: staging.appendingPathComponent("existing"))
    let projected = try await BackendCloudConversationProjectionWriter.project(archive: archive, manifestID: try await manifest(archive, relative: "project/\(id).jsonl"),
      provider: .claude, conversationID: id, projectID: "project", rootID: "root", oldPath: "/source/app", newPath: "/dest/app", stagingDirectory: staging)
    XCTAssertEqual(projected.conversationID, id)
    XCTAssertEqual(projected.rawHash, CloudSyncBytes.hash(raw))
    XCTAssertTrue(try Data(contentsOf: base.appendingPathComponent("a/project/\(id).jsonl")) == raw)
    XCTAssertTrue(try Data(contentsOf: staging.appendingPathComponent("existing")) == Data("keep".utf8))
    let output = try Data(contentsOf: projected.file)
    let firstNewline = try XCTUnwrap(output.firstIndex(of: 10))
    let changed = try NativeRPCValue.parseJSON(Data(output[..<firstNewline]))
    XCTAssertEqual(changed["cwd"].string, "/dest/app")
    XCTAssertEqual(changed["sessionId"].string, id)
    XCTAssertTrue(Data(output[(firstNewline + 1)...]) == Data(String(repeating: line, count: 10_000).utf8))
  }
  /// Finding 18: no plaintext intermediates remain, and a second Continue reuses the same projection.
  func testProjectionLeavesNoRawCopiesAndIsReusedForTheSameDestination() async throws {
    let base = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: base) }
    let id = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    let archive = try await seed([("project/\(id).jsonl", Data("{\"sessionId\":\"\(id)\",\"cwd\":\"/source/app\"}\n".utf8)),
      ("project/\(id)/subagents/agent-child.jsonl", Data("{\"sessionId\":\"\(id)\",\"cwd\":\"/source/app\"}\n".utf8))], provider: .claude, base: base)
    let mainID = try await manifest(archive, relative: "project/\(id).jsonl")
    let first = try await BackendCloudConversationProjectionWriter.project(archive: archive, manifestID: mainID, provider: .claude,
      conversationID: id, projectID: "project", rootID: "root", oldPath: "/source/app", newPath: "/dest/app", stagingDirectory: staging(base))
    let folder = first.transformManifest.deletingLastPathComponent()
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".raw") || $0 == "codex-projection.jsonl" }
    XCTAssertTrue(leftovers.isEmpty)
    // Turns made in the continued session stay; the second Continue does not make another full copy.
    let handle = try FileHandle(forWritingTo: first.file); _ = try handle.seekToEnd(); try handle.write(contentsOf: Data("{\"sessionId\":\"\(id)\"}\n".utf8)); try handle.close()
    let second = try await BackendCloudConversationProjectionWriter.project(archive: archive, manifestID: mainID, provider: .claude,
      conversationID: id, projectID: "project", rootID: "root", oldPath: "/source/app", newPath: "/dest/app", stagingDirectory: staging(base))
    XCTAssertEqual(second.branchID, first.branchID)
    XCTAssertEqual(second.file, first.file)
    XCTAssertEqual(second.supportFiles, first.supportFiles)
    let folders = try FileManager.default.contentsOfDirectory(atPath: staging(base).path).filter { UUID(uuidString: $0) != nil }
    XCTAssertEqual(folders.count, 1)
    XCTAssertTrue(String(decoding: try Data(contentsOf: second.file), as: UTF8.self).hasSuffix("{\"sessionId\":\"\(id)\"}\n"))
  }
  func testCodexProjectionUsesExistingCarryLayoutAndKeepsIdentity() async throws {
    let base = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: base) }
    let id = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    let raw = Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\",\"cwd\":\"/source/app\"}}\n".utf8)
    let relative = "2026/11/12/rollout-2026-11-12T08-00-00-\(id).jsonl"
    let archive = try await seed([(relative, raw)], provider: .codex, base: base, prefix: "sessions")
    let projected = try await BackendCloudConversationProjectionWriter.project(archive: archive, manifestID: try await manifest(archive, relative: relative), provider: .codex,
      conversationID: id, projectID: "project", rootID: "root", oldPath: "/source/app", newPath: "/dest/app", stagingDirectory: staging(base))
    XCTAssertTrue(projected.file.path.hasSuffix("sessions/" + relative))
    let value = try NativeRPCValue.parseJSON(Data(contentsOf: projected.file))
    XCTAssertEqual(value["payload"]["id"].string, id)
    XCTAssertEqual(value["payload"]["cwd"].string, "/dest/app")
    XCTAssertTrue(try Data(contentsOf: base.appendingPathComponent("a/" + relative)) == raw)
  }
  /// Finding 19b: an archived Codex rollout (flat folder) can be continued; its date comes from its own name.
  func testArchivedCodexRolloutCanBeProjected() async throws {
    let base = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: base) }
    let id = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    let raw = Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\",\"cwd\":\"/source/app\"}}\n".utf8)
    let name = "rollout-2026-11-12T08-00-00-\(id).jsonl"
    let archive = try await seed([(name, raw)], provider: .codex, base: base, prefix: "archived_sessions")
    let projected = try await BackendCloudConversationProjectionWriter.project(archive: archive, manifestID: try await manifest(archive, relative: name), provider: .codex,
      conversationID: id, projectID: "project", rootID: "root", oldPath: "/source/app", newPath: "/dest/app", stagingDirectory: staging(base))
    XCTAssertTrue(projected.file.path.hasSuffix("provider-home/sessions/2026/11/12/" + name))
    let value = try NativeRPCValue.parseJSON(Data(contentsOf: projected.file))
    XCTAssertEqual(value["payload"]["id"].string, id)
  }
  func testNativeProjectionWriterNeverOverwritesAnExistingFile() throws {
    let base = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: base) }
    let first = try NativeTranscriptPaths.createCloudProjectionFile(relative: "projects/one/file.jsonl", in: base)
    try first.write(contentsOf: Data("keep".utf8)); try first.close()
    XCTAssertThrowsError(try NativeTranscriptPaths.createCloudProjectionFile(relative: "projects/one/file.jsonl", in: base))
    XCTAssertTrue(try Data(contentsOf: base.appendingPathComponent("projects/one/file.jsonl")) == Data("keep".utf8))
    XCTAssertThrowsError(try NativeTranscriptPaths.createCloudProjectionFile(relative: "../escape", in: base))
  }
  func testClaudeProjectionCarriesSubagentsAndMatchingIndexWithoutChangingMessageText() async throws {
    let base = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: base) }
    let id = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
    let main = Data("{\"sessionId\":\"\(id)\",\"cwd\":\"/source/app\",\"message\":{\"content\":\"main\"}}\n".utf8)
    let child = Data("{\"sessionId\":\"\(id)\",\"agentId\":\"child\",\"cwd\":\"/source/app\",\"message\":{\"content\":\"keep /source/app exact\"}}\n".utf8)
    let index: NativeRPCValue = .object([.init("version", .number(1)), .init("originalPath", .string("/source/app")), .init("entries", .array([
      .object([.init("sessionId", .string(id)), .init("fullPath", .string("/source/raw.jsonl")), .init("projectPath", .string("/source/app")), .init("firstPrompt", .string("keep /source/app exact"))]),
      .object([.init("sessionId", .string("unrelated")), .init("firstPrompt", .string("not this conversation"))])
    ]))])
    let archive = try await seed([("project/\(id).jsonl", main), ("project/\(id)/subagents/agent-child.jsonl", child),
      ("project/sessions-index.json", try index.encodedJSON())], provider: .claude, base: base)
    let projected = try await BackendCloudConversationProjectionWriter.project(archive: archive, manifestID: try await manifest(archive, relative: "project/" + id + ".jsonl"),
      provider: .claude, conversationID: id, projectID: "project", rootID: "root", oldPath: "/source/app", newPath: "/dest/app", stagingDirectory: staging(base))
    XCTAssertEqual(projected.supportFiles.count, 2)
    let childURL = try XCTUnwrap(projected.supportFiles.first { $0.lastPathComponent == "agent-child.jsonl" })
    let childValue = try NativeRPCValue.parseJSON(Data(contentsOf: childURL))
    XCTAssertEqual(childValue["cwd"].string, "/dest/app")
    XCTAssertEqual(childValue["sessionId"].string, id)
    XCTAssertEqual(childValue["message"]["content"].string, "keep /source/app exact")
    let indexURL = try XCTUnwrap(projected.supportFiles.first { $0.lastPathComponent == "sessions-index.json" })
    let mappedIndex = try NativeRPCValue.parseJSON(Data(contentsOf: indexURL))
    XCTAssertEqual(mappedIndex["entries"].elements?.count, 1)
    XCTAssertEqual(mappedIndex["entries"].elements?.first?["fullPath"].string, projected.file.path)
    XCTAssertEqual(mappedIndex["entries"].elements?.first?["firstPrompt"].string, "keep /source/app exact")
    XCTAssertTrue(try Data(contentsOf: base.appendingPathComponent("a/project/" + id + "/subagents/agent-child.jsonl")) == child)
  }
}
