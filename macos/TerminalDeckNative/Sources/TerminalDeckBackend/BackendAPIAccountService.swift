import Foundation
import TerminalDeckNativeCore

public struct BackendAPIAccountAccess: Sendable {
    public var find: @Sendable (String, NativeRPCContext) async throws -> BackendAccountProfile?
    public var list: @Sendable (NativeRPCContext) async throws -> [BackendAccountProfile]
    public var create: @Sendable (String, String, String, NativeRPCContext) async throws -> BackendAccountProfile
    public var rename: @Sendable (String, String, NativeRPCContext) async throws -> BackendAccountProfile
    public var remove: @Sendable (String, NativeRPCContext) async throws -> NativeRPCValue
    public init(find: @escaping @Sendable (String, NativeRPCContext) async throws -> BackendAccountProfile?,
                list: @escaping @Sendable (NativeRPCContext) async throws -> [BackendAccountProfile],
                create: @escaping @Sendable (String, String, String, NativeRPCContext) async throws -> BackendAccountProfile,
                rename: @escaping @Sendable (String, String, NativeRPCContext) async throws -> BackendAccountProfile,
                remove: @escaping @Sendable (String, NativeRPCContext) async throws -> NativeRPCValue) {
        self.find = find; self.list = list; self.create = create; self.rename = rename; self.remove = remove
    }
}

/// 18 Oct (#89, #527): the open sessions running as an account, by title, and whether a launch with it is starting.
public struct BackendAccountUse: Sendable, Equatable {
    public var sessions: [String]
    public var starting: Bool
    public init(sessions: [String], starting: Bool = false) { self.sessions = sessions; self.starting = starting }
    public var isEmpty: Bool { sessions.isEmpty && !starting }
    public func refusal(_ subject: String) -> String { CodingAIAccountInUse.refusal(subject, sessions: sessions, starting: starting) }
}

public actor BackendAPIAccountService {
    public static let channels: Set<String> = ["profiles:api:list", "profiles:api:add", "profiles:api:update", "profiles:api:check", "profiles:api:remove"]
    private let configuration: BackendAccountConfiguration
    private let access: BackendAPIAccountAccess
    private let authorize: @Sendable (NativeRPCContext) throws -> Void
    private let inUse: @Sendable (String) async -> BackendAccountUse
    private var mutating = Set<String>()
    public init(configuration: BackendAccountConfiguration, access: BackendAPIAccountAccess,
                authorizeMutation: @escaping @Sendable (NativeRPCContext) throws -> Void,
                inUse: @escaping @Sendable (String) async -> BackendAccountUse = { _ in BackendAccountUse(sessions: [], starting: true) }) {
        self.configuration = configuration; self.access = access; authorize = authorizeMutation; self.inUse = inUse
    }
    public func invoke(_ channel: String, args: [NativeRPCValue], context: NativeRPCContext) async throws -> NativeRPCValue {
        if channel != "profiles:api:list" { try authorize(context) }
        let input = args.first ?? .object([])
        let mutationID = ["profiles:api:update", "profiles:api:remove"].contains(channel) ? input["id"].string : nil
        if let mutationID, !mutating.insert(mutationID).inserted { throw BackendAccountFailure("This API account is already being changed.") }
        defer { if let mutationID { mutating.remove(mutationID) } }
        switch channel {
        case "profiles:api:list":
            return .array(try await access.list(context).map { profile in
                var value = try NativeRPCValue.parseJSON(JSONEncoder().encode(profile))
                if let record = try BackendAPIAccountRecord.read(profile) {
                    for field in record.wire.fields ?? [] { value = value.setting(field.key, field.value) }
                } else { value = value.setting("authentication", .string(BackendAPIAccountRecord.isAPIAccountID(profile.id) ? "api-key" : "subscription")) }
                return value
            })
        case "profiles:api:add":
            return try await add(input, context: context)
        case "profiles:api:update":
            let id = try input["id"].requireString("account id", nonempty: true)
            let current = try await owned(id, context: context)
            guard (await inUse(id)).isEmpty, let profile = try await access.find(id, context),
                  Set(input.fields?.map(\.key) ?? []).isSubset(of: ["id", "kind", "baseURL", "model", "workspaceID"]) else {
                throw BackendAccountFailure("Stop or switch this account's sessions before changing the API connection.")
            }
            let kind = input["kind"].string.flatMap(BackendAPIAccountRecord.Kind.init(rawValue:)) ?? current.kind
            var record = try BackendAPIAccountRecord(profile: profile, appName: configuration.appName, kind: kind,
                baseURL: input.has("baseURL") ? input["baseURL"].string : current.baseURL, model: input.has("model") ? input["model"].string : current.model,
                workspaceID: input.has("workspaceID") ? input["workspaceID"].string : current.workspaceID)
            record.credentialRevision = current.credentialRevision
            if record.credentialScope != current.credentialScope { try await BackendAPIAccountCLI.removeLogin(current, inherited: configuration.inheritedEnvironment) }
            try authorize(context)
            try record.save(); try BackendAPIAccountCLI.configure(record)
            return record.wire.setting("id", .string(id))
        case "profiles:api:check":
            let id = try input["id"].requireString("account id", nonempty: true)
            let before = try await owned(id, context: context)
            let outcome = try await BackendAPIAccountCheck.run(before)
            var current = try await owned(id, context: context)
            guard current == before else { return current.wire.setting("id", .string(id)) }
            current.checkState = outcome.state; current.checkDetail = outcome.detail; current.checkedAt = Date().timeIntervalSince1970 * 1000
            try current.save()
            return current.wire.setting("id", .string(id))
        case "profiles:api:remove":
            let id = try input["id"].requireString("account id", nonempty: true)
            let record = try await removable(id, context: context)
            // 18 Oct (#89): the refusal names the sessions; a tab whose agent has ended is not counted.
            let using = await inUse(id)
            guard using.isEmpty else { throw BackendAccountFailure(using.refusal("This API account")) }
            try await BackendAPIAccountCLI.removeLogin(record, inherited: configuration.inheritedEnvironment)
            let result = try await access.remove(id, context)
            guard result["removed"].bool == true else { throw BackendAccountFailure("The account entry was not removed; its API key was kept.") }
            do { try BackendAPIAccountKeychain.remove(record) }
            catch { return result.setting("credentialsRetained", .bool(true)).setting("warning", .string("The account was removed, but Keychain could not remove its API key.")) }
            return result.setting("credentialsRetained", .bool(false))
        default: throw BackendAccountFailure("Choose a supported API-account action.")
        }
    }
    private func owned(_ id: String, context: NativeRPCContext) async throws -> BackendAPIAccountRecord {
        guard let profile = try await access.find(id, context),
              BackendAccountSignInStorage.ownsFolder(profile, configuration: configuration),
              let record = try BackendAPIAccountRecord.read(profile), record.appName == configuration.appName else {
            throw BackendAccountFailure("Choose an API account owned by this copy of the app.")
        }
        return record
    }
    private func removable(_ id: String, context: NativeRPCContext) async throws -> BackendAPIAccountRecord {
        guard let profile = try await access.find(id, context), BackendAccountSignInStorage.ownsFolder(profile, configuration: configuration) else {
            throw BackendAccountFailure("Choose an API account owned by this copy of the app.")
        }
        if let record = try? BackendAPIAccountRecord.read(profile) {
            guard record.appName == configuration.appName else { throw BackendAccountFailure("This API account belongs to another copy of the app.") }
            return record
        }
        guard BackendAPIAccountRecord.isAPIAccountID(id), let kind = BackendAPIAccountRecord.Kind.allCases.first(where: { $0.provider == profile.provider }) else {
            throw BackendAccountFailure("The account's API settings are unavailable.")
        }
        return try BackendAPIAccountRecord(profile: profile, appName: configuration.appName, kind: kind, baseURL: nil, model: nil)
    }
    private func add(_ input: NativeRPCValue, context: NativeRPCContext) async throws -> NativeRPCValue {
        guard Set(input.fields?.map(\.key) ?? []).isSubset(of: ["name", "kind", "baseURL", "model", "workspaceID", "invalidCheckCredential"]),
              let kind = input["kind"].string.flatMap(BackendAPIAccountRecord.Kind.init(rawValue:)) else {
            throw BackendAccountFailure("Choose an API account kind. Enter real keys only in the app's secure field.")
        }
        let name = try input["name"].requireString("account name", nonempty: true).trimmingCharacters(in: .whitespacesAndNewlines)
        guard name.count <= BackendAccountProfile.maximumNameLength else { throw BackendAccountFailure("Use an account name of at most 60 characters.") }
        let check = input["invalidCheckCredential"].bool == true
        guard !check || name.lowercased().hasPrefix("check ") else { throw BackendAccountFailure("Invalid-key check accounts must have a check-prefixed name.") }
        guard !check || kind != .compatibleLocal else { throw BackendAccountFailure("A local keyless account does not take a test key.") }
        let home = configuration.accountLoginsRoot.appendingPathComponent("api-" + UUID().uuidString.lowercased())
        let provisional = BackendAccountProfile(id: "pending", name: name, provider: kind.provider, configDir: home.path,
            system: false, color: "--accent", createdAt: 0)
        _ = try BackendAPIAccountRecord(profile: provisional, appName: configuration.appName, kind: kind,
            baseURL: input["baseURL"].string, model: input["model"].string, workspaceID: input["workspaceID"].string)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let internalName = "api-key-" + String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(24))
        // 18 Oct (#219): an account that was not made leaves no empty folder behind (the start-up tidy skips api- names).
        let created: BackendAccountProfile
        do { created = try await access.create(internalName, kind.provider, home.path, context) }
        catch { try? FileManager.default.removeItem(at: home); throw error }
        let profile: BackendAccountProfile
        do { profile = try await access.rename(created.id, name, context) }
        catch { _ = try? await access.remove(created.id, context); try? FileManager.default.removeItem(at: home); throw error }
        let record = try BackendAPIAccountRecord(profile: profile, appName: configuration.appName, kind: kind,
            baseURL: input["baseURL"].string, model: input["model"].string, workspaceID: input["workspaceID"].string)
        try record.save(); try BackendAPIAccountCLI.configure(record)
        if check {
            let invalid = "sk-terminaldeck-invalid-check-" + UUID().uuidString.lowercased()
            try await storeNativeKey(id: profile.id, key: invalid, context: context)
        }
        return record.wire.setting("id", .string(profile.id)).setting("name", .string(profile.name))
    }
    /// Typed, app-owned secure entry only. No RPC channel or MCP argument accepts a real key.
    public func storeNativeKey(id: String, key: String, context: NativeRPCContext) async throws {
        guard mutating.insert(id).inserted else { throw BackendAccountFailure("This API account is already being changed.") }
        defer { mutating.remove(id) }
        try authorize(context)
        var record = try await owned(id, context: context)
        guard record.requiresKey else { throw BackendAccountFailure("This local connection does not use an API key.") }
        guard (await inUse(id)).isEmpty else { throw BackendAccountFailure("Stop or switch this account's sessions before replacing its API key.") }
        guard !record.baseURL.contains(key), !record.accountID.contains(key), record.model?.contains(key) != true else {
            throw BackendAccountFailure("Keep the API key separate from the account name, endpoint and model.")
        }
        let executables = [Bundle.main.executableURL, configuration.helperExecutable,
            configuration.helperExecutable.deletingLastPathComponent().appendingPathComponent("TerminalDeckSessionHostHelper")].compactMap { $0 }
            .filter { FileManager.default.isExecutableFile(atPath: $0.path) }
        try authorize(context)
        try BackendAPIAccountKeychain.write(key, record: record, trustedExecutables: executables)
        record.credentialRevision += 1; record.checkState = nil; record.checkedAt = nil; try record.save()
    }
}

enum BackendAPIAccountDeletion {
    @TaskLocal static var insideCleanup = false
}
