import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class CloudBrainAgentsSeatTests: XCTestCase, @unchecked Sendable {
  func testOldShellLinksExportWithoutAgeCapAndNeverEnterDestinationResumeMap() async throws {
    let root = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    let aRoot = root.appendingPathComponent("a"), bRoot = root.appendingPathComponent("b")
    let original = NativeRPCValue.object([.init("version", .number(1)), .init("tabs", .object([
      .init("old-tab", AGTShellAgent(provider: "claude", conversationID: "old-id", cwd: "/source/app", updatedAt: 1).wireValue)
    ]))])
    try CloudBrainAgentsFixture.write(original.encodedJSON(), to: aRoot.appendingPathComponent("agt-shell-agents.json"))
    let a = BackendAGTShellAgents(dataRoot: aRoot, home: aRoot.path)
    let b = BackendAGTShellAgents(dataRoot: bRoot, home: bRoot.path)
    XCTAssertTrue(a.all().isEmpty, "The ordinary live view intentionally ages this record out")
    let snapshot = try await CloudBrainAgentsFixture.roundTrip(BackendCloudBrainAgents.shellAdapter(owner: a, account: CloudBrainAgentsFixture.account(CloudBrainAgentsFixture.device)),
      BackendCloudBrainAgents.shellAdapter(owner: b, account: CloudBrainAgentsFixture.account(CloudBrainAgentsFixture.deviceB)))
    XCTAssertEqual(snapshot.operations.count, 1)
    XCTAssertNil(b.record(tabKey: "old-tab"))
    XCTAssertTrue(b.all().isEmpty)
    let versions = try b.cloudSeatVersions()
    XCTAssertEqual(versions, snapshot.operations)
    XCTAssertFalse(FileManager.default.fileExists(atPath: bRoot.appendingPathComponent("agt-shell-agents.json").path))
    XCTAssertTrue(try Data(contentsOf: aRoot.appendingPathComponent("agt-shell-agents.json")) == original.encodedJSON())
  }
  func testSessionChoicesRestoreAsPublicHistoryWithoutVaultOrAutoResume() async throws {
    let root = try CloudBrainAgentsFixture.directory(); defer { try? FileManager.default.removeItem(at: root) }
    let a = BackendAGSSessionChoices(persistence: try .init(directory: root.appendingPathComponent("a"), ownership: .exclusive), cipher: CloudBrainAgentsFixtureCipher(usable: true))
    try await a.start()
    try await a.save(tabKey: "old-tab", settings: .init(provider: "claude", effort: "high", environment: ["FIXTURE": "fixture-only"], workingFolder: "/source/app"))
    let b = BackendAGSSessionChoices(persistence: try .init(directory: root.appendingPathComponent("b"), ownership: .exclusive), cipher: CloudBrainAgentsFixtureCipher(usable: false))
    let snapshot = try await CloudBrainAgentsFixture.roundTrip(BackendCloudBrainAgents.sessionOptionsAdapter(owner: a, account: CloudBrainAgentsFixture.account(CloudBrainAgentsFixture.device)),
      BackendCloudBrainAgents.sessionOptionsAdapter(owner: b, account: CloudBrainAgentsFixture.account(CloudBrainAgentsFixture.deviceB)))
    let versions = try await b.cloudChoiceVersions()
    XCTAssertEqual(versions, snapshot.operations)
    let settings = try BackendAGSCodec.decode(AGSAgentSettings.self, versions[0].payload.raw["settings"])
    XCTAssertEqual(settings.effort, "high")
    XCTAssertTrue(CloudBrainAgentsOptions.isPortable(settings))
    try await b.start()
    let live = try await b.choice(tabKey: "old-tab")
    XCTAssertNil(live)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("b/ags-session-choices.json").path))
  }
}
