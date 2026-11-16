import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class CloudConversationPreparedRestartTests: XCTestCase, @unchecked Sendable {
  private typealias Fixture = CloudConversationFixture
  private func export(_ sources: [CloudConversationRoot], base: URL, content: CloudConversationFixtureContent) async throws -> ([CloudOperation], [CloudLocalBlob]) {
    let reader = try CloudConversationExport(roots: sources, chunks: try Fixture.chunks(base, content: content), journal: try Fixture.journal(base, name: "sender"),
      deviceID: CloudBrainAgentsFixture.device, cut: CloudBrainAgentsFixture.cut)
    var operations: [CloudOperation] = [], files: [CloudLocalBlob] = []
    while let page = try await reader.next() { operations += page.operations; files += page.files }
    return (operations, files)
  }
  private func adapter(_ sources: [CloudConversationRoot], base: URL, content: CloudConversationFixtureContent) throws -> (BackendCloudConversationAdapter, BackendCloudConversationArchive) {
    let archive = try Fixture.archive(base, content: content)
    return (try BackendCloudConversationAdapter(provider: .claude, roots: sources, chunks: try Fixture.chunks(base, content: content), archive: archive,
      reconciler: try Fixture.journal(base, name: "receiver"), deviceID: CloudBrainAgentsFixture.deviceB, subjectHash: Fixture.subject), archive)
  }
  func testLargeDiskBackedPreparationReplaysAfterAdapterAndOwnerRestart() async throws {
    let root = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    let sourceRoot = root.appendingPathComponent("a"), original = Data(repeating: 65, count: 9 * 1024 * 1024 + 5)
    try CloudBrainAgentsFixture.write(original, to: sourceRoot.appendingPathComponent("one.jsonl"))
    let content = CloudConversationFixtureContent()
    let sources = [Fixture.root(.claude, directory: sourceRoot)]
    let (operations, files) = try await export(sources, base: root, content: content)
    let (adapter1, archive1) = try adapter(sources, base: root, content: content)
    let plan = try await adapter1.validateIncoming(operations, files: files)
    let savedPlan = try JSONEncoder().encode(plan)
    let notPublished = try await archive1.manifests()
    XCTAssertTrue(notPublished.isEmpty)
    let archiveFolder = Fixture.account(root).appendingPathComponent("b")
    let stagedFiles = try FileManager.default.contentsOfDirectory(atPath: archiveFolder.path).filter { $0.hasPrefix("prepared-") }
    XCTAssertEqual(stagedFiles.count, files.count)
    // These new instances have none of the old adapter's memory or decrypted pages.
    let (adapter2, archive2) = try adapter(sources, base: root, content: content)
    let recovered = try JSONDecoder().decode(CloudPreparedImport.self, from: savedPlan)
    let receipt = try await adapter2.applyPrepared(recovered, origin: .init(deviceId: CloudBrainAgentsFixture.device, sequence: CloudSequence(1)))
    let proof = try await adapter2.verify(receipt)
    XCTAssertTrue(proof.verified); XCTAssertEqual(proof.counts.bytes, Int64(original.count))
    let manifests = try await archive2.manifests(), manifest = try XCTUnwrap(manifests.first)
    var restored = Data(), index = 0
    while let bytes = try await archive2.chunkAt(manifestID: manifest.opId, index: index) { restored.append(bytes); index += 1 }
    XCTAssertTrue(restored == original)
    let duplicate = try await adapter2.applyPrepared(recovered, origin: .init(deviceId: CloudBrainAgentsFixture.device, sequence: CloudSequence(1)))
    XCTAssertTrue(duplicate.results.allSatisfy { $0.status == .alreadyPresent })
    let leftover = try FileManager.default.contentsOfDirectory(atPath: archiveFolder.path).filter { $0.hasPrefix("prepared-") }
    XCTAssertTrue(leftover.isEmpty)
    // A third instance reloads the append-only index from disk and still reads every byte.
    let archive3 = try Fixture.archive(root, content: content)
    let again = try await archive3.read(manifestID: manifest.opId, offset: Int64(original.count) - 5, limit: 5)
    XCTAssertTrue(again == original.suffix(5))
  }
  func testChangedPreparationIDCannotPublishAValidatedPage() async throws {
    let root = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    let sourceRoot = root.appendingPathComponent("a")
    try CloudBrainAgentsFixture.write(Data("fixture-only\n".utf8), to: sourceRoot.appendingPathComponent("one.jsonl"))
    let content = CloudConversationFixtureContent()
    let sources = [Fixture.root(.claude, directory: sourceRoot)]
    let reader = try CloudConversationExport(roots: sources, chunks: try Fixture.chunks(root, content: content), journal: try Fixture.journal(root, name: "sender"),
      deviceID: CloudBrainAgentsFixture.device, cut: CloudBrainAgentsFixture.cut)
    let first = try await reader.next(), page = try XCTUnwrap(first)
    let (adapter, archive) = try adapter(sources, base: root, content: content)
    let plan = try await adapter.validateIncoming(page.operations, files: page.files)
    let changed = CloudPreparedImport(preparationId: UUID().uuidString.lowercased(), operations: plan.operations, files: plan.files)
    do { _ = try await adapter.applyPrepared(changed, origin: .init(deviceId: CloudBrainAgentsFixture.device, sequence: .zero)); XCTFail("Changed preparation must refuse") } catch {}
    let retained = try await archive.retained(page.operations)
    XCTAssertFalse(retained)
  }
  /// Finding 8: an adapter offers only operations this device authored.
  func testSnapshotPagesOfferOnlyThisDevicesOperations() async throws {
    let root = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    let sourceRoot = root.appendingPathComponent("a")
    try CloudBrainAgentsFixture.write(Data("fixture-only\n".utf8), to: sourceRoot.appendingPathComponent("one.jsonl"))
    let content = CloudConversationFixtureContent()
    let sources = [Fixture.root(.claude, directory: sourceRoot)]
    let (adapter, _) = try adapter(sources, base: root, content: content)
    var authors = Set<String>(), count = 0
    for try await page in await adapter.snapshotPages(cut: CloudBrainAgentsFixture.cut) {
      authors.formUnion(page.operations.map(\.originDevice)); count += page.operations.count
    }
    XCTAssertGreaterThan(count, 0)
    XCTAssertEqual(authors, [CloudBrainAgentsFixture.deviceB])
  }
}
