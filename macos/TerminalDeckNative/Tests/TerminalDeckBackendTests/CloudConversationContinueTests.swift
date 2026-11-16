import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// Fixture clock: every sleep advances simulated time instead of waiting.
actor CloudConversationFixtureClock {
  private(set) var now: Int64 = 1_000
  private(set) var acquires = 0
  private(set) var releases = 0
  func advance(seconds: Int) { now += Int64(seconds) * 1000 }
  func acquired() { acquires += 1 }
  func released() { releases += 1 }
}

final class CloudConversationContinueTests: XCTestCase, @unchecked Sendable {
  private typealias Fixture = CloudConversationFixture
  private static let id = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
  /// The providers' own resume arguments, as the native provider resolver builds them.
  private func spec(_ provider: CloudConversationProvider) -> BackendProviderSpec {
    switch provider {
    case .claude: return .init(id: "claude", command: "claude", args: [], resumeArgs: ["--continue"])
    case .codex: return .init(id: "codex", command: "codex", args: [], resumeArgs: ["resume", "--last"])
    case .gemini: return .init(id: "gemini", command: "gemini", args: [], resumeArgs: [])
    }
  }
  /// Finding 16: ordinary Gemini restarts and task resumes keep the arguments they had before Cloud.
  func testOrdinaryGeminiRestartArgumentsAreUnchanged() throws {
    var input = BackendCreateSessionInput(cwd: "/fixture/destination", provider: "gemini")
    input.resume = true; input.resumeConversationId = "saved-id"
    let ordinary = try BackendConversationLaunch.arguments(input, provider: spec(.gemini), live: [])
    XCTAssertEqual(ordinary.arguments, [])
    XCTAssertFalse(ordinary.resumed)
    XCTAssertNil(ordinary.conversationID)
    // A decoded marker (renderer or saved input) is never honoured.
    let decoded = try JSONDecoder().decode(BackendCreateSessionInput.self, from: Data(#"{"cwd":"/fixture/destination","cols":100,"rows":30,"provider":"gemini","resume":true,"resumeConversationId":"saved-id","cloudContinue":{}}"#.utf8))
    XCTAssertEqual(try BackendConversationLaunch.arguments(decoded, provider: spec(.gemini), live: []).arguments, [])
    input.cloudContinue = .continuing
    let continuing = try BackendConversationLaunch.arguments(input, provider: spec(.gemini), live: [])
    XCTAssertEqual(continuing.arguments, ["--resume", "saved-id"])
    XCTAssertTrue(continuing.resumed)
  }
  private func raw(_ provider: CloudConversationProvider) -> (relative: String, prefix: String, bytes: Data) {
    let id = Self.id
    switch provider {
    case .claude: return ("project/\(id).jsonl", "projects", Data("{\"sessionId\":\"\(id)\",\"cwd\":\"/source/app\",\"message\":{\"text\":\"fixture\"}}\n".utf8))
    case .codex: return ("2026/11/12/rollout-2026-11-12T08-00-00-\(id).jsonl", "sessions", Data("{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(id)\",\"cwd\":\"/source/app\"}}\n".utf8))
    case .gemini: return ("project/chats/session-fixture.json", ".gemini/tmp", Data("{\"sessionId\":\"\(id)\",\"projectHash\":\"\(CloudSyncBytes.hash(Data("/source/app".utf8)))\",\"messages\":[]}".utf8))
    }
  }
  private func archived(_ provider: CloudConversationProvider, base: URL) async throws -> (BackendCloudConversationArchive, String, CloudConversationFixtureContent) {
    let item = raw(provider), directory = base.appendingPathComponent("a")
    try CloudBrainAgentsFixture.write(item.bytes, to: directory.appendingPathComponent(item.relative))
    let content = CloudConversationFixtureContent()
    let archive = try Fixture.archive(base, content: content)
    _ = try await Fixture.transfer(roots: [Fixture.root(provider, directory: directory, prefix: item.prefix)], base: base, archive: archive, content: content)
    let manifests = try await archive.manifests(provider: provider)
    return (archive, try XCTUnwrap(manifests.first?.opId), content)
  }
  private func service(_ archive: BackendCloudConversationArchive, base: URL, provider: CloudConversationProvider, clock: CloudConversationFixtureClock,
                       ended: AsyncStream<Void>? = nil, argv: CloudConversationFixtureArguments? = nil) throws -> BackendCloudConversationContinue {
    let branches = try BackendCloudConversationBranches(directory: Fixture.account(base).appendingPathComponent("branches"), subjectHash: Fixture.subject)
    let providerSpec = spec(provider), device = CloudBrainAgentsFixture.deviceB
    return BackendCloudConversationContinue(archive: archive, branches: branches, ports: .init(
      context: { project in .init(projectId: project, throughSeq: CloudSequence(1), sourceCounts: .init(domains: 1, records: 1, files: 1, bytes: 1, blocked: 0), verified: true, missingSources: []) },
      checkMappingAndProvider: { request in guard request.rootID == "root" && request.provider == provider else { throw CloudFailure.invalidRequest } },
      acquire: { request in
        await clock.acquired()
        let now = await clock.now
        let next = (UInt64(request.expectedGeneration.rawValue) ?? 0) + 1
        return .init(resourceId: request.resourceId, generation: CloudSequence(next), until: now + 60_000, deviceId: device)
      },
      release: { _ in await clock.released() },
      launchFile: { input, projected in
        // The real launcher's argument choice, with the provider's real resume arguments.
        let selection = try BackendConversationLaunch.arguments(input, provider: providerSpec, live: [])
        await argv?.record(selection.arguments, file: projected.file)
        return .init(conversationID: selection.conversationID ?? "", sessionID: "new-local-process", resumed: selection.resumed)
      },
      sessionEnded: { _ in
        guard let ended else { return }
        for await _ in ended { return }
      },
      sleep: { seconds in await clock.advance(seconds: seconds); await Task.yield() }),
      deviceID: device, now: { 0 })
  }
  /// Finding 20: continuation identity is proved by the provider format, not by a launcher echo:
  /// the exact resume argv for each CLI and the projected transcript's own session record.
  func testExplicitContinueResumesSameProviderConversationForAllThree() async throws {
    for provider in CloudConversationProvider.allCases {
      let base = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: base) }
      let (archive, manifestID, _) = try await archived(provider, base: base)
      let clock = CloudConversationFixtureClock(), argv = CloudConversationFixtureArguments()
      let (ended, finish) = AsyncStream<Void>.makeStream()
      let continuing = try service(archive, base: base, provider: provider, clock: clock, ended: ended, argv: argv)
      // History reads must neither lease nor launch.
      _ = try await archive.read(manifestID: manifestID, offset: 0, limit: 1024)
      let beforeLease = await clock.acquires
      XCTAssertEqual(beforeLease, 0)
      let receipt = try await continuing.explicitlyContinue(.init(manifestID: manifestID, conversationID: Self.id, projectID: "project", rootID: "root",
        provider: provider, oldPath: "/source/app", newPath: "/dest/app", expectedGeneration: .zero))
      XCTAssertEqual(receipt.launch.conversationID, Self.id)
      let recorded = await argv.arguments
      XCTAssertEqual(recorded, provider == .codex ? ["resume", Self.id] : ["--resume", Self.id])
      let projected = try Data(contentsOf: receipt.projectedFile.file)
      let firstLine = projected.split(separator: 10).first.map { Data($0) } ?? projected
      let record = try NativeRPCValue.parseJSON(firstLine)
      XCTAssertEqual(provider == .codex ? record["payload"]["id"].string : record["sessionId"].string, Self.id)
      finish.finish()
    }
  }
  /// Finding 7: what the continued session writes is in an approved home that is exported with its branch link.
  func testContinuedSessionOutputIsEnumeratedAndCarriesBranchMetadata() async throws {
    let base = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: base) }
    let (archive, manifestID, content) = try await archived(.claude, base: base)
    let clock = CloudConversationFixtureClock()
    let (ended, finish) = AsyncStream<Void>.makeStream()
    let receipt = try await service(archive, base: base, provider: .claude, clock: clock, ended: ended)
      .explicitlyContinue(.init(manifestID: manifestID, conversationID: Self.id, projectID: "project", rootID: "root",
        provider: .claude, oldPath: "/source/app", newPath: "/dest/app", expectedGeneration: .zero))
    // A new turn made on this Mac after Continue.
    let handle = try FileHandle(forWritingTo: receipt.projectedFile.file); _ = try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"sessionId\":\"\(Self.id)\",\"message\":{\"text\":\"new turn on B\"}}\n".utf8)); try handle.close()
    let branches = try BackendCloudConversationBranches(directory: Fixture.account(base).appendingPathComponent("branches"), subjectHash: Fixture.subject)
    let empty = base.appendingPathComponent("empty"); try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    let inventory = try await BackendCloudConversationHomes.discover(defaultHomes: [], profiles: [], accountLoginsRoot: empty, agentHomesRoot: empty,
      approvedRemoteHomes: [], branches: branches, resolveOwnedHome: { _ in [] })
    let branchRoots = inventory.roots.filter { $0.branch != nil }
    XCTAssertFalse(branchRoots.isEmpty)
    let other = try Fixture.archive(base, content: content, name: "c")
    let sent = try await Fixture.transfer(roots: branchRoots, base: base, archive: other, content: content)
    let manifests = sent.operations.filter { $0.payload.raw["kind"].string == "file" && $0.payload.raw["relativePath"].string?.hasSuffix(Self.id + ".jsonl") == true }
    let manifest = try XCTUnwrap(manifests.first)
    XCTAssertEqual(manifest.payload.raw["branch"]["parentManifest"].string, manifestID)
    XCTAssertEqual(manifest.payload.raw["branch"]["conversationId"].string, Self.id)
    XCTAssertEqual(manifest.payload.raw["branch"]["deviceId"].string, CloudBrainAgentsFixture.deviceB)
    let uploaded = try await other.read(manifestID: manifest.opId, offset: 0, limit: 4096)
    XCTAssertTrue(String(decoding: uploaded, as: UTF8.self).contains("new turn on B"))
    finish.finish()
  }
  /// Finding 7: the lease is renewed for the session's life (well past 60 s) and released when it ends.
  func testLeaseIsRenewedPastSixtySecondsAndReleasedWhenSessionEnds() async throws {
    let base = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: base) }
    let (archive, manifestID, _) = try await archived(.claude, base: base)
    let clock = CloudConversationFixtureClock()
    let (ended, finish) = AsyncStream<Void>.makeStream()
    let receipt = try await service(archive, base: base, provider: .claude, clock: clock, ended: ended)
      .explicitlyContinue(.init(manifestID: manifestID, conversationID: Self.id, projectID: "project", rootID: "root",
        provider: .claude, oldPath: "/source/app", newPath: "/dest/app", expectedGeneration: .zero))
    let holder = receipt.lease
    var waited = 0
    while waited < 10_000 { if await holder.renewals >= 4 { break }; await Task.yield(); waited += 1 }
    let renewals = await holder.renewals, elapsed = await clock.now - 1_000, lease = await holder.lease
    XCTAssertGreaterThanOrEqual(renewals, 4)
    XCTAssertGreaterThan(elapsed, 60_000, "simulated time ran past one lease period")
    XCTAssertGreaterThan(lease.until, 1_000 + 60_000, "the held lease still runs after the first 60 seconds")
    let lost = await holder.lost
    XCTAssertFalse(lost)
    finish.finish()
    waited = 0
    while waited < 10_000 { if await holder.released { break }; await Task.yield(); waited += 1 }
    let released = await holder.released, releases = await clock.releases
    XCTAssertTrue(released); XCTAssertGreaterThanOrEqual(releases, 1)
  }
  /// Finding 7: a superseded version is not continued unless that older version was chosen explicitly.
  func testStaleManifestIsRefusedUnlessOlderVersionIsChosen() async throws {
    let base = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: base) }
    let (archive, oldID, content) = try await archived(.claude, base: base)
    let item = raw(.claude), file = base.appendingPathComponent("a").appendingPathComponent(item.relative)
    let handle = try FileHandle(forWritingTo: file); _ = try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"sessionId\":\"\(Self.id)\",\"message\":{\"text\":\"later turn\"}}\n".utf8)); try handle.close()
    _ = try await Fixture.transfer(roots: [Fixture.root(.claude, directory: base.appendingPathComponent("a"), prefix: item.prefix)], base: base, archive: archive, content: content)
    let current = try await archive.manifests(provider: .claude)
    XCTAssertEqual(current.count, 1); XCTAssertNotEqual(current.first?.opId, oldID)
    let clock = CloudConversationFixtureClock()
    let (ended, finish) = AsyncStream<Void>.makeStream()
    let continuing = try service(archive, base: base, provider: .claude, clock: clock, ended: ended)
    do {
      _ = try await continuing.explicitlyContinue(.init(manifestID: oldID, conversationID: Self.id, projectID: "project", rootID: "root",
        provider: .claude, oldPath: "/source/app", newPath: "/dest/app", expectedGeneration: .zero))
      XCTFail("A superseded version must not be continued silently")
    } catch { XCTAssertEqual(error as? CloudFailure, .versionChanged) }
    let refusedLeases = await clock.acquires
    XCTAssertEqual(refusedLeases, 0)
    let older = try await continuing.explicitlyContinue(.init(manifestID: oldID, conversationID: Self.id, projectID: "project", rootID: "root",
      provider: .claude, oldPath: "/source/app", newPath: "/old/app", expectedGeneration: .zero, allowOlderVersion: true))
    XCTAssertFalse(String(decoding: try Data(contentsOf: older.projectedFile.file), as: UTF8.self).contains("later turn"))
    finish.finish()
  }
  func testMissingContextPreventsLeaseAndLaunch() async throws {
    let base = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: base) }
    let (archive, id, _) = try await archived(.claude, base: base)
    let effects = CloudBrainAgentsFixtureEffects()
    let branches = try BackendCloudConversationBranches(directory: Fixture.account(base).appendingPathComponent("branches"), subjectHash: Fixture.subject)
    let service = BackendCloudConversationContinue(archive: archive, branches: branches, ports: .init(
      context: { project in .init(projectId: project, throughSeq: .zero, sourceCounts: .init(domains: 0, records: 0, files: 0, bytes: 0, blocked: 1), verified: false, missingSources: ["fixture-source"]) },
      checkMappingAndProvider: { _ in }, acquire: { _ in await effects.called(); throw CloudFailure.unavailable }, release: { _ in },
      launchFile: { _, _ in await effects.called(); throw CloudFailure.unavailable }, sessionEnded: { _ in }), deviceID: CloudBrainAgentsFixture.deviceB)
    do {
      _ = try await service.explicitlyContinue(.init(manifestID: id, conversationID: Self.id, projectID: "project", rootID: "root", provider: .claude,
        oldPath: "/source/app", newPath: "/dest/app", expectedGeneration: .zero))
      XCTFail("Incomplete context must block continuation")
    } catch {}
    let count = await effects.calls; XCTAssertEqual(count, 0)
  }
}

actor CloudConversationFixtureArguments {
  private(set) var arguments: [String] = []
  private(set) var file: URL?
  func record(_ arguments: [String], file: URL) { self.arguments = arguments; self.file = file }
}
