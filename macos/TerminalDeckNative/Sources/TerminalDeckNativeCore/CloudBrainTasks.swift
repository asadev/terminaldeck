import Foundation

/// A registered project folder as the Cloud names it: projectId + stable rootId, never the absolute path (design D4).
public struct CloudBrainProjectRoot: Sendable, Equatable, Hashable {
  public let projectID: String
  public let rootID: String
  public let path: String
  public init(projectID: String, rootID: String, path: String) { self.projectID = projectID; self.rootID = rootID; self.path = path }
}

public enum CloudBrainTasks {
  /// Fields that describe what one Mac is doing with a task right now. They never move another Mac's work:
  /// a Mac that already holds the task keeps its own values; a Mac that receives it new gets it stopped and unassigned.
  public static let runtimeKeys = ["sessionId", "seatSession", "seatToldAt", "runStartedAt", "keepOpenUntil", "agoptRunID", "agoptAgentID",
    "agoptRunToken", "questionOpen", "hootTurnOpen", "process", "stopped"]
  /// Folder fields are machine paths; the shared record also carries `cloudProjectRef` (finding 11).
  public static let pathKeys = ["project", "cwd", "agoptCwd", "taskProject", "sourceDirectory", "sourceFile"]
  public static let kinds: Set<String> = ["task", "run", "seen", "ours", "rollup", "runtime", "history-since", "row"]

  /// Entity id: kind plus the record's own id; long or unusual ids are hashed (the original id stays in the payload).
  public static func entity(kind: String, id: String) -> String {
    let plain = id.utf8.count <= 180 && !id.isEmpty && !id.hasPrefix("#") && id.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 }
    return kind + ":" + (plain ? id : "#" + CloudSyncBytes.hash(Data(id.utf8)))
  }
  public static func record(kind: String, id: String, value: NativeRPCValue, place: String? = nil) -> CloudBrainAgentsRecord {
    var payload: [NativeRPCValue.Field] = [.init("kind", .string(kind)), .init("id", .string(id))]
    if let place { payload.append(.init("place", .string(place))) }
    payload.append(.init("record", value))
    return .init(domain: "tasks", id: entity(kind: kind, id: id), value: .object(payload), projectID: value["projectId"].string)
  }

  /// Exactly the rows of the three task files as written (unknown fields and rows the app no longer reads included).
  public static func records(tasks: NativeRPCValue?, runs: NativeRPCValue?, receipts: NativeRPCValue?) throws -> [CloudBrainAgentsRecord] {
    var result: [CloudBrainAgentsRecord] = [], seen = Set<String>()
    func add(_ record: CloudBrainAgentsRecord) {
      if seen.insert(record.id).inserted { result.append(record); return }
      // A repeated id on disk is kept as its own row, never folded into the first.
      let row = record.value.raw
      let id = CloudSyncBytes.hash((try? CloudSyncCanonical.encode(CloudValue(row))) ?? Data())
      if seen.insert("row:" + id).inserted { result.append(.init(domain: "tasks", id: "row:" + id, value: .object([.init("kind", .string("row")), .init("id", .string(id)), .init("record", row)]))) }
    }
    func rowID(_ row: NativeRPCValue) -> String { row["id"].string ?? ("#" + CloudSyncBytes.hash((try? CloudSyncCanonical.encode(CloudValue(row))) ?? Data())) }
    if let tasks {
      for (place, key) in [("tasks", "tasks"), ("trash", "trash")] {
        for row in tasks[key].elements ?? [] { add(record(kind: "task", id: rowID(row), value: row, place: place)) }
      }
    }
    if let runs {
      for row in runs["agentRuns"].elements ?? [] { add(record(kind: "run", id: rowID(row), value: row)) }
      for field in runs["agentRunRollups"].fields ?? [] { add(record(kind: "rollup", id: field.key, value: field.value)) }
      for field in runs["agentRuntimeState"].fields ?? [] { add(record(kind: "runtime", id: field.key, value: field.value)) }
      if runs.has("agentHistorySince"), !runs["agentHistorySince"].isNullish { add(record(kind: "history-since", id: "origin", value: runs["agentHistorySince"])) }
    }
    if let receipts {
      for kind in ["seen", "ours"] {
        for entry in receipts[kind].elements ?? [] {
          if let pair = entry.elements, pair.count == 2, let id = pair[0].string { add(record(kind: kind, id: id, value: pair[1])) }
          else { add(record(kind: kind, id: rowID(entry), value: entry)) }
        }
      }
    }
    return result
  }

  /// The local image of a shared task. `existing` is this Mac's current copy, if any.
  /// The runtime and folder fields of an existing copy stay as they are; a new copy is inert (stopped, unassigned)
  /// and gets its folder only through the project's rootId mapped on this Mac.
  public static func show(_ shared: NativeRPCValue, existing: NativeRPCValue?, operationID: String,
                          localPath: (String, String) -> String?) -> NativeRPCValue {
    var result = shared.removing("cloudProjectRef")
    if let existing {
      for key in runtimeKeys + pathKeys + ["assignee"] {
        result = existing.has(key) ? result.setting(key, existing[key]) : result.removing(key)
      }
      return result
    }
    for key in runtimeKeys + pathKeys { result = result.removing(key) }
    var path = ""
    if let projectID = shared["cloudProjectRef"]["projectId"].string, let rootID = shared["cloudProjectRef"]["rootId"].string {
      path = localPath(projectID, rootID) ?? ""
    }
    result = result.setting("sessionId", .null).setting("process", .string("stopped"))
      .setting("stopped", .bool(true)).setting("assignee", .object([.init("kind", .string("none"))]))
      .setting("cloudRestoredOperation", .string(operationID)).setting("project", .string(path))
    if path.isEmpty, !(shared["project"].string ?? "").isEmpty { result = result.setting("cloudNeedsPathMapping", .bool(true)) }
    return result
  }
  /// The shared form of a local task: its folder also named by projectId/rootId when it is a registered root.
  public static func share(_ local: NativeRPCValue, roots: [String: CloudBrainProjectRoot]) -> NativeRPCValue {
    var value = local.removing("cloudRestoredOperation").removing("cloudNeedsPathMapping")
    if let path = local["project"].string, let root = roots[path] {
      value = value.setting("cloudProjectRef", .object([.init("projectId", .string(root.projectID)), .init("rootId", .string(root.rootID))]))
    }
    return value
  }
}
