import Foundation
import Testing
@testable import TerminalDeckBackend
import TerminalDeckNativeCore

/// FIXRESTART (16 Oct): after the session-helper restart Asad's "Session 2" (agent Alex, Claude chat) was not started
/// again: "A key may only narrow its owner's agent settings." Its saved private settings carry the bypass every fresh
/// start gets (R73), while Alex's own profile leaves the permission unset, so the restore was judged as a key broadening.
/// Held Codex tabs failed the same way on a plugin server ("code-review") the first launch had turned off itself.
@Suite("FIXRESTART: a tab relaunched from its own saved settings is not a key request", .serialized)
struct FixRestartAgentSettingsTests {
    private struct Cipher: BackendAccountVaultCipher {
        func available() -> Bool { true }
        func prepareForWrites(existingVault: Bool) throws {}
        func encrypt(_ text: String, existingVault: Bool) throws -> Data { Data(text.utf8) }
        func decrypt(_ blob: Data) throws -> String { String(decoding: blob, as: UTF8.self) }
    }

    @Test func sessionTwoShapeRelaunchesWithItsOwnSavedBypassWhileAKeyStillMayOnlyNarrow() async throws {
        let persistence = try BackendTaskPersistence(directory: URL(fileURLWithPath: "/tmp/fixrestart-ags-memory"), ownership: .memory)
        let store = BackendAGSStore(persistence: persistence, cipher: Cipher()); try await store.start()
        try await store.saveDefaults(.init(providers: ["claude": AGSAgentSettings(provider: "claude", model: "opus")]), expectedRevision: 0)
        let config = try BackendTaskConfiguration(persistence: persistence); try await config.start(); try await config.bindAGS(store)
        _ = try await config.saveAgent(.object([.init("id", .string("alex")), .init("name", .string("Alex")),
            .init("provider", .string("claude")), .init("model", .string("opus"))]))
        var input = BackendCreateSessionInput(cwd: "/tmp", provider: "claude"); input.agentProfileID = "alex"; input.chat = true
        func resolve(_ requested: AGSAgentSettings?) async throws -> AGSAgentSettings? {
            try await BackendAGSSettingsResolution.resolve(input: input, store: store, configuration: config,
                defaultProvider: "claude", taskProfile: "alex", requested: requested)
        }
        // First start: Alex's settings, then the fresh-start bypass (BackendCoordinatedSessionLaunch), saved for the tab.
        var saved = try #require(try await resolve(nil))
        #expect(saved.permissionMode == nil)
        saved.permissionMode = "bypassPermissions"
        // Restore from that saved record: starts, with the permission it ran with.
        let restored = try await BackendAGSLaunchScope.$ownSavedChoice.withValue(true) { try await resolve(saved) }
        #expect(restored?.permissionMode == "bypassPermissions")
        #expect(restored?.model == saved.model)
        // The same settings supplied by a caller (a key) are still a broadening and are refused.
        await #expect(throws: (any Error).self) { _ = try await resolve(saved) }
    }

    @Test func aHeldCodexTabWithAPluginServerItsLaunchTurnedOffStartsAgain() throws {
        let help = "--model --config --sandbox --ask-for-approval"
        // What the first launch saved: code-review off because the launch itself marked it off (Codex's own list).
        let saved = AGSAgentSettings(provider: "codex", permissionMode: "danger-full-access", mcpServers: ["code-review": false])
        let names: Set<String> = ["deck-control", "code-review"]
        func plan(_ off: Set<String>) throws -> BackendAGSLaunchPlan {
            try BackendAGSLaunch.plan(saved, privateDirectory: URL(fileURLWithPath: "/tmp/ags-owned"), installedHelp: help,
                knownServers: names, overridable: ["deck-control"], requestedOff: off)
        }
        let relaunch = BackendAGSLaunchBinding.requestedOff(saved, serverNames: names, ownSavedChoice: true)
        #expect(relaunch.isEmpty)
        let started = try plan(relaunch)
        #expect(!started.arguments.joined(separator: " ").contains("code-review"))
        // The person asking for a plugin server off for one session is still refused plainly.
        let asked = BackendAGSLaunchBinding.requestedOff(saved, serverNames: names, ownSavedChoice: false)
        #expect(asked == ["code-review"])
        #expect(throws: (any Error).self) { _ = try plan(asked) }
    }
}
