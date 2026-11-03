import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// 3 Nov 2026 (#26, AI Connectors): Codex's PermissionRequest hook, and scratch copies that never carry this Mac's
/// Claude account profile.
@Suite("AI26: Codex approval hook and neutral scratch Claude homes")
struct AI26Tests {
    private static let endpoint = BackendSessionHookEndpoint(socketPath: "/tmp/terminaldeck-test/hook/hook.sock",
        configPath: "/tmp/terminaldeck-test/hook/hook-endpoint.conf", sessionEnvironment: "TERMINALDECK_SESSION_ID", appID: "terminaldeck")

    private static func installation(_ root: URL) throws -> BackendSessionHookInstallation {
        let configuration = try BackendAccountConfiguration(dataDirectory: root.appendingPathComponent("data"), homeDirectory: root, appName: "Terminal Deck",
            appID: "terminaldeck", helperExecutable: root.appendingPathComponent("never-executed-helper"), inheritedEnvironment: [:])
        return try BackendSessionHookInstallation(configuration: configuration, endpoint: endpoint,
            providerSettingsFiles: ["claude": root.appendingPathComponent(".claude/settings.json"), "codex": root.appendingPathComponent(".codex/hooks.json"),
                                    "gemini": root.appendingPathComponent(".gemini/settings.json")],
            offerFile: root.appendingPathComponent("offer.json"), authorizeMutation: { _ in })
    }

    // MARK: Codex's PermissionRequest hook

    @Test func codexIsGivenAPermissionRequestHookThatDecidesNothing() async throws {
        let scratch = try BackendFoundationTestsSessionsScratch(), owner = NativeRPCContext(caller: .nativeApp, ownerID: "ai26")
        let installation = try Self.installation(scratch.root)
        let status = try await installation.install("codex", context: owner)
        #expect(status.state == "complete")
        #expect(status.installedEvents == ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "Stop"])
        let written = try NativeRPCValue.parseJSON(Data(contentsOf: scratch.root.appendingPathComponent(".codex/hooks.json")))
        let command = written["hooks"]["PermissionRequest"].elements?.first?["hooks"].elements?.first?["command"].string ?? ""
        #expect(command.contains("http://localhost/hook/codex/PermissionRequest"))
        #expect(command.contains("-o /dev/null"), "prints nothing, so Codex takes no decision from it and asks the person")
        #expect(command.contains("|| true"), "a failed post never fails the approval")
        #expect(written["hooks"]["PermissionRequest"].elements?.first?["hooks"].elements?.first?["timeout"] == .missing)
        #expect(BackendSessionHookCoordinator.statuses["codex"]?["PermissionRequest"] == .input)
    }

    @Test func anEarlierCodexInstallIsRepairedWithTheNewHookAtStart() async throws {
        let scratch = try BackendFoundationTestsSessionsScratch(), owner = NativeRPCContext(caller: .nativeApp, ownerID: "ai26")
        let installation = try Self.installation(scratch.root)
        // What #25 wrote: five events, no PermissionRequest.
        var hooks: [NativeRPCValue.Field] = []
        for event in ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"] {
            let entry = NativeRPCValue.object([.init("type", .string("command")), .init("command", .string(await installation.command(provider: "codex", event: event)))])
            hooks.append(.init(event, .array([.object([.init("matcher", .string("")), .init("hooks", .array([entry]))])])))
        }
        try scratch.write(".codex/hooks.json", String(decoding: try NativeRPCValue.object([.init("hooks", .object(hooks))]).encodedJSON(pretty: true), as: UTF8.self) + "\n")
        let earlier = await installation.status("codex")
        #expect(earlier.state == "partial" && earlier.missingEvents == ["PermissionRequest"])
        let repaired = try await installation.sync(context: owner).first { $0.id == "codex" }
        #expect(repaired?.state == "complete")
        let entries = try NativeRPCValue.parseJSON(Data(contentsOf: scratch.root.appendingPathComponent(".codex/hooks.json")))["hooks"]
        #expect(entries["Stop"].elements?.count == 1 && entries["PermissionRequest"].elements?.count == 1, "one entry per event, nothing doubled")
    }

    // MARK: Scratch copies and the installed app's login

    private static let home = URL(fileURLWithPath: "/Users/someone")
    private static let dev = "/Users/someone/Library/Application Support/Terminal Deck Dev"
    private static let installed = "/Users/someone/Library/Application Support/terminaldeck"
    /// What an agent session of the installed app hands a copy started from inside it (`open`, devloop.sh).
    private static let inherited: [String: String] = [
        "PATH": installed + "/shim:" + installed + "/account-vault-shim:/Users/someone/.local/bin:/usr/bin:/bin",
        "TERMINALDECK_ACCOUNT_VAULT": installed + "/account-vault/vault.sock", "TERMINALDECK_ACCOUNT_TICKET": "ticket",
        "TERMINALDECK_ACCOUNT_HOME": installed + "/account-vault/home", "CLAUDE_SECURESTORAGE_CONFIG_DIR": installed + "/account-vault/store/system",
        "CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat-not-real", "LANG": "en_US.UTF-8",
    ]

    @Test func aScratchCopyDropsTheInheritedRouteToTheInstalledAppsLogin() {
        var environment = Self.inherited; environment[NativeLaunchSwitches.dataFolder] = Self.dev
        let scratch = BackendScratchAgentHomes.environment(environment, home: Self.home, bundleID: BackendDevCopy.bundleID)
        for key in ["TERMINALDECK_ACCOUNT_VAULT", "TERMINALDECK_ACCOUNT_TICKET", "TERMINALDECK_ACCOUNT_HOME", "CLAUDE_SECURESTORAGE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN"] {
            #expect(scratch[key] == nil, "\(key) leads to the installed app's login")
        }
        #expect(scratch["PATH"] == "/Users/someone/.local/bin:/usr/bin:/bin", "the installed app's shims are gone, every other entry kept in order")
        #expect(scratch["LANG"] == "en_US.UTF-8")
        #expect(scratch["CLAUDE_CONFIG_DIR"] == Self.dev + "/agent-homes/claude")
        // The dev bundle with no named folder is a scratch copy too.
        #expect(BackendScratchAgentHomes.withoutInstalledLogin(Self.inherited, home: Self.home, bundleID: BackendDevCopy.bundleID)["CLAUDE_SECURESTORAGE_CONFIG_DIR"] == nil)
    }

    @Test func theInstalledAppKeepsItsEnvironmentAsItIs() {
        #expect(BackendScratchAgentHomes.environment(Self.inherited, home: Self.home, bundleID: "dev.terminaldeck.app") == Self.inherited)
        var named = Self.inherited; named[NativeLaunchSwitches.dataFolder] = Self.installed + "/"
        #expect(BackendScratchAgentHomes.environment(named, home: Self.home, bundleID: "dev.terminaldeck.app") == named)
        #expect(BackendScratchAgentHomes.scratchData(environment: named, home: Self.home, bundleID: "dev.terminaldeck.app") == nil)
    }

    // MARK: A profile copied into a scratch Claude home

    private struct Mac {
        let scratch = try! BackendFoundationTestsSessionsScratch()
        var home: URL { scratch.root }
        var data: URL { home.appendingPathComponent("Library/Application Support/Terminal Deck Dev", isDirectory: true) }
        var claudeHome: URL { data.appendingPathComponent("agent-homes/claude", isDirectory: true) }
        static func profile(_ account: String) -> String {
            #"{"accountUuid":"\#(account)","emailAddress":"person@example.com","organizationUuid":"org-1","organizationName":"Example"}"#
        }
        init() throws {
            // This Mac's own login and one login the installed app keeps.
            try scratch.write(".claude.json", #"{"hasCompletedOnboarding":true,"oauthAccount":\#(Self.profile("AAAA-own"))}"# + "\n")
            try scratch.write("Library/Application Support/terminaldeck/account-logins/kept-1/.claude.json", #"{"oauthAccount":\#(Self.profile("BBBB-kept"))}"#)
        }
        @discardableResult func scratchConfig(account: String?) throws -> URL {
            let profile = account.map { #","oauthAccount":\#(Self.profile($0))"# } ?? ""
            return try scratch.write("Library/Application Support/Terminal Deck Dev/agent-homes/claude/.claude.json",
                                     #"{"firstStartTime":"2026-11-02T14:42:00Z","userID":"abc123abc123"\#(profile),"migrationVersion":3}"#)
        }
        func neutralize(_ claudeHome: URL? = nil) -> Bool {
            BackendScratchAgentHomes.neutralizeCopiedProfile(claudeHome: claudeHome ?? self.claudeHome, scratchData: data, home: home)
        }
        func config() throws -> NativeRPCValue { try NativeRPCValue.parseJSON(Data(contentsOf: claudeHome.appendingPathComponent(".claude.json"))) }
    }

    @Test func aProfileCopiedFromThisMacsOwnLoginIsTakenOut() throws {
        let mac = try Mac(), ownBefore = try Data(contentsOf: mac.home.appendingPathComponent(".claude.json"))
        try mac.scratchConfig(account: "aaaa-OWN".uppercased())
        #expect(mac.neutralize())
        let config = try mac.config()
        #expect(config["oauthAccount"] == .missing)
        #expect(config.fields?.map(\.key) == ["firstStartTime", "userID", "migrationVersion"], "every other key kept, in order")
        #expect(try Data(contentsOf: mac.home.appendingPathComponent(".claude.json")) == ownBefore, "this Mac's own file is only read")
        let mode = try FileManager.default.attributesOfItem(atPath: mac.claudeHome.appendingPathComponent(".claude.json").path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        #expect(!mac.neutralize(), "nothing left to take out")
    }

    @Test func aProfileCopiedFromALoginTheInstalledAppKeepsIsTakenOut() throws {
        let mac = try Mac()
        try mac.scratchConfig(account: "BBBB-kept")
        #expect(mac.neutralize())
        #expect(try mac.config()["oauthAccount"] == .missing)
    }

    @Test func aScratchCopysOwnLoginOfAnotherAccountIsKept() throws {
        let mac = try Mac()
        let file = try mac.scratchConfig(account: "CCCC-scratch-only"), before = try Data(contentsOf: file)
        #expect(!mac.neutralize())
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func onlyAHomeInsideTheScratchCopysOwnFolderAndNeverWhileClaudeHoldsItsLock() throws {
        let mac = try Mac()
        // A launcher that pointed CLAUDE_CONFIG_DIR at a folder outside the scratch copy: left alone.
        let outside = try mac.scratch.write("elsewhere/.claude.json", #"{"oauthAccount":\#(Mac.profile("AAAA-own"))}"#), outsideBefore = try Data(contentsOf: outside)
        #expect(!mac.neutralize(outside.deletingLastPathComponent()))
        #expect(try Data(contentsOf: outside) == outsideBefore)
        // Claude Code writing its file right now: left for the next start.
        let file = try mac.scratchConfig(account: "AAAA-own"), before = try Data(contentsOf: file)
        try mac.scratch.write("Library/Application Support/Terminal Deck Dev/agent-homes/claude/.claude.json.lock", "")
        #expect(!mac.neutralize())
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func theInstalledAppNeverTouchesAClaudeHomeAtStart() throws {
        let mac = try Mac()
        let file = try mac.scratchConfig(account: "AAAA-own"), before = try Data(contentsOf: file)
        // Not a scratch copy (installed bundle id, no named data folder in this test process): apply does nothing.
        #expect(BackendScratchAgentHomes.scratchData(environment: [:], home: mac.home, bundleID: "dev.terminaldeck.app") == nil)
        // apply reads this process's environment; it may only run here when that names no data folder (no scratch copy).
        guard ProcessInfo.processInfo.environment[NativeLaunchSwitches.dataFolder] == nil else { return }
        BackendScratchAgentHomes.apply(home: mac.home, bundleID: "dev.terminaldeck.app")
        #expect(try Data(contentsOf: file) == before)
    }
}
