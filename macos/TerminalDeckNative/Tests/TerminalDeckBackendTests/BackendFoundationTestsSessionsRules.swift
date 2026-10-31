import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

@Suite("Foundation: inherited session environment")
struct BackendFoundationTestsSessionsEnvironment {
    let inherited = ["CLAUDECODE": "1", "CLAUDE_AGENT_SDK_VERSION": "0.4.2", "CLAUDE_CODE_CHILD_SESSION": "1", "CLAUDE_CODE_DISABLE_CRON": "1", "CLAUDE_CODE_EAGER_FLUSH": "1", "CLAUDE_CODE_ENTRYPOINT": "cli", "CLAUDE_CODE_EXECPATH": "/usr/local/bin/claude", "CLAUDE_CODE_HOST_SESSION_ID": "abc-123", "CLAUDE_CODE_SESSION_ID": "def-456", "CLAUDE_EFFORT": "xhigh", "CLAUDE_PID": "4242", "CLAUDE_PREVIEW_CLASSIFIER_FLOOR": "0.5", "ANTHROPIC_API_KEY": "sk-ant-not-a-real-key", "ANTHROPIC_BASE_URL": "https://api.anthropic.com", "CLAUDE_CONFIG_DIR": "/Users/x/.claude-work", "PATH": "/usr/bin", "HOME": "/Users/x"]
    // TS session-env.test.ts:33
    @Test func childSessionMarkerRemoved() { #expect(BackendSessionEnvironment.stripInherited(inherited)["CLAUDE_CODE_CHILD_SESSION"] == nil) }
    // TS session-env.test.ts:39
    @Test func parentRunMarkersRemoved() {
        let clean = BackendSessionEnvironment.stripInherited(inherited)
        #expect(clean.keys.filter { $0.range(of: "^(CLAUDECODE|CLAUDE_PID|CLAUDE_CODE_|CLAUDE_AGENT_SDK|CLAUDE_PREVIEW_)", options: .regularExpression) != nil && $0 != "CLAUDE_CONFIG_DIR" }.isEmpty)
    }
    // TS session-env.test.ts:44
    @Test func effortPinRemoved() { #expect(BackendSessionEnvironment.stripInherited(inherited)["CLAUDE_EFFORT"] == nil) }
    // TS session-env.test.ts:51
    @Test func deliberateConfigDirectoryKept() { #expect(BackendSessionEnvironment.stripInherited(inherited)["CLAUDE_CONFIG_DIR"] == "/Users/x/.claude-work") }
    // TS session-env.test.ts:55
    @Test func anthropicConfigurationKept() {
        let clean = BackendSessionEnvironment.stripInherited(inherited)
        #expect(clean["ANTHROPIC_API_KEY"] == "sk-ant-not-a-real-key"); #expect(clean["ANTHROPIC_BASE_URL"] == "https://api.anthropic.com")
    }
    // TS session-env.test.ts:60
    @Test func unrelatedEnvironmentKept() {
        let clean = BackendSessionEnvironment.stripInherited(inherited)
        #expect(clean["PATH"] == "/usr/bin"); #expect(clean["HOME"] == "/Users/x")
    }
    // TS session-env.test.ts:65
    @Test func outerSessionMarkerRemoved() {
        let clean = BackendSessionEnvironment.stripInherited(["TERMINALDECK_SESSION_ID": "outer", "HOME": "/Users/x"])
        #expect(clean["TERMINALDECK_SESSION_ID"] == nil); #expect(clean["HOME"] == "/Users/x")
    }
}

@Suite("Foundation: viewport status classifier")
struct BackendFoundationTestsSessionsActivity {
    // TS session-activity.test.ts:15
    @Test func workingAgentDetected() { #expect(BackendSessionClassifier.classify(viewport: "\u{1b}[2m✻ Thinking… (12s · esc to interrupt)\u{1b}[0m") == .working) }
    // TS session-activity.test.ts:19
    @Test func promptBoxWaiting() { #expect(BackendSessionClassifier.classify(viewport: "╭────────────╮\n│ >          │\n╰────────────╯") == .waiting) }
    // TS session-activity.test.ts:23
    @Test func yesNoNeedsInput() { #expect(BackendSessionClassifier.classify(viewport: "Do you want to proceed? (y/n)") == .input) }
    // TS session-activity.test.ts:27
    @Test func numberedChoiceNeedsInput() { #expect(BackendSessionClassifier.classify(viewport: "Select an option:\n❯ 1. Yes\n  2. No") == .input) }
    // TS session-activity.test.ts:31
    @Test func shellPromptWaiting() { #expect(BackendSessionClassifier.classify(viewport: "apple@Mac ~ % ") == .waiting) }
    // TS session-activity.test.ts:35
    @Test func plainOutputIdle() { #expect(BackendSessionClassifier.classify(viewport: "some build output here\ndone.") == .idle) }
    // TS session-activity.test.ts:39
    @Test func exitOverridesEverything() { #expect(BackendSessionClassifier.classify(viewport: "anything at all", exited: true) == .exited) }
    // TS session-activity.test.ts:43
    @Test func spinnerOverridesOldPrompt() { #expect(BackendSessionClassifier.classify(viewport: "│ > │\n✻ Thinking… (3s · esc to interrupt)") == .working) }
    // TS session-activity.test.ts:52
    @Test func answeredQuestionReturnsToWaiting() { #expect(BackendSessionClassifier.classify(viewport: "% echo \"Do you want to continue? (y/n)\"\nDo you want to continue? (y/n)\napple@Mac ~ % ") == .waiting) }
    // TS session-activity.test.ts:61
    @Test func lastQuestionStillBlocks() { #expect(BackendSessionClassifier.classify(viewport: "Writing files…\nDo you want to proceed? (y/n)") == .input) }
    // TS session-activity.test.ts:71
    @Test func realClaudePromptWaiting() {
        #expect(BackendSessionClassifier.classify(viewport: "╰──────────────────────────────────────────────────────╯\n\n        ✦ ultracode · xhigh effort + dynamic workflows\n─────────────────────────────────────────── ultracode ─\n❯ \n───────────────────────────────────────────────────────\n\n  ⏵⏵ bypass permissions on (shift+tab to cycle)") == .waiting)
    }
    // TS session-activity.test.ts:85
    @Test func realTrustFolderNeedsInput() {
        #expect(BackendSessionClassifier.classify(viewport: "Accessing workspace:\n\n/Users/apple/Projects/terminaldeck\n\nClaude Code will be able to read, edit, and execute files here.\n\n❯ 1. Yes, I trust this folder\n  2. No, exit\n\nEnter to confirm · Esc to cancel") == .input)
    }
    // TS agent-controls.test.ts:572 — classifier half; the controls owner ports readComposer.
    @Test func fullscreenCounterStillClassifiesEmptyComposerAsWaiting() {
        let working = "⏺ Sleeping for 25 seconds\n  ⎿  $ sleep 25\n\n✶ Dilly-dallying… (5s · ↓ 90 tokens)\n\n─────── Update Claude Code terminal to new version ──\n❯ \n──────\n  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents"
        #expect(BackendSessionClassifier.classify(viewport: working) == .waiting)
    }
}

@Suite("Foundation: exact conversation recovery file fixtures")
struct BackendFoundationTestsSessionsRecovery {
    private func recover(_ files: [(String, Double, String)], claimed: Set<String> = []) throws -> String? {
        let scratch = try BackendFoundationTestsSessionsScratch()
        for (id, at, body) in files { try scratch.modified(scratch.write(id + ".jsonl", body), milliseconds: at) }
        return try BackendConversationRecovery.read(directories: [scratch.root], startedAt: Date(timeIntervalSince1970: 1000), claimed: claimed)
    }
    // TS conversation-id.test.ts:28
    @Test func oneConversationWrittenSinceStart() throws { #expect(try recover([("older", 940000, "{\"type\":\"user\"}\n"), ("mine", 1005000, "{\"type\":\"user\"}\n")]) == "mine") }
    // TS conversation-id.test.ts:35
    @Test func claimedLiveConversationExcluded() throws { #expect(try recover([("mine", 1001000, "{\"type\":\"user\"}\n"), ("theirs", 1005000, "{\"type\":\"user\"}\n")], claimed: ["theirs"]) == "mine") }
    // TS conversation-id.test.ts:42
    @Test func twoMovingConversationsNeverGuessed() throws { #expect(try recover([("a", 1001000, "{\"type\":\"user\"}\n"), ("b", 1002000, "{\"type\":\"user\"}\n")]) == nil) }
    // TS conversation-id.test.ts:49
    @Test func newestNonemptyPriorConversationSelected() throws { #expect(try recover([("newest-then", 995000, "{\"type\":\"user\"}\n"), ("older", 940000, "{\"type\":\"user\"}\n"), ("empty", 999000, "")]) == "newest-then") }
}

@Suite("Foundation: one-conversation.ts spawn guard")
struct BackendFoundationTestsSessionsConversationGuard {
    typealias F = BackendFoundationTestsSessionsFixtures
    private func selection(_ live: [BackendSessionMeta] = [], cwd: String = "/w/app", resume: Bool = true,
                           replaces: String? = nil, provider: String = "claude", args: [String] = [], resumeArgs: [String] = ["--continue"]) throws -> BackendConversationLaunch.Selection {
        var input = BackendCreateSessionInput(cwd: cwd, provider: provider); input.resume = resume; input.replaces = replaces
        return try BackendConversationLaunch.arguments(input, provider: .init(id: provider, command: provider, args: args, resumeArgs: resumeArgs), live: live, makeID: { F.conversation })
    }
    // TS one-conversation.test.ts:34
    @Test func emptyFolderNotHeld() throws { #expect(try selection().resumed) }
    // TS one-conversation.test.ts:38
    @Test func liveSameFolderHeld() throws { #expect(try !selection([F.meta("s")]).resumed) }
    // TS one-conversation.test.ts:42
    @Test func neighboringFolderNotHeld() throws { #expect(try selection([F.meta("s", cwd: "/w/other")]).resumed) }
    // TS one-conversation.test.ts:48
    @Test func exitedSessionNotHeld() throws { #expect(try selection([F.meta("s", exited: true)]).resumed) }
    // TS one-conversation.test.ts:58
    @Test func otherProviderNotHeld() throws { #expect(try selection([F.meta("s", provider: "codex")]).resumed) }
    // TS one-conversation.test.ts:65 — POSIX expectations; Windows path assertion not applicable on Mac.
    @Test func trailingSlashIgnored() throws {
        #expect(try !selection([F.meta("s", cwd: "/w/app/")]).resumed)
        #expect(try !selection([F.meta("s")], cwd: "/w/app/").resumed)
    }
    // TS one-conversation.test.ts:74
    @Test func holderFoundAmongMany() throws { #expect(try !selection([F.meta("one", cwd: "/w/one"), F.meta("dead", exited: true), F.meta("two", cwd: "/w/two"), F.meta("holder")]).resumed) }
    // TS one-conversation.test.ts:88
    @Test func freeFolderGetsContinueArguments() throws { #expect(try selection().arguments == ["--continue"]) }
    // TS one-conversation.test.ts:92 (argsForSpawn's answer; the launch adds `--session-id` after it, as host-core does)
    @Test func busyFolderGetsPlainArguments() throws { #expect(try selection([F.meta("s")]).arguments == []) }
    // TS one-conversation.test.ts:98
    @Test func noResumeRequestGetsPlainArguments() throws { #expect(try selection(resume: false).arguments == []) }
    // TS one-conversation.test.ts:102
    @Test func noResumeFlagGetsProviderPlainArguments() throws { #expect(try selection(provider: "custom:fixture", args: ["--interactive"], resumeArgs: []).arguments == ["--interactive"]) }
    // TS one-conversation.test.ts:114
    @Test func aliasedBusyFolderGetsPlainArguments() throws { #expect(try selection([F.meta("s", cwd: "/w/app/")]).arguments == []) }
    // TS one-conversation.test.ts:131
    @Test func outgoingSessionExemptForReplacement() throws { #expect(try selection([F.meta("s")], replaces: "s").resumed) }
    // TS one-conversation.test.ts:136
    @Test func thirdSessionStillHoldsConversation() throws { #expect(try !selection([F.meta("s"), F.meta("other")], replaces: "s").resumed) }
    // TS one-conversation.test.ts:144
    @Test func replacementGetsContinueArguments() throws { #expect(try selection([F.meta("s")], replaces: "s").arguments == ["--continue"]) }
    // TS one-conversation.test.ts:159
    @Test func replacementWithThirdTabGetsPlainArguments() throws { #expect(try selection([F.meta("s"), F.meta("other")], replaces: "s").arguments == []) }
    // TS one-conversation.test.ts:174
    @Test func ordinarySpawnStillHeld() throws {
        #expect(try !selection([F.meta("s")]).resumed)
        #expect(try !selection([F.meta("s")], replaces: nil).resumed)
    }
    // TS session-resume-args.test.ts:118
    @Test func namedPOSIXResumeOnlyJoinsConversation() throws {
        var input = BackendCreateSessionInput(cwd: "/w/app", provider: "claude"); input.resume = true; input.resumeConversationId = "8b1a1a48-14a6-41de-a773-022597c6b96c"
        let provider = BackendProviderSpec(id: "claude", command: "claude", args: [], resumeArgs: ["--continue"])
        let chosen = try BackendConversationLaunch.arguments(input, provider: provider, live: [])
        #expect(provider.command == "claude"); #expect(chosen.arguments == ["--resume", "8b1a1a48-14a6-41de-a773-022597c6b96c"]); #expect(!chosen.arguments.contains("--session-id"))
    }
    // TS session-resume-args.test.ts:147
    @Test func freshConversationNeverAlsoResumed() throws {
        let chosen = try selection(resume: false)
        #expect(!chosen.arguments.contains("--resume")); #expect(!chosen.arguments.contains("--continue"))
    }
    // TS session-switch-reliability.test.ts:229
    @Test func namedResumeHeldOnlyByExactConversation() throws {
        let id = "8b1a1a48-14a6-41de-a773-022597c6b96c"
        var input = BackendCreateSessionInput(cwd: "/w/app", provider: "claude"); input.resume = true; input.resumeConversationId = id
        let provider = BackendProviderSpec(id: "claude", command: "claude", args: [], resumeArgs: ["--continue"])
        #expect(try BackendConversationLaunch.arguments(input, provider: provider, live: [F.meta("other", conversation: "another")]).arguments == ["--resume", id])
        // argsForSpawn answers the plain arguments; the launch itself then refuses (host-core.ts `named && chosen !== resumeArgs`).
        #expect(try BackendConversationLaunch.arguments(input, provider: provider, live: [F.meta("other", conversation: id)]).arguments == [])
    }
}
