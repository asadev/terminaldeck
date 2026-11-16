import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class CloudConversationHomesTests: XCTestCase, @unchecked Sendable {
  func testApprovedSharedProjectsLinkKeepsBothProfilesWithoutDuplicatingFiles() async throws {
    let base = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: base) }
    let primary = base.appendingPathComponent("primary"), profile = base.appendingPathComponent("inactive-profile")
    try CloudBrainAgentsFixture.write(Data("fixture-only\n".utf8), to: primary.appendingPathComponent("projects/project/one.jsonl"))
    try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: profile.appendingPathComponent("projects"), withDestinationURL: primary.appendingPathComponent("projects"))
    let roots = try BackendCloudConversationHomes.roots([
      .init(profileID: "default", provider: .claude, directory: primary),
      .init(profileID: "inactive", provider: .claude, directory: profile)
    ]).filter { $0.relativePrefix == "projects" }
    XCTAssertEqual(roots.count, 1)
    XCTAssertEqual(Set(roots[0].profileIDs), ["default", "inactive"])
    let cursor = try CloudConversationEnumerator(roots: roots)
    var count = 0
    while try await cursor.next() != nil { count += 1 }
    XCTAssertEqual(count, 1)
    let coverage = await cursor.coverage()
    XCTAssertTrue(coverage.allSatisfy(\.complete))
  }
  func testProjectsLinkOutsideApprovedHomesIsNotFollowed() async throws {
    let base = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: base) }
    let home = base.appendingPathComponent("home"), outside = base.appendingPathComponent("not-approved")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    try CloudBrainAgentsFixture.write(Data("fixture-only\n".utf8), to: outside.appendingPathComponent("one.jsonl"))
    try FileManager.default.createSymbolicLink(at: home.appendingPathComponent("projects"), withDestinationURL: outside)
    let roots = try BackendCloudConversationHomes.roots([.init(profileID: "fixture", provider: .claude, directory: home)]).filter { $0.relativePrefix == "projects" }
    let cursor = try CloudConversationEnumerator(roots: roots)
    let first = try await cursor.next()
    XCTAssertNil(first)
    let coverage = await cursor.coverage()
    XCTAssertTrue(coverage.allSatisfy { !$0.complete })
  }
  func testManagedInventoryVisitsAllChildrenAndMarksUnresolvedHomeIncomplete() async throws {
    let base = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: base) }
    let logins = base.appendingPathComponent("account-logins"), agents = base.appendingPathComponent("agent-homes")
    for path in [logins.appendingPathComponent("one"), logins.appendingPathComponent("two"), agents.appendingPathComponent("unknown")] {
      try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
    }
    let resolved = CloudBrainAgentsFixtureEffects()
    let inventory = try await BackendCloudConversationHomes.discover(defaultHomes: [], profiles: [], accountLoginsRoot: logins,
      agentHomesRoot: agents, approvedRemoteHomes: [], resolveOwnedHome: { path in
        await resolved.called()
        if path.lastPathComponent == "unknown" { return [] }
        return [.init(profileID: path.lastPathComponent, provider: .claude, directory: path)]
      })
    let count = await resolved.calls
    XCTAssertEqual(count, 3)
    XCTAssertEqual(inventory.homes.count, 2)
    XCTAssertFalse(inventory.blockedSources.isEmpty)
  }
}
