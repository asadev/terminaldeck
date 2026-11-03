import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

struct Verify20LaunchRoutingTests {
    @Test func explicitTerminalKeepsModeAndConversationWhileDefaultChatStartsFreshJob() {
        let sender = BackendTeamChatSender(id: "lead", name: "Lead")
        var terminal = BackendCreateSessionInput(cwd: "/scratch", provider: "codex")
        terminal.chat = false; terminal.resume = true; terminal.resumeConversationId = "kept-conversation"
        terminal.projectId = "scratch"; terminal.profileId = "chosen-account"
        let kept = BackendCompositionProductionBindings.chatJobInput(terminal, sender: sender, title: "Work")
        #expect(kept == terminal)
        var chat = terminal; chat.chat = nil
        let job = BackendCompositionProductionBindings.chatJobInput(chat, sender: sender, title: "Work")
        #expect(job.chat == true && job.resume == false && job.resumeConversationId == nil)
        #expect(job.profileId == terminal.profileId && job.projectId == terminal.projectId)
        #expect(job.teamJob?.fromName == "Lead" && job.teamJob?.title == "Work")
        #expect(job.origin == .copilot)
    }
}
