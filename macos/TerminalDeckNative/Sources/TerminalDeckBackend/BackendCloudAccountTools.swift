import Foundation
import TerminalDeckNativeCore

public enum BackendCloudAccountTools {
    public static let owner = "cloud-account"
    public static let ids = ["cloud.status", "cloud.signin", "cloud.signout", "cloud.sync", "cloud.devices", "cloud.contents"]
    public static func definitions(includeSubscription: Bool = false) throws -> [BackendMCPTool] {
        func schema(_ properties: [NativeRPCValue.Field] = [], required: [String] = []) -> NativeRPCValue {
            .object([.init("type", .string("object")), .init("properties", .object(properties)),
                     .init("required", .array(required.map(NativeRPCValue.string))), .init("additionalProperties", .bool(false))])
        }
        func choice(_ values: [String]) -> NativeRPCValue { .object([.init("type", .string("string")), .init("enum", .array(values.map(NativeRPCValue.string)))]) }
        var specs: [(String, String, BackendMCPTier, NativeRPCValue)] = [
            ("cloud.status", "Read Cloud status: what this Mac has saved and what is still going up, whether this Mac has everything the Cloud holds, which devices wait to be trusted and what waits on this Mac for the person; the main window's one status line exactly as shown (statusLine: state, line, what needs the person, whether Sync now is offered, when everything was last level) and the space used per kind with the total and the account's limit (space); the person's name as their profile says it now (profileName); and when the Cloud last received the list your phones show while your Macs are off, and from which Mac (shelf: on, lastPut, from); how many sessions this Mac lists in the Cloud and how far their chats are uploaded (sessions: listed, uploadedBytes, historyBytes, percent, line). Never returns sign-in tokens or passwords.", .read, schema()),
            ("cloud.signin", "Open the existing website sign-in flow for this Mac.", .act, schema([.init("provider", choice(["google", "github"]))])),
            ("cloud.signout", "Sign out of Cloud on this Mac. Local work and running sessions stay open.", .alter, schema()),
            ("cloud.sync", "Sync now (fetch from Cloud, then send), retry sending, pause or resume Cloud on this Mac, or check again the changes from Cloud that could not be checked. Waiting changes are retained.", .alter, schema([.init("action", choice(["now", "retry", "pause", "resume", "check"]))], required: ["action"])),
            ("cloud.devices", "Read this Cloud identity's device names and status. No credentials are returned.", .read, schema()),
            ("cloud.contents", "Read what is in your Cloud and how it is moving, as the \"See what is in your Cloud\" page shows it: each device by name with when it last sent and received and its state; every item by kind (memory, projects, agents, instruction files, settings, saved passwords) with its name, where it belongs, which device changed it last and when, and on which devices it is; and the recent activity in sentences. Names, kinds, device names and times only: never content, never a saved password's value, never an id, key or code.", .read, schema())
        ]
        if includeSubscription {
            specs.append(("cloud.subscription", "Read the Cloud plan, state, paid-until date, store and included/extra storage shown in Settings. No credentials or purchase action.", .read, schema()))
        }
        return try specs.map { try .init(id: $0.0, wireName: $0.0.replacingOccurrences(of: ".", with: "_"), description: $0.1, inputSchema: $0.3, tier: $0.2) }
    }
    /// `overview` is the Cloud page's one summary (`BackendCloudOverview.wireValue`), so an agent reads the same
    /// plain state the person sees; nil where no page model exists (fixtures).
    public static func registrations(service: BackendCloudAccount, now: Int64,
                                     overview: (@Sendable () async -> NativeRPCValue?)? = nil,
                                     contents: (@Sendable () async -> NativeRPCValue?)? = nil,
                                     line: (@Sendable () async -> NativeRPCValue?)? = nil,
                                     shelf: (@Sendable () async -> NativeRPCValue?)? = nil,
                                     chats: (@Sendable () async -> NativeRPCValue?)? = nil,
                                     signin: @escaping @Sendable (String?) async throws -> Void) async throws -> [(BackendMCPTool, BackendNativeMCPServer.Handler)] {
        let snapshot = await service.state()
        let cloud = snapshot.visible(at: now) && snapshot.subscription.offers(.cloudTools)
        return try definitions(includeSubscription: snapshot.subscription.showsSubscription)
            .filter { $0.id == "cloud.subscription" || cloud }.map { spec in
            (spec, { _, arguments in
                let current = await service.state()
                if spec.id == "cloud.subscription" {
                    guard current.subscription.showsSubscription else { throw CloudFailure.gateClosed }
                    return .value(current.subscription.wireValue)
                }
                guard current.visible(at: Int64(Date().timeIntervalSince1970 * 1000)), current.subscription.offers(.cloudTools) else { throw CloudFailure.gateClosed }
                switch spec.id {
                case "cloud.status":
                    let state = await service.state().wireValue
                    guard var fields = state.fields else { return .value(state) }
                    if let summary = await overview?() { fields.append(.init("overview", summary)) }
                    // Status-line lane: the status line and the space per kind, the same values the window shows.
                    if let extra = await line?()?.fields { fields += extra }
                    // Mac shelf: read only (when it was last put and from which Mac); no tool can switch it off.
                    if let shelf = await shelf?() { fields.append(.init("shelf", shelf)) }
                    // Sessions in the Cloud (15 Nov): how many sessions this Mac lists and how far their chats are up.
                    // Counts only: no chat text, nothing of another machine, nothing that deletes.
                    if let chats = await chats?() { fields.append(.init("sessions", chats)) }
                    return .value(.object(fields))
                case "cloud.devices": return .value(await service.state().wireValue["devices"])
                case "cloud.contents":
                    // The page's own lists; where no page model exists (fixtures) nothing is known yet.
                    return .value(await contents?() ?? .object([.init("devices", .array([])), .init("kinds", .array([])),
                                                                  .init("items", .array([])), .init("activity", .array([]))]))
                case "cloud.signin":
                    try await signin(arguments["provider"].string)
                    return .value(.object([.init("pending", .bool(true))]))
                case "cloud.signout": try await service.signOut()
                case "cloud.sync": try await service.sync(action: arguments["action"].requireString("action", nonempty: true))
                default: throw CloudFailure.invalidRequest
                }
                return .value(await service.state().wireValue)
            })
        }
    }
}
