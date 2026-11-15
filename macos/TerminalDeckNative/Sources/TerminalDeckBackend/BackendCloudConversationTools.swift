import Foundation
import TerminalDeckNativeCore

public struct BackendCloudConversationMetadata: Sendable {
  public let archiveID: String
  public let provider: CloudConversationProvider
  public let conversationID: String?
  public let projectID: String?
  public let bytes: Int64
  public init(archiveID: String, provider: CloudConversationProvider, conversationID: String?, projectID: String?, bytes: Int64) {
    self.archiveID = archiveID; self.provider = provider; self.conversationID = conversationID; self.projectID = projectID; self.bytes = bytes
  }
  public var wire: NativeRPCValue {
    .object([.init("archiveId", .string(archiveID)), .init("provider", .string(provider.rawValue)),
      .init("conversationId", conversationID.map(NativeRPCValue.string) ?? .null),
      .init("projectId", projectID.map(NativeRPCValue.string) ?? .null), .init("bytes", .string(String(bytes)))])
  }
}
public struct BackendCloudConversationPage: Sendable {
  public let items: [BackendCloudConversationMetadata]
  public let after: String?
  public init(items: [BackendCloudConversationMetadata], after: String?) { self.items = items; self.after = after }
}

public enum BackendCloudConversationTools {
  public static let owner = "cloud-adapters"
  public struct Ports: Sendable {
    public let gate: @Sendable () async -> Bool
    public let authorize: @Sendable (BackendMCPCallContext, String, NativeRPCValue) async throws -> Void
    public let list: @Sendable (BackendMCPCallContext, NativeRPCValue) async throws -> BackendCloudConversationPage
    public let providerOfConversation: @Sendable (String) async throws -> CloudConversationProvider
    public let resume: @Sendable (BackendMCPCallContext, NativeRPCValue) async throws -> BackendCloudConversationLaunchReceipt
    public init(gate: @escaping @Sendable () async -> Bool,
                authorize: @escaping @Sendable (BackendMCPCallContext, String, NativeRPCValue) async throws -> Void,
                list: @escaping @Sendable (BackendMCPCallContext, NativeRPCValue) async throws -> BackendCloudConversationPage,
                providerOfConversation: @escaping @Sendable (String) async throws -> CloudConversationProvider,
                resume: @escaping @Sendable (BackendMCPCallContext, NativeRPCValue) async throws -> BackendCloudConversationLaunchReceipt) {
      self.gate = gate; self.authorize = authorize; self.list = list; self.providerOfConversation = providerOfConversation; self.resume = resume
    }
  }
  /// A supplies verified coverage, not a user toggle. Default contribution has no unsupported controls.
  public static func contribution(verifiedArchiveRows: Set<String> = [], verifiedContinueRows: Set<String> = []) throws -> CloudFeatureContribution {
    let supported: Set<String> = ["I17", "I18", "I19"]
    guard verifiedArchiveRows.isSubset(of: supported), verifiedContinueRows.isSubset(of: verifiedArchiveRows) else { throw CloudFailure.invalidRequest }
    func schema(_ properties: [NativeRPCValue.Field], required: [String] = []) -> CloudValue {
      .init(.object([.init("type", .string("object")), .init("properties", .object(properties)),
        .init("required", .array(required.map(NativeRPCValue.string))), .init("additionalProperties", .bool(false))]))
    }
    let string: NativeRPCValue = .object([.init("type", .string("string")), .init("minLength", .number(1))])
    var tools: [CloudToolDefinition] = []
    if !verifiedArchiveRows.isEmpty {
      let providers = CloudConversationProvider.allCases.filter { verifiedArchiveRows.contains($0.inventoryRow) }.map { NativeRPCValue.string($0.rawValue) }
      tools.append(.init(id: "cloud.conversations", title: "Saved conversations", description: "Read a page of saved conversation metadata. Reading history starts nothing.",
        inputSchema: schema([.init("projectId", string), .init("provider", .object([.init("type", .string("string")), .init("enum", .array(providers))])),
          .init("after", string), .init("limit", .object([.init("type", .string("integer")), .init("minimum", .number(1)), .init("maximum", .number(200))]))]),
        mutates: false, inventoryRows: verifiedArchiveRows.sorted()))
    }
    if !verifiedContinueRows.isEmpty {
      tools.append(.init(id: "cloud.continue", title: "Continue conversation", description: "Explicitly continue one saved conversation after its context, path, provider and lease checks.",
        inputSchema: schema([.init("conversationId", string), .init("projectId", string), .init("rootId", string), .init("requestId", string)], required: ["conversationId", "projectId", "rootId"]),
        mutates: true, inventoryRows: verifiedContinueRows.sorted()))
    }
    return .init(owner: "A2", tools: tools, inventoryRows: verifiedArchiveRows.sorted(), actions: tools.map(\.id))
  }
  public static func registrations(contribution: CloudFeatureContribution, ports: Ports) async throws -> [(BackendMCPTool, BackendNativeMCPServer.Handler)] {
    guard await ports.gate() else { return [] }
    return try contribution.tools.map { definition in
      guard ["cloud.conversations", "cloud.continue"].contains(definition.id) else { throw CloudFailure.invalidRequest }
      let spec = try BackendMCPTool(id: definition.id, wireName: definition.id.replacingOccurrences(of: ".", with: "_"),
        description: definition.description, inputSchema: definition.inputSchema.raw, tier: definition.mutates ? .act : .read)
      return (spec, { context, arguments in
        guard await ports.gate(), !context.cancellation.isCancelled,
          context.allowedTiers.contains(spec.tier), BackendMCPToolNames.permits(spec.id, granted: context.allowedTools),
          let fields = arguments.fields else { throw CloudFailure.gateClosed }
        let allowed = Set((definition.inputSchema.raw["properties"].fields ?? []).map(\.key))
        guard Set(fields.map(\.key)).count == fields.count, Set(fields.map(\.key)).isSubset(of: allowed) else { throw CloudFailure.invalidRequest }
        for field in fields where field.key != "limit" {
          guard let text = field.value.string, !text.isEmpty else { throw CloudFailure.invalidRequest }
        }
        for required in definition.inputSchema.raw["required"].elements ?? [] {
          guard let key = required.string, let value = arguments[key].string, !value.isEmpty else { throw CloudFailure.invalidRequest }
        }
        if let raw = arguments["provider"].string {
          guard let provider = CloudConversationProvider(rawValue: raw), definition.inventoryRows.contains(provider.inventoryRow) else { throw CloudFailure.unsupportedFormat }
        }
        if arguments.has("limit") {
          guard let n = arguments["limit"].number, n.rounded() == n, (1...200).contains(n) else { throw CloudFailure.invalidRequest }
        }
        // The same project/session fence used by chats.read and the existing launcher remains mandatory.
        try await ports.authorize(context, spec.id, arguments)
        guard await ports.gate(), !context.cancellation.isCancelled else { throw CloudFailure.gateClosed }
        try Task.checkCancellation()
        if spec.id == "cloud.conversations" {
          let page = try await ports.list(context, arguments)
          guard page.items.count <= Int(arguments["limit"].number ?? 50),
            page.items.allSatisfy({ definition.inventoryRows.contains($0.provider.inventoryRow) &&
              (arguments["provider"].string == nil || $0.provider.rawValue == arguments["provider"].string) &&
              (arguments["projectId"].string == nil || $0.projectID == arguments["projectId"].string) }) else { throw CloudFailure.invalidRequest }
          return .value(.object([.init("items", .array(page.items.map(\.wire))), .init("after", page.after.map(NativeRPCValue.string) ?? .null)]))
        }
        let conversationID = arguments["conversationId"].string!
        let provider = try await ports.providerOfConversation(conversationID)
        guard definition.inventoryRows.contains(provider.inventoryRow) else { throw CloudFailure.unsupportedFormat }
        guard await ports.gate(), !context.cancellation.isCancelled else { throw CloudFailure.gateClosed }
        try Task.checkCancellation()
        let receipt = try await ports.resume(context, arguments)
        guard receipt.resumed, receipt.conversationID == conversationID else { throw CloudFailure.unsupportedFormat }
        return .value(.object([.init("sessionId", .string(receipt.sessionID)), .init("conversationId", .string(receipt.conversationID)), .init("resumed", .bool(true))]))
      })
    }
  }
}
