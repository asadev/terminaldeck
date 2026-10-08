import Foundation
import TerminalDeckNativeCore

public protocol BackendDeckToolsAppApplicationService: Sendable {
    func about() async throws -> NativeRPCValue
    func brand() async throws -> NativeRPCValue
    func paths() async throws -> [NativeRPCValue]
    func logStatus() async throws -> NativeRPCValue
    func openPath(_ key: String) async throws -> NativeRPCValue
    func openLogFolder() async throws -> String
    /// Already redacted by the diagnostic/log owner.
    func diagnostics(includeClis: Bool, logLines: Int, text: Bool) async throws -> NativeRPCValue
    func recentLog(_ lines: Int) async throws -> NativeRPCValue
    func recentCalls(_ limit: Int) async throws -> [NativeRPCValue]
    func clearLog() async throws
    func clearCalls() async throws
    func clearBrowserData() async throws -> NativeRPCValue
    /// nil means this build genuinely has no updater.
    func updates() async throws -> (any BackendDeckToolsAppUpdateService)?
}
public protocol BackendDeckToolsAppUpdateService: Sendable {
    func state() async throws -> NativeRPCValue
    func check(automatic: Bool) async throws -> NativeRPCValue
    func download() async throws -> NativeRPCValue
    func installNow() async throws -> NativeRPCValue
}
public protocol BackendDeckToolsAppSettingsService: Sendable {
    func readSettings() async throws -> NativeRPCValue
    func snapshotSettings() async throws -> String
    func writeSettings(_ patch: NativeRPCValue) async throws -> NativeRPCValue
    func applyToWindow(_ settings: NativeRPCValue) async throws -> Bool
}
public enum BackendDeckToolsAppApplication {
    private typealias K = BackendDeckToolsAppKit
    public static let protectedPrefixes = ["remote.", "hoot.", "copilot.", "deckControl.", "security.", "confine."]
    public static let protectedKeys = ["browser.persistSession", "advanced.debugMode"]
    public static func isProtected(_ key: String) -> Bool { protectedKeys.contains(key) || protectedPrefixes.contains(where: key.hasPrefix) }
    private static func updater(_ service: any BackendDeckToolsAppApplicationService) async throws -> any BackendDeckToolsAppUpdateService {
        guard let updater = try await service.updates() else { throw K.refused("this build has no updater running, so it cannot check for or install updates.") }
        return updater
    }
    public static func definitions(service: any BackendDeckToolsAppApplicationService, settings: any BackendDeckToolsAppSettingsService,
                                   access: BackendDeckToolsAppAccess) throws -> [BackendDeckToolsDefinition] {
        try K.definitions(module: "app-tools", access: access, consent: { id, _, args in
            let sentence: String
            switch id {
            case "app.about": sentence = "Read about this app"
            case "app.reveal": sentence = "Show \(args["place"].string ?? "?") in Finder"
            case "app.diagnostics": sentence = "Collect diagnostics"
            case "app.log": sentence = "Read the \(args["source"].string == "calls" ? "internal call record" : "app log")"
            case "app.clear_log": sentence = "Clear the \(args["source"].string == "calls" ? "internal call record" : "app log")"
            case "settings.reset":
                let reset = try await settings.readSettings()["settings"].fields?.map(\.key).filter { !isProtected($0) } ?? []
                sentence = reset.isEmpty ? "Reset settings to defaults (nothing is set, so nothing changes)" : "Reset \(reset.count) setting\(reset.count == 1 ? "" : "s") to defaults: \(reset.joined(separator: ", "))"
            case "settings.clear_browser_data": sentence = "Delete the built-in browser’s cookies, storage and cache, signing it out of every site"
            case "updates.status": sentence = args["check"].bool == true ? "Check for an update" : "Read the update status"
            case "updates.download": sentence = "Download the available update"
            default: sentence = "Install the update and restart the app (running sessions stop; the connection drops)"
            }
            let tier: BackendMCPTier = ["app.reveal", "updates.download"].contains(id) ? .act : ["app.clear_log", "settings.reset", "settings.clear_browser_data", "updates.install"].contains(id) ? .alter : .read
            return (tier, sentence, false)
        }, run: { id, _, args in
            switch id {
            case "app.about":
                let paths = try await service.paths()
                let value = try await service.brand().merging(K.object([("about", try await service.about()), ("places", .array(paths)), ("log", try await service.logStatus())]))
                return .init(value, K.object([("places", K.n(paths.count))]))
            case "app.reveal":
                let place = try K.str(args, "place", trimmed: true)
                if place == "logs" {
                    let problem = try await service.openLogFolder()
                    return .init(K.object([("opened", .bool(problem.isEmpty)), ("message", .string(problem.isEmpty ? "Opened." : problem))]), K.object([("place", .string(place))]))
                }
                let result = try await service.openPath(place)
                return .init(result, K.object([("place", .string(place)), ("opened", result["opened"])]))
            case "app.diagnostics":
                let text = try BackendDeckToolsArgs.optBool(args, "text", false)
                let value = try await service.diagnostics(includeClis: BackendDeckToolsArgs.optBool(args, "includeClis", true), logLines: BackendDeckToolsArgs.optInt(args, "logLines", 200, 1, 2000), text: text)
                return .init(text ? K.object([("report", value)]) : value, K.object([("text", .bool(text))]))
            case "app.log":
                let source = try K.oneOf(args, "source", ["app", "calls"], fallback: "app"), lines = try BackendDeckToolsArgs.optInt(args, "lines", 200, 1, 2000)
                if source == "calls" { let calls = try await service.recentCalls(lines); return .init(K.object([("source", .string(source)), ("calls", .array(calls))]), K.object([("source", .string(source)), ("calls", K.n(calls.count))])) }
                let log = try await service.recentLog(lines)
                return .init(K.object([("source", .string(source))]).merging(log), K.object([("source", .string(source)), ("lines", K.n(log["lines"].elements?.count ?? 0))]))
            case "app.clear_log":
                let source = try K.oneOf(args, "source", ["app", "calls"])
                if source == "calls" { try await service.clearCalls() } else { try await service.clearLog() }
                return .init(K.object([("cleared", .string(source))]), K.object([("source", .string(source))]))
            case "settings.reset":
                let keys = try await settings.readSettings()["settings"].fields?.map(\.key) ?? [], reset = keys.filter { !isProtected($0) }, kept = keys.filter(isProtected)
                if reset.isEmpty { return .init(K.object([("reset", .array([])), ("kept", K.strings(kept)), ("snapshot", .null)]), K.object([("reset", .number(0)), ("kept", K.n(kept.count))])) }
                let snapshot: String
                do { snapshot = try await settings.snapshotSettings() }
                catch { throw NativeRPCError(code: "internal", message: "could not save a copy of the current settings first, so nothing was reset: " + error.localizedDescription) }
                let changed = try await settings.writeSettings(.object(reset.map { .init($0, .null) })), applied = try await settings.applyToWindow(changed)
                return .init(K.object([("reset", K.strings(reset)), ("kept", K.strings(kept)), ("snapshot", .string(snapshot)), ("appliedToWindow", .bool(applied)), ("protected", K.object([("keys", K.strings(protectedKeys)), ("prefixes", K.strings(protectedPrefixes))]))]), K.object([("reset", K.n(reset.count)), ("kept", K.n(kept.count)), ("snapshot", .string(snapshot)), ("appliedToWindow", .bool(applied))]))
            case "settings.clear_browser_data":
                let result = try await service.clearBrowserData()
                guard result["cleared"].bool == true else { throw NativeRPCError(code: "internal", message: result["message"].string ?? "Browser data could not be cleared.") }
                return .init(result, K.object([("cleared", .bool(true))]))
            case "updates.status":
                let controller = try await updater(service)
                let wantsCheck = try BackendDeckToolsArgs.optBool(args, "check", false)
                let state: NativeRPCValue
                if wantsCheck { state = try await controller.check(automatic: false) } else { state = try await controller.state() }
                return .init(state, K.object([("phase", state["phase"])]))
            case "updates.download":
                let controller = try await updater(service), state = try await controller.download()
                return .init(state, K.object([("phase", state["phase"])]))
            default:
                let controller = try await updater(service), before = try await controller.state()
                guard before["phase"].string == "ready" else { throw K.refused("there is no downloaded update to install (the updater says \(before["phase"].string ?? "undefined")). Use updates.status and updates.download first.") }
                let state = try await controller.installNow(); return .init(state, K.object([("phase", state["phase"])]))
            }
        })
    }
}

public protocol BackendDeckToolsAppHookService: Sendable {
    var providers: [String] { get }
    func status() async throws -> [NativeRPCValue]
    func server() async throws -> NativeRPCValue
    func offer() async throws -> NativeRPCValue
    func install(_ provider: String, caller: BackendMCPCallContext) async throws -> NativeRPCValue
    func remove(_ provider: String, caller: BackendMCPCallContext) async throws -> NativeRPCValue
    func sync(_ caller: BackendMCPCallContext) async throws -> [NativeRPCValue]
    func acceptOffer(_ caller: BackendMCPCallContext) async throws -> [NativeRPCValue]
    func declineOffer(_ caller: BackendMCPCallContext) async throws
}
public enum BackendDeckToolsAppHooks {
    private typealias K = BackendDeckToolsAppKit
    public static func definitions(service: any BackendDeckToolsAppHookService, access: BackendDeckToolsAppAccess) throws -> [BackendDeckToolsDefinition] {
        let definitions = try K.definitions(module: "hook-tools", access: access, precheck: { id, _, args in
            if id == "hooks.install" || id == "hooks.remove" { _ = try K.oneOf(args, "agent", service.providers + (id == "hooks.install" ? ["all"] : [])) }
        }, consent: { id, _, args in
            let agent = args["agent"].string ?? "?"
            let sentences = ["hooks.status": "Read the hook status", "hooks.install": agent == "all" ? "Install hooks into every installed agent that has none" : "Install hooks into \(agent)’s settings file", "hooks.remove": "Remove hooks from \(agent)’s settings file", "hooks.sync": "Re-aim the installed hooks at this copy of the app", "hooks.decline_offer": "Decline the first-run hooks offer"]
            return (id == "hooks.status" ? .read : id == "hooks.decline_offer" ? .act : .alter, sentences[id]!, false)
        }, run: { id, context, args in
            switch id {
            case "hooks.status":
                let agents = try await service.status()
                return .init(K.object([("agents", .array(agents)), ("listener", try await service.server()), ("offer", try await service.offer())]), statusSummary(agents))
            case "hooks.install", "hooks.remove":
                let agent = try K.oneOf(args, "agent", service.providers + (id == "hooks.install" ? ["all"] : []))
                if agent == "all" { let results = try await service.acceptOffer(context); return .init(K.object([("results", .array(results))]), K.object([("agent", .string(agent)), ("installed", K.n(results.filter { $0["ok"].bool == true }.count))])) }
                let result: NativeRPCValue
                if id == "hooks.install" { result = try await service.install(agent, caller: context) } else { result = try await service.remove(agent, caller: context) }
                guard result["ok"].bool == true else { throw K.refused(result["message"].string ?? "Hook write was refused.") }
                return .init(result, K.object([("agent", .string(agent)), ("state", result["status"]["state"])]))
            case "hooks.sync": let agents = try await service.sync(context); return .init(K.object([("agents", .array(agents))]), statusSummary(agents))
            default: try await service.declineOffer(context); return .init(K.object([("declined", .bool(true)), ("offer", try await service.offer())]), K.object([("declined", .bool(true))]))
            }
        })
        // Provider choices are supplied by the actual hooks owner, as in TS.
        return try definitions.map { definition in
            guard definition.spec.id == "hooks.install" || definition.spec.id == "hooks.remove" else { return definition }
            let choices = service.providers + (definition.spec.id == "hooks.install" ? ["all"] : [])
            let schema = definition.spec.inputSchema, agent = schema["properties"]["agent"].setting("enum", K.strings(choices))
            let spec = try BackendMCPTool(id: definition.spec.id, wireName: definition.spec.wireName, description: definition.spec.description,
                inputSchema: schema.setting("properties", schema["properties"].setting("agent", agent)), tier: definition.spec.tier)
            return BackendDeckToolsDefinition(spec: spec, title: definition.title, index: definition.index, aliases: definition.aliases, handler: definition.handler)
        }
    }
    private static func statusSummary(_ agents: [NativeRPCValue]) -> NativeRPCValue { K.object([("agents", K.strings(agents.map { "\($0["id"].string ?? ""):\($0["state"].string ?? "")" }))]) }
}

public protocol BackendDeckToolsAppVoiceService: Sendable {
    func providers() async throws -> [NativeRPCValue]
    func status() async throws -> NativeRPCValue
    func save(provider: String, key: String) async throws -> NativeRPCValue
    func forget() async throws
    func transcribe(audio: Data, filename: String) async throws -> NativeRPCValue
}
public enum BackendDeckToolsAppVoice {
    private typealias K = BackendDeckToolsAppKit
    public static let maxAudioBytes = 20 * 1024 * 1024
    public static func decode(_ audio: String) throws -> Data {
        let compact = audio.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
        guard compact.range(of: #"^[A-Za-z0-9+/_-]+={0,2}$"#, options: .regularExpression) != nil else { throw BackendDeckToolsArgs.bad("audio must be base64") }
        guard (compact.utf8.count * 3) / 4 <= maxAudioBytes else { throw BackendDeckToolsArgs.bad("audio is larger than 20 MB") }
        var clean = compact.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/").replacingOccurrences(of: "=", with: "")
        // Buffer.from accepts missing padding, URL alphabet and an incomplete
        // final six-bit group. That trailing group produces no byte.
        if clean.count % 4 == 1 { clean.removeLast() }
        clean += String(repeating: "=", count: (4 - clean.count % 4) % 4)
        guard let bytes = Data(base64Encoded: clean), !bytes.isEmpty else { throw BackendDeckToolsArgs.bad("audio is empty") }
        return bytes
    }
    public static func definitions(service: any BackendDeckToolsAppVoiceService, access: BackendDeckToolsAppAccess) throws -> [BackendDeckToolsDefinition] {
        try K.definitions(module: "voice-tools", access: access, precheck: { id, _, args in
            if id == "voice.save_key" { _ = try K.str(args, "provider", trimmed: true); _ = try K.str(args, "key", trimmed: true) }
            if id == "voice.transcribe" { _ = try decode(K.str(args, "audio", trimmed: true)) }
        }, consent: { id, _, args in
            let sentence = id == "voice.status" ? "Read the dictation setup" : id == "voice.save_key" ? "Save a \(args["provider"].string ?? "?") transcription key" : id == "voice.forget_key" ? "Delete the stored transcription key" : "Transcribe a recording with the dictation key"
            return (id == "voice.status" ? .read : id == "voice.transcribe" ? .act : .alter, sentence, false)
        }, run: { id, _, args in
            switch id {
            case "voice.status": return .init(K.object([("providers", .array(try await service.providers())), ("status", try await service.status())]))
            case "voice.save_key":
                let provider = try K.str(args, "provider", trimmed: true), result = try await service.save(provider: provider, key: K.str(args, "key", trimmed: true))
                guard result["ok"].bool == true else { throw K.refused("the key was not saved: \(result["message"].string ?? "")") }
                return .init(K.object([("saved", .bool(true)), ("message", result["message"]), ("status", try await service.status())]), K.object([("provider", .string(provider))]))
            case "voice.forget_key": try await service.forget(); return .init(K.object([("forgotten", .bool(true)), ("status", try await service.status())]))
            default:
                let audio = try decode(K.str(args, "audio", trimmed: true)), filename = try K.optStr(args, "filename", trimmed: true) ?? "speech.webm"
                let result = try await service.transcribe(audio: audio, filename: filename)
                guard result["ok"].bool == true else { throw K.refused(result["message"].string ?? "Transcription was refused.") }
                return .init(K.object([("text", result["text"]), ("message", result["message"])]), K.object([("bytes", K.n(audio.count)), ("chars", K.n(result["text"].string?.utf16.count ?? 0))]))
            }
        })
    }
}
