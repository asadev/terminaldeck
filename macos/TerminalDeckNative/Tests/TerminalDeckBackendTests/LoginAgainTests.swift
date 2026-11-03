import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// 29 Oct (Asad: "when I start new sessions it says login again"): a new ClaudeCRM session ran on this Mac's own
/// Claude Code login, which was signed out (its keychain item held no Claude login), so Claude Code answered only
/// "Not logged in" and showed "API Usage Billing". A session never starts on a signed-out login; it is said plainly
/// with Sign in. And a scratch copy never uses this Mac's own AI logins at all.
@Suite("Sessions start signed in; scratch copies keep their own AI logins")
struct LoginAgainTests {
    static let system = BackendAccountProfile(id: "system", name: "Default", provider: "claude", configDir: "/Users/someone/.claude", system: true, color: "", createdAt: 0)
    static let kept = BackendAccountProfile(id: "kept-1", name: "work@example.com", provider: "claude", configDir: "/data/account-logins/kept-1", system: false, color: "", createdAt: 0)

    @Test func aSignedOutLoginIsRefusedInPlainWordsAndOthersStart() throws {
        let refusal = try #require(BackendAccountLaunchAdapter.signedOutRefusal(Self.system, state: "signed-out"))
        #expect(refusal.message.hasPrefix("This Mac's own Claude Code login is not signed in, so no session was started."))
        #expect(refusal.message.contains("Sign in"), "it says where to sign in")
        #expect(refusal.message.contains(BackendAccountLaunchAdapter.notSignedInMarker))
        let named = try #require(BackendAccountLaunchAdapter.signedOutRefusal(Self.kept, state: "signed-out"))
        #expect(named.message.hasPrefix("The Claude login \u{201C}work@example.com\u{201D} is not signed in"))
        // Signed in, or a state that cannot be told: the session starts as before.
        for state in ["signed-in", "unknown", "unsupported", nil] as [String?] {
            #expect(BackendAccountLaunchAdapter.signedOutRefusal(Self.system, state: state) == nil)
        }
    }

    /// Reviewer 29 Oct (MUST): another way in, or a fresh "signed in", always starts the session.
    @Test func anotherWayInOrAFreshSignInStartsTheSession() async {
        actor Reads { var fresh = 0; var cached = 0; func note(_ isFresh: Bool) { if isFresh { fresh += 1 } else { cached += 1 } } }
        func checker(cached: String, fresh: String, reads: Reads) -> BackendAccountLaunchAdapter.SignInCheck {
            { _, isFresh in await reads.note(isFresh); return isFresh ? fresh : cached }
        }
        // An API key in the session's environment: it starts; no fresh read is needed.
        let key = Reads()
        #expect(await BackendAccountLaunchAdapter.refusal(Self.system, check: checker(cached: "signed-out", fresh: "signed-out", reads: key),
            environment: ["ANTHROPIC_API_KEY": "set"], settings: []) == nil)
        let keyReads = await key.fresh
        #expect(keyReads == 0)
        // Bedrock, Vertex or a key helper in the account's settings: it starts.
        for settings in [NativeRPCValue.object([.init("env", .object([.init("CLAUDE_CODE_USE_BEDROCK", .string("1"))]))]),
                         .object([.init("apiKeyHelper", .string("/usr/local/bin/key"))]),
                         .object([.init("env", .object([.init("CLAUDE_CODE_USE_VERTEX", .string("1"))]))])] {
            #expect(await BackendAccountLaunchAdapter.refusal(Self.system, check: checker(cached: "signed-out", fresh: "signed-out", reads: Reads()),
                environment: [:], settings: [settings]) == nil)
        }
        // A stale "signed out" (signed in a minute ago in a terminal), then a fresh "signed in": it starts.
        let stale = Reads()
        #expect(await BackendAccountLaunchAdapter.refusal(Self.system, check: checker(cached: "signed-out", fresh: "signed-in", reads: stale),
            environment: [:], settings: []) == nil)
        let staleFresh = await stale.fresh
        #expect(staleFresh == 1, "the fresh read decides, never the cache alone")
        // Signed out now too, and no other way in: refused in plain words.
        let refused = await BackendAccountLaunchAdapter.refusal(Self.system, check: checker(cached: "signed-out", fresh: "signed-out", reads: Reads()),
            environment: ["PATH": "/usr/bin"], settings: [.object([.init("env", .object([.init("NO_COLOR", .string("1"))]))])])
        #expect(refused?.message.contains(BackendAccountLaunchAdapter.notSignedInMarker) == true)
        // Signed in from the cache: no fresh read at all.
        let fine = Reads()
        #expect(await BackendAccountLaunchAdapter.refusal(Self.system, check: checker(cached: "signed-in", fresh: "signed-out", reads: fine), environment: [:], settings: []) == nil)
        let fineFresh = await fine.fresh
        #expect(fineFresh == 0)
    }

    @Test func theInstalledAppsFolderByAnotherSpellingIsNeverAScratchCopy() {
        let home = URL(fileURLWithPath: "/Users/someone")
        #expect(BackendScratchAgentHomes.additions(environment: [NativeLaunchSwitches.dataFolder: "/Users/someone/Library/Application Support/TerminalDeck"],
                                                   home: home, bundleID: "dev.terminaldeck.app").isEmpty)
        #expect(BackendScratchAgentHomes.additions(environment: [NativeLaunchSwitches.dataFolder: "/Users/someone/Library/Application Support/terminaldeck/"],
                                                   home: home, bundleID: "dev.terminaldeck.app").isEmpty)
        let dev = "/Users/someone/Library/Application Support/Terminal Deck Dev"
        let merged = BackendScratchAgentHomes.environment([NativeLaunchSwitches.dataFolder: dev, "PATH": "/usr/bin"], home: home, bundleID: BackendDevCopy.bundleID)
        #expect(merged["CLAUDE_CONFIG_DIR"] == dev + "/agent-homes/claude" && merged["PATH"] == "/usr/bin")
    }

    @Test func aRetryNeverStartsASessionThatIsAlreadyRunning() async throws {
        actor Starts { var count = 0; func next() -> Int { count += 1; return count } }
        let starts = Starts()
        let value = try await BackendSessionRestoreCoordinator.startingAgain(pause: .milliseconds(1), alreadyRunning: { "already running" }) { () async throws -> String in
            _ = await starts.next()
            throw BackendAccountFailure("The selected account or its CLI/MCP configuration changed during launch. Start again.")
        }
        let started = await starts.count
        #expect(value == "already running" && started == 1, "the running one is the answer; nothing starts twice")
    }

    @Test func theChipSaysNotSignedInWhenTheLoginIsGone() {
        let current = (id: "system", name: "Default", system: Optional(true))
        // Claude Code still remembers the email in ~/.claude.json; the live sign-in says signed out: that wins.
        let gone = AccountChipRules.chipIdentity(knownEmail: "work@example.com", current: current,
                                                 live: CodingAISignIn(state: .signedOut, detail: "Not signed in."))
        #expect(gone.label == "Not signed in" && !gone.verified)
        #expect(gone.detail?.contains("Switch") == true && gone.detail?.contains("Sign in") == true)
        // Only a checked sign-in may name Default’s remembered email.
        #expect(AccountChipRules.chipIdentity(knownEmail: "work@example.com", current: current, live: CodingAISignIn(state: .signedIn, account: "work@example.com")).label == "work@example.com")
        #expect(AccountChipRules.chipIdentity(knownEmail: "work@example.com", current: current, live: nil).label == "Checking…")
    }

    @Test func aChatSaysPlainlyWhatToDoInsteadOfNotLoggedIn() {
        let failed = NativeRPCValue.object([.init("problem", .string("Not logged in \u{00B7} Please run /login"))])
        #expect(BackendSessionChats.plainSignInProblem(failed)["problem"].string == BackendSessionChats.signedOutNotice)
        #expect(BackendSessionChats.signedOutNotice.contains("Switch") && BackendSessionChats.signedOutNotice.contains("Sign in"))
        let other = NativeRPCValue.object([.init("problem", .string("API Error: 529 Overloaded"))])
        #expect(BackendSessionChats.plainSignInProblem(other) == other)
        let none = NativeRPCValue.object([.init("busy", .bool(false))])
        #expect(BackendSessionChats.plainSignInProblem(none) == none)
    }

    @Test func aScratchCopyGetsItsOwnAIHomesAndTheInstalledAppDoesNot() {
        let home = URL(fileURLWithPath: "/Users/someone")
        // The installed app: nothing added.
        #expect(BackendScratchAgentHomes.additions(environment: [:], home: home, bundleID: "dev.terminaldeck.app").isEmpty)
        #expect(BackendScratchAgentHomes.additions(environment: [NativeLaunchSwitches.dataFolder: "/Users/someone/Library/Application Support/terminaldeck"],
                                                   home: home, bundleID: "dev.terminaldeck.app").isEmpty)
        // The dev copy (its own data folder): each AI's login lives inside it.
        let dev = "/Users/someone/Library/Application Support/Terminal Deck Dev"
        let added = BackendScratchAgentHomes.additions(environment: [NativeLaunchSwitches.dataFolder: dev], home: home, bundleID: BackendDevCopy.bundleID)
        #expect(added == ["CLAUDE_CONFIG_DIR": dev + "/agent-homes/claude", "CODEX_HOME": dev + "/agent-homes/codex", "GEMINI_CLI_HOME": dev + "/agent-homes/gemini"])
        // The dev bundle without a named folder uses its own; a scratch install with another folder too.
        #expect(BackendScratchAgentHomes.additions(environment: [:], home: home, bundleID: BackendDevCopy.bundleID)["CLAUDE_CONFIG_DIR"] == dev + "/agent-homes/claude")
        #expect(BackendScratchAgentHomes.additions(environment: [NativeLaunchSwitches.dataFolder: "/tmp/scratch-copy"], home: home, bundleID: "dev.terminaldeck.app")["CODEX_HOME"] == "/tmp/scratch-copy/agent-homes/codex")
        // A home the launcher set (the accounts proof) stays.
        let proof = BackendScratchAgentHomes.additions(environment: [NativeLaunchSwitches.dataFolder: dev, "CLAUDE_CONFIG_DIR": dev + "/proof-claude"], home: home, bundleID: BackendDevCopy.bundleID)
        #expect(proof["CLAUDE_CONFIG_DIR"] == nil && proof["CODEX_HOME"] != nil)
    }

    /// The standing rule itself: in a scratch copy the "Default" Claude account's keychain item is never this Mac's own.
    @Test func aScratchCopysDefaultClaudeNeverNamesTheMacWideKeychainItem() throws {
        let home = URL(fileURLWithPath: "/Users/someone")
        let dev = "/Users/someone/Library/Application Support/Terminal Deck Dev"
        let environment = [NativeLaunchSwitches.dataFolder: dev].merging(BackendScratchAgentHomes.additions(environment: [NativeLaunchSwitches.dataFolder: dev],
            home: home, bundleID: BackendDevCopy.bundleID)) { $1 }
        let configuration = try BackendAccountConfiguration(dataDirectory: URL(fileURLWithPath: dev), homeDirectory: home, appName: BackendDevCopy.name,
            appID: BackendSharedBrand.id, helperExecutable: URL(fileURLWithPath: "/bin/true"), inheritedEnvironment: environment)
        #expect(configuration.systemDirectory("claude") == dev + "/agent-homes/claude")
        let system = BackendAccountProfile(id: "system", name: "Default", provider: "claude", configDir: configuration.systemDirectory("claude"), system: true, color: "", createdAt: 0)
        let directory = BackendAccountBroker.agentLaunchDir(system, inherited: environment)
        let service = BackendAccountShimParsing.serviceName(slot: "keychain:Claude Code-credentials", directory: directory)
        #expect(service != "Claude Code-credentials", "never the Mac-wide login")
        #expect(service.hasPrefix("Claude Code-credentials-"))
        // The installed app keeps using this Mac's own login, as before.
        #expect(BackendAccountShimParsing.serviceName(slot: "keychain:Claude Code-credentials", directory: BackendAccountBroker.agentLaunchDir(system, inherited: [:])) == "Claude Code-credentials")
    }

    /// Keeper restart 00:52: one chat was refused "changed during launch" because a sibling's Claude Code rewrote
    /// .claude.json. Only what a launch uses is compared now.
    @Test func aLaunchComparesOnlyTheClaudeConfigItUses() throws {
        func config(_ startups: Int, servers: [String] = ["deck"], approved: [String] = ["crm"], other: String = "a") -> NativeRPCValue {
            .object([.init("numStartups", .number(Double(startups))), .init("tipsHistory", .object([.init("x", .number(Double(startups)))])),
                .init("mcpServers", .object(servers.map { .init($0, .object([.init("command", .string("/bin/" + $0))])) })),
                .init("projects", .object([.init("/work/crm", .object([.init("enabledMcpjsonServers", .array(approved.map(NativeRPCValue.string))),
                                                                       .init("lastSessionId", .string("s\(startups)"))])),
                                           .init("/work/other", .object([.init("lastSessionId", .string(other))]))]))])
        }
        let base = BackendAGSSelectedAccountFacts.claudeLaunchDigest(config(1), projectRoot: "/work/crm")
        #expect(BackendAGSSelectedAccountFacts.claudeLaunchDigest(config(2), projectRoot: "/work/crm") == base, "start-up counters and tips do not matter")
        #expect(BackendAGSSelectedAccountFacts.claudeLaunchDigest(config(1, other: "b"), projectRoot: "/work/crm") == base, "another project does not matter")
        #expect(BackendAGSSelectedAccountFacts.claudeLaunchDigest(config(1, servers: ["deck", "new"]), projectRoot: "/work/crm") != base, "a new MCP server does")
        #expect(BackendAGSSelectedAccountFacts.claudeLaunchDigest(config(1, approved: []), projectRoot: "/work/crm") != base, "a withdrawn approval does")
    }

    @Test func aRaceDuringARestartGetsOneFreshAttempt() async throws {
        actor Attempts { var count = 0; func next() -> Int { count += 1; return count } }
        let raced = Attempts()
        let value = try await BackendSessionRestoreCoordinator.startingAgain(pause: .milliseconds(1)) { () async throws -> String in
            if await raced.next() == 1 { throw BackendAccountFailure("The selected account or its CLI/MCP configuration changed during launch. Start again.") }
            return "started"
        }
        let tries = await raced.count
        #expect(value == "started" && tries == 2)
        let other = Attempts()
        await #expect(throws: BackendAccountFailure.self) {
            _ = try await BackendSessionRestoreCoordinator.startingAgain(pause: .milliseconds(1)) { () async throws -> String in
                _ = await other.next(); throw BackendAccountFailure("This Mac's own Claude Code login is not signed in, so no session was started.")
            }
        }
        let once = await other.count
        #expect(once == 1, "any other failure is reported at once, never retried")
    }

    /// Guard: every Claude launch asks the sign-in check before it starts (app and keeper are both wired).
    @Test func everyClaudeLaunchAsksBeforeItStarts() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        func source(_ name: String) throws -> String { try String(contentsOf: root.appendingPathComponent("Sources/TerminalDeckBackend/" + name), encoding: .utf8) }
        #expect(try source("BackendAccountLaunchAdapter.swift").contains("if let refused = await Self.refusal(login, check: check, environment: seen, settings: settings) { throw refused }"))
        #expect(try source("BackendCompositionSessions.swift").contains("setSignInCheck"))
        #expect(try source("BackendHOSTAccountControl.swift").contains("setSignInCheck"))
    }
}
