import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class CloudConversationToolsTests: XCTestCase, @unchecked Sendable {
  private func context(_ label: String, tiers: Set<BackendMCPTier> = [.read, .act]) -> BackendMCPCallContext {
    .init(sessionID: label, machineID: "fixture-machine", projectRoot: "/fixture/project", attended: true,
      allowedTools: ["cloud.conversations", "cloud.continue"], allowedTiers: tiers, cancellation: .init())
  }
  func testDefaultUnverifiedContributionIsEmptyAndGateOffRegistersNothing() async throws {
    let empty = try BackendCloudConversationTools.contribution()
    XCTAssertTrue(empty.tools.isEmpty); XCTAssertTrue(empty.inventoryRows.isEmpty)
    let verified = try BackendCloudConversationTools.contribution(verifiedArchiveRows: ["I17"], verifiedContinueRows: ["I17"])
    let entries = try await BackendCloudConversationTools.registrations(contribution: verified, ports: .init(gate: { false }, authorize: { _, _, _ in },
      list: { _, _ in XCTFail("Gate off"); throw CloudFailure.gateClosed }, providerOfConversation: { _ in .claude },
      resume: { _, _ in XCTFail("Gate off"); throw CloudFailure.gateClosed }))
    XCTAssertTrue(entries.isEmpty)
  }
  func testRegisteredHandlersUseSameScopedPortsForSessionHootAndConnectedAI() async throws {
    let reads = CloudBrainAgentsFixtureEffects(), launches = CloudBrainAgentsFixtureEffects()
    let contribution = try BackendCloudConversationTools.contribution(verifiedArchiveRows: ["I17"], verifiedContinueRows: ["I17"])
    let entries = try await BackendCloudConversationTools.registrations(contribution: contribution, ports: .init(gate: { true },
      authorize: { context, _, _ in guard context.projectRoot == "/fixture/project" else { throw CloudFailure.gateClosed } },
      list: { _, _ in await reads.called(); return .init(items: [.init(archiveID: "archive", provider: .claude, conversationID: "same-id", projectID: "project", bytes: 10)], after: nil) },
      providerOfConversation: { _ in .claude },
      resume: { _, args in await launches.called(); return .init(conversationID: args["conversationId"].string!, sessionID: "session", resumed: true) }))
    let server = BackendNativeMCPServer()
    try await server.replaceTools(ownerID: BackendCloudConversationTools.owner, tools: entries)
    let registered = await server.registrations()
    XCTAssertEqual(registered.count, 2)
    let list = try XCTUnwrap(registered.first { $0.0.id == "cloud.conversations" }?.1)
    let resume = try XCTUnwrap(registered.first { $0.0.id == "cloud.continue" }?.1)
    for caller in ["session", "hoot", "connected-ai"] {
      _ = try await list(context(caller), .object([.init("projectId", .string("project"))]))
      _ = try await resume(context(caller), .object([.init("conversationId", .string("same-id")), .init("projectId", .string("project")), .init("rootId", .string("root"))]))
    }
    do { _ = try await list(context("session"), .object([.init("unknown", .bool(true))])); XCTFail("Unknown fields must refuse") } catch {}
    do { _ = try await resume(context("readonly", tiers: [.read]), .object([.init("conversationId", .string("same-id")), .init("projectId", .string("project")), .init("rootId", .string("root"))])); XCTFail("Read-only cannot continue") } catch {}
    let readCount = await reads.calls, launchCount = await launches.calls
    XCTAssertEqual(readCount, 3); XCTAssertEqual(launchCount, 3)
  }
}
