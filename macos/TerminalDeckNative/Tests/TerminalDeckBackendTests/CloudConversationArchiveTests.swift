import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class CloudConversationArchiveTests: XCTestCase, @unchecked Sendable {
  private typealias Fixture = CloudConversationFixture
  func testEveryByteAndFileSurvivesAllProvidersIncludingSubagentsAndLargeTranscript() async throws {
    let base = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: base) }
    let content = CloudConversationFixtureContent()
    let archive = try Fixture.archive(base, content: content)
    let descriptions: [(CloudConversationProvider, String, Data)] = [
      (.claude, "project/main.jsonl", Data(repeating: 65, count: 4 * 1024 * 1024 + 31)),
      (.claude, "project/main/subagents/agent-child.jsonl", Data("{\"fixture\":\"child\"}\n".utf8)),
      (.claude, "project/sessions-index.json", Data("{\"entries\":[]}".utf8)),
      (.claude, "project/main/tool-results/result.txt", Data("support record\n".utf8)),
      (.codex, "2026/11/12/rollout-fixture.jsonl", Data("{\"type\":\"session_meta\"}\n".utf8)),
      (.gemini, "project/chats/session-fixture.json", Data("{\"sessionId\":\"fixture\",\"messages\":[]}".utf8)),
      (.gemini, "project/chats/session-other.jsonl", Data("{\"sessionId\":\"other\"}\n".utf8)),
      (.gemini, "project/logs.json", Data("[]".utf8))
    ]
    var originals: [String: Data] = [:]
    for (provider, relative, bytes) in descriptions {
      try CloudBrainAgentsFixture.write(bytes, to: base.appendingPathComponent("a/" + provider.rawValue + "/" + relative))
      originals[provider.rawValue + ":" + relative] = bytes
    }
    let roots = CloudConversationProvider.allCases.map { provider in
      Fixture.root(provider, directory: base.appendingPathComponent("a/" + provider.rawValue), source: "fixture-" + provider.rawValue)
    }
    let result = try await Fixture.transfer(roots: roots, base: base, archive: archive, content: content)
    XCTAssertGreaterThan(result.pages, descriptions.count * 2)
    // 19c: support files (tool results, Gemini logs) are exported too, so coverage can be complete.
    XCTAssertTrue(result.coverage.allSatisfy(\.complete))
    XCTAssertEqual(result.coverage.reduce(0) { $0 + $1.items }, descriptions.count)
    XCTAssertEqual(result.coverage.reduce(Int64(0)) { $0 + $1.bytes }, descriptions.reduce(Int64(0)) { $0 + Int64($1.2.count) })
    let manifests = try await archive.manifests(limit: 100)
    XCTAssertEqual(manifests.count, descriptions.count)
    for manifest in manifests {
      let key = manifest.payload.raw["provider"].string! + ":" + manifest.payload.raw["relativePath"].string!
      let bytes = try await archive.read(manifestID: manifest.opId, offset: 0, limit: CloudWire.maximumPlainChunkBytes)
      XCTAssertTrue(bytes == originals[key])
      let source = base.appendingPathComponent("a/" + key.replacingOccurrences(of: ":", with: "/"))
      XCTAssertTrue(try Data(contentsOf: source) == originals[key])
      XCTAssertLessThan(try CloudSyncCanonical.encode(manifest.payload).count, 65_536)
    }
    // An unchanged home is not read again and offers nothing.
    let again = try await Fixture.transfer(roots: roots, base: base, archive: archive, content: content)
    XCTAssertTrue(again.operations.isEmpty)
    let current = try await archive.manifests(limit: 100)
    XCTAssertEqual(current.map(\.opId), manifests.map(\.opId))
  }
  func testGeminiRewriteKeepsBothWholeRevisionsButListsTheConversationOnce() async throws {
    let base = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: base) }
    let content = CloudConversationFixtureContent(), directory = base.appendingPathComponent("a")
    let file = directory.appendingPathComponent("project/chats/session-fixture.json")
    let first = Data("{\"sessionId\":\"fixture\",\"messages\":[\"first\",\"removed\"]}".utf8)
    let second = Data("{\"sessionId\":\"fixture\",\"messages\":[\"replacement\"]}".utf8)
    try CloudBrainAgentsFixture.write(first, to: file)
    let roots = [Fixture.root(.gemini, directory: directory)]
    let archive = try Fixture.archive(base, content: content)
    _ = try await Fixture.transfer(roots: roots, base: base, archive: archive, content: content, chunkBytes: 7)
    try second.write(to: file, options: .atomic)
    _ = try await Fixture.transfer(roots: roots, base: base, archive: archive, content: content, chunkBytes: 7)
    // 19a: a listing shows one row per conversation, the current version.
    let listed = try await archive.manifests(provider: .gemini)
    XCTAssertEqual(listed.count, 1)
    let versions = try await archive.history(fileID: try XCTUnwrap(listed.first?.entityId))
    XCTAssertEqual(versions.count, 2)
    XCTAssertEqual(versions.filter { $0.kind == .supersede && $0.parents.count == 1 }.count, 1)
    var restored: [Data] = []
    for version in versions { restored.append(try await archive.read(manifestID: version.opId, offset: 0, limit: 1024)) }
    XCTAssertTrue(restored.contains(first)); XCTAssertTrue(restored.contains(second))
    let currentBytes = try await archive.read(manifestID: listed[0].opId, offset: 0, limit: 1024)
    XCTAssertTrue(currentBytes == second)
  }
  func testS16AllSuppliedHomesAndOverTenThousandEntriesAreEnumerated() async throws {
    let base = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: base) }
    var roots: [CloudConversationRoot] = []
    for kind in ["default", "inactive-profile", "account-login", "agent-home", "approved-device-home"] {
      let directory = base.appendingPathComponent(kind)
      let count = kind == "default" ? 10_003 : 2
      for index in 0..<count { try CloudBrainAgentsFixture.write(Data([10]), to: directory.appendingPathComponent("project/\(index).jsonl")) }
      roots.append(.init(sourceID: kind, profileID: kind, provider: .claude, directory: directory))
    }
    let cursor = try CloudConversationEnumerator(roots: roots)
    var count = 0
    while try await cursor.next() != nil { count += 1 }
    let coverage = await cursor.coverage()
    XCTAssertEqual(count, 10_011)
    XCTAssertEqual(coverage.count, 5)
    XCTAssertTrue(coverage.allSatisfy(\.complete))
  }
  func testS16UnreadableRootAndEscapingLinkCannotReportComplete() async throws {
    let base = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: base) }
    let directory = base.appendingPathComponent("a")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let outside = base.appendingPathComponent("outside.jsonl")
    try CloudBrainAgentsFixture.write(Data([10]), to: outside)
    try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("escape.jsonl"), withDestinationURL: outside)
    let cursor = try CloudConversationEnumerator(roots: [
      .init(sourceID: "linked", profileID: "fixture", provider: .claude, directory: directory),
      .init(sourceID: "missing", profileID: "fixture", provider: .claude, directory: base.appendingPathComponent("missing"))
    ])
    while try await cursor.next() != nil {}
    let coverage = await cursor.coverage()
    XCTAssertTrue(coverage.allSatisfy { !$0.complete && $0.items == 0 && !$0.blockedReasons.isEmpty })
  }
  func testChangedSourceAfterFirstChunkHasNoReadableManifest() async throws {
    let base = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: base) }
    let directory = base.appendingPathComponent("a"), file = directory.appendingPathComponent("one.jsonl")
    try CloudBrainAgentsFixture.write(Data(repeating: 65, count: 32), to: file)
    let content = CloudConversationFixtureContent()
    let reader = try CloudConversationExport(roots: [Fixture.root(.claude, directory: directory)],
      chunks: try Fixture.chunks(base, content: content), journal: try Fixture.journal(base),
      deviceID: CloudBrainAgentsFixture.device, cut: CloudBrainAgentsFixture.cut, chunkBytes: 8)
    _ = try await reader.next()
    try Data(repeating: 66, count: 64).write(to: file)
    var manifests = 0, coverage: [CloudCoverage] = []
    while let page = try await reader.next() { manifests += page.operations.filter { $0.payload.raw["kind"].string == "file" }.count; coverage += page.coverage }
    XCTAssertEqual(manifests, 0)
    XCTAssertTrue(coverage.allSatisfy { !$0.complete })
  }
  func testS15DeletingLastLocalFileAddsOneArchiveMarkerButKeepsCloudBytes() async throws {
    let base = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: base) }
    let directory = base.appendingPathComponent("a"), file = directory.appendingPathComponent("one.jsonl")
    let original = Data("fixture-only\n".utf8)
    try CloudBrainAgentsFixture.write(original, to: file)
    let content = CloudConversationFixtureContent()
    let archive = try Fixture.archive(base, content: content)
    let roots = [Fixture.root(.claude, directory: directory)]
    _ = try await Fixture.transfer(roots: roots, base: base, archive: archive, content: content)
    let manifests = try await archive.manifests()
    let manifest = try XCTUnwrap(manifests.first)
    try FileManager.default.removeItem(at: file)
    let removed = try await Fixture.transfer(roots: roots, base: base, archive: archive, content: content)
    XCTAssertTrue(removed.coverage.allSatisfy { !$0.complete && $0.items == 0 })
    XCTAssertEqual(removed.operations.filter { $0.kind == .archive }.count, 1)
    let history = try await archive.history(fileID: manifest.entityId)
    XCTAssertEqual(history.count, 2)
    XCTAssertEqual(history.filter { $0.kind == .archive }.count, 1)
    let bytes = try await archive.read(manifestID: manifest.opId, offset: 0, limit: 1024)
    XCTAssertTrue(bytes == original)
    // 5: a marker the outbox already took is never offered again.
    let repeated = try await Fixture.transfer(roots: roots, base: base, archive: archive, content: content)
    XCTAssertTrue(repeated.operations.isEmpty)
    let after = try await archive.history(fileID: manifest.entityId)
    XCTAssertEqual(after.count, 2)
    // The removed file's last version stays readable and listed once.
    let listed = try await archive.manifests()
    XCTAssertEqual(listed.map(\.opId), [manifest.opId])
  }

  func testAppendReusesUnchangedChunksAndKeepsBothVersions() async throws {
    let base = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: base) }
    let directory = base.appendingPathComponent("a"), source = directory.appendingPathComponent("one.jsonl")
    try CloudBrainAgentsFixture.write(Data("abcdefgh".utf8), to: source)
    let content = CloudConversationFixtureContent()
    let archive = try Fixture.archive(base, content: content)
    let roots = [Fixture.root(.claude, directory: directory)]
    _ = try await Fixture.transfer(roots: roots, base: base, archive: archive, content: content, chunkBytes: 4)
    let staging = Fixture.account(base).appendingPathComponent("staging")
    let firstBlobs = Set(try FileManager.default.contentsOfDirectory(atPath: staging.path).filter { $0.hasSuffix(".envelope") })
    XCTAssertEqual(firstBlobs.count, 2)
    // A replaced file (new inode) is read again, but chunks it already sent are not offered again.
    try Data("abcdefghijkl".utf8).write(to: source, options: .atomic)
    let second = try await Fixture.transfer(roots: roots, base: base, archive: archive, content: content, chunkBytes: 4)
    XCTAssertEqual(second.operations.filter { $0.payload.raw["kind"].string == "chunk" }.count, 1)
    XCTAssertEqual(second.operations.count, 3, "one new chunk, its list page and one manifest")
    let nextBlobs = Set(try FileManager.default.contentsOfDirectory(atPath: staging.path).filter { $0.hasSuffix(".envelope") })
    XCTAssertEqual(nextBlobs.count, 3)
    XCTAssertTrue(firstBlobs.isSubset(of: nextBlobs))
    let rawBlocks = try FileManager.default.contentsOfDirectory(atPath: Fixture.account(base).appendingPathComponent("b").path)
      .filter { $0.hasSuffix(".bytes") && !$0.hasPrefix("prepared-") }
    XCTAssertEqual(rawBlocks.count, 3)
    let listed = try await archive.manifests()
    XCTAssertEqual(listed.count, 1)
    let versions = try await archive.history(fileID: listed[0].entityId)
    XCTAssertEqual(versions.count, 2)
    var bytes: [Data] = []
    for revision in versions { bytes.append(try await archive.read(manifestID: revision.opId, offset: 0, limit: 100)) }
    XCTAssertTrue(bytes.contains(Data("abcdefgh".utf8)))
    XCTAssertTrue(bytes.contains(Data("abcdefghijkl".utf8)))
  }

  /// Finding 5: an append to a large active file must add a constant number of operations, re-read only the tail,
  /// and grow the journal by a small amount; a pass with no change writes nothing.
  func testAppendToLargeFileAddsConstantOperationsAndBoundedJournalBytes() async throws {
    let base = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: base) }
    let directory = base.appendingPathComponent("a"), source = directory.appendingPathComponent("long.jsonl")
    let chunkBytes = 64, chunks = 300
    try CloudBrainAgentsFixture.write(Data((0..<(chunkBytes * chunks)).map { UInt8($0 % 251) }), to: source)
    let content = CloudConversationFixtureContent()
    let archive = try Fixture.archive(base, content: content)
    let roots = [Fixture.root(.claude, directory: directory)]
    let first = try await Fixture.transfer(roots: roots, base: base, archive: archive, content: content, chunkBytes: chunkBytes)
    XCTAssertEqual(first.operations.filter { $0.payload.raw["kind"].string == "chunk" }.count, chunks)
    XCTAssertEqual(first.operations.filter { $0.payload.raw["kind"].string == "list" }.count, 2)
    let journal = try Fixture.journal(base)
    let before = try await journal.journalBytes()
    // Same file object grows, as an active transcript does.
    let handle = try FileHandle(forWritingTo: source); _ = try handle.seekToEnd(); try handle.write(contentsOf: Data("appended!\n".utf8)); try handle.close()
    let counting = CloudConversationCountingChunks(try Fixture.chunks(base, content: content))
    let second = try await Fixture.transfer(roots: roots, base: base, archive: archive, content: content, chunkBytes: chunkBytes, chunkPort: counting)
    XCTAssertEqual(second.operations.filter { $0.payload.raw["kind"].string == "chunk" }.count, 1)
    XCTAssertEqual(second.operations.filter { $0.payload.raw["kind"].string == "list" }.count, 1, "only the last list page changed")
    XCTAssertEqual(second.operations.filter { $0.payload.raw["kind"].string == "file" }.count, 1)
    XCTAssertEqual(second.operations.count, 3)
    let sealed = await counting.sealed
    XCTAssertEqual(sealed, 1)
    let grown = try await Fixture.journal(base).journalBytes() - before
    XCTAssertGreaterThan(grown, 0)
    XCTAssertLessThan(grown, 8 * 1024, "one delta line, not a rewrite of every file's state")
    let quiet = try await Fixture.transfer(roots: roots, base: base, archive: archive, content: content, chunkBytes: chunkBytes)
    XCTAssertTrue(quiet.operations.isEmpty)
    let unchanged = try await Fixture.journal(base).journalBytes()
    XCTAssertEqual(unchanged, before + grown)
    let listed = try await archive.manifests()
    let restored = try await archive.read(manifestID: try XCTUnwrap(listed.first).opId, offset: 0, limit: CloudWire.maximumPlainChunkBytes)
    XCTAssertTrue(restored == (try Data(contentsOf: source)))
  }

  /// Finding 6: identity follows the owner's stable home id. Moving the home, copying it, or adding a profile alias adds nothing.
  func testMovedCopiedOrAliasedHomeProducesNoNewOperations() async throws {
    let base = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: base) }
    let first = base.appendingPathComponent("home-one"), moved = base.appendingPathComponent("home-two"), copied = base.appendingPathComponent("home-three")
    try CloudBrainAgentsFixture.write(Data("{\"sessionId\":\"x\"}\n".utf8), to: first.appendingPathComponent("projects/p/x.jsonl"))
    let content = CloudConversationFixtureContent()
    let archive = try Fixture.archive(base, content: content)
    let keys = try BackendCloudConversationHomeKeys(directory: Fixture.account(base).appendingPathComponent("homes"), subjectHash: Fixture.subject)
    let initial = try await keys.roots([.init(homeID: "default", profileID: "default", provider: .claude, directory: first)])
    let sent = try await Fixture.transfer(roots: initial, base: base, archive: archive, content: content)
    XCTAssertEqual(sent.operations.filter { $0.payload.raw["kind"].string == "file" }.count, 1)
    try FileManager.default.moveItem(at: first, to: moved)
    let relinked = try await BackendCloudConversationHomeKeys(directory: Fixture.account(base).appendingPathComponent("homes"), subjectHash: Fixture.subject)
      .roots([.init(homeID: "default", profileID: "default", provider: .claude, directory: moved),
              .init(homeID: "profile:alias", profileID: "alias", provider: .claude, directory: moved)])
    XCTAssertEqual(Set(relinked.map(\.sourceID)), Set(initial.map(\.sourceID)))
    let afterMove = try await Fixture.transfer(roots: relinked, base: base, archive: archive, content: content)
    XCTAssertTrue(afterMove.operations.isEmpty)
    try FileManager.default.copyItem(at: moved, to: copied)
    let recopied = try await keys.roots([.init(homeID: "default", profileID: "default", provider: .claude, directory: copied)])
    let afterCopy = try await Fixture.transfer(roots: recopied, base: base, archive: archive, content: content)
    XCTAssertTrue(afterCopy.operations.isEmpty)
    let listed = try await archive.manifests()
    XCTAssertEqual(listed.count, 1)
  }

  /// Finding 8: stores refuse a folder outside the signed-in account's Cloud folder.
  func testConversationStoresAreBoundToOneAccountFolder() throws {
    let base = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: base) }
    let content = CloudConversationFixtureContent()
    XCTAssertThrowsError(try BackendCloudConversationArchive(directory: base.appendingPathComponent("b"), content: content, subjectHash: Fixture.subject))
    XCTAssertThrowsError(try BackendCloudConversationReconciler(directory: Fixture.account(base, subject: Fixture.otherSubject).appendingPathComponent("r"), subjectHash: Fixture.subject))
    XCTAssertThrowsError(try BackendCloudConversationChunks(directory: Fixture.account(base).appendingPathComponent("s"), content: content, subjectHash: "not-a-hash"))
    let chunks = try Fixture.chunks(base, content: content), archive = try Fixture.archive(base, content: content)
    let other = try BackendCloudConversationReconciler(directory: Fixture.account(base, subject: Fixture.otherSubject).appendingPathComponent("r"), subjectHash: Fixture.otherSubject)
    XCTAssertThrowsError(try BackendCloudConversationAdapter(provider: .claude, roots: [Fixture.root(.claude, directory: base)], chunks: chunks,
      archive: archive, reconciler: other, deviceID: CloudBrainAgentsFixture.device, subjectHash: Fixture.subject))
  }
}
