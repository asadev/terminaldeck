import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Fixture-only account folder and export→archive pipeline. Never imported by a production target.
enum CloudConversationFixture {
  static let subject = String(repeating: "ab", count: 32)
  static let otherSubject = String(repeating: "cd", count: 32)
  static func account(_ base: URL, subject: String = subject) -> URL { base.appendingPathComponent("cloud").appendingPathComponent(subject) }
  static func archive(_ base: URL, content: CloudConversationFixtureContent, name: String = "b") throws -> BackendCloudConversationArchive {
    try .init(directory: account(base).appendingPathComponent(name), content: content, subjectHash: subject)
  }
  static func chunks(_ base: URL, content: CloudConversationFixtureContent) throws -> BackendCloudConversationChunks {
    try .init(directory: account(base).appendingPathComponent("staging"), content: content, subjectHash: subject)
  }
  static func journal(_ base: URL, name: String = "reconcile") throws -> BackendCloudConversationReconciler {
    try .init(directory: account(base).appendingPathComponent(name), subjectHash: subject)
  }
  struct Transfer {
    var pages = 0
    var operations: [CloudOperation] = []
    var files: [CloudLocalBlob] = []
    var coverage: [CloudCoverage] = []
  }
  /// Export from `roots`, carry every page through the fixture cloud's canonical pack form, apply it to `archive`.
  static func transfer(roots: [CloudConversationRoot], base: URL, archive: BackendCloudConversationArchive,
                       content: CloudConversationFixtureContent, chunkBytes: Int = 1024 * 1024,
                       chunkPort: (any CloudConversationChunkPort)? = nil) async throws -> Transfer {
    let staging: any CloudConversationChunkPort
    if let chunkPort { staging = chunkPort } else { staging = try chunks(base, content: content) }
    let reader = try CloudConversationExport(roots: roots, chunks: staging, journal: try journal(base),
      deviceID: CloudBrainAgentsFixture.device, cut: CloudBrainAgentsFixture.cut, chunkBytes: chunkBytes)
    var result = Transfer()
    while let page = try await reader.next() {
      result.pages += 1; result.coverage += page.coverage; result.operations += page.operations; result.files += page.files
      let operations = try CloudSyncPack.decode(CloudSyncPack.encode(page.operations))
      let files = try CloudBrainAgentsFixture.copyToFixtureCloud(page.files, directory: base.appendingPathComponent("fixture-cloud"))
      let staged = try await archive.prepare(operations, files: files)
      _ = try await archive.apply(operations, staged: staged)
      let retained = try await archive.retained(operations)
      XCTAssertTrue(retained)
    }
    return result
  }
  static func root(_ provider: CloudConversationProvider, directory: URL, source: String = "fixture", prefix: String = "") -> CloudConversationRoot {
    .init(sourceID: source, profileID: "fixture", provider: provider, directory: directory, relativePrefix: prefix)
  }
}

/// Counts every seal request, so a test can prove which chunk bytes were read and sealed again.
actor CloudConversationCountingChunks: CloudConversationChunkPort {
  private let inner: BackendCloudConversationChunks
  private(set) var sealed = 0
  init(_ inner: BackendCloudConversationChunks) { self.inner = inner }
  func seal(_ bytes: Data, blobID: String, sourceID: String) async throws -> CloudLocalBlob {
    sealed += 1
    return try await inner.seal(bytes, blobID: blobID, sourceID: sourceID)
  }
}
