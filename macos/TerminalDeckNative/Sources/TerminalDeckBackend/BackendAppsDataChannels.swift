import Foundation
import TerminalDeckNativeCore

/// APD owns the data subset of the Apps contract. DKA registers each channel
/// once and injects the same existing approval gate used by the Apps engine.
/// This service owns no stream, connection, cache, process or Mac timer.
public actor BackendAppsDataChannels {
    public typealias Authorize = BackendAppsChannels.Authorize
    public typealias Publish = BackendAppsChannels.Publish
    public static let readChannels: Set<String> = [
        "apps:databases:connection", "apps:backups:list", "apps:backups:policy:read", "apps:templates:list"
    ]
    public static let writeChannels: Set<String> = [
        "apps:databases:create", "apps:databases:bind", "apps:backups:create", "apps:backups:policy", "apps:backups:restore", "apps:templates:deploy"
    ]
    public static let invokeChannels = readChannels.union(writeChannels)
    public static let inheritedChannels = invokeChannels.subtracting(["apps:databases:connection", "apps:databases:bind"])
    /// DKA enables only after a server/resource-scoped transaction recovery
    /// capability survives caller cancellation and is verified by fake tests.
    public static let recoveryFeature = "apps:transaction-recovery"

    private let runtime: BackendAppsRuntime
    private let store: BackendAppsStore
    private let databases: BackendAppsDataDatabases
    private let binding: BackendAppsDataDatabaseBinding
    private let backups: BackendAppsDataBackups
    private let templates: BackendAppsDataTemplateDeploy
    private let authorize: Authorize
    private let publish: Publish?

    public init(runtime: BackendAppsRuntime, store: BackendAppsStore? = nil,
                authorize: @escaping Authorize = { action, _ in
                    if BackendAppsDataChannels.writeChannels.contains(action.channel) {
                        throw NativeRPCError(code: "approval-required", message: "This server action needs approval through Terminal Deck.")
                    }
                }, publish: Publish? = nil) {
        let store = store ?? BackendAppsStore(runtime: runtime)
        self.runtime = runtime; self.store = store
        self.databases = BackendAppsDataDatabases(runtime: runtime, store: store)
        self.binding = BackendAppsDataDatabaseBinding(runtime: runtime, store: store)
        self.backups = BackendAppsDataBackups(runtime: runtime, store: store)
        self.templates = BackendAppsDataTemplateDeploy(runtime: runtime, store: store)
        self.authorize = authorize; self.publish = publish
    }

    public static func register(registry: NativeChannelRegistry, service: BackendAppsDataChannels,
                                ownerID: String = "native-apps-data", finished: (@Sendable (NativeRPCContext) async -> Void)? = nil) async throws {
        var installed: [String] = []
        do {
            for channel in invokeChannels.sorted() {
                try await registry.register(channel, ownerID: ownerID) { context, args in
                    guard args.count == 1, args[0].fields != nil else {
                        throw NativeRPCError.invalidArguments("App data actions expect one request object.")
                    }
                    do {
                        let value = try await service.invoke(channel, request: args[0], context: context)
                        await finished?(context); return value
                    } catch { await finished?(context); throw error }
                }
                installed.append(channel)
            }
        } catch {
            for channel in installed { await registry.removeHandler(channel, ownerID: ownerID) }
            throw error
        }
    }

    public func invoke(_ channel: String, request: NativeRPCValue, context: NativeRPCContext) async throws -> NativeRPCValue {
        guard Self.invokeChannels.contains(channel), let fields = request.fields else {
            throw NativeRPCError.invalidArguments("That app data action is not supported.")
        }
        let allowed = Self.payloadKeys(channel)
        guard Set(fields.map(\.key)).count == fields.count, fields.allSatisfy({ allowed.contains($0.key) }) else {
            throw NativeRPCError.invalidArguments("That app data request has unsupported or repeated fields.")
        }
        let changing = Self.writeChannels.contains(channel)
        try context.require(changing ? "apps.write" : "apps.read")
        if channel == "apps:backups:policy", request.has("upload") {
            try BackendAppsDataTools.validateBackupUpload(request["upload"])
        }
        let optionalServer = channel == "apps:templates:list"
        let server = optionalServer && !request.has("serverId") ? "" : try Self.text(request, "serverId")
        let id = channel == "apps:templates:list" ? nil : try BackendAppsValidation.id(Self.text(request, "appId"))
        let destructive = channel == "apps:backups:restore"
        let confirmation = request["confirmation"].string
        if destructive, confirmation?.isEmpty != false {
            throw NativeRPCError(code: "confirmation-required", message: "Type the app's exact name before restoring its data.")
        }
        var preview = BackendAppsValidation.object([
            ("channel", .string(channel)), ("serverId", .string(server)),
            ("appId", id.map(NativeRPCValue.string) ?? .null), ("destructive", .bool(destructive))
        ])
        for key in ["name", "kind", "version", "templateId", "backupId", "schedule", "targetAppId", "key"] where request.has(key) {
            preview = preview.setting(key, .string(try Self.text(request, key)))
        }
        if request.has("enabled") {
            guard let enabled = request["enabled"].bool else { throw NativeRPCError.invalidArguments("Choose whether scheduled backups are enabled.") }
            preview = preview.setting("enabled", .bool(enabled))
        }
        if request.has("retention") {
            guard let retention = request["retention"].number else { throw NativeRPCError.invalidArguments("Choose how many backups to keep.") }
            preview = preview.setting("retention", .number(retention))
        }
        if channel == "apps:backups:policy" {
            let upload = request["upload"]
            if upload == .missing { preview = preview.setting("uploadChange", .string("keep-saved")) }
            else if upload == .null { preview = preview.setting("uploadChange", .string("remove")) }
            else {
                preview = preview.setting("upload", BackendAppsValidation.object([
                    ("endpoint", upload["endpoint"]), ("bucket", upload["bucket"]),
                    ("prefix", upload["prefix"].isNullish ? .string("terminaldeck") : upload["prefix"])
                ]))
            }
        }
        try Task.checkCancellation()
        // An unavailable implementation cannot use an approval, so refuse it
        // before asking. This is an inert integration check, with no server I/O.
        guard !changing || (runtime.features.contains(Self.recoveryFeature) && runtime.recovery != nil) else {
            throw BackendAppsRuntime.unavailable("This action is unavailable because recovery after an interrupted change is not connected yet.")
        }
        // Caller grants and the asynchronous approval are checked before any
        // server read as well as every write. Request booleans never grant access.
        try await authorize(.init(channel: channel, serverID: server, appID: id,
                                  destructive: destructive, confirmation: confirmation, preview: preview), context)
        try Task.checkCancellation()
        let value: NativeRPCValue
        switch channel {
        case "apps:templates:list": return BackendAppsDataTemplates.list(expandedTemplatesEnabled: runtime.features.contains("templates:catalogue-v2"))
        case "apps:databases:connection":
            return try await databases.connection(serverID: server, appID: id!)
        case "apps:databases:create":
            value = try await databases.create(serverID: server, appID: id!, name: Self.text(request, "name"),
                                               kind: Self.text(request, "kind"), version: Self.optionalText(request, "version"))
        case "apps:databases:bind":
            value = try await binding.bind(serverID: server, appID: id!, targetAppID: Self.text(request, "targetAppId"), key: Self.optionalText(request, "key"))
        case "apps:backups:list": return try await backups.list(serverID: server, appID: id!)
        case "apps:backups:policy:read": return try await backups.policyRead(serverID: server, appID: id!)
        case "apps:backups:create": value = try await backups.create(serverID: server, appID: id!)
        case "apps:backups:policy":
            guard request["enabled"].bool != nil else { throw NativeRPCError.invalidArguments("Choose whether scheduled backups are enabled.") }
            value = try await backups.policy(serverID: server, appID: id!, request: request)
        case "apps:backups:restore":
            value = try await backups.restore(serverID: server, appID: id!, backupID: Self.text(request, "backupId"), confirmation: confirmation!)
        case "apps:templates:deploy":
            let env = request.has("env") ? try BackendAppsValidation.environment(request["env"]) : [:]
            guard !env.values.contains(where: { ["••••••••", "••••••", "[redacted]"].contains($0) }) else {
                throw NativeRPCError.invalidArguments("Masked settings cannot replace real secret values.")
            }
            value = try await templates.deploy(serverID: server, appID: id!, name: Self.text(request, "name"),
                                                templateID: Self.text(request, "templateId"), environment: env)
        default: throw BackendAppsRuntime.unavailable("That app data action is unavailable.")
        }
        // A successful mutation stands even if an optional event transport has
        // closed. Only the caller's owner receives this safe state notification.
        let changedID = channel == "apps:databases:bind" ? request["targetAppId"].string : id
        if let id = changedID, let record = try? await store.read(server, id) {
            try? await publish?("apps:changed", BackendAppsValidation.object([
                ("serverId", .string(server)), ("appId", .string(id)), ("record", BackendAppsStore.publicRecord(record))
            ]), context.ownerID)
        }
        return value
    }

    private static func text(_ request: NativeRPCValue, _ key: String) throws -> String {
        let value = try request[key].requireString(key, nonempty: true)
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf8.count <= 256, !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw NativeRPCError.invalidArguments("Use a short, nonempty \(key) without control characters.")
        }
        return value
    }
    private static func optionalText(_ request: NativeRPCValue, _ key: String) throws -> String? {
        request.has(key) ? try text(request, key) : nil
    }
    private static func payloadKeys(_ channel: String) -> Set<String> {
        var keys: Set<String> = channel == "apps:templates:list" ? ["serverId"] : ["serverId", "appId"]
        switch channel {
        case "apps:databases:create": keys.formUnion(["name", "kind", "version"])
        case "apps:databases:bind": keys.formUnion(["targetAppId", "key"])
        case "apps:backups:policy": keys.formUnion(["enabled", "schedule", "retention", "upload"])
        case "apps:backups:restore": keys.formUnion(["backupId", "confirmation"])
        case "apps:templates:deploy": keys.formUnion(["name", "templateId", "env"])
        default: break
        }
        return keys
    }
}
