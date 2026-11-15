import Foundation

/// How a follows-class field is merged (design v2 D1): never a conflict.
public enum CloudBrainMergeFollow: Sendable, Equatable {
  /// The largest number among the heads (`archivedAt`): a lone change on one Mac survives a concurrent edit elsewhere.
  case newest
  /// The largest number, but a change to this field alone never makes a revision (`updatedAt` is touched by every write).
  case touched
  /// The smallest number among the heads (`createdAt`).
  case oldest
  /// Travels with the partner field: among the heads that hold the partner's shown stamp, the newest own stamp wins.
  case partner(String)
}

/// Field classes of design v2 Appendix A (revision 4).
public enum CloudBrainMergeClass: Sendable, Equatable {
  /// Merged per field by the newest last-changed stamp; a different concurrent value is an other version.
  case shared
  /// Written once when the record is created on a Mac; a later value never replaces it.
  case identity
  /// Shared, but a change from another device that widens what would launch here is held by the owner (D10).
  case widening
  /// Travels only from off to on (task `decisionRequired`, Ruling 3 change 4): concurrent on beats off; a Cloud value
  /// that would turn it off is held by the owner (`CloudBrainMerge.mayApply`).
  case raise
  /// A limit that may only get smaller (task `tokenBudget`, Ruling 3 change 5): the smallest positive value wins; a larger
  /// value, zero (no limit) or none from another device is held by the owner.
  case shrink
  case follows(CloudBrainMergeFollow)
  /// A set of elements by element id; `cap` keeps the newest N in the shared set and is never a removal.
  case collection(cap: Int?)
  /// Never sent, never a change on this Mac.
  case thisMac
}

/// One versioned allow-list. Any key not listed is this-Mac-only and never travels.
public struct CloudBrainMergeTable: Sendable {
  public let domain: String
  public let version: Int
  public let classes: [String: CloudBrainMergeClass]
  /// Table version that introduced each field (absent = 1). Feeds a revision's `minTable`.
  public let introduced: [String: Int]
  public init(domain: String, version: Int, classes: [String: CloudBrainMergeClass], introduced: [String: Int] = [:]) {
    self.domain = domain; self.version = version; self.classes = classes; self.introduced = introduced
  }
  /// nil: this app version does not know the key.
  public func fieldClass(_ key: String) -> CloudBrainMergeClass? { key == CloudBrainMerge.existsField ? .shared : classes[key] }
}

/// Appendix A, version 1, as signed by the Security seat (Ruling 3, 12 Nov 2026). The test
/// `CloudBrainAgentsFieldTableTests` compares every table here with the checked-in signed copy; a change needs Security.
public enum CloudBrainMergeTables {
  public static let version = 1
  private static func all(_ kind: CloudBrainMergeClass, _ keys: [String]) -> [String: CloudBrainMergeClass] {
    Dictionary(keys.map { ($0, kind) }, uniquingKeysWith: { first, _ in first })
  }
  private static func table(_ domain: String, _ parts: [[String: CloudBrainMergeClass]]) -> CloudBrainMergeTable {
    .init(domain: domain, version: version, classes: parts.reduce(into: [:]) { result, part in result.merge(part) { first, _ in first } })
  }

  /// `tasks.json` rows (live and Trash), entity `task:<id>`. `place` is "tasks" or "trash"; `projectRef` is `{projectId, rootId}`.
  public static let task = table("tasks", [
    all(.identity, ["id", "keyId", "externalTaskId", "originExternalTaskId", "externalThreadId", "creator"]),
    all(.shared, ["title", "instructions", "crmStatus", "priority", "labels", "dueDate", "dueTime", "startDate", "startTime",
      "estimateMinutes", "taskType", "goalId", "result", "effort", "model", "projectRef", "place"]),
    ["decisionRequired": .raise, "tokenBudget": .shrink],
    ["updatedAt": .follows(.touched), "createdAt": .follows(.oldest), "completedAt": .follows(.partner("crmStatus")),
     "deletedAt": .follows(.partner("place")), "archivedAt": .follows(.newest), "hops": .follows(.newest), "notes": .collection(cap: 100)],
    all(.thisMac, ["local", "notificationKeyId", "reviewVerdict", "reusedFromTask", "decisionID", "decisionPolicyID", "decisionEpoch",
      "decisionEligible", "decisionCreateRequest", "assignee", "mainAssignee", "handedFrom", "requestedBy", "parentTaskId",
      "parentExternalTaskId", "reviewOfTaskId", "reviewerTaskId", "project", "cwd", "sessionId", "conversationId", "seatSession",
      "seatToldAt", "process", "stopped", "runStartedAt", "keepOpenUntil", "keepAliveUntilClose", "questionOpen", "hootTurnOpen",
      "lastTurn", "childrenTold", "seq", "stalled", "startFailed", "awaitingSetup", "useWorkspace", "briefFile", "landing",
      "landingAttempts", "reviewWaitingForFolder", "tokenUsageByAgent", "isAPIAccount", "detail"])])
  /// Accepted values of a task's `taskType` (Ruling 3 change 8).
  public static let taskTypes: Set<String> = ["task", "milestone"]
  /// S8 / Ruling 3 change 8: a `model` (agent or task) is letters, digits and `. _ : [ ] -`, starting with a letter or digit.
  public static func isValidModel(_ value: String) -> Bool {
    value.range(of: #"\A[A-Za-z0-9][A-Za-z0-9._:\[\]-]{0,127}\z"#, options: .regularExpression) != nil
  }

  /// Elements of a task's `notes` collection: only these keys travel; `cloudFrom` is set by the receiving Mac.
  public static let noteKeys: Set<String> = ["id", "at", "by", "kind", "text"]

  /// Finished agent runs (history), entity `run:<id>`.
  public static let run = table("tasks", [
    all(.shared, ["id", "agent_id", "task_id", "provider", "project_id", "session_id", "conversation_id", "session_name", "started_at",
      "ended_at", "outcome", "summary", "needed_help", "verified", "tokens", "cost_usd", "cost_source", "billing_kind", "requested_model",
      "requested_effort"]),
    all(.thisMac, ["cwd", "account_id"])])

  /// `task-config.json` `agents` rows, entity `agent:<id>`. `instructionHash` names the instruction file's bytes.
  public static let agent = table("agents", [
    all(.identity, ["id"]),
    all(.shared, ["name", "role", "toolsPreferred", "toolsAvoided", "model", "effort", "icon", "reportsTo", "instructionHash"]),
    // `seat` picks the login an agent runs under (NativeCompositionProductionTasks.swift:162-173; Ruling 3 change 10).
    all(.widening, ["provider", "permissionMode", "allowedTools", "blockedTools", "skillsOff", "toolUseRestrictions", "claudeAgent", "skills",
      "maxConcurrent", "maxRunMinutes", "keepAliveMinutes", "keepAliveUntilClose", "status", "projectId", "seat"]),
    ["statusAt": .follows(.partner("status"))],
    // `account` ids are made per Mac; `creatorKeyId` gives a key owner rights over the agent (BackendTAGProfilePolicy.swift:22).
    all(.thisMac, ["account", "creatorKeyId", "keyInitializedFields", "syncStatus", "syncedAt", "syncError", "instructions",
      "instructionsFile", "verifyCommand", "sourceDirectory", "sourceFile", "sourcePath", "defaultProject", "startIn", "reviewerAgent"])])

  /// AGS vault options per profile and per provider default.
  public static let agentOptions = table("agent-options", [
    all(.shared, ["model", "effort"]),
    all(.widening, ["provider", "permissionMode", "allowedTools", "deniedTools", "mcpServers", "keepOpen", "efficiency", "contextWindow", "fastMode"]),
    all(.thisMac, ["environment", "hooks", "workingFolder"])])

  /// `settings.json` values, one record per key holding `key` and `value`.
  public static let appSettingKeys: Set<String> = ["appearance.theme", "appearance.terminalFontSize", "notifications.onComplete",
    "notifications.onNeedsInput", "notifications.onFinishSound", "notifications.soundName"]
  /// `state.json` `preferences`, one record per key; `defaultProvider` is a widening (the owner holds it).
  public static let nativePreferenceKeys: Set<String> = ["theme", "notifyOnComplete", "defaultProvider"]
  public static let nativeWideningKeys: Set<String> = ["defaultProvider"]
  public static let setting = table("settings", [all(.identity, ["key"]), all(.shared, ["value"])])

  /// Project registry rows, entity `project:<id>`; `roots` is the full set of rootId elements (`{id}`), folders stay here.
  public static let project = table("projects", [
    all(.identity, ["id"]),
    all(.shared, ["name", "icon", "colour", "logo"]),
    all(.widening, ["lead"]),
    ["leadName": .follows(.partner("lead")), "roots": .collection(cap: nil)],
    all(.thisMac, ["folders"])])

  /// Connected-task connection rows: history only. `eventsHost` is the host part of `eventsUrl`, derived by the owner.
  public static let connection = table("agents", [
    all(.identity, ["keyId"]),
    all(.shared, ["name", "enabled", "hasEventsSecret", "eventsHost"]),
    all(.thisMac, ["eventsSecret", "eventsUrl", "statuses", "hootIdentity", "identities", "allowedSenders", "folders", "maxHops"])])
}

// Delete rule L4: v1 remains the Security-reviewed compatibility list above. No new field is emitted
// until the account gate opens. minTable=2 then prevents a v1 reader silently misapplying Cloud scope.
extension CloudBrainMergeTables {
  public static let recordDeleteFields = ["deletedBy", "deletedOn", "deletedGroup", "deletedSession", "deletedAgent", "deletedMacName", "deletedTime", "deletedScope", "deletedWithAgent"]
  public static func recordsDeleteRule(_ base: CloudBrainMergeTable, partner: String = CloudBrainMerge.existsField) -> CloudBrainMergeTable {
    var classes = base.classes
    for field in recordDeleteFields { classes[field] = .follows(.partner(partner)) }
    var introduced = base.introduced
    for field in recordDeleteFields { introduced[field] = 2 }
    return .init(domain: base.domain, version: max(2, base.version), classes: classes, introduced: introduced)
  }
}

// Tasks everywhere (15 Nov 2026, owner: "every small thing to be synced"). Reviewed allow-list additions, each one
// listed for the Security seat. Sent only while the delete rule's gate is open (every Mac of the account runs this
// build); then minTable 2 keeps a v1 reader from half-applying them. No second gate.
extension CloudBrainMergeTables {
  /// Task fields that were "this Mac" (or not listed) and now travel. `assignee`/`mainAssignee` travel as INFORMATION:
  /// an arriving one never starts work (`BackendCloudKindsTasks.compose`, the arriving-assignment guard).
  /// `workingOn` is the device id of the Mac whose session works the task (the other Mac's card names it).
  /// `detail` travels without this Mac's delivery receipts, repeat schedule, reminders and uploaded files
  /// (`BackendCloudKindsTasks.detailLocalKeys`).
  public static let taskEverywhereFields = ["assignee", "mainAssignee", "handedFrom", "requestedBy", "parentTaskId",
    "parentExternalTaskId", "reviewOfTaskId", "reviewerTaskId", "reviewVerdict", "reusedFromTask", "askedFromTask", "board",
    "position", "recurrence", "useWorkspace", "tokenUsage", "tokenUsageByAgent", "detail", "workingOn"]
  public static func tasksEverywhere(_ base: CloudBrainMergeTable) -> CloudBrainMergeTable {
    var classes = base.classes, introduced = base.introduced
    for field in taskEverywhereFields { classes[field] = .shared; introduced[field] = 2 }
    return .init(domain: base.domain, version: max(2, base.version), classes: classes, introduced: introduced)
  }
  /// A connected task system (connected-tasks.json row), entity `task-system:<id>`: how to reach it, never its token
  /// (the token travels inside saved passwords, domain `task-connection`). Each Mac fetches the system's tasks itself.
  public static let taskSystem = CloudBrainMergeTable(domain: "tasks", version: 2, classes: all(.identity, ["id", "createdAt"])
    .merging(all(.shared, ["name", "url", "enabled", "changes", "markDone", "projectId", "profile", "server", "me", "docsUrl"])) { first, _ in first }
    .merging(all(.thisMac, ["tokenEnding", "problem", "projectIdInferred", "folder", "startIn"])) { first, _ in first },
    introduced: Dictionary(uniqueKeysWithValues: ["id", "createdAt", "name", "url", "enabled", "changes", "markDone", "projectId", "profile",
      "server", "me", "docsUrl"].map { ($0, 2) }))
  /// A task a CRM task link sent to ONE Mac (entity `crm-task:<keyId>:<externalTaskId>`), travelling to the other
  /// Macs as a READ-ONLY, never-started copy: the task fields of `tasksEverywhere(task)` plus `systemName` (the CRM's
  /// name as its link names it) and `homeMac` (device id of the Mac that receives it). The CRM's access key never
  /// travels (`keyId` is only the key's id, the task's identity). Every field is new here, so all are version 2.
  public static let crmTask: CloudBrainMergeTable = {
    let base = tasksEverywhere(task)
    var classes = base.classes
    classes["systemName"] = .shared; classes["homeMac"] = .shared
    return .init(domain: base.domain, version: 2, classes: classes,
                 introduced: Dictionary(uniqueKeysWithValues: classes.keys.map { ($0, 2) }))
  }()
  /// A CRM task link (task-config.json connection, entity `task-link:<keyId>`): name and on/off only. The CRM sends its
  /// tasks to the loopback address of ONE Mac with that Mac's access key, so the other Mac shows a plain line instead.
  public static let taskLink = CloudBrainMergeTable(domain: "tasks", version: 2, classes: all(.identity, ["keyId"])
    .merging(all(.shared, ["name", "enabled"])) { first, _ in first },
    introduced: ["keyId": 2, "name": 2, "enabled": 2])
}
