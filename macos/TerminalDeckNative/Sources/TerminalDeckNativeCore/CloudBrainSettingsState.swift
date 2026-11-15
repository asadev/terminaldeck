import Foundation

public enum CloudBrainSettingsState {
  public static let linkKeys: Set<String> = ["id", "tabKey", "conversationId", "agentSessionId", "provider", "projectId", "name", "title"]
  private static func hash(_ value: NativeRPCValue) -> String { CloudSyncBytes.hash((try? CloudSyncCanonical.encode(CloudValue(value))) ?? Data()) }
  /// The part of state.json the Cloud reads; compared cheaply before any capture work on the hot commit path.
  public static func relevant(_ state: NativeRPCValue) -> NativeRPCValue {
    .object([.init("preferences", CloudBrainSettings.portable(state["preferences"])), .init("projects", state["projects"]),
      .init("openSessions", .array((state["openSessions"].elements ?? []).map { .object(($0.fields ?? []).filter { linkKeys.contains($0.key) }) }))])
  }
  /// Preferences are shared; open-session links and project rows are history (processes are never imported).
  /// Ids never depend on list order, and a row without a path or key is still exported (findings 19d, 19e).
  public static func records(_ state: NativeRPCValue) -> [CloudBrainAgentsRecord] {
    var rows = (CloudBrainSettings.portable(state["preferences"]).fields ?? []).map { field in
      CloudBrainAgentsRecord(domain: "native-state", id: "preference:" + field.key,
        value: .object([.init("kind", .string("preference")), .init("key", .string(field.key)), .init("value", field.value)]))
    }
    var seen = Set(rows.map(\.id))
    for project in state["projects"].elements ?? [] {
      let identity = project["path"].string.map { CloudSyncBytes.hash(Data($0.utf8)) } ?? ("row-" + hash(project))
      guard seen.insert("project:" + identity).inserted else { continue }
      rows.append(.init(domain: "native-state", id: "project:" + identity,
        value: .object([.init("kind", .string("project")), .init("record", project)]), projectID: project["projectId"].string))
    }
    for session in state["openSessions"].elements ?? [] {
      let metadata = NativeRPCValue.object((session.fields ?? []).filter { linkKeys.contains($0.key) })
      let key = session["tabKey"].string ?? session["id"].string ?? ("content-" + hash(metadata))
      let id = CloudBrainTasks.entity(kind: "conversation-link", id: key)
      guard seen.insert(id).inserted else { continue }
      rows.append(.init(domain: "native-state", id: id,
        value: .object([.init("kind", .string("conversation-link")), .init("key", .string(key)), .init("record", metadata)]), projectID: session["projectId"].string))
    }
    return rows
  }
  public static func shape() -> CloudBrainAgentsShape {
    CloudBrainAgentsShape(show: { op, payload in
      switch payload["kind"].string {
      case "preference":
        guard let key = payload["key"].string, CloudBrainSettings.portableKeys.contains(key), CloudBrainSettings.isScalar(payload["value"]),
              op.entityId == "preference:" + key else { throw CloudFailure.invalidRequest }
        return payload
      case "project":
        guard op.entityId.hasPrefix("project:") else { throw CloudFailure.invalidRequest }
        return nil
      case "conversation-link":
        guard let key = payload["key"].string, op.entityId == CloudBrainTasks.entity(kind: "conversation-link", id: key),
              Set((payload["record"].fields ?? []).map(\.key)).isSubset(of: linkKeys) else { throw CloudFailure.invalidRequest }
        return nil
      default:
        throw CloudFailure.unsupportedFormat
      }
    })
  }
}
