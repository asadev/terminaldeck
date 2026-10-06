import Foundation
import Testing
@testable import TerminalDeckNativeCore

// Mirrors the wording tests in src/renderer/settings/sections/TasksSection.test.tsx.

private let AGENT = AgentProfile(id: "builder", name: "Builder", role: "builder", maxConcurrent: 1, maxRunMinutes: 0, keepAliveMinutes: 30)

private func connection(senders: [String] = [], folders: [String] = []) -> CrmConnection {
    CrmConnection(keyId: "k1", name: "Sales CRM", enabled: false, eventsUrl: nil, hasEventsSecret: false, statuses: DEFAULT_CRM_STATUSES,
                  hootIdentity: nil, identities: [:], identityOrder: [], allowedSenders: senders, folders: folders, maxHops: 3)
}

private let DOT = TasksKey(id: "k-dot", name: "Dot", crmOnly: false, lastApp: "ChatGPT")
private let OWN = TasksKey(id: "k-own", name: "Sales CRM (CRM)", crmOnly: true, lastApp: nil)

@Suite("Settings → Tasks — what it says")
struct TasksSettingsTextTests {
    @Test func sumsAnAgentUpInOnePlainLine() {
        #expect(TasksSettingsText.agentSummary(AGENT) == "Default coding agent · 1 at once · no time limit · stays open 30 min")
        var gemini = AGENT
        gemini.provider = "gemini"
        gemini.maxRunMinutes = 45
        gemini.keepAliveMinutes = 0
        #expect(TasksSettingsText.agentSummary(gemini) == "Gemini CLI · 1 at once · stops after 45 min · closes when done")
        var claude = AGENT
        claude.provider = "claude"
        claude.model = "opus"
        claude.effort = "high"
        #expect(TasksSettingsText.agentSummary(claude).hasPrefix("Claude Code (opus, high effort) · "))
    }

    @Test func sumsAConnectionUpInOnePlainLine() {
        #expect(TasksSettingsText.connectionSummary(connection()) == "nobody allowed to send work · no project folders")
        #expect(TasksSettingsText.connectionSummary(connection(senders: ["u-1"], folders: ["/a", "/b"])) == "1 allowed sender · 2 project folders")
    }

    @Test func namesAnAiAppsKeyAsOneSoACrmNeverBorrowsItBySurprise() {
        #expect(TasksSettingsText.keyOption(DOT) == "Dot — an AI-app key, used by ChatGPT")
        var unused = DOT
        unused.lastApp = nil
        #expect(TasksSettingsText.keyOption(unused) == "Dot — an AI-app key")
        #expect(TasksSettingsText.keyOption(OWN) == "Sales CRM (CRM) — a CRM key")
        #expect(TasksSettingsText.keyHelp(DOT).contains("sign in as that app"))
        #expect(TasksSettingsText.keyHelp(nil) == "Recommended. It can send tasks and nothing else, and you confirm before it is made.")
    }

    @Test func saysUnderEachConnectionWhichKeyItUses() {
        #expect(TasksSettingsText.keyLine(DOT, name: "Dot") == "Signs in with Dot, an AI app’s key")
        #expect(TasksSettingsText.keyLine(OWN, name: OWN.name) == "Signs in with its own key, Sales CRM (CRM)")
        #expect(TasksSettingsText.keyLine(nil, name: "a removed key") == "Signs in with a removed key")
    }

    @Test func theAppDefaultAndGeminiTakeInstructionsAsAdvice() {
        #expect(AgentCapabilities.support("gemini", .instructions).tag == "Advice only")
        #expect(AgentCapabilities.support(nil, .instructions).tag == "Advice only")
        #expect(TasksSettingsText.instructionsHelp(nil, file: nil)
            .contains("Choose Claude Code or Codex to have them given at the start as standing instructions."))
        // Limits stay enforced for the app default: a start on another agent is refused.
        #expect(AgentCapabilities.support(nil, .blockedTools).tag == "Enforced")
    }

    @Test func namesTheInstructionsFileOnceThereIsOne() {
        let file = "/Users/me/Library/Application Support/app/remote/agent-instructions/builder.md"
        #expect(TasksSettingsText.instructionsHelp("claude", file: file).hasSuffix("Kept in \(file); an edit made there is read back here."))
        #expect(TasksSettingsText.instructionsHelp("claude", file: nil).contains("Saved as a file of its own."))
        var claude = AGENT
        claude.provider = "claude"
        claude.instructions = "x"
        claude.instructionsFile = file
        #expect(TasksSettingsText.agentStackSummary(claude) == "Enforced: standing instructions")
        var gemini = claude
        gemini.provider = "gemini"
        #expect(TasksSettingsText.agentStackSummary(gemini) == "Told: instructions")
        var stacked = AGENT
        stacked.toolsPreferred = ["Read"]
        stacked.blockedTools = ["Bash", "Write"]
        stacked.skillsOff = true
        #expect(TasksSettingsText.agentStackSummary(stacked) == "Told: 1 preferred tool — Enforced: 2 tools blocked · skills off")
        #expect(TasksSettingsText.agentStackSummary(AGENT) == nil)
    }

    @Test func claudeCodesOwnToolsAreOfferedOnlyForClaudeCode() {
        #expect(TasksSettingsText.defaultTools("claude").first?.label == "Bash — Run commands")
        #expect(TasksSettingsText.defaultTools(nil).count == 12)
        #expect(TasksSettingsText.defaultTools("codex").isEmpty)
    }

    @Test func marksAPausedAgentAndSaysWhatPausingDoes() {
        #expect(TasksSettingsText.statusBadge(.paused) == "Paused")
        #expect(TasksSettingsText.statusLine(.paused, at: nil) == "Paused: takes no new work. What it is running carries on.")
        #expect(TasksSettingsText.statusLine(.archived, at: nil) == "Archived: kept, and offered nowhere until it is restored.")
        #expect(TasksSettingsText.statusLine(.active, at: nil) == nil)
        #expect(TasksSettingsText.statusLine(.paused, at: 1_790_000_000_000)?.hasPrefix("Paused since ") == true)
    }

    @Test func saysHowEachAgentKeepsEachSetting() {
        #expect(AgentCapabilities.how("claude", .blockedTools) == "Claude Code refuses these tools itself.")
        #expect(AgentCapabilities.how("codex", .model).hasPrefix("Not set for Codex by this app yet"))
        #expect(AgentCapabilities.how("shell", .model) == "A shell reads no brief and takes no agent settings.")
        #expect(AgentCapabilities.how("my-agent", .skillsOff) == "Not offered for an added agent.")
        #expect(TasksSettingsText.providerName(nil) == "Default coding agent")
        #expect(TasksSettingsText.providerName("my-agent") == "my-agent")
    }
}
