import Foundation
import TerminalDeckNativeCore

public struct BackendDeckCoreEventsRelayFacts: Sendable {
    public let url: String, hostId: String
    public let connected: Bool
    public let reason: String?
    public init(url: String, hostId: String, connected: Bool, reason: String?) { self.url = url; self.hostId = hostId; self.connected = connected; self.reason = reason }
}

/// Owner-only settings, intentionally absent from the MCP tool catalogue.
public struct BackendDeckCoreEventsAIApps: Sendable {
    public static let changedChannel = "ai-apps:changed"
    public static let channels = ["ai-apps:state","ai-apps:create","ai-apps:rename","ai-apps:level","ai-apps:ask-first","ai-apps:tasks","ai-apps:folders","ai-apps:revoke","ai-apps:internet","ai-apps:notify","ai-apps:notify-secret","ai-apps:notify-test","ai-apps:events-stop"]
    public let keys: BackendDeckCoreSecurityAccessKeys
    public let hub: BackendDeckCoreEventsHub?
    public let events: BackendDeckCoreEvents?
    public let port: @Sendable () async -> Int?
    public let movedFrom: @Sendable () async -> Int?
    public let relay: @Sendable () async -> BackendDeckCoreEventsRelayFacts?
    public let folders: @Sendable () async -> [String]
    public let channelBridge: @Sendable () async -> String?
    public init(keys: BackendDeckCoreSecurityAccessKeys, hub: BackendDeckCoreEventsHub? = nil, events: BackendDeckCoreEvents? = nil,
                port: @escaping @Sendable () async -> Int?, movedFrom: @escaping @Sendable () async -> Int? = { nil },
                relay: @escaping @Sendable () async -> BackendDeckCoreEventsRelayFacts? = { nil },
                folders: @escaping @Sendable () async -> [String], channelBridge: @escaping @Sendable () async -> String? = { nil }) {
        self.keys = keys; self.hub = hub; self.events = events; self.port = port; self.movedFrom = movedFrom; self.relay = relay; self.folders = folders; self.channelBridge = channelBridge
    }
    public static func internetBase(relayUrl: String, hostId: String) -> String? {
        guard !hostId.isEmpty, let url = URL(string:relayUrl), let host = url.host,
              let scheme = ["wss":"https","ws":"http"][url.scheme?.lowercased() ?? ""] else { return nil }
        let path = URLComponents(url:url,resolvingAgainstBaseURL:false)?.percentEncodedPath ?? url.path
        let prefix = path.replacingOccurrences(of:#"/+$"#,with:"",options:.regularExpression), port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)\(prefix)/mcp/\(hostId)"
    }
    public func state() async -> NativeRPCValue {
        let relay = await relay(), port = await port(), list = await keys.list()
        var delivery: [NativeRPCValue.Field] = []
        for key in list {
            if let id = key["id"].string, let last = await hub?.lastDelivery(keyId:id) { delivery.append(.init(id,last)) }
        }
        var subscriptions = NativeRPCValue.object([])
        for view in await events?.subscriptions() ?? [] {
            guard let key = view["keyId"].string else { continue }
            subscriptions = subscriptions.setting(key,.array((subscriptions[key].elements ?? []) + [view]))
        }
        let host = relay.flatMap { URL(string:$0.url) }.map { ($0.host ?? "") + ($0.port.map { ":\($0)" } ?? "") }
        let reason = relay == nil ? "Remote access is off, so this computer is not connected to a relay." : relay?.reason
        return BackendDeckCoreEventsSupport.object([("keys",.array(list)),("internet",BackendDeckCoreEventsSupport.object([("on",.bool(await keys.internet())),("base",BackendDeckCoreEventsSupport.nullable(relay.flatMap { Self.internetBase(relayUrl:$0.url,hostId:$0.hostId) })),("relayHost",BackendDeckCoreEventsSupport.nullable(host)),("connected",.bool(relay?.connected == true)),("reason",BackendDeckCoreEventsSupport.nullable(reason))])),("local",BackendDeckCoreEventsSupport.object([("url",BackendDeckCoreEventsSupport.nullable(port.map { "http://127.0.0.1:\($0)/mcp" })),("movedFrom",BackendDeckCoreEventsSupport.number(await movedFrom().map(Double.init)))])),("folders",.array(await folders().map(NativeRPCValue.string))),("problem",BackendDeckCoreEventsSupport.nullable(await keys.loadProblem())),("delivery",.object(delivery)),("channelBridge",BackendDeckCoreEventsSupport.nullable(await channelBridge())),("subscriptions",subscriptions)])
    }
    public func register(in registry: NativeChannelRegistry, ownerID: String,
                         isApprover: @escaping @Sendable (NativeRPCContext) -> Bool) async throws -> NativeRPCSubscription {
        for channel in Self.channels {
            try await registry.register(channel,ownerID:ownerID,policy:{ context in
                guard isApprover(context) else { throw NativeRPCError(code:"access-denied",message:"ai-apps: only the app’s own window may change who can reach this computer") }
            }) { _,args in try await self.invoke(channel,arguments:args) }
        }
        let observer = await keys.onChange { Task { try? await registry.publish(Self.changedChannel,arguments:[]) } }
        return NativeRPCSubscription { await keys.removeObserver(observer) }
    }
    /// Registered invocation must always run the owner policy above.
    private func invoke(_ channel: String, arguments args: [NativeRPCValue]) async throws -> NativeRPCValue {
        func argument(_ index: Int) -> NativeRPCValue { args.indices.contains(index) ? args[index] : .missing }
        func id() throws -> String {
            guard let id = argument(0).string, !id.isEmpty else { throw NativeRPCError(code:"key-refused",message:"That key no longer exists.") }; return id
        }
        if channel == "ai-apps:state" { return await state() }
        if channel == "ai-apps:notify-test" {
            guard let hub else { return await result(ok:false,message:"Notifications are not running in this build.") }
            let value = await hub.testWebhook(keyId:try id()); return await result(ok:value["ok"].bool == true,message:value["message"].string)
        }
        if channel == "ai-apps:events-stop" {
            guard let subscription = argument(1).string, !subscription.isEmpty else { throw NativeRPCError.invalidArguments("Which subscription?") }
            let stopped = await events?.stopSubscription(keyId:try id(),id:subscription) ?? false
            return await result(ok:stopped,message:stopped ? nil : "That subscription had already ended.")
        }
        do {
            switch channel {
            case "ai-apps:create":
                let raw = argument(0), input = BackendDeckCoreEventsSupport.object([("name",raw["name"]),("level",raw["level"]),("askFirst",raw["askFirst"]),("folders",raw["folders"])])
                let made = try await keys.create(input)
                return await result(ok:true).setting("key",made["key"]).setting("id",made["view"]["id"])
            case "ai-apps:rename": _ = try await keys.rename(id:id(),name:argument(1))
            case "ai-apps:level": _ = try await keys.setLevel(id:id(),level:argument(1))
            case "ai-apps:ask-first": _ = try await keys.setAskFirst(id:id(),askFirst:argument(1))
            case "ai-apps:tasks": _ = try await keys.setTasks(id:id(),on:argument(1))
            case "ai-apps:folders": _ = try await keys.setFolders(id:id(),folders:argument(1))
            case "ai-apps:revoke":
                guard try await keys.revoke(id:id()) else { throw NativeRPCError(code:"key-refused",message:"That key was already gone.") }
            case "ai-apps:internet": _ = try await keys.setInternet(.bool(argument(0).bool == true))
            case "ai-apps:notify":
                let raw = argument(1), made = try await keys.setNotify(id:id(),input:BackendDeckCoreEventsSupport.object([("mode",raw["mode"]),("url",raw["url"])]))
                return await result(ok:true).setting("secret",made["secret"])
            case "ai-apps:notify-secret":
                let made = try await keys.rotateWebhookSecret(id:id()); return await result(ok:true).setting("secret",made["secret"])
            default: throw NativeRPCError(code:"missing-handler",message:"Nothing in this app answers \"\(channel)\".")
            }
            return await result(ok:true)
        } catch {
            let typed = error as? NativeRPCError, known = typed?.code == "key-refused"
            let prefix = channel == "ai-apps:create" ? "The key was not made: " : "That did not save: "
            return await result(ok:false,message:known ? error.localizedDescription : prefix + error.localizedDescription)
        }
    }
    private func result(ok: Bool, message: String? = nil) async -> NativeRPCValue {
        BackendDeckCoreEventsSupport.object([("ok",.bool(ok)),("message",message.map(NativeRPCValue.string) ?? .missing),("state",await state())])
    }
}
