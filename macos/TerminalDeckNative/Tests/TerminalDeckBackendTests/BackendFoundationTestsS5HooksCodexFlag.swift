import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

// S5 night: hooks.test.ts "the codex feature flag migration" (:1222-1330).
// Swift has no separate migratedCodexFeatures/migrateCodexFeatureFlag; the flag is repaired inside
// BackendSessionHookInstallation.install (enableCodexFeature), so each TS case is driven through install/sync/answerOffer.
// Skipped: "answers unchanged for a file with nothing to migrate" (:1269) — pure-function result, no Swift seam.
// Skipped, with reason: the Windows hook-command cases (:335-:392, :743), and "the command we write actually works" (:772-:888),
// which runs the shell command against a Node server; the Swift command is curl-over-unix-socket and is covered by the S5 hook-server endpoint suites.
// "installHooksWhereConfigured" (:974-:1040) maps to answerOffer(accept:), already covered by BackendFoundationTestsHooksOffer
// (acceptInstallsAllConfiguredCLIs, otherCopyInstallDoesNotPromptTakeover, invalidJSONLeftUntouched..., backupOnlyBeforeFirstWrite).

@Suite("Foundation S5: codex feature flag migration")
struct BackendFoundationTestsS5HooksCodexFlag {
    static let config = """
    model = "gpt-5.3-codex"

    [features]
    codex_hooks = true

    [hooks.state]
    trusted_hash = "abc123"

    """
    private struct Fixture {
        let scratch: BackendFoundationTestsSessionsScratch
        let installation: BackendSessionHookInstallation
        let context = NativeRPCContext(caller: .nativeApp, ownerID: "foundation-s5-codex")
        var configFile: URL { scratch.root.appendingPathComponent(".codex/config.toml") }
        init(config: String? = BackendFoundationTestsS5HooksCodexFlag.config) throws {
            scratch = try BackendFoundationTestsSessionsScratch()
            let configuration = try BackendAccountConfiguration(dataDirectory: scratch.root.appendingPathComponent("data"), homeDirectory: scratch.root, appName: "Terminal Deck", appID: "terminaldeck",
                helperExecutable: scratch.root.appendingPathComponent("never-executed-helper"), inheritedEnvironment: [:])
            let endpoint = BackendSessionHookEndpoint(socketPath: "/tmp/terminaldeck-test/hook/hook.sock", configPath: "/tmp/terminaldeck-test/hook/hook-endpoint.conf", sessionEnvironment: "TERMINALDECK_SESSION_ID", appID: "terminaldeck")
            installation = try BackendSessionHookInstallation(configuration: configuration, endpoint: endpoint,
                providerSettingsFiles: ["claude": scratch.root.appendingPathComponent(".claude/settings.json"), "codex": scratch.root.appendingPathComponent(".codex/hooks.json"), "gemini": scratch.root.appendingPathComponent(".gemini/settings.json")], offerFile: scratch.root.appendingPathComponent("offer.json"), authorizeMutation: { _ in })
            if let config { try scratch.write(".codex/config.toml", config) }
        }
        func text() throws -> String { try String(contentsOf: configFile, encoding: .utf8) }
    }
    // TS hooks.test.ts:1238
    @Test func keyRenamedInPlaceAndNothingElseTouched() async throws {
        let f = try Fixture(); _ = try await f.installation.install("codex", context: f.context)
        let out = try f.text()
        #expect(out.contains("hooks = true")); #expect(!out.contains("codex_hooks"))
        #expect(out.contains(#"trusted_hash = "abc123""#)); #expect(out.contains(#"model = "gpt-5.3-codex""#))
        #expect(out.components(separatedBy: "\n").count == Self.config.components(separatedBy: "\n").count)
    }
    // TS hooks.test.ts:1250 — the migration keeps the value and the trailing comment
    @Test func valueAndTrailingCommentKept() async throws {
        let f = try Fixture(config: "[features]\ncodex_hooks = false # off for now\n"); _ = try await f.installation.install("codex", context: f.context)
        #expect(try f.text().contains("hooks = false # off for now"))
    }
    // TS hooks.test.ts:1255
    @Test func deprecatedLineDroppedWhenNewKeyExists() async throws {
        let f = try Fixture(config: "[features]\nhooks = true\ncodex_hooks = true\n"); _ = try await f.installation.install("codex", context: f.context)
        let out = try f.text()
        #expect(out.contains("hooks = true")); #expect(!out.contains("codex_hooks"))
    }
    // TS hooks.test.ts:1264
    @Test func keyOutsideFeaturesTableUntouched() async throws {
        let f = try Fixture(config: "[something_else]\ncodex_hooks = true\n"); _ = try await f.installation.install("codex", context: f.context)
        #expect(try f.text().contains("[something_else]\ncodex_hooks = true"))
    }
    // TS hooks.test.ts:1274 — rewrite, backup of the original, and idempotence. The backup half is expected to FAIL: Swift keeps no codex-config.toml backup (NIGHT-REQUESTS S5).
    @Test func rewriteIsIdempotent() async throws {
        let f = try Fixture(); _ = try await f.installation.install("codex", context: f.context)
        let rewritten = try f.text(); #expect(!rewritten.contains("codex_hooks"))
        _ = try await f.installation.install("codex", context: f.context)
        #expect(try f.text() == rewritten)
    }
    @Test func originalConfigBackedUpBeforeRewrite() async throws {
        let f = try Fixture(); _ = try await f.installation.install("codex", context: f.context)
        let backup = f.scratch.root.appendingPathComponent("data/hook/backups/codex-config.toml")
        #expect(try String(contentsOf: backup, encoding: .utf8) == Self.config)
    }
    // TS hooks.test.ts:1290 — a machine with no codex config gets nothing from the startup pass
    @Test func noCodexConfigMeansNoFileWritten() async throws {
        let f = try Fixture(config: nil); _ = try await f.installation.sync(context: f.context)
        #expect(!FileManager.default.fileExists(atPath: f.configFile.path)); #expect(!FileManager.default.fileExists(atPath: f.scratch.root.appendingPathComponent(".codex").path))
    }
    // TS hooks.test.ts:1295 — the startup pass repairs the flag even when the hooks already read complete
    @Test func startupPassRepairsFlagWhenHooksAlreadyComplete() async throws {
        let f = try Fixture(config: "[features]\nhooks = true\n"); _ = try await f.installation.install("codex", context: f.context)
        try f.scratch.write(".codex/config.toml", Self.config)
        _ = try await f.installation.sync(context: f.context)
        #expect(!(try f.text().contains("codex_hooks")))
    }
    // TS hooks.test.ts:1309 — the headless install pass (installHooksWhereConfigured) is answerOffer(accept:) in Swift
    @Test func headlessInstallPassRepairsFlag() async throws {
        let f = try Fixture(); try f.scratch.write(".codex/hooks.json", "{}\n")
        _ = try await f.installation.answerOffer(accept: true, context: f.context)
        #expect(!(try f.text().contains("codex_hooks")))
    }
    // TS hooks.test.ts:1317 — the Install result says the flag was repaired
    @Test func installMessageNamesTheRenamedFlag() async throws {
        let f = try Fixture(); let status = try await f.installation.install("codex", context: f.context)
        #expect(status.message.contains("Renamed the deprecated codex_hooks flag"))
    }
}
