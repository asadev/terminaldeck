import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@MainActor
final class BackendDeckCoreTestPortToolsAppTests: XCTestCase {
    private typealias F = BackendDeckCoreTestPortToolsFixture
    private func application(_ fake: BackendDeckCoreTestPortToolsApplicationFake,_ audit: BackendDeckCoreTestPortToolsAudit) throws -> [BackendDeckToolsDefinition] { try BackendDeckToolsAppApplication.definitions(service:fake,settings:fake,access:F.access(audit)) }
    private func voice(_ fake: BackendDeckCoreTestPortToolsApplicationFake,_ audit: BackendDeckCoreTestPortToolsAudit) throws -> [BackendDeckToolsDefinition] { try BackendDeckToolsAppVoice.definitions(service:fake,access:F.access(audit)) }
    private func hooks(_ fake: BackendDeckCoreTestPortToolsApplicationFake,_ audit: BackendDeckCoreTestPortToolsAudit) throws -> [BackendDeckToolsDefinition] { try BackendDeckToolsAppHooks.definitions(service:BackendDeckCoreTestPortToolsHookFake(owner:fake),access:F.access(audit)) }
    private func usage(_ fake: BackendDeckCoreTestPortToolsApplicationFake,_ audit: BackendDeckCoreTestPortToolsAudit) throws -> [BackendDeckToolsDefinition] { try BackendDeckToolsAppUsage.definitions(service:fake,access:F.access(audit)) }
    private func setup(_ fake: BackendDeckCoreTestPortToolsApplicationFake,_ audit: BackendDeckCoreTestPortToolsAudit) throws -> [BackendDeckToolsDefinition] { try BackendDeckToolsAppSetup.definitions(service:fake,access:F.access(audit)) }
    private func admin(_ fake: BackendDeckCoreTestPortToolsApplicationFake,_ audit: BackendDeckCoreTestPortToolsAudit) throws -> [BackendDeckToolsDefinition] { try BackendDeckToolsAppAdmin.definitions(copilot:fake,doors:fake,access:F.access(audit)) }
    // TSCASE app-tools.test.ts:34
    func testAppL34ResetKeepsProtectedValues() async throws {
        let fake = BackendDeckCoreTestPortToolsApplicationFake(),audit = BackendDeckCoreTestPortToolsAudit()
        let value = try F.value(await F.call(application(fake,audit),"settings.reset"))
        XCTAssertEqual(value["reset"],try F.json(#"["appearance.density","editor.font"]"#)); XCTAssertEqual(value["kept"],try F.json(#"["remote.enabled","advanced.debugMode"]"#)); XCTAssertEqual(value["snapshot"],.string("/state/settings.last-good.json"))
        let state = await fake.currentSettings(); XCTAssertEqual(state,try F.json(#"{"remote.enabled":true,"advanced.debugMode":false}"#))
    }
    // TSCASE app-tools.test.ts:45
    func testAppL45SnapshotPrecedesWrite() async throws {
        let fake = BackendDeckCoreTestPortToolsApplicationFake(); _ = try await F.call(application(fake,.init()),"settings.reset")
        let calls = await fake.calls(); XCTAssertEqual(calls.filter { ["snapshot","writeSettings"].contains($0["operation"].string ?? "") }.map { $0["operation"].string },["snapshot","writeSettings"])
        XCTAssertEqual(calls.first { $0["operation"].string == "writeSettings" }?["args"].elements?.first?.fields?.map(\.key),["appearance.density","editor.font"])
    }
    // TSCASE app-tools.test.ts:51
    func testAppL51ExactResetConsent() async throws {
        let fake = BackendDeckCoreTestPortToolsApplicationFake(),audit = BackendDeckCoreTestPortToolsAudit(); _ = try await F.call(application(fake,audit),"settings.reset")
        let consent = await audit.consent(); XCTAssertEqual(consent.first?["sentence"],.string("Reset 2 settings to defaults: appearance.density, editor.font"))
    }
    // TSCASE app-tools.test.ts:60
    func testAppL60CachedAndCheckedUpdater() async throws {
        let fake = BackendDeckCoreTestPortToolsApplicationFake(),defs = try application(fake,.init())
        let cached = try F.value(await F.call(defs,"updates.status")),checked = try F.value(await F.call(defs,"updates.status",#"{"check":true}"#))
        XCTAssertEqual(cached["phase"],.string("idle")); XCTAssertEqual(checked["phase"],.string("available"))
    }
    // TSCASE app-tools.test.ts:67
    func testAppL67InstallOnlyDownloadedAndMetadataSaysConnectionDrops() async throws {
        let fake = BackendDeckCoreTestPortToolsApplicationFake(),defs = try application(fake,.init())
        F.error(try await F.call(defs,"updates.install"),contains:"no downloaded update")
        let before = await fake.calls(); XCTAssertFalse(before.contains { $0["operation"].string == "installNow" })
        let tool = try XCTUnwrap(defs.first { $0.spec.id == "updates.install" }); XCTAssertEqual(tool.spec.tier,.alter); XCTAssertTrue(tool.spec.description.contains("connection drops and comes back"))
        await fake.setPhase("ready"); _ = try F.value(await F.call(defs,"updates.install")); let after = await fake.calls(); XCTAssertEqual(after.filter { $0["operation"].string == "installNow" }.count,1)
    }
    // TSCASE app-tools.test.ts:81
    func testAppL81NoUpdater() async throws {
        let fake = BackendDeckCoreTestPortToolsApplicationFake(); await fake.setUpdater(false)
        F.error(try await F.call(application(fake,.init()),"updates.status"),contains:"no updater")
    }
    // TSCASE app-tools.test.ts:88
    func testAppL88LogAndCallsSources() async throws {
        let fake = BackendDeckCoreTestPortToolsApplicationFake(),defs = try application(fake,.init())
        let app = try F.value(await F.call(defs,"app.log",#"{"lines":2}"#)),calls = try F.value(await F.call(defs,"app.log",#"{"source":"calls"}"#))
        XCTAssertEqual(app["source"],.string("app")); XCTAssertEqual(app["lines"],try F.json(#"["line 0","line 1"]"#)); XCTAssertEqual(calls["source"],.string("calls"))
    }
    // TSCASE app-tools.test.ts:95
    func testAppL95ClearsOnlyCalls() async throws {
        let fake = BackendDeckCoreTestPortToolsApplicationFake(); _ = try await F.call(application(fake,.init()),"app.clear_log",#"{"source":"calls"}"#)
        let names = await fake.calls().compactMap { $0["operation"].string }; XCTAssertTrue(names.contains("clearCalls")); XCTAssertFalse(names.contains("clearLog"))
    }
    // TSCASE app-tools.test.ts:104
    func testAppL104RevealRoutesLogsAndPlaceKey() async throws {
        let fake = BackendDeckCoreTestPortToolsApplicationFake(),defs = try application(fake,.init()); _ = try await F.call(defs,"app.reveal",#"{"place":"logs"}"#); _ = try await F.call(defs,"app.reveal",#"{"place":"settings"}"#)
        let calls = await fake.calls(); XCTAssertEqual(calls.filter { $0["operation"].string == "openLogFolder" }.count,1); XCTAssertEqual(calls.first { $0["operation"].string == "openPath" }?["args"],.array([.string("settings")]))
    }
    // TSCASE hook-tools.test.ts:23
    func testHooksL23CombinedStatus() async throws {
        let fake = BackendDeckCoreTestPortToolsApplicationFake(),value = try F.value(await F.call(hooks(fake,.init()),"hooks.status"))
        XCTAssertEqual(value["agents"].elements?.first,try F.json(#"{"id":"claude","label":"Claude Code","state":"complete","message":"Installed."}"#)); XCTAssertEqual(value["listener"]["running"],.bool(true)); XCTAssertEqual(value["offer"]["show"],.bool(false))
    }
    // TSCASE hook-tools.test.ts:29
    func testHooksL29SingleAndAllInstall() async throws {
        let fake = BackendDeckCoreTestPortToolsApplicationFake(),defs = try hooks(fake,.init()); _ = try await F.call(defs,"hooks.install",#"{"agent":"codex"}"#); _ = try await F.call(defs,"hooks.install",#"{"agent":"all"}"#)
        let calls = await fake.calls(); XCTAssertEqual(calls.first { $0["operation"].string == "install" }?["args"],.array([.string("codex")])); XCTAssertEqual(calls.filter { $0["operation"].string == "acceptOffer" }.count,1)
    }
    // TSCASE hook-tools.test.ts:40
    func testHooksL40ClosedProviderSetBeforeConsent() async throws {
        let fake = BackendDeckCoreTestPortToolsApplicationFake(),audit = BackendDeckCoreTestPortToolsAudit(),defs = try hooks(fake,audit)
        F.error(try await F.call(defs,"hooks.install",#"{"agent":"/etc/passwd"}"#),contains:"agent must be one of")
        F.error(try await F.call(defs,"hooks.remove",#"{"agent":"all"}"#),contains:"agent must be one of")
        let consent = await audit.consent(); XCTAssertTrue(consent.isEmpty)
    }
    // TSCASE hook-tools.test.ts:48
    func testHooksL48ModuleRefusalSentence() async throws {
        let fake = BackendDeckCoreTestPortToolsApplicationFake(); await fake.set("remove",try F.json(#"{"ok":false,"message":"settings.json is not valid JSON"}"#))
        F.error(try await F.call(hooks(fake,.init()),"hooks.remove",#"{"agent":"claude"}"#),contains:"not valid JSON")
    }
    // TSCASE hook-tools.test.ts:54
    func testHooksL54ExactTiers() throws {
        let defs = try hooks(.init(),.init()); XCTAssertEqual(["hooks.install","hooks.remove","hooks.sync"].map { id in defs.first { $0.spec.id == id }?.spec.tier },[.alter,.alter,.alter]); XCTAssertEqual(defs.first { $0.spec.id == "hooks.decline_offer" }?.spec.tier,.act)
    }
    // TSCASE voice-tools.test.ts:17
    func testVoiceL17CredentialUsedButRedactedFromResultConsentAndLog() async throws {
        let fake = BackendDeckCoreTestPortToolsApplicationFake(),audit = BackendDeckCoreTestPortToolsAudit(),args = #"{"provider":"groq","key":"gsk_live_secret_value"}"#
        let value = try F.value(await F.call(voice(fake,audit),"voice.save_key",args)),calls = await fake.calls(),consent = await audit.consent(),records = await audit.completed()
        XCTAssertEqual(calls.first { $0["operation"].string == "save" }?["args"],try F.json(#"["groq","gsk_live_secret_value"]"#)); XCTAssertFalse(value.compact.contains("gsk_live")); XCTAssertFalse(consent[0]["args"].compact.contains("gsk_live")); XCTAssertFalse(records[0]["args"].compact.contains("gsk_live")); XCTAssertEqual(consent[0]["sentence"],.string("Save a groq transcription key"))
    }
    // TSCASE voice-tools.test.ts:29
    func testVoiceL29RejectedCredentialNotSaved() async throws {
        let fake = BackendDeckCoreTestPortToolsApplicationFake(); await fake.set("save",try F.json(#"{"ok":false,"message":"Groq said the key is invalid."}"#))
        F.error(try await F.call(voice(fake,.init()),"voice.save_key",#"{"provider":"groq","key":"x"}"#),contains:"not saved: Groq said")
    }
    // TSCASE voice-tools.test.ts:37
    func testVoiceL37AudioBytesFilenameAndExactResult() async throws {
        let fake = BackendDeckCoreTestPortToolsApplicationFake(),audio = Data("RIFF....WAVE".utf8).base64EncodedString(),defs = try voice(fake,.init())
        let tool = try XCTUnwrap(defs.first { $0.spec.id == "voice.transcribe" }),reply = try await tool.handler(F.caller(),F.object([("audio",.string(audio)),("filename",.string("n.wav"))]))
        XCTAssertEqual(try F.value(reply),try F.json(#"{"text":"hello there","message":""}"#)); let calls = await fake.calls(); XCTAssertEqual(calls.first { $0["operation"].string == "transcribe" }?["args"],.array([.bytes(Data("RIFF....WAVE".utf8)),.string("n.wav")]))
    }
    // TSCASE voice-tools.test.ts:47
    func testVoiceL47BadAndOversizedAudioNeverUploadOrAsk() async throws {
        let fake = BackendDeckCoreTestPortToolsApplicationFake(),audit = BackendDeckCoreTestPortToolsAudit(),defs = try voice(fake,audit)
        F.error(try await F.call(defs,"voice.transcribe",#"{"audio":"not base64!"}"#),contains:"must be base64")
        let tool = try XCTUnwrap(defs.first { $0.spec.id == "voice.transcribe" }),big = String(repeating:"A",count:Int(ceil(Double(BackendDeckToolsAppVoice.maxAudioBytes)*4/3))+8)
        F.error(try await tool.handler(F.caller(),F.object([("audio",.string(big))])),contains:"larger than")
        let calls = await fake.calls(),consent = await audit.consent(); XCTAssertFalse(calls.contains { $0["operation"].string == "transcribe" }); XCTAssertTrue(consent.isEmpty)
    }
    // TSCASE voice-tools.test.ts:55
    func testVoiceL55ExactRecordingRedaction() { XCTAssertEqual(BackendDeckToolsAppKit.redacted("voice.transcribe",try! F.json(#"{"audio":"QUJD"}"#)),try! F.json(#"{"audio":"[4 base64 characters]"}"#)) }
    // TSCASE usage-tools.test.ts:21
    func testUsageL21SessionLimitsAndContext() async throws {
        let fake = BackendDeckCoreTestPortToolsApplicationFake(),value = try F.value(await F.call(usage(fake,.init()),"usage.read",#"{"sessionId":"theirs-1"}"#))
        XCTAssertEqual(value,try F.json(#"{"sessionId":"theirs-1","limits":{"sessionId":"theirs-1","readings":[]},"contextWindow":{"percent":40}}"#))
    }
    // TSCASE usage-tools.test.ts:27
    func testUsageL27OmittedSessionReadsAllLogins() async throws {
        let fake = BackendDeckCoreTestPortToolsApplicationFake(); _ = try await F.call(usage(fake,.init()),"usage.read"); let calls = await fake.calls(); XCTAssertEqual(calls.first { $0["operation"].string == "usageRead" }?["args"],.array([.null]))
    }
    // TSCASE usage-tools.test.ts:34
    func testUsageL34OnlyFolderTranscriptMayBeCosted() async throws {
        let fake = BackendDeckCoreTestPortToolsApplicationFake(),defs = try usage(fake,.init()); _ = try await F.call(defs,"usage.cost",#"{"projectPath":"/work/api","transcriptPath":"/store/api/a.jsonl"}"#)
        let calls = await fake.calls(); XCTAssertEqual(calls.first { $0["operation"].string == "sessionCost" }?["args"],.array([.string("/store/api/a.jsonl")]))
        F.error(try await F.call(defs,"usage.cost",#"{"projectPath":"/work/api","transcriptPath":"/store/other/z.jsonl"}"#),contains:"not one of /work/api’s transcripts")
    }
    // TSCASE usage-tools.test.ts:45
    func testUsageL45TranscriptCapAndTotal() async throws {
        let fake = BackendDeckCoreTestPortToolsApplicationFake(),value = try F.value(await F.call(usage(fake,.init()),"usage.cost",#"{"projectPath":"/work/api","limit":1}"#))
        XCTAssertEqual(value["transcripts"].elements?.map { $0["sessionId"] },[.string("a")]); XCTAssertEqual(value["totalTranscripts"],.number(2)); XCTAssertEqual(value["project"]["tokens"],.number(100))
    }
    // TSCASE setup-tools.test.ts:24
    func testSetupL24ScanOnlyOpenFolder() async throws { F.error(try await F.call(setup(.init(),.init()),"readiness.scan",#"{"projectPath":"/etc"}"#),contains:"not a folder this app has open") }
    // TSCASE setup-tools.test.ts:31
    func testSetupL31ApplyExactOfferedFix() async throws {
        let fake = BackendDeckCoreTestPortToolsApplicationFake(),value = try F.value(await F.call(setup(fake,.init()),"readiness.fix",#"{"projectPath":"/work/api","fixId":"create-gitignore"}"#)),calls = await fake.calls()
        XCTAssertEqual(calls.first { $0["operation"].string == "fix" }?["args"],try F.json(#"["/work/api","create-gitignore"]"#)); XCTAssertEqual(value["changed"],.array([.string(".gitignore")])); XCTAssertEqual(value["applied"],try F.json(#"{"id":"create-gitignore","label":"Create .gitignore","description":"Writes a .gitignore for this stack.","touches":[".gitignore"],"destructive":false}"#))
    }
    // TSCASE setup-tools.test.ts:39
    func testSetupL39UnofferedFixNeverApplied() async throws {
        let fake = BackendDeckCoreTestPortToolsApplicationFake(); F.error(try await F.call(setup(fake,.init()),"readiness.fix",#"{"projectPath":"/work/api","fixId":"create-readme"}"#),contains:"not offering create-readme"); let calls = await fake.calls(); XCTAssertFalse(calls.contains { $0["operation"].string == "fix" })
    }
    // TSCASE setup-tools.test.ts:48
    func testSetupL48UnknownFixBeforeConsent() async throws {
        let fake = BackendDeckCoreTestPortToolsApplicationFake(),audit = BackendDeckCoreTestPortToolsAudit(); F.error(try await F.call(setup(fake,audit),"readiness.fix",#"{"projectPath":"/work/api","fixId":"rm-rf"}"#),contains:"not a fix this version can apply"); let consent = await audit.consent(); XCTAssertTrue(consent.isEmpty)
    }
    // TSCASE github-tools.test.ts:45
    func testGitHubL45OpenProjectOrSessionFolderOnly() async throws {
        let fake = BackendDeckCoreTestPortToolsApplicationFake(),defs = try BackendDeckToolsAppGitHub.definitions(service:fake,access:F.access(.init()))
        _ = try F.value(await F.call(defs,"github.look",#"{"folder":"/work/site"}"#)); _ = try F.value(await F.call(defs,"github.look",#"{"folder":"/work/api"}"#)); F.error(try await F.call(defs,"github.look",#"{"folder":"/Users/someone/secret-repo"}"#),contains:"not a folder this app has open")
    }
    // TSCASE github-tools.test.ts:51
    func testGitHubL51CacheClearedBeforeRefresh() async throws {
        let fake = BackendDeckCoreTestPortToolsApplicationFake(),defs = try BackendDeckToolsAppGitHub.definitions(service:fake,access:F.access(.init())); _ = try await F.call(defs,"github.look",#"{"folder":"/work/site","refresh":true}"#)
        let names = await fake.calls().compactMap { $0["operation"].string }; XCTAssertLessThan(try XCTUnwrap(names.firstIndex(of:"clearCache")),try XCTUnwrap(names.firstIndex(of:"refresh"))); XCTAssertFalse(names.contains("overview"))
    }
    // TSCASE github-tools.test.ts:58
    func testGitHubL58ReadNeverLeaksPendingDeviceCode() async throws {
        let fake = BackendDeckCoreTestPortToolsApplicationFake(),defs = try BackendDeckToolsAppGitHub.definitions(service:fake,access:F.access(.init())); let value = try F.value(await F.call(defs,"github.look",#"{"folder":"/work/site"}"#)); XCTAssertFalse(value.compact.contains("WXYZ-1234"))
    }
    // TSCASE github-tools.test.ts:65
    func testGitHubL65StartingSignInReturnsCodeButLogDoesNot() async throws {
        let fake = BackendDeckCoreTestPortToolsApplicationFake(),audit = BackendDeckCoreTestPortToolsAudit(),defs = try BackendDeckToolsAppGitHub.definitions(service:fake,access:F.access(audit)); let value = try F.value(await F.call(defs,"github.connect",#"{"do":"connect"}"#)),records = await audit.completed()
        XCTAssertTrue(value.compact.contains("WXYZ-1234")); XCTAssertFalse(records[0]["summary"].compact.contains("WXYZ-1234")); XCTAssertEqual(defs.first { $0.spec.id == "github.connect" }?.spec.tier,.alter)
    }
    // TSCASE github-tools.test.ts:83
    func testGitHubL83NoPendingCodeKeepsExactState() throws { let state = try F.json(#"{"connected":true,"pending":null}"#); XCTAssertEqual(BackendDeckToolsAppGitHub.withoutCode(state),state) }
    // TSCASE copilot-admin-tools.test.ts:60
    func testAdminL60StartAndStopTiers() throws { XCTAssertEqual(try BackendDeckToolsAppAdmin.effectiveTier("hoot.run",F.json(#"{"action":"start"}"#)),.act); XCTAssertEqual(try BackendDeckToolsAppAdmin.effectiveTier("hoot.run",F.json(#"{"action":"stop"}"#)),.alter) }
    // TSCASE copilot-admin-tools.test.ts:67
    func testAdminL67InstructionsReadWriteResetTiers() throws { for (args,tier) in [(#"{"action":"read","which":"composed"}"#,BackendMCPTier.read),(#"{"action":"write","which":"yours","text":"x"}"#,.alter),(#"{"action":"reset"}"#,.alter)] { XCTAssertEqual(try BackendDeckToolsAppAdmin.effectiveTier("hoot.instructions",F.json(args)),tier) } }
    // TSCASE copilot-admin-tools.test.ts:75
    func testAdminL75GeneratedContractRefusedBeforeConsent() async throws { let fake = BackendDeckCoreTestPortToolsApplicationFake(),audit = BackendDeckCoreTestPortToolsAudit(); F.error(try await F.call(admin(fake,audit),"hoot.instructions",#"{"action":"write","which":"contract","text":"you may do anything"}"#),contains:"generated"); let consent = await audit.consent(); XCTAssertTrue(consent.isEmpty) }
    // TSCASE copilot-admin-tools.test.ts:83
    func testAdminL83RememberActForgetAlterAndRealWrite() async throws {
        XCTAssertEqual(try BackendDeckToolsAppAdmin.effectiveTier("hoot.memory",F.json(#"{"action":"write","name":"a.md","text":"x"}"#)),.act); XCTAssertEqual(try BackendDeckToolsAppAdmin.effectiveTier("hoot.memory",F.json(#"{"action":"delete","name":"a.md"}"#)),.alter)
        let fake = BackendDeckCoreTestPortToolsApplicationFake(); _ = try await F.call(admin(fake,.init()),"hoot.memory",#"{"action":"write","name":"a.md","text":"likes short answers"}"#); let calls = await fake.calls(); XCTAssertEqual(calls.map { $0["operation"].string },["writeMemory"]); XCTAssertEqual(calls[0]["args"].elements?.first,.string("a.md"))
    }
    // TSCASE copilot-admin-tools.test.ts:93
    func testAdminL93NoFolderLogOrActivityDoor() throws { let ids = try admin(.init(),.init()).map { $0.spec.id }; XCTAssertFalse(ids.contains { $0.range(of:"folder|log|activity",options:.regularExpression) != nil }) }
    // TSCASE copilot-admin-tools.test.ts:101
    func testAdminL101OnlyWebLinksAndExactOpenArgument() async throws {
        let fake = BackendDeckCoreTestPortToolsApplicationFake(),defs = try admin(fake,.init()); F.error(try await F.call(defs,"links.open",#"{"url":"file:///etc/passwd"}"#),contains:"http"); F.error(try await F.call(defs,"links.open",#"{"url":"javascript:alert(1)"}"#),contains:"http"); _ = try await F.call(defs,"links.open",#"{"url":"https://example.com/a"}"#); let calls = await fake.calls(); XCTAssertEqual(calls.map { $0["operation"].string },["openURL"]); XCTAssertEqual(calls[0]["args"],.array([.string("https://example.com/a")]))
    }
    // TSCASE copilot-admin-tools.test.ts:111
    func testAdminL111NotificationsReadAndMinutesToMilliseconds() async throws {
        XCTAssertEqual(try BackendDeckToolsAppAdmin.effectiveTier("notifications.status",.object([])),.read); XCTAssertEqual(try BackendDeckToolsAppAdmin.effectiveTier("notifications.status",F.json(#"{"openSettings":true}"#)),.act)
        let fake = BackendDeckCoreTestPortToolsApplicationFake(),value = try F.value(await F.call(admin(fake,.init()),"notifications.status",#"{"sinceMinutes":10}"#)); XCTAssertEqual(value["delivery"]["since"],.number(400_000)); let calls = await fake.calls(); XCTAssertFalse(calls.contains { $0["operation"].string == "openNotificationSettings" })
    }
    // TSCASE copilot-admin-tools.test.ts:122
    func testAdminL122ServerNotStartedIsSaid() async throws { let fake = BackendDeckCoreTestPortToolsApplicationFake(),value = try F.value(await F.call(admin(fake,.init()),"tools.status")); XCTAssertEqual(value["running"],.bool(false)) }
}
