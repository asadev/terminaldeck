import Foundation
import TerminalDeckNativeCore

public protocol BackendDeckToolsAppCopilotService: Sendable {
    func state() async throws -> NativeRPCValue
    func signIn() async throws -> NativeRPCValue
    func start() async throws -> NativeRPCValue
    func stop() async throws -> NativeRPCValue
    func scaffold() async throws -> NativeRPCValue
    func reveal(_ place: String) async throws -> NativeRPCValue
    func readInstructions(_ which: String) async throws -> NativeRPCValue
    func writeInstructions(_ which: String, text: String) async throws -> NativeRPCValue
    func resetInstructions() async throws -> NativeRPCValue
    func listMemory() async throws -> NativeRPCValue
    /// Memory owner enforces plain filenames and retains the original on edits.
    func readMemory(_ name: String) async throws -> NativeRPCValue
    func writeMemory(_ name: String, text: String) async throws -> NativeRPCValue
    func deleteMemory(_ name: String) async throws -> NativeRPCValue
}
public protocol BackendDeckToolsAppSmallDoorsService: Sendable {
    func toolStatus() async throws -> NativeRPCValue?
    func notificationSupport() async throws -> NativeRPCValue
    func notificationDelivery(sinceMs: Double) async throws -> NativeRPCValue
    func openNotificationSettings() async throws -> NativeRPCValue
    func openURL(_ url: String) async throws -> Bool
}
public enum BackendDeckToolsAppAdmin {
    private typealias K = BackendDeckToolsAppKit
    public static let places = ["root", "instructions", "memory", "log", "routines", "layer", "contract", "composed"]
    public struct InstructionsCall: Sendable { public let action: String, which: String, text: String }
    public struct MemoryCall: Sendable { public let action: String, name: String, text: String }
    public static func runAction(_ args: NativeRPCValue) throws -> String {
        let action = try K.str(args, "action")
        guard ["start", "stop", "scaffold", "reveal"].contains(action) else { throw BackendDeckToolsArgs.bad("action must be \"start\", \"stop\", \"scaffold\" or \"reveal\"") }
        return action
    }
    public static func instructionsCall(_ args: NativeRPCValue) throws -> InstructionsCall {
        let action = try K.str(args, "action"), which = try K.optStr(args, "which") ?? "yours"
        if action == "reset" { return .init(action: action, which: "yours", text: "") }
        if action == "read" {
            guard ["yours", "folder", "contract", "composed"].contains(which) else { throw BackendDeckToolsArgs.bad("which must be \"yours\", \"folder\", \"contract\" or \"composed\"") }
            return .init(action: action, which: which, text: "")
        }
        if action == "write" {
            guard which == "yours" || which == "folder" else { throw BackendDeckToolsArgs.bad("only \"yours\" and \"folder\" can be written; the contract is generated from what is wired") }
            guard let text = args["text"].string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BackendDeckToolsArgs.bad("text is required for \"write\"") }
            return .init(action: action, which: which, text: text)
        }
        throw BackendDeckToolsArgs.bad("action must be \"read\", \"write\" or \"reset\"")
    }
    public static func memoryCall(_ args: NativeRPCValue) throws -> MemoryCall {
        let action = try K.str(args, "action")
        if action == "list" { return .init(action: action, name: "", text: "") }
        if action == "read" || action == "delete" { return .init(action: action, name: try K.str(args, "name"), text: "") }
        if action == "write" {
            guard let text = args["text"].string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BackendDeckToolsArgs.bad("text is required for \"write\"") }
            return .init(action: action, name: try K.str(args, "name"), text: text)
        }
        throw BackendDeckToolsArgs.bad("action must be \"list\", \"read\", \"write\" or \"delete\"")
    }
    public static func webAddress(_ args: NativeRPCValue) throws -> String {
        let text = try K.str(args, "url").trimmingCharacters(in: .whitespacesAndNewlines)
        var candidate = text
        // WHATWG special web schemes accept a missing pair of slashes, and
        // treat backslashes before the query/fragment as path separators.
        if let colon = text.firstIndex(of: ":"), ["http", "https"].contains(text[..<colon].lowercased()) {
            let scheme = text[..<colon].lowercased(), rest = String(text[text.index(after: colon)...])
            let split = rest.firstIndex(where: { $0 == "?" || $0 == "#" }) ?? rest.endIndex
            var address = String(rest[..<split]).replacingOccurrences(of: "\\", with: "/")
            while address.hasPrefix("/") { address.removeFirst() }
            candidate = scheme + "://" + address + String(rest[split...])
        }
        guard let parsed = URL(string: candidate), let scheme = parsed.scheme else { throw BackendDeckToolsArgs.bad("url must be a full web address, like https://example.com") }
        guard scheme.lowercased() == "http" || scheme.lowercased() == "https" else { throw BackendDeckToolsArgs.bad("only http and https links are opened this way") }
        guard parsed.host != nil else { throw BackendDeckToolsArgs.bad("url must be a full web address, like https://example.com") }
        guard var components = URLComponents(url: parsed, resolvingAgainstBaseURL: false) else { throw BackendDeckToolsArgs.bad("url must be a full web address, like https://example.com") }
        components.scheme = scheme.lowercased(); components.host = components.host?.lowercased()
        if components.percentEncodedPath.isEmpty { components.percentEncodedPath = "/" }
        var segments: [String] = []
        let incoming = components.percentEncodedPath.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        for (index, component) in incoming.enumerated() {
            let part = String(component), dots = part.lowercased().replacingOccurrences(of: "%2e", with: ".")
            if dots == "." { if index == incoming.count - 1 { segments.append("") }; continue }
            if dots == ".." { if !segments.isEmpty { segments.removeLast() }; if index == incoming.count - 1 { segments.append("") }; continue }
            segments.append(part)
        }
        components.percentEncodedPath = "/" + segments.joined(separator: "/")
        if (components.scheme == "https" && components.port == 443) || (components.scheme == "http" && components.port == 80) { components.port = nil }
        return components.url?.absoluteString ?? parsed.absoluteString
    }
    public static func effectiveTier(_ id: String, _ args: NativeRPCValue) throws -> BackendMCPTier {
        switch id {
        case "hoot.run": return args["action"].string == "stop" ? .alter : .act
        case "hoot.instructions": return args["action"].string == "read" ? .read : .alter
        case "hoot.memory": return args["action"].string == "delete" ? .alter : args["action"].string == "write" ? .act : .read
        case "notifications.status": return try BackendDeckToolsArgs.optBool(args, "openSettings", false) ? .act : .read
        case "links.open": return .act
        default: return .read
        }
    }
    public static func definitions(copilot: any BackendDeckToolsAppCopilotService, doors: any BackendDeckToolsAppSmallDoorsService,
                                   access: BackendDeckToolsAppAccess) throws -> [BackendDeckToolsDefinition] {
        try K.definitions(module: "copilot-admin-tools", access: access, precheck: { id, _, args in
            switch id {
            case "hoot.run": if try runAction(args) == "reveal" { _ = try K.str(args, "place") }
            case "hoot.instructions": _ = try instructionsCall(args)
            case "hoot.memory": _ = try memoryCall(args)
            case "links.open": _ = try webAddress(args)
            default: break
            }
        }, consent: { id, _, args in
            let action = args["action"].string ?? "", which = args["which"].string ?? "yours", name = args["name"].string ?? "?"
            let sentence: String
            switch id {
            case "hoot.state": sentence = "Read Hoot’s state"
            case "hoot.run": sentence = action == "start" ? "Start Hoot" : action == "stop" ? "Stop Hoot" : action == "scaffold" ? "Create Hoot’s folder and starter files" : "Open Hoot’s \(args["place"].string ?? "?") in Finder"
            case "hoot.instructions": sentence = action == "write" ? "Replace Hoot’s \(which == "folder" ? "folder" : "own") instructions (\(args["text"].string?.utf16.count ?? 0) characters)" : action == "reset" ? "Put Hoot’s instructions back to this build’s default" : "Read Hoot’s \(which) instructions"
            case "hoot.memory": sentence = action == "read" ? "Read Hoot’s memory “\(name)”" : action == "write" ? "Save Hoot’s memory “\(name)”" : action == "delete" ? "Delete Hoot’s memory “\(name)”" : "List what Hoot remembers"
            case "tools.status": sentence = "Read the tool server’s status"
            case "notifications.status": sentence = try BackendDeckToolsArgs.optBool(args, "openSettings", false) ? "Open the system notification settings for this app" : "Check whether notifications reach the person"
            default: sentence = "Open \(args["url"].string ?? "?") in the Mac’s browser"
            }
            return (try effectiveTier(id, args), sentence, false)
        }, run: { id, _, args in
            switch id {
            case "hoot.state": return .init(K.object([("state", try await copilot.state()), ("signIn", try await copilot.signIn())]))
            case "hoot.run":
                let action = try runAction(args), value: NativeRPCValue
                switch action {
                case "start": value = K.object([("state", try await copilot.start())])
                case "stop": value = K.object([("state", try await copilot.stop())])
                case "scaffold": value = try await copilot.scaffold()
                default: value = try await copilot.reveal(K.str(args, "place"))
                }
                var summary = K.object([("action", .string(action))]); if action == "reveal" { summary = summary.setting("opened", value["opened"]) }
                return .init(value, summary)
            case "hoot.instructions":
                let call = try instructionsCall(args), value: NativeRPCValue
                if call.action == "read" { value = try await copilot.readInstructions(call.which) }
                else if call.action == "reset" { value = try await copilot.resetInstructions() }
                else { value = try await copilot.writeInstructions(call.which, text: call.text) }
                var summary = K.object([("action", .string(call.action))]); if call.action != "reset" { summary = summary.setting("which", .string(call.which)) }; if call.action == "write" { summary = summary.setting("chars", K.n(call.text.utf16.count)) }
                return .init(value, summary)
            case "hoot.memory":
                let call = try memoryCall(args), value: NativeRPCValue
                switch call.action {
                case "list": value = try await copilot.listMemory()
                case "read": value = try await copilot.readMemory(call.name)
                case "write": value = try await copilot.writeMemory(call.name, text: call.text)
                default: value = try await copilot.deleteMemory(call.name)
                }
                var summary = K.object([("action", .string(call.action))]); if call.action != "list" { summary = summary.setting("name", .string(call.name)) }; if call.action == "write" { summary = summary.setting("chars", K.n(call.text.utf16.count)) }
                return .init(value, summary)
            case "tools.status": return .init(try await doors.toolStatus() ?? K.object([("running", .bool(false)), ("note", .string("The tool server has not finished starting."))]))
            case "notifications.status":
                let since = access.now() - Double(try BackendDeckToolsArgs.optInt(args, "sinceMinutes", 60, 1, 10_080) * 60_000), opening = try BackendDeckToolsArgs.optBool(args, "openSettings", false)
                let opened = opening ? try await doors.openNotificationSettings() : NativeRPCValue.missing
                var value = K.object([("support", try await doors.notificationSupport()), ("delivery", try await doors.notificationDelivery(sinceMs: since))])
                if opening { value = value.setting("opened", opened) }
                return .init(value, K.object([("opened", .bool(opening))]))
            default:
                let url = try webAddress(args)
                guard try await doors.openURL(url) else { throw BackendDeckToolsArgs.bad("\(url) could not be opened outside the app") }
                return .init(K.object([("url", .string(url)), ("opened", .bool(true))]), K.object([("url", .string(url))]))
            }
        })
    }
}

/// Native SwiftUI dispatcher; strings are arguments, never evaluated code.
/// Implement on MainActor in the app target, using AppCommands' real handlers.
public protocol BackendDeckToolsAppUIService: Sendable {
    func list() async throws -> NativeRPCValue?
    func perform(kind: String, target: String) async throws -> NativeRPCValue?
}
public enum BackendDeckToolsAppUI {
    private typealias K = BackendDeckToolsAppKit
    public static let global = "__terminaldeckUi"
    public static let listCall = "globalThis.__terminaldeckUi?.list() ?? null"
    public static let refused: [String: NativeRPCValue] = [
        "session.new": .string("sessions.start"), "session.newDialog": .string("sessions.start"), "session.resume": .string("sessions.start"), "session.close": .string("sessions.stop"),
        "project.open": .string("projects.browse"), "palette.quickOpen": .string("files.find"), "app.quickOpen": .string("files.find"), "view.search": .string("sessions.search"), "panel.search": .string("sessions.search"),
        "palette.commands": .string("ui.list"), "app.palette": .string("ui.list"), "app.join": .null
    ]
    public static let noWindow = "There is no app window open to act on, so nothing on screen changed. Sessions, files and everything else still work through their own tools."
    public static func doCall(kind: String, target: String) -> String {
        let literal = K.object([("kind", .string(kind)), ("target", .string(target))]).compact.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return "globalThis.\(global)?.do(\(literal)) ?? null"
    }
    public static func kind(_ args: NativeRPCValue) throws -> String {
        let kind = try K.str(args, "action")
        guard ["run", "focus", "settings"].contains(kind) else { throw BackendDeckToolsArgs.bad("action must be \"run\", \"focus\" or \"settings\"") }
        return kind
    }
    public static func refuseDialogs(_ args: NativeRPCValue) throws {
        guard try kind(args) == "run" else { return }
        let target = try K.str(args, "target")
        guard let instead = refused[target] else { return }
        let suffix = instead == .null ? "There is nothing behind that dialog yet." : "Use \(instead.string!) instead."
        throw K.refused("\(target) opens something that waits for a person to type or pick, and nobody may be at this screen. \(suffix)")
    }
    public static func effectiveTier(_ args: NativeRPCValue) -> BackendMCPTier { args["action"].string == "run" && args["target"].string?.hasPrefix("features.install.") == true ? .alter : .act }
    public static func definitions(service: any BackendDeckToolsAppUIService, access: BackendDeckToolsAppAccess) throws -> [BackendDeckToolsDefinition] {
        try K.definitions(module: "ui-tools", access: access, precheck: { id, _, args in if id == "ui.do" { try refuseDialogs(args) } }, consent: { id, _, args in
            if id == "ui.list" { return (.read, "List what can be done in the window", false) }
            let target = args["target"].string ?? "?", action = args["action"].string ?? ""
            let sentence = action == "focus" ? "Bring session \(target) to the front" : action == "settings" ? "Open Settings at \(target)" : target.hasPrefix("features.install.") ? "Install the \(target.dropFirst("features.install.".count)) feature" : "Run \(target) in the window"
            return (effectiveTier(args), sentence, false)
        }, run: { id, _, args in
            if id == "ui.list" {
                let listing: NativeRPCValue?
                do { listing = try await service.list() }
                catch let error as NativeRPCError where ["unavailable", "missing-capability"].contains(error.code) { throw error }
                catch { listing = nil }
                guard let listing, listing.fields != nil else { return .init(K.object([("window", .null), ("note", .string(noWindow))]), K.object([("window", .string("none"))])) }
                let commands = (listing["commands"].elements ?? []).filter { $0["id"].string.map { refused[$0] == nil } == true }
                return .init(listing.setting("commands", .array(commands)).setting("refused", .object(refused.keys.sorted().map { .init($0, refused[$0]!) })), K.object([("commands", K.n(commands.count))]))
            }
            try refuseDialogs(args)
            let action = try kind(args), target = try K.str(args, "target"), raw: NativeRPCValue?
            do { raw = try await service.perform(kind: action, target: target) }
            catch let error as NativeRPCError where ["unavailable", "missing-capability"].contains(error.code) { throw error }
            catch { raw = nil }
            guard let raw, let ok = raw["ok"].bool, let text = raw[ok ? "did" : "why"].string else { return .init(K.object([("done", .bool(false)), ("note", .string(noWindow))]), K.object([("window", .string("none"))])) }
            guard ok else { throw BackendDeckToolsArgs.bad("\(text) ui.list shows what is there.") }
            return .init(K.object([("done", .bool(true)), ("did", .string(text))]), K.object([("action", .string(action)), ("target", .string(target))]))
        })
    }
}
