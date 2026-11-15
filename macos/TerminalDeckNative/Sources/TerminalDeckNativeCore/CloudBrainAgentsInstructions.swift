import Foundation

/// The roster as stored: every task-config.json row byte-for-byte (unknown and newer fields, rows this app version
/// no longer reads) plus every instruction file's exact bytes (finding 9). Display trimming is never a backup reader.
public enum CloudBrainAgentsInstructions {
  /// The largest instruction file the app itself reads; a larger file is still exported, as history only.
  public static let maximumBytes = 128_000
  public static let exportLimit = 8 * 1024 * 1024
  /// Keys of task-config.json this adapter names explicitly; any other top-level key is kept as an extra record.
  public static let configKeys: Set<String> = ["v", "agents", "connections", "agentImportSelections", "profileChangePlans"]
  /// Kinds kept in Cloud history but never shown on another device: connected-task definitions need reconnecting there,
  /// import folder choices are this Mac's paths, pending profile reviews belong to this Mac's approvals.
  public static let historyOnlyKinds: Set<String> = ["connection", "import-selections", "profile-plan", "extra", "row"]
  /// Machine-specific agent fields: kept from this Mac's own copy, cleared on a new copy.
  public static let machineKeys = ["sourceDirectory", "sourceFile", "sourcePath", "instructionsFile", "defaultProject", "startIn", "verifyCommand"]

  public static func validName(_ name: String) -> Bool {
    name.hasSuffix(".md") && name.utf8.count <= 255 && !name.contains("/") && !name.contains("\\") && !name.contains("\0") && name != ".md" && !name.hasPrefix(".")
  }
  public static func record(kind: String, id: String, value: NativeRPCValue) -> CloudBrainAgentsRecord {
    .init(domain: "agents", id: CloudBrainTasks.entity(kind: kind, id: id),
      value: .object([.init("kind", .string(kind)), .init("id", .string(id)), .init("record", value)]), projectID: value["projectId"].string)
  }
  public static func instruction(name: String, bytes: Data) throws -> CloudBrainAgentsRecord {
    guard validName(name), bytes.count <= exportLimit else { throw CloudFailure.unsupportedFormat }
    return .init(domain: "agents", id: CloudBrainTasks.entity(kind: "instruction", id: name),
      value: .object([.init("kind", .string("instruction")), .init("id", .string(name)), .init("data", .string(bytes.base64EncodedString()))]))
  }
  public static func instructionBytes(_ payload: NativeRPCValue) throws -> (name: String, bytes: Data) {
    guard payload["kind"].string == "instruction", let name = payload["id"].string, validName(name), let text = payload["data"].string,
      let bytes = Data(base64Encoded: text), bytes.base64EncodedString() == text, bytes.count <= maximumBytes,
      Set((payload.fields ?? []).map(\.key)) == ["kind", "id", "data"] else { throw CloudFailure.invalidRequest }
    return (name, bytes)
  }
  public static func records(config: NativeRPCValue?, files: [(name: String, bytes: Data)]) throws -> [CloudBrainAgentsRecord] {
    var result: [CloudBrainAgentsRecord] = [], seen = Set<String>()
    func add(_ record: CloudBrainAgentsRecord) {
      if seen.insert(record.id).inserted { result.append(record); return }
      let id = CloudSyncBytes.hash((try? CloudSyncCanonical.encode(record.value)) ?? Data())
      if seen.insert("row:" + id).inserted { result.append(Self.record(kind: "row", id: id, value: record.value.raw)) }
    }
    func rowID(_ row: NativeRPCValue, _ key: String) -> String {
      row[key].string ?? ("#" + CloudSyncBytes.hash((try? CloudSyncCanonical.encode(CloudValue(row))) ?? Data()))
    }
    if let config {
      for row in config["agents"].elements ?? [] { add(record(kind: "agent", id: rowID(row, "id"), value: row)) }
      for row in config["connections"].elements ?? [] { add(record(kind: "connection", id: rowID(row, "keyId"), value: row)) }
      if config.has("agentImportSelections") { add(record(kind: "import-selections", id: "this-mac", value: config["agentImportSelections"])) }
      for row in config["profileChangePlans"].elements ?? [] { add(record(kind: "profile-plan", id: rowID(row, "planId"), value: row)) }
      for field in config.fields ?? [] where !configKeys.contains(field.key) { add(record(kind: "extra", id: field.key, value: field.value)) }
    }
    for file in files { add(try instruction(name: file.name, bytes: file.bytes)) }
    return result
  }
}
