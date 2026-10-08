import Foundation
import TerminalDeckNativeCore

/// The local owner UI gets private values only in memory so SecureField edits can
/// remove/replace them. Page/device/MCP callers never get this private read.
public enum BackendAGSChannels {
    public static let channels = ["ags:get", "ags:save", "ags:hook-test"]
    public static func register(registry: NativeChannelRegistry, ownerID: String, store: BackendAGSStore, runner: BackendAGSHookRunner,
                                baseProfile: @escaping @Sendable (String) async throws -> AGSAgentSettings,
                                requireOwner: @escaping @Sendable (NativeRPCContext) async throws -> Void,
                                authorize: @escaping @Sendable (NativeRPCContext, String, NativeRPCValue) async throws -> Void,
                                saveProfile: (@Sendable (NativeRPCContext, String, AGSAgentSettings, UInt64) async throws -> Void)? = nil,
                                defaultProvider: (@Sendable () async -> String)? = nil) async throws {
        for channel in channels {
            try await registry.register(channel, ownerID: ownerID) { context, args in
                guard context.caller == .nativeApp else { throw NativeRPCError(code: "access-denied", message: "Private agent settings are available only in the owner's native Settings window.") }
                try await requireOwner(context); try context.requireCount(args, 1...1)
                if channel == "ags:get" {
                    let revision = try await store.currentRevision()
                    if let profile = args[0].string {
                        let base = try await baseProfile(profile)
                        return .object([.init("revision", .number(Double(revision))), .init("profile", .string(profile)),
                                        .init("settings", try BackendAGSCodec.value(try await store.profile(profile) ?? base))])
                    }
                    guard args[0].isNullish else { throw BackendAGSValidation.bad("Choose an existing profile or app defaults.") }
                    var result: NativeRPCValue = .object([.init("revision", .number(Double(revision))), .init("defaults", try BackendAGSCodec.value(try await store.defaults()))])
                    if let defaultProvider { result = result.setting("defaultProvider", .string(await defaultProvider())) }
                    return result
                }
                let input = args[0], revision = try BackendAGSMCP.expectedRevision(input)
                guard try await store.currentRevision() == revision else { throw BackendAGSMCP.changed() }
                var profile: String?, settings: AGSAgentSettings?, defaults: AGSDefaults?, hook: AGSAppHook?
                if channel == "ags:save" {
                    guard let fields = input.fields, fields.allSatisfy({ ["revision", "profile", "settings", "defaults"].contains($0.key) }) else { throw BackendAGSValidation.bad("Use the documented settings fields.") }
                    profile = input["profile"].string
                    if let profile {
                        _ = try await baseProfile(profile)
                        guard input["defaults"].isNullish else { throw BackendAGSValidation.bad("Save the profile on its own.") }
                        settings = try BackendAGSCodec.decode(AGSAgentSettings.self, input["settings"]); try BackendAGSValidation.check(settings!)
                    } else {
                        guard input["profile"].isNullish, input["settings"].isNullish else { throw BackendAGSValidation.bad("Save app defaults on their own.") }
                        defaults = try BackendAGSCodec.decode(AGSDefaults.self, input["defaults"]); try BackendAGSValidation.check(defaults!)
                    }
                } else {
                    guard let fields = input.fields, fields.allSatisfy({ ["revision", "hook"].contains($0.key) }), let id = input["hook"].string,
                          let saved = try await store.defaults().hooks.first(where: { $0.id == id }) else { throw BackendAGSValidation.bad("Choose a saved hook to test.") }; hook = saved
                }
                // Native owner draft is the reviewable proposal. Never send raw env values
                // or webhook credentials to the approval log.
                var safe = input.removing("settings").removing("defaults")
                if let settings { safe = safe.setting("settings", try BackendAGSCodec.masked(settings)) }
                if let defaults { safe = safe.setting("defaults", try BackendAGSCodec.maskedDefaults(defaults)) }
                try await authorize(context, channel, safe)
                try Task.checkCancellation(); try await requireOwner(context)
                guard try await store.currentRevision() == revision else { throw BackendAGSMCP.changed() }
                if let profile, let settings {
                    guard let saveProfile else { throw NativeRPCError(code: "unavailable", message: "The combined task profile save is not installed. Save app defaults only.") }
                    _ = try await baseProfile(profile)
                    try await saveProfile(context, profile, settings, revision)
                }
                else if let defaults { try await store.saveDefaults(defaults, expectedRevision: revision) }
                if let hook { return await runner.test(hook).wireValue }
                return .object([.init("ok", .bool(true)), .init("revision", .number(Double(try await store.currentRevision())))])
            }
        }
    }
}

/// TAG's canonical model remains the base. This adapter avoids a second AgentProfile.
public enum BackendAGSProfileProjection {
    public static func settings(_ profile: NativeRPCValue, defaultProvider: String) throws -> AGSAgentSettings {
        let provider = profile["provider"].string ?? defaultProvider
        let value = AGSAgentSettings(provider: provider, model: profile["model"].string,
            effort: profile["effort"].string == "auto" ? nil : profile["effort"].string,
            permissionMode: profile["permissionMode"].string,
            allowedTools: profile["allowedTools"].elements.map { $0.compactMap(\.string) },
            deniedTools: profile["blockedTools"].elements?.compactMap(\.string) ?? [],
            workingFolder: profile["defaultProject"].string, keepOpen: profile["keepAliveUntilClose"].bool == true)
        try BackendAGSValidation.check(value); return value
    }
}
