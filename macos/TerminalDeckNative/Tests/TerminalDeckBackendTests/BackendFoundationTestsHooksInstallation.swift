import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

private final class BackendFoundationTestsHooksFixture {
    let scratch: BackendFoundationTestsSessionsScratch
    let configuration: BackendAccountConfiguration
    let owner = NativeRPCContext(caller: .nativeApp, ownerID: "foundation-hooks")
    let endpoint = BackendSessionHookEndpoint(socketPath: "/tmp/terminaldeck-test/hook/hook.sock", configPath: "/tmp/terminaldeck-test/hook/hook-endpoint.conf", sessionEnvironment: "TERMINALDECK_SESSION_ID", appID: "terminaldeck")
    let other = BackendSessionHookEndpoint(socketPath: "/tmp/terminaldeck-other/hook/hook.sock", configPath: "/tmp/terminaldeck-other/hook/hook-endpoint.conf", sessionEnvironment: "TERMINALDECK_SESSION_ID", appID: "terminaldeck")
    let installation: BackendSessionHookInstallation
    static let claudeEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "Notification", "Stop", "StopFailure", "SessionEnd"]
    static let geminiEvents = ["SessionStart", "BeforeAgent", "BeforeTool", "AfterTool", "AfterAgent", "Notification", "SessionEnd"]
    static let codexRequirement = "Codex needs `hooks = true` in ~/.codex/config.toml [features], then Trust all once when it asks."
    static let foreignStart = NativeRPCValue.object([.init("type", .string("command")), .init("command", .string("sh -c 'mkdir -p /tmp/vibeyard && echo SessionStart:waiting > /tmp/vibeyard/$CLAUDE_IDE_SESSION_ID.status # vibeyard-hook'"))])
    static let foreignStop = NativeRPCValue.object([.init("type", .string("command")), .init("command", .string("/usr/bin/python3 \"/Users/apple/.vibeyard/run/claude_event_Stop.py\" \"# vibeyard-hook\""))])
    static func group(_ entries: [NativeRPCValue], sequential: Bool? = nil) -> NativeRPCValue {
        var value = NativeRPCValue.object([.init("matcher", .string("")), .init("hooks", .array(entries))])
        if let sequential { value = value.setting("sequential", .bool(sequential)) }; return value
    }
    static var original: NativeRPCValue {
        .object([.init("cleanupPeriodDays", .number(3650)), .init("permissions", .object([.init("allow", .array([.string("mcp__example__*")])), .init("defaultMode", .string("bypassPermissions"))])),
            .init("hooks", .object([.init("SessionStart", .array([group([foreignStart])])), .init("Stop", .array([group([foreignStop])]))])),
            .init("statusLine", .object([.init("type", .string("command")), .init("command", .string("/Users/apple/.vibeyard/run/statusline.sh"))])), .init("effortLevel", .string("xhigh"))])
    }
    init() throws {
        scratch = try BackendFoundationTestsSessionsScratch()
        configuration = try BackendAccountConfiguration(dataDirectory: scratch.root.appendingPathComponent("data"), homeDirectory: scratch.root, appName: "Terminal Deck", appID: "terminaldeck", helperExecutable: scratch.root.appendingPathComponent("never-executed-helper"), inheritedEnvironment: [:])
        installation = try BackendSessionHookInstallation(configuration: configuration, endpoint: endpoint,
            providerSettingsFiles: ["claude": scratch.root.appendingPathComponent(".claude/settings.json"), "codex": scratch.root.appendingPathComponent(".codex/hooks.json"), "gemini": scratch.root.appendingPathComponent(".gemini/settings.json")],
            offerFile: scratch.root.appendingPathComponent("offer.json"), authorizeMutation: { _ in })
    }
    func alternate() throws -> BackendSessionHookInstallation {
        try BackendSessionHookInstallation(configuration: configuration, endpoint: other,
            providerSettingsFiles: ["claude": file("claude"), "codex": file("codex"), "gemini": file("gemini")], offerFile: scratch.root.appendingPathComponent("offer.json"), authorizeMutation: { _ in })
    }
    func file(_ provider: String) -> URL { scratch.root.appendingPathComponent("." + provider + (provider == "codex" ? "/hooks.json" : "/settings.json")) }
    @discardableResult func write(_ provider: String = "claude", raw: NativeRPCValue = BackendFoundationTestsHooksFixture.original) throws -> URL {
        try scratch.write("." + provider + (provider == "codex" ? "/hooks.json" : "/settings.json"), String(decoding: raw.encodedJSON(pretty: true), as: UTF8.self) + "\n")
    }
    func read(_ provider: String = "claude") throws -> NativeRPCValue { try NativeRPCValue.parseJSON(Data(contentsOf: file(provider))) }
    func text(_ provider: String = "claude") throws -> String { try String(contentsOf: file(provider), encoding: .utf8) }
    func entries(_ provider: String = "claude") throws -> [NativeRPCValue] {
        try (read(provider)["hooks"].fields ?? []).flatMap { ($0.value.elements ?? []).flatMap { $0["hooks"].elements ?? [] } }
    }
}

@Suite("Foundation: hook consent offer and standing consent")
struct BackendFoundationTestsHooksOffer {
    private typealias F = BackendFoundationTestsHooksFixture
    // TS hooks.test.ts:1050
    @Test func freshOfferOnlyNamesConfiguredCLI() async throws {
        let f = try F(); try f.write(); let offer = await f.installation.offer()
        #expect(offer["show"].bool == true); #expect(offer["answered"] == .null)
        #expect(offer["eligible"].elements?.compactMap { $0["id"].string } == ["claude"]); #expect(offer["followUps"].elements == [])
    }
    // TS hooks.test.ts:1062
    @Test func codexTrustStepStillShown() async throws {
        let f = try F(); try f.write(); try f.write("codex", raw: .object([]))
        #expect(await f.installation.offer()["followUps"].elements == [.string(F.codexRequirement)])
    }
    // TS hooks.test.ts:1072
    @Test func noConfiguredCLIsNoOfferOrRecord() async throws {
        let f = try F(); #expect(await f.installation.offer()["show"].bool == false)
        #expect(!FileManager.default.fileExists(atPath: f.scratch.root.appendingPathComponent("offer.json").path))
    }
    // TS hooks.test.ts:1081 — result-array API is unavailable; installed/absent file effects are covered.
    @Test func acceptInstallsAllConfiguredCLIs() async throws {
        let f = try F(); try f.write(); try f.write("codex", raw: .object([]))
        _ = try await f.installation.answerOffer(accept: true, context: f.owner)
        #expect(await f.installation.status("claude").state == "complete"); #expect(await f.installation.status("codex").state == "complete")
        #expect(!FileManager.default.fileExists(atPath: f.file("gemini").path))
    }
    // TS hooks.test.ts:1094
    @Test func acceptedConsentNeverAsksAgain() async throws {
        let f = try F(); try f.write(); _ = try await f.installation.answerOffer(accept: true, context: f.owner)
        let offer = await f.installation.offer(); #expect(offer["answered"].string == "accepted"); #expect(offer["show"].bool == false)
    }
    // TS hooks.test.ts:1102
    @Test func declinedConsentRememberedWithoutConfigWrite() async throws {
        let f = try F(); try f.write(); let before = try f.text()
        _ = try await f.installation.answerOffer(accept: false, context: f.owner)
        let offer = await f.installation.offer(); #expect(offer["answered"].string == "declined"); #expect(offer["show"].bool == false); #expect(try f.text() == before)
    }
    // TS hooks.test.ts:1113
    @Test func existingOwnInstallSuppressesOffer() async throws {
        let f = try F(); try f.write(); try f.write("codex", raw: .object([])); _ = try await f.installation.install("claude", context: f.owner)
        #expect(await f.installation.offer()["show"].bool == false)
    }
    // TS hooks.test.ts:1125
    @Test func otherCopyInstallDoesNotPromptTakeover() async throws {
        let f = try F(); try f.write(); _ = try await f.alternate().install("claude", context: f.owner)
        #expect(await f.installation.offer()["show"].bool == false)
    }
    // TS hooks.test.ts:1134
    @Test func acceptedConsentCoversLaterConfiguredCLI() async throws {
        let f = try F(); try f.write(); _ = try await f.installation.answerOffer(accept: true, context: f.owner); try f.write("codex", raw: .object([]))
        #expect(try await f.installation.sync(context: f.owner).first { $0.id == "codex" }?.state == "complete")
    }
    // TS hooks.test.ts:1147
    @Test func declinedConsentLeavesUninstalledHooksAlone() async throws {
        let f = try F(); try f.write(); _ = try await f.installation.answerOffer(accept: false, context: f.owner)
        #expect(try await f.installation.sync(context: f.owner).first { $0.id == "claude" }?.state == "none")
    }
    // TS hooks.test.ts:1156
    @Test func removalWithdrawsStandingConsent() async throws {
        let f = try F(); try f.write(); _ = try await f.installation.answerOffer(accept: true, context: f.owner); _ = try await f.installation.remove("claude", context: f.owner)
        #expect(await f.installation.offer()["answered"].string == "declined")
        #expect(try await f.installation.sync(context: f.owner).first { $0.id == "claude" }?.state == "none")
    }
    // TS hooks.test.ts:1168
    @Test func removalAlsoSettlesNeverAskedOffer() async throws {
        let f = try F(); try f.write(); _ = try await f.installation.install("claude", context: f.owner); _ = try await f.installation.remove("claude", context: f.owner)
        #expect(await f.installation.offer()["show"].bool == false)
    }
    // TS hooks.test.ts:1192
    @Test func unreadableOfferMarkerMeansUnanswered() async throws {
        let f = try F(); try f.write(); _ = try f.scratch.write("offer.json", "{ not json")
        let offer = await f.installation.offer(); #expect(offer["answered"] == .null); #expect(offer["show"].bool == true)
    }
    // TS hooks.test.ts:1203 — failure results array unavailable; preserved consent and successful other provider covered.
    @Test func acceptedConsentSurvivesOneFailedInstall() async throws {
        let f = try F(); try f.write(); try f.write("codex", raw: .object([])); let before = await f.installation.offer()
        #expect(before["eligible"].elements?.contains { $0["id"].string == "claude" } == true)
        _ = try f.scratch.write(".claude/settings.json", "{ this is not json")
        _ = try await f.installation.answerOffer(accept: true, context: f.owner)
        #expect(await f.installation.status("codex").state == "complete"); #expect(await f.installation.offer()["answered"].string == "accepted")
    }
}

@Suite("Foundation: hook ownership, commands, file edits and status")
struct BackendFoundationTestsHooksInstallation {
    private typealias F = BackendFoundationTestsHooksFixture
    // TS hooks.test.ts:236
    @Test func onlyMarkedCommandEntriesClaimed() async throws {
        let f = try F(), marked = NativeRPCValue.object([.init("type", .string("command")), .init("command", .string("curl ... # terminaldeck-hook"))])
        try f.write(raw: .object([.init("hooks", .object([.init("Stop", .array([F.group([marked, F.foreignStart, .object([.init("type", .string("command"))]), .string("not an object")])]))]))]))
        _ = try await f.installation.remove("claude", context: f.owner)
        #expect(try f.entries() == [F.foreignStart, .object([.init("type", .string("command"))]), .string("not an object")])
    }
    // TS hooks.test.ts:243 — native currently returns the whole marker instead of its owner name.
    @Test func foreignMarkerOwnerNamed() async throws {
        let f = try F(); try f.write()
        #expect(await f.installation.status("claude").foreignOwners == ["vibeyard"])
        try f.write(raw: .object([.init("hooks", .object([.init("Stop", .array([F.group([.object([.init("type", .string("command")), .init("command", .string("echo hi"))])])]))]))]))
        #expect(await f.installation.status("claude").foreignOwners.isEmpty)
    }
    // TS hooks.test.ts:248
    @Test func commandConsumesStdinAndCannotFailSession() async throws {
        let f = try F(), command = await f.installation.command(provider: "claude", event: "Stop")
        #expect(command.contains("--data-binary @-")); #expect(command.contains("http://localhost/hook/claude/Stop")); #expect(command.contains("|| true")); #expect(command.hasSuffix("# terminaldeck-hook"))
    }
    // TS hooks.test.ts:267
    @Test func responsesKeptForContextEvents() async throws {
        let f = try F()
        for event in ["SessionStart", "UserPromptSubmit", "PostToolUse"] {
            let command = await f.installation.command(provider: "claude", event: event)
            #expect(!command.contains("-o /dev/null")); #expect(command.contains("2>/dev/null"))
        }
        for event in ["Stop", "PreToolUse", "Notification"] { #expect(await f.installation.command(provider: "claude", event: event).contains("-o /dev/null")) }
        for event in ["SessionStart", "PostToolUse"] { #expect(await !f.installation.command(provider: "codex", event: event).contains("-o /dev/null")) }
    }
    // TS hooks.test.ts:307 — POSIX half; Windows half is not applicable on Mac.
    @Test func commandStableAndCarriesNoToken() async throws {
        let f = try F(), a = await f.installation.command(provider: "claude", event: "Stop"), b = await f.installation.command(provider: "claude", event: "Stop")
        #expect(a == b); #expect(!a.contains(String(repeating: "a", count: 48))); #expect(a.contains("-K '" + f.endpoint.configPath + "'"))
    }
    // TS hooks.test.ts:395
    @Test func foreignHooksSurviveInstall() async throws {
        let f = try F(); try f.write(); _ = try await f.installation.install("claude", context: f.owner)
        let groups = try #require(f.read()["hooks"]["SessionStart"].elements)
        #expect(groups.count == 2); #expect(groups[0] == F.group([F.foreignStart])); #expect(groups[1]["hooks"].elements?.first?["command"].string?.contains("# terminaldeck-hook") == true)
    }
    // TS hooks.test.ts:407
    @Test func repeatedInstallHasOneEntryPerEvent() async throws {
        let f = try F(); _ = try await f.installation.install("claude", context: f.owner); _ = try await f.installation.install("claude", context: f.owner)
        #expect(try f.entries().filter { $0["command"].string?.contains("# terminaldeck-hook") == true }.count == F.claudeEvents.count)
    }
    // TS hooks.test.ts:413
    @Test func explicitInstallReplacesOtherCopy() async throws {
        let f = try F(); _ = try await f.alternate().install("claude", context: f.owner); _ = try await f.installation.install("claude", context: f.owner)
        let commands = try f.entries().compactMap { $0["command"].string }
        #expect(commands.allSatisfy { $0.contains(f.endpoint.configPath) }); #expect(!commands.contains { $0.contains(f.other.configPath) })
    }
    // TS hooks.test.ts:423
    @Test func retiredOwnedEventRemovedByInstall() async throws {
        let f = try F(); try f.write(raw: .object([.init("hooks", .object([.init("RetiredEvent", .array([F.group([.object([.init("type", .string("command")), .init("command", .string("old # terminaldeck-hook"))])])]))]))]))
        _ = try await f.installation.install("claude", context: f.owner); #expect(try f.read()["hooks"]["RetiredEvent"] == .missing)
    }
    // TS hooks.test.ts:432
    @Test func geminiNonEventKeysPreserved() async throws {
        let f = try F(); try f.write("gemini", raw: .object([.init("hooks", .object([.init("enabled", .bool(true)), .init("notifications", .object([.init("level", .string("all"))]))]))]))
        _ = try await f.installation.install("gemini", context: f.owner)
        #expect(try f.read("gemini")["hooks"]["enabled"].bool == true); #expect(try f.read("gemini")["hooks"]["notifications"] == .object([.init("level", .string("all"))]))
    }
    // TS hooks.test.ts:441
    @Test func onlyGeminiEntriesHaveNames() async throws {
        let f = try F(); _ = try await f.installation.install("gemini", context: f.owner); _ = try await f.installation.install("claude", context: f.owner)
        #expect(try f.entries("gemini")[0]["name"] != .missing); #expect(try f.entries("claude")[0]["name"] == .missing)
    }
    // TS hooks.test.ts:449
    @Test func providerTimeoutUnitsPreserved() async throws {
        let f = try F(); _ = try await f.installation.install("gemini", context: f.owner); _ = try await f.installation.install("claude", context: f.owner)
        #expect(try f.entries("claude")[0]["timeout"].number == 5); #expect(try f.entries("gemini")[0]["timeout"].number == 5000)
    }
    // TS hooks.test.ts:456 — source no-op identity is verified through its no-write file consequence.
    @Test func foreignOnlyRemovePreservesFile() async throws {
        let f = try F(); try f.write(); let before = try f.text()
        _ = try await f.installation.remove("claude", context: f.owner); #expect(try f.text() == before)
    }
    // TS hooks.test.ts:464
    @Test func removalDropsOnlyOwnedHooksKey() async throws {
        let f = try F(); try f.write(raw: .object([.init("theme", .string("dark"))])); _ = try await f.installation.install("claude", context: f.owner); _ = try await f.installation.remove("claude", context: f.owner)
        #expect(try f.read()["hooks"] == .missing); #expect(try f.read()["theme"].string == "dark")
    }
    // TS hooks.test.ts:471
    @Test func foreignMatcherGroupFieldsKept() async throws {
        let f = try F(), own = NativeRPCValue.object([.init("type", .string("command")), .init("command", .string("x # terminaldeck-hook"))])
        try f.write(raw: .object([.init("hooks", .object([.init("Stop", .array([F.group([F.foreignStop, own], sequential: true)]))]))]))
        _ = try await f.installation.remove("claude", context: f.owner)
        #expect(try f.read()["hooks"]["Stop"].elements == [F.group([F.foreignStop], sequential: true)])
    }
    // TS hooks.test.ts:490
    @Test func preexistingEmptyGroupKept() async throws {
        let f = try F(), own = NativeRPCValue.object([.init("type", .string("command")), .init("command", .string("x # terminaldeck-hook"))])
        try f.write(raw: .object([.init("hooks", .object([.init("Stop", .array([F.group([]), F.group([own])]))]))]))
        _ = try await f.installation.remove("claude", context: f.owner); #expect(try f.read()["hooks"]["Stop"].elements == [F.group([])])
    }
    // TS hooks.test.ts:500
    @Test func foreignInstallRoundTripByteIdentical() async throws {
        let f = try F(); try f.write(); let original = try f.text()
        _ = try await f.installation.install("claude", context: f.owner)
        #expect(try f.entries().filter { $0["command"].string?.contains("# terminaldeck-hook") != true } == [F.foreignStart, F.foreignStop])
        #expect(try f.read()["statusLine"] == F.original["statusLine"]); #expect(try f.read()["permissions"] == F.original["permissions"])
        _ = try await f.installation.remove("claude", context: f.owner); #expect(try f.text() == original)
    }
    // TS hooks.test.ts:521
    @Test func fileMode0600Preserved() async throws {
        let f = try F(), file = try f.write(); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        _ = try await f.installation.install("claude", context: f.owner); #expect(try (FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
    // TS hooks.test.ts:527 — native's fixed two-space encoder currently diverges.
    @Test func existingFourSpaceIndentPreserved() async throws {
        let f = try F(); _ = try f.scratch.write(".claude/settings.json", "{\n    \"hooks\": {}\n}\n")
        _ = try await f.installation.install("claude", context: f.owner); let text = try f.text()
        #expect(text.contains("\n    \"hooks\"")); #expect(text.hasSuffix("\n"))
    }
    // TS hooks.test.ts:535
    @Test func absentProviderConfigCreatedOwnerOnly() async throws {
        let f = try F(); _ = try await f.installation.install("gemini", context: f.owner)
        #expect(try f.entries("gemini").filter { $0["command"].string?.contains("# terminaldeck-hook") == true }.count == F.geminiEvents.count)
        #expect(try (FileManager.default.attributesOfItem(atPath: f.file("gemini").path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }
    // TS hooks.test.ts:544
    @Test func backupOnlyBeforeFirstWrite() async throws {
        let f = try F(); try f.write(); let original = try f.text(), backup = f.configuration.dataDirectory.appendingPathComponent("hook/backups/claude-settings.json")
        _ = try await f.installation.install("claude", context: f.owner); #expect(try String(contentsOf: backup, encoding: .utf8) == original)
        _ = try await f.installation.install("claude", context: f.owner); #expect(try String(contentsOf: backup, encoding: .utf8) == original)
    }
    // TS hooks.test.ts:557
    @Test func invalidJSONLeftUntouchedWithExactExplanation() async throws {
        let f = try F(), body = "{ \"hooks\": { /* a comment makes this JSONC */ } }"; _ = try f.scratch.write(".claude/settings.json", body)
        var message = ""
        do { _ = try await f.installation.install("claude", context: f.owner); Issue.record("An unparseable settings file must be refused.") } catch { message = error.localizedDescription }
        #expect(message.contains("not valid JSON")); #expect(try f.text() == body)
    }
    // TS hooks.test.ts:566
    @Test func nonObjectHooksRefusedWithoutWrite() async throws {
        let f = try F(); try f.write(raw: .object([.init("hooks", .array([]))])); let before = try f.text()
        do { _ = try await f.installation.install("claude", context: f.owner); Issue.record("An array hooks key must be refused.") } catch {}
        #expect(try f.text() == before)
    }
    // TS hooks.test.ts:573
    @Test func removeForeignOnlyDoesNotWriteOrBackup() async throws {
        let f = try F(); try f.write(); let before = try f.text(), status = try await f.installation.remove("claude", context: f.owner)
        #expect(status.message.contains("not modified")); #expect(try f.text() == before)
        #expect(!FileManager.default.fileExists(atPath: f.configuration.dataDirectory.appendingPathComponent("hook/backups/claude-settings.json").path))
    }
    // TS hooks.test.ts:584
    @Test func removeRetiredOwnedEvent() async throws {
        let f = try F(); try f.write(raw: .object([.init("hooks", .object([.init("RetiredEvent", .array([F.group([.object([.init("type", .string("command")), .init("command", .string("old # terminaldeck-hook"))])])]))]))]))
        _ = try await f.installation.remove("claude", context: f.owner); #expect(try f.read()["hooks"] == .missing)
    }
    // TS hooks.test.ts:603
    @Test func symlinkedSettingsRemainLinkedAndRealFileChanged() async throws {
        let f = try F(), real = try f.scratch.write("dotfiles/claude-settings.json", String(decoding: F.original.encodedJSON(pretty: true), as: UTF8.self) + "\n"), original = try String(contentsOf: real, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: real.path)
        try FileManager.default.createDirectory(at: f.file("claude").deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.file("claude"), withDestinationURL: real)
        _ = try await f.installation.install("claude", context: f.owner)
        #expect(try f.file("claude").resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
        #expect(try f.entries().filter { $0["command"].string?.contains("# terminaldeck-hook") == true }.count == F.claudeEvents.count)
        #expect(try (FileManager.default.attributesOfItem(atPath: real.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        _ = try await f.installation.remove("claude", context: f.owner)
        #expect(try f.file("claude").resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true); #expect(try String(contentsOf: real, encoding: .utf8) == original)
    }
    // TS hooks.test.ts:634
    @Test func repeatedAtomicWritesLeaveNoTempFiles() throws {
        let f = try F(), file = f.file("claude")
        for n in 0..<40 { try BackendAccountFiles.writeAtomic(Data("{\"n\":\(n)}".utf8), to: file) }
        #expect(try f.text() == "{\"n\":39}"); #expect(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path) == ["settings.json"])
    }
    // TS hooks.test.ts:654
    @Test func foreignOnlyStatusNamesOwnerWithoutRepeatingMessage() async throws {
        let f = try F(); try f.write(); let status = await f.installation.status("claude")
        #expect(status.state == "none"); #expect(status.foreignHooks == 2); #expect(status.foreignOwners == ["vibeyard"]); #expect(!status.message.contains("vibeyard"))
    }
    // TS hooks.test.ts:665
    @Test func completeStatusPreservesEventOrder() async throws {
        let f = try F(); try f.write(); _ = try await f.installation.install("claude", context: f.owner); let status = await f.installation.status("claude")
        #expect(status.state == "complete"); #expect(status.installedEvents == F.claudeEvents); #expect(status.missingEvents == []); #expect(status.backupPath != nil)
    }
    // TS hooks.test.ts:675
    @Test func otherCopyStatusStaleWithExactExplanation() async throws {
        let f = try F(); try f.write(); _ = try await f.alternate().install("claude", context: f.owner); let status = await f.installation.status("claude")
        #expect(status.state == "stale"); #expect(status.staleEvents == F.claudeEvents); #expect(status.message.contains("somewhere other than this copy"))
    }
    // TS hooks.test.ts:693
    @Test func stableEndpointStatusCompleteOnRestart() async throws {
        let f = try F(); try f.write(); _ = try await f.installation.install("claude", context: f.owner)
        let status = await f.installation.status("claude"); #expect(status.state == "complete"); #expect(status.staleEvents == [])
    }
    // TS hooks.test.ts:702
    @Test func onlyOneInstalledEventStatusPartial() async throws {
        let f = try F(), command = await f.installation.command(provider: "claude", event: "Stop")
        try f.write(raw: .object([.init("hooks", .object([.init("Stop", .array([F.group([.object([.init("type", .string("command")), .init("command", .string(command))])])]))]))]))
        #expect(await f.installation.status("claude").state == "partial")
    }
    // TS hooks.test.ts:717
    @Test func unparsableStatusReportsErrorWithoutThrowing() async throws {
        let f = try F(); _ = try f.scratch.write(".claude/settings.json", "not json at all"); let status = await f.installation.status("claude")
        #expect(status.state == "error"); #expect(status.message.contains("left untouched"))
    }
    // TS hooks.test.ts:724
    @Test func missingFileStatusNoneWithExactExplanation() async throws {
        let f = try F(), status = await f.installation.status("codex")
        #expect(status.state == "none"); #expect(!status.fileExists); #expect(status.message.contains("does not exist yet"))
    }
    // TS hooks.test.ts:889
    @Test func syncLeavesUninstalledProviderAlone() async throws {
        let f = try F(); try f.write(); let statuses = try await f.installation.sync(context: f.owner)
        #expect(statuses.first { $0.id == "codex" }?.state == "none"); #expect(!FileManager.default.fileExists(atPath: f.file("codex").path))
    }
    // TS hooks.test.ts:916
    @Test func syncLeavesOtherCopyByteIdentical() async throws {
        let f = try F(); try f.write(); _ = try await f.alternate().install("claude", context: f.owner); let before = try f.text()
        let statuses = try await f.installation.sync(context: f.owner)
        #expect(statuses.first { $0.id == "claude" }?.state == "stale"); #expect(try f.text() == before)
    }
    // TS hooks.test.ts:929
    @Test func syncMigratesOwnLegacyTokenCommand() async throws {
        let f = try F(), command = NativeRPCValue.object([.init("type", .string("command")), .init("command", .string("curl -s http://127.0.0.1:51234/hook # terminaldeck-hook"))])
        var raw = F.original
        for event in F.claudeEvents { raw = raw.setting("hooks", raw["hooks"].setting(event, .array((raw["hooks"][event].elements ?? []) + [F.group([command])]))) }
        try f.write(raw: raw); let statuses = try await f.installation.sync(context: f.owner)
        #expect(statuses.first { $0.id == "claude" }?.state == "complete")
    }
    // TS hooks.test.ts:951
    @Test func requestedTakeoverBecomesComplete() async throws {
        let f = try F(); try f.write(); _ = try await f.alternate().install("claude", context: f.owner)
        #expect(try await f.installation.install("claude", context: f.owner).state == "complete")
    }
}
