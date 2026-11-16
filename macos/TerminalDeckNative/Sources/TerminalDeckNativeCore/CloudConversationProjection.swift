import Foundation

public struct CloudConversationProjectionResult: Sendable {
  public let bytes: Data
  public let conversationID: String
  public let oldPath: String
  public let newPath: String
  public let rawHash: String
  public let projectedHash: String
}

public enum CloudConversationProjection {
  public struct MappedRecord: Sendable {
    public let value: NativeRPCValue
    public let identity: Bool
    public let path: Bool
  }
  public static func mapRecord(_ value: NativeRPCValue, provider: CloudConversationProvider, conversationID: String,
                               oldPath: String, newPath: String) throws -> MappedRecord {
    var identity = false, path = false
      var value = value
      switch provider {
      case .claude:
        if let id = value["sessionId"].string {
          guard id == conversationID else { throw CloudFailure.unsupportedFormat }
          identity = true
        }
        if value["cwd"].string == oldPath { path = true; value = value.setting("cwd", .string(newPath)) }
      case .codex:
        if value["type"].string == "session_meta" {
          guard value["payload"]["id"].string == conversationID, value["payload"]["cwd"].string == oldPath else { throw CloudFailure.unsupportedFormat }
          identity = true; path = true
          if value["payload"]["cwd"].string == oldPath { value = value.setting("payload", value["payload"].setting("cwd", .string(newPath))) }
        } else if value["type"].string == "turn_context", value["payload"]["cwd"].string == oldPath {
          value = value.setting("payload", value["payload"].setting("cwd", .string(newPath)))
        }
      case .gemini:
        if value["sessionId"].string == conversationID {
          identity = true
          if let projectHash = value["projectHash"].string {
            guard projectHash == CloudSyncBytes.hash(Data(oldPath.utf8)) else { throw CloudFailure.unsupportedFormat }
            path = true
            value = value.setting("projectHash", .string(CloudSyncBytes.hash(Data(newPath.utf8))))
          }
        }
      }
    return .init(value: value, identity: identity, path: path)
  }
  /// This transform changes only provider-owned metadata. Message/tool text is never searched or replaced.
  /// Large raw archives remain readable even when this format's projection cannot be made in memory.
  public static func project(_ raw: Data, provider: CloudConversationProvider, conversationID: String,
                             oldPath: String, newPath: String, jsonLines: Bool) throws -> CloudConversationProjectionResult {
    guard raw.count <= CloudWire.maximumPlainChunkBytes,
      conversationID.range(of: "^[A-Za-z0-9_-]{1,128}$", options: .regularExpression) != nil,
      oldPath.hasPrefix("/"), newPath.hasPrefix("/") else { throw CloudFailure.unsupportedFormat }
    var foundIdentity = false, foundPath = false
    func transform(_ value: NativeRPCValue) throws -> NativeRPCValue {
      let mapped = try mapRecord(value, provider: provider, conversationID: conversationID, oldPath: oldPath, newPath: newPath)
      foundIdentity = foundIdentity || mapped.identity; foundPath = foundPath || mapped.path
      return mapped.value
    }
    let bytes: Data
    if jsonLines {
      var output = Data()
      let lines = raw.split(separator: 10, omittingEmptySubsequences: false)
      for (index, line) in lines.enumerated() {
        if !line.isEmpty {
          let value = try NativeRPCValue.parseJSON(Data(line), maximumBytes: CloudWire.maximumPlainChunkBytes)
          let mapped = try transform(value)
          if mapped == value { output.append(contentsOf: line) } else { output.append(try mapped.encodedJSON()) }
        }
        if index < lines.count - 1 { output.append(10) }
      }
      bytes = output
    } else {
      guard provider == .gemini else { throw CloudFailure.unsupportedFormat }
      let value = try NativeRPCValue.parseJSON(raw, maximumBytes: CloudWire.maximumPlainChunkBytes)
      bytes = try transform(value).encodedJSON()
    }
    guard foundIdentity, foundPath else { throw CloudFailure.unsupportedFormat }
    return .init(bytes: bytes, conversationID: conversationID, oldPath: oldPath, newPath: newPath,
      rawHash: CloudSyncBytes.hash(raw), projectedHash: CloudSyncBytes.hash(bytes))
  }
}
