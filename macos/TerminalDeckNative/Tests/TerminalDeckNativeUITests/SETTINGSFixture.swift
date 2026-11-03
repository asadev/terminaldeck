import Foundation
import TerminalDeckNativeCore
import TerminalDeckBackend
@testable import TerminalDeckNative

/// Inert graph. Every registered action is an in-memory fixture action.
actor SETTINGSFixture {
    static let owner = "SETTINGS-render-fixture"
    private var preferences = NativeRPCValue.object([.init("theme", .string("system"))])
    private var settings = NativeRPCValue.object([])
    private var hooks = ["claude": "complete", "codex": "none", "gemini": "error"]
    private var refuseWrites = false
    private(set) var calls: [String] = []
    let directory: URL
    init(directory: URL) { self.directory = directory }

    func refuse(_ next: Bool) { refuseWrites = next }
    func root() async throws -> BackendCompositionRoot {
        let graph = try BackendCompositionRoot(dataRoot: directory, state: NativeStateStore(),
            environment: ["HOME": directory.path, "PATH": "/nonexistent"], home: directory.path)
        let channels = Set(["prefs:get", "prefs:set", "settings:get", "settings:set", "settings:about", "settings:paths",
            "hooks:status", "hooks:server", "hooks:install", "hooks:remove", "prereq:check", "setup:status", "providers:detect",
            "profiles:account-providers", "profiles:list", "profiles:signin", "accounts:history-state", "session:list", "machines:list",
            "browser-signin:agents", "power:lid-awake:get", "notifications:support", "hoot-menubar:config", "hoot-menubar:configure",
            "voice:providers", "voice:status", "plugins:state", "ai-apps:state", "ags:get", "tasks:state", "tasks:list", "connected-tasks:state",
            "browser-password:state", "browser-password:list", "browser-session:info", "browser-profile:list", "browser-download:list",
            "browser-scraping:config", "browser-scraping:status", "browser:block-capture", "browser-worker:lift-requests", "browser-store:list",
            "hoot:state", "hoot:memory", "hoot:actions", "hoot:read-instructions", "routines:list",
            "hoot-provider:get", "hoot-provider:options", "hoot:ready:read", "hoot:provider:read"])
        for channel in channels {
            try await graph.registry.register(channel, ownerID: Self.owner) { [self] _, arguments in
                try await answer(channel, arguments)
            }
        }
        try await graph.retain(.init(name: "SETTINGS-fixture", domains: ["SETTINGS-fixture"], ownerID: Self.owner,
            invokes: channels, stop: {}))
        return graph
    }

    func answer(_ channel: String, _ arguments: [NativeRPCValue]) throws -> NativeRPCValue {
        calls.append(channel)
        switch channel {
        case "prefs:get": return preferences
        case "prefs:set": preferences = preferences.merging(arguments.first ?? .object([])); return preferences
        case "settings:get": return .object([.init("values", settings)])
        case "settings:set":
            if refuseWrites { throw NativeRPCError(code: "fixture-refused", message: "Fixture could not save that change.") }
            settings = settings.merging(arguments.first ?? .object([])); return .object([.init("values", settings)])
        case "settings:about": return try json(#"{"name":"Terminal Deck","version":"0.19.1","tagline":"Your coding workspace","license":"MIT","repository":"https://github.com/asadev/terminaldeck","homepage":"https://terminaldeck.app","platform":"darwin","arch":"arm64","updates":{"checkable":false}}"#)
        case "settings:paths": return .array([.object([.init("key", .string("logs")), .init("label", .string("Logs")), .init("purpose", .string("Diagnostic logs.")), .init("path", .string(directory.appendingPathComponent("logs").path)), .init("kind", .string("folder")), .init("exists", .bool(true))])])
        case "hooks:status":
            return .array(["claude", "codex", "gemini"].map { id in
                .object([.init("id", .string(id)), .init("label", .string(CodingAICatalog.label(id))),
                    .init("file", .string(directory.appendingPathComponent(id + ".json").path)),
                    .init("fileExists", .bool(true)), .init("state", .string(hooks[id] ?? "none")),
                    .init("foreignHooks", .number(id == "claude" ? 2 : 0)), .init("foreignOwners", .array([.string("another tool")])),
                    .init("message", .string(id == "gemini" ? "Fixture settings are unreadable." : ""))])
            })
        case "hooks:server": return try json(#"{"running":true,"address":"fixture://local"}"#)
        case "hooks:install", "hooks:remove":
            guard !refuseWrites else { throw NativeRPCError(code: "fixture-refused", message: "Fixture could not update live status.") }
            guard let id = arguments.first?.string, hooks[id] != nil, hooks[id] != "error" else {
                throw NativeRPCError(code: "fixture-unreadable", message: "The fixture settings are unreadable.")
            }
            hooks[id] = channel == "hooks:install" ? "complete" : "none"
            return try json(#"{"ok":true,"message":"Live status updated."}"#)
        case "prereq:check", "setup:status": return try json(#"{"canRunSessions":true,"tools":[{"id":"claude","label":"Claude Code","state":"ready","version":"fixture 1.0"},{"id":"codex","label":"Codex CLI","state":"ready","version":"fixture 1.0"},{"id":"gemini","label":"Gemini CLI","state":"missing"}]}"#)
        case "providers:detect": return try json(#"{"claude":{"available":true},"codex":{"available":true}}"#)
        case "profiles:account-providers": return try json(#"{"providers":[{"id":"claude","supported":true,"canSignIn":true},{"id":"codex","supported":true,"canSignIn":true}]}"#)
        case "profiles:list": return try json(#"{"defaultId":"fixture-claude","profiles":[{"id":"fixture-claude","name":"Personal","provider":"claude","system":true},{"id":"fixture-codex","name":"Personal","provider":"codex","system":true}]}"#)
        case "profiles:signin": return try json(#"{"state":"signed-in","account":"person@example.test","detail":"Signed in."}"#)
        case "accounts:history-state": return try json(#"{"state":{"link":"shared","ownProjects":0,"root":"~/AI"}}"#)
        case "session:list", "browser-signin:agents", "browser-download:list", "browser-password:list", "browser-worker:lift-requests", "browser-store:list", "routines:list": return .array([])
        case "machines:list": return try json(#"{"here":{"name":"Fixture Mac"},"servers":[],"devices":[]}"#)
        case "power:lid-awake:get": return try json(#"{"on":false,"known":true,"supported":true,"idleBlocked":false}"#)
        case "notifications:support": return try json(#"{"settingsPane":false}"#)
        case "hoot-menubar:config", "hoot-menubar:configure": return try json(#"{"enabled":true}"#)
        case "voice:providers": return try json(#"[{"id":"groq","label":"Groq","model":"whisper-large-v3"},{"id":"openai","label":"OpenAI","model":"whisper-1"}]"#)
        case "voice:status": return try json(#"{"hasKey":false,"canStore":true}"#)
        case "plugins:state": return try json(#"{"plugins":[],"folder":"~/Plugins"}"#)
        case "ai-apps:state": return try json(#"{"keys":[{"id":"fixture-key","name":"Example AI app","level":"full","askFirst":true,"tasks":true,"folders":["~/Projects/Example"],"createdAt":1791590400000,"lastUsedAt":1791590460000,"notify":{"mode":"wait","hasSecret":false},"grantedScopes":["settings.read","tasks.read"]}],"folders":["~/Projects/Example","~/Projects/Sandbox"],"local":{"url":"http://fixture.invalid"},"internet":{"on":false}}"#)
        case "ags:get":
            let defaults = try NativeRPCValue.parseJSON(JSONEncoder().encode(AGSDefaults()))
            return .object([.init("revision", .number(1)), .init("defaults", defaults), .init("defaultProvider", .string("claude"))])
        case "tasks:state", "tasks:list": return try json(#"{"agents":[],"connections":[],"crms":[],"tasks":[]}"#)
        case "connected-tasks:state": return try json(#"{"systems":[]}"#)
        case "browser-password:state": return try json(#"{"available":true,"canStore":true}"#)
        case "browser-session:info": return try json(#"{"persist":true,"cookies":0,"origins":0}"#)
        case "browser-profile:list": return try json(#"{"profiles":[{"id":"default","name":"Default","isDefault":true}],"activeId":"default"}"#)
        case "browser-scraping:config": return try json(#"{"fleet":{"profileIds":[],"concurrency":2,"delayMs":200},"assets":{"ledger":{"on":true,"refetch":false}}}"#)
        case "browser-scraping:status": return try json(#"{"workers":[]}"#)
        case "browser:block-capture": return .bool(false)
        case "hoot:state": return try json(#"{"status":"stopped","paths":{"root":"~/Hoot","instructions":"~/Hoot/AGENTS.md","memory":"~/Hoot/memory","actions":"~/Hoot/actions.jsonl"},"folder":{"path":"~/Hoot"},"instructions":"ready"}"#)
        case "hoot:memory": return try json(#"{"dir":"~/Hoot/memory","exists":true,"facts":[]}"#)
        case "hoot:actions": return try json(#"{"dir":"~/Hoot","file":"~/Hoot/actions.jsonl","exists":true,"rows":[]}"#)
        case "hoot:read-instructions": return try json(#"{"ok":true,"text":"","exists":true}"#)
        case "hoot:ready:read": return try json(#"{"provider":"claude","choices":{"provider":"","model":"","effort":""},"accounts":[]}"#)
        case "hoot:provider:read": return try json(#"{"provider":"claude","restartRequired":false}"#)
        case "hoot-provider:get": return try json(#"{"provider":"auto","model":"","effort":""}"#)
        case "hoot-provider:options": return try json(#"{"providers":[{"id":"claude","label":"Claude Code","installed":true},{"id":"codex","label":"Codex CLI","installed":true}]}"#)
        default: throw NativeRPCError(code: "fixture-unavailable", message: "No fixture for " + channel)
        }
    }
    private func json(_ text: String) throws -> NativeRPCValue { try NativeRPCValue.parseJSON(Data(text.utf8)) }
}
