import Foundation
import TerminalDeckNativeCore

/// Bind scope to the current TAG caller/key grant. No attended-token shortcut.
public struct BackendAGSAccess: Sendable {
    public let require: @Sendable (BackendMCPCallContext, String?, Bool) async throws -> Void
    public let baseProfile: @Sendable (String) async throws -> AGSAgentSettings
    public let saveProfile: (@Sendable (BackendMCPCallContext, String, AGSAgentSettings, UInt64) async throws -> Void)?
    public init(require: @escaping @Sendable (BackendMCPCallContext, String?, Bool) async throws -> Void,
                baseProfile: @escaping @Sendable (String) async throws -> AGSAgentSettings,
                saveProfile: (@Sendable (BackendMCPCallContext, String, AGSAgentSettings, UInt64) async throws -> Void)? = nil) {
        self.require = require; self.baseProfile = baseProfile; self.saveProfile = saveProfile
    }
}
public enum BackendAGSMCP {
    public static let toolIDs = ["agents.settings_read", "agents.settings_change", "agents.hook_test"]
    public static func definitions(store: BackendAGSStore, hooks: BackendAGSHookRunner,
                                   access: BackendDeckToolsAppAccess, scope: BackendAGSAccess) throws -> [BackendDeckToolsDefinition] {
        let read = try NativeRPCValue.parseJSON(Data(#"{"type":"object","properties":{"profile":{"type":"string","description":"An existing TAG agent id. Omit for app defaults."}},"additionalProperties":false}"#.utf8))
        let change = try NativeRPCValue.parseJSON(Data(#"{"type":"object","properties":{"profile":{"type":"string"},"revision":{"type":"integer","minimum":0},"settings":{"type":"object","description":"Complete AGSAgentSettings record for this profile. Environment values from reads are masked; retain masked values to keep them; omit a key to remove it."},"defaults":{"type":"object","description":"Complete AGSDefaults record. For individual app hooks use hook or removeHook instead."},"hook":{"type":"object","description":"Add or replace one complete AGSAppHook."},"removeHook":{"type":"string"}},"required":["revision"],"additionalProperties":false}"#.utf8))
        let test = try NativeRPCValue.parseJSON(Data(#"{"type":"object","properties":{"hook":{"type":"string"},"revision":{"type":"integer","minimum":0}},"required":["hook","revision"],"additionalProperties":false}"#.utf8))
        let specs: [(String, String, BackendMCPTier, NativeRPCValue, String)] = [
            (toolIDs[0], "agents_settings_read", .read, read, "Read agent settings, CLI hooks or app defaults. Environment values and webhook addresses are masked. Reads run freely within your existing TAG scope."),
            (toolIDs[1], "agents_settings_change", .alter, change, "Ask the owner before changing settings or hooks. Read the current revision first. Keys can only narrow an existing profile; they cannot change app defaults, hooks or environment. No global CLI settings are edited."),
            (toolIDs[2], "agents_hook_test", .act, test, "Ask the owner to run one saved Terminal Deck hook, even when disabled. Commands and webhooks really run; no output or secrets are returned. The revision pins the approved configuration.")
        ]
        return try specs.map { id, wire, tier, schema, description in
            let spec = try BackendMCPTool(id: id, wireName: wire, description: description, inputSchema: schema, tier: tier)
            return BackendDeckToolsDefinition(spec: spec, title: id == toolIDs[0] ? "Read agent settings" : id == toolIDs[1] ? "Change agent settings" : "Test saved hook", index: description) { context, args in
                await BackendDeckToolsSupport.reply {
                    guard context.allowedTiers.contains(tier), !context.cancellation.isCancelled else { throw refusal() }
                    let profile = args["profile"].string
                    guard args["profile"].isNullish || profile != nil else { throw BackendAGSValidation.bad("The profile identifier must be text.") }
                    let allowed: Set<String> = id == toolIDs[0] ? ["profile"] : id == toolIDs[1] ? ["profile", "revision", "settings", "defaults", "hook", "removeHook"] : ["hook", "revision"]
                    guard let fields = args.fields, fields.allSatisfy({ allowed.contains($0.key) }) else { throw BackendAGSValidation.bad("Use only the documented settings fields.") }
                    try await scope.require(context, profile, tier != .read)
                    let caller = try await access.caller(context)
                    if profile == nil, caller.kind == .key { throw refusal() }
                    if id == toolIDs[0] {
                        var view = try await store.view(profile: profile)
                        if let profile, view["settings"].isNullish { view = view.setting("settings", try BackendAGSCodec.masked(try await scope.baseProfile(profile))) }
                        return .value(view)
                    }
                    let revision = try expectedRevision(args)
                    guard try await store.currentRevision() == revision else { throw changed() }
                    // Freeze the exact write/test before the owner reviews it. No actor reads of
                    // mutable configuration supply a different command after the approval.
                    var settings: AGSAgentSettings?, defaults: AGSDefaults?, hook: AGSAppHook?
                    if id == toolIDs[1] {
                        if let profile {
                            guard !args["settings"].isNullish, args["defaults"].isNullish, args["hook"].isNullish, args["removeHook"].isNullish else { throw BackendAGSValidation.bad("A profile change needs only settings and revision.") }
                            var next = try BackendAGSCodec.decode(AGSAgentSettings.self, args["settings"])
                            let base = try await scope.baseProfile(profile)
                            let current = try await store.profile(profile) ?? base
                            // A complete environment map supports deletion; masked entries preserve their saved values.
                            next.environment = try BackendAGSCodec.preserveMaskedEnvironment(next.environment, previous: current.environment)
                            next.hooks = try BackendAGSCodec.restoreMaskedHooks(next.hooks, previous: current)
                            try BackendAGSValidation.check(next)
                            if caller.kind == .key { try BackendAGSPolicy.requireNarrowing(next, owner: current) }
                            settings = next
                        } else {
                            guard args["settings"].isNullish else { throw BackendAGSValidation.bad("Use defaults or a hook for app settings.") }
                            let actions = [!args["defaults"].isNullish, !args["hook"].isNullish, !args["removeHook"].isNullish].filter { $0 }.count
                            guard actions == 1 else { throw BackendAGSValidation.bad("Choose exactly one defaults or hook change.") }
                            var next = try await store.defaults()
                            if !args["defaults"].isNullish {
                                let previous = next
                                next = try BackendAGSCodec.decode(AGSDefaults.self, args["defaults"])
                                for provider in next.providers.keys {
                                    if let old = previous.providers[provider] {
                                        next.providers[provider]!.environment = try BackendAGSCodec.preserveMaskedEnvironment(next.providers[provider]!.environment, previous: old.environment)
                                        next.providers[provider]!.hooks = try BackendAGSCodec.restoreMaskedHooks(next.providers[provider]!.hooks, previous: old)
                                    }
                                }
                                next.hooks = try BackendAGSCodec.restoreMaskedAppHooks(next.hooks, previous: previous)
                            } else if !args["hook"].isNullish {
                                let submitted = try BackendAGSCodec.decode(AGSAppHook.self, args["hook"])
                                let replacement = try BackendAGSCodec.restoreMaskedAppHooks([submitted], previous: next)[0]; try BackendAGSValidation.check(replacement)
                                next.hooks.removeAll { $0.id == replacement.id }; next.hooks.append(replacement)
                            } else {
                                guard let remove = args["removeHook"].string else { throw BackendAGSValidation.bad("Choose a hook identifier to remove.") }
                                guard next.hooks.contains(where: { $0.id == remove }) else { throw BackendAGSValidation.bad("That hook no longer exists.") }
                                next.hooks.removeAll { $0.id == remove }
                            }
                            try BackendAGSValidation.check(next); defaults = next
                        }
                    } else {
                        guard caller.kind != .key, let hookID = args["hook"].string,
                              let saved = try await store.defaults().hooks.first(where: { $0.id == hookID }) else { throw BackendAGSValidation.bad("Choose a saved app hook.") }
                        hook = saved
                    }
                    var safe = args.removing("settings").removing("defaults").removing("hook")
                    if let settings { safe = safe.setting("settings", try BackendAGSCodec.masked(settings)) }
                    if let defaults {
                        // Approval gets action counts and safe commands; hook addresses remain private.
                        safe = safe.setting("defaults", try BackendAGSCodec.maskedDefaults(defaults))
                    }
                    if let hook { safe = safe.setting("hook", try BackendAGSCodec.maskedDefaults(.init(hooks: [hook]))["hooks"].elements!.first!) }
                    let sentence = id == toolIDs[2] ? "Run the saved \(hook!.event) hook now (\(hook!.command == nil ? "webhook" : "command"), with a \(hook!.timeoutSeconds)-second timeout)." : "Save the reviewed agent settings or hooks for \(profile ?? "Terminal Deck defaults"). These settings can run commands in future sessions."
                    try await access.authorize(context, id, safe, tier, sentence, true)
                    guard !context.cancellation.isCancelled else { throw CancellationError() }
                    try await scope.require(context, profile, true)
                    let currentCaller = try await access.caller(context)
                    guard currentCaller.kind == caller.kind else { throw refusal() }
                    guard try await store.currentRevision() == revision else { throw changed() }
                    if let profile, let settings {
                        let base = try await scope.baseProfile(profile)
                        if currentCaller.kind == .key { try BackendAGSPolicy.requireNarrowing(settings, owner: try await store.profile(profile) ?? base) }
                        guard let save = scope.saveProfile else { throw NativeRPCError(code: "unavailable", message: "The combined task profile save is not installed.") }
                        try await save(context, profile, settings, revision)
                    } else if let defaults { try await store.saveDefaults(defaults, expectedRevision: revision) }
                    let result: NativeRPCValue
                    if let hook { result = await hooks.test(hook).wireValue }
                    else { result = try await store.view(profile: profile) }
                    try await access.record(context, id, safe, .object([.init("ok", result["ok"].bool.map(NativeRPCValue.bool) ?? .bool(true))]))
                    return .value(result)
                }
            }
        }
    }
    static func expectedRevision(_ args: NativeRPCValue) throws -> UInt64 {
        guard let number = args["revision"].number, number >= 0, number <= Double(Int32.max), number.rounded() == number else { throw BackendAGSValidation.bad("Read the current settings revision first.") }; return UInt64(number)
    }
    static func refusal() -> NativeRPCError { .init(code: "not-permitted", message: "This caller cannot change these agent settings.") }
    static func changed() -> NativeRPCError { .init(code: "settings-changed", message: "Settings changed while approval was open. Read them again.") }
}
