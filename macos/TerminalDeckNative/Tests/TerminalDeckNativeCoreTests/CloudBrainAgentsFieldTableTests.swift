import Foundation
import XCTest
@testable import TerminalDeckNativeCore

/// Checked-in copy of the field list the Security seat signed (security-ruling-cloud-adapters-design.md, Ruling 3,
/// 12 Nov 2026). A change to this copy needs the Security seat. The code tables must match it class by class.
enum CloudBrainAgentsSignedFieldList {
  static let tables: [String: [String: String]] = [
    "task": classes([
      "identity": ["id", "keyId", "externalTaskId", "originExternalTaskId", "externalThreadId", "creator"],
      "shared": ["title", "instructions", "crmStatus", "priority", "labels", "dueDate", "dueTime", "startDate", "startTime",
        "estimateMinutes", "taskType", "goalId", "result", "effort", "model", "projectRef", "place"],
      "raise": ["decisionRequired"],
      "shrink": ["tokenBudget"],
      "follows.touched": ["updatedAt"], "follows.oldest": ["createdAt"], "follows.newest": ["archivedAt", "hops"],
      "follows.partner:crmStatus": ["completedAt"], "follows.partner:place": ["deletedAt"],
      "collection:100": ["notes"],
      "thisMac": ["local", "notificationKeyId", "reviewVerdict", "reusedFromTask", "decisionID", "decisionPolicyID", "decisionEpoch",
        "decisionEligible", "decisionCreateRequest", "assignee", "mainAssignee", "handedFrom", "requestedBy", "parentTaskId",
        "parentExternalTaskId", "reviewOfTaskId", "reviewerTaskId", "project", "cwd", "sessionId", "conversationId", "seatSession",
        "seatToldAt", "process", "stopped", "runStartedAt", "keepOpenUntil", "keepAliveUntilClose", "questionOpen", "hootTurnOpen",
        "lastTurn", "childrenTold", "seq", "stalled", "startFailed", "awaitingSetup", "useWorkspace", "briefFile", "landing",
        "landingAttempts", "reviewWaitingForFolder", "tokenUsageByAgent", "isAPIAccount", "detail"]]),
    "run": classes([
      "shared": ["id", "agent_id", "task_id", "provider", "project_id", "session_id", "conversation_id", "session_name", "started_at",
        "ended_at", "outcome", "summary", "needed_help", "verified", "tokens", "cost_usd", "cost_source", "billing_kind",
        "requested_model", "requested_effort"],
      "thisMac": ["cwd", "account_id"]]),
    "agent": classes([
      "identity": ["id"],
      "shared": ["name", "role", "toolsPreferred", "toolsAvoided", "model", "effort", "icon", "reportsTo", "instructionHash"],
      "widening": ["provider", "permissionMode", "allowedTools", "blockedTools", "skillsOff", "toolUseRestrictions", "claudeAgent",
        "skills", "maxConcurrent", "maxRunMinutes", "keepAliveMinutes", "keepAliveUntilClose", "status", "projectId", "seat"],
      "follows.partner:status": ["statusAt"],
      "thisMac": ["account", "creatorKeyId", "keyInitializedFields", "syncStatus", "syncedAt", "syncError", "instructions",
        "instructionsFile", "verifyCommand", "sourceDirectory", "sourceFile", "sourcePath", "defaultProject", "startIn", "reviewerAgent"]]),
    "agentOptions": classes([
      "shared": ["model", "effort"],
      "widening": ["provider", "permissionMode", "allowedTools", "deniedTools", "mcpServers", "keepOpen", "efficiency", "contextWindow", "fastMode"],
      "thisMac": ["environment", "hooks", "workingFolder"]]),
    "setting": classes(["identity": ["key"], "shared": ["value"]]),
    "project": classes([
      "identity": ["id"], "shared": ["name", "icon", "colour", "logo"], "widening": ["lead"],
      "follows.partner:lead": ["leadName"], "collection:none": ["roots"], "thisMac": ["folders"]]),
    "connection": classes([
      "identity": ["keyId"], "shared": ["name", "enabled", "hasEventsSecret", "eventsHost"],
      "thisMac": ["eventsSecret", "eventsUrl", "statuses", "hootIdentity", "identities", "allowedSenders", "folders", "maxHops"]]),
  ]
  static let appSettingKeys: Set<String> = ["appearance.theme", "appearance.terminalFontSize", "notifications.onComplete",
    "notifications.onNeedsInput", "notifications.onFinishSound", "notifications.soundName"]
  static let nativePreferenceKeys: Set<String> = ["theme", "notifyOnComplete", "defaultProvider"]
  static let nativeWideningKeys: Set<String> = ["defaultProvider"]
  static let noteKeys: Set<String> = ["id", "at", "by", "kind", "text"]
  static let taskTypes: Set<String> = ["task", "milestone"]

  private static func classes(_ byClass: [String: [String]]) -> [String: String] {
    var result: [String: String] = [:]
    for (kind, keys) in byClass { for key in keys { result[key] = kind } }
    return result
  }
}

final class CloudBrainAgentsFieldTableTests: XCTestCase, @unchecked Sendable {
  private func name(_ kind: CloudBrainMergeClass) -> String {
    switch kind {
    case .shared: return "shared"
    case .identity: return "identity"
    case .widening: return "widening"
    case .raise: return "raise"
    case .shrink: return "shrink"
    case .thisMac: return "thisMac"
    case .collection(let cap): return "collection:" + (cap.map(String.init) ?? "none")
    case .follows(.newest): return "follows.newest"
    case .follows(.touched): return "follows.touched"
    case .follows(.oldest): return "follows.oldest"
    case .follows(.partner(let partner)): return "follows.partner:" + partner
    }
  }

  /// Ruling 3: the code tables equal the signed list, field by field and class by class.
  func testCodeTablesMatchTheSignedList() {
    let code: [String: CloudBrainMergeTable] = ["task": CloudBrainMergeTables.task, "run": CloudBrainMergeTables.run,
      "agent": CloudBrainMergeTables.agent, "agentOptions": CloudBrainMergeTables.agentOptions, "setting": CloudBrainMergeTables.setting,
      "project": CloudBrainMergeTables.project, "connection": CloudBrainMergeTables.connection]
    XCTAssertEqual(Set(code.keys), Set(CloudBrainAgentsSignedFieldList.tables.keys))
    for (table, signed) in CloudBrainAgentsSignedFieldList.tables {
      let actual = (code[table]?.classes ?? [:]).mapValues(name)
      XCTAssertEqual(actual, signed, "Table \(table) differs from the signed list")
    }
    XCTAssertEqual(CloudBrainMergeTables.appSettingKeys, CloudBrainAgentsSignedFieldList.appSettingKeys)
    XCTAssertEqual(CloudBrainMergeTables.nativePreferenceKeys, CloudBrainAgentsSignedFieldList.nativePreferenceKeys)
    XCTAssertEqual(CloudBrainMergeTables.nativeWideningKeys, CloudBrainAgentsSignedFieldList.nativeWideningKeys)
    XCTAssertEqual(CloudBrainMergeTables.noteKeys, CloudBrainAgentsSignedFieldList.noteKeys)
    XCTAssertEqual(CloudBrainMergeTables.taskTypes, CloudBrainAgentsSignedFieldList.taskTypes)
  }

  /// The never-travel names of D10.1 are never in a travelling class.
  func testNeverTravelNamesStayOnThisMac() {
    let never = ["eventsSecret", "creatorKeyId", "keyInitializedFields", "syncStatus", "syncedAt", "syncError", "verifyCommand", "startIn",
      "defaultProject", "sourceFile", "sourceDirectory", "sourcePath", "instructionsFile", "account", "notificationKeyId", "reviewVerdict",
      "reusedFromTask", "decisionID", "decisionPolicyID", "decisionEpoch", "decisionEligible", "decisionCreateRequest", "environment", "hooks", "workingFolder"]
    for table in [CloudBrainMergeTables.task, CloudBrainMergeTables.agent, CloudBrainMergeTables.agentOptions, CloudBrainMergeTables.connection] {
      for key in never { if let kind = table.classes[key] { XCTAssertEqual(kind, .thisMac, "\(key) travels in \(table.domain)") } }
    }
    XCTAssertFalse(CloudBrainMergeTables.task.classes.keys.contains { $0.hasPrefix("agopt") && CloudBrainMergeTables.task.classes[$0] != .thisMac })
  }

  /// Ruling 3 change 8: task types and the model character rule.
  func testTaskTypeAndModelRules() {
    XCTAssertTrue(CloudBrainMergeTables.taskTypes.contains("milestone"))
    XCTAssertFalse(CloudBrainMergeTables.taskTypes.contains("routine"))
    for good in ["claude-opus-5-5", "gpt-5.1", "models/gemini-2.5-pro:latest".replacingOccurrences(of: "/", with: "-"), "o3[1m]"] {
      XCTAssertTrue(CloudBrainMergeTables.isValidModel(good), good)
    }
    for bad in ["-x", "", "a b", "model\nnext", "model\n", "a/b", "../x", String(repeating: "a", count: 129)] {
      XCTAssertFalse(CloudBrainMergeTables.isValidModel(bad), bad)
    }
  }
}
