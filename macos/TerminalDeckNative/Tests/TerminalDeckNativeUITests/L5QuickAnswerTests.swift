import Foundation
import Testing
import TerminalDeckNativeCore
@testable import TerminalDeckNative

/// Retest 11 Oct (M13b): the quick answers follow the question's wording, not its note refs.
@MainActor @Test
func L5QuickAnswersFitTheQuestion() {
    func q(_ text: String) -> DeckMemoryQuestion {
        DeckMemoryQuestion(id: 1, owner: .hoot, text: text, context: "", refs: ["a", "b"], askedAt: Date())
    }
    #expect(NativeMemoryTidyPart.quickAnswers(q("Is session cd7a1517 still running in TD-dev-test? If it has ended, should Hoot go ahead?")) == ["Yes", "No"])
    #expect(NativeMemoryTidyPart.quickAnswers(q("Two notes disagree: “staging first” and “ship straight to live”. Which one holds?")).first == "Keep the newer one")
    #expect(NativeMemoryTidyPart.quickAnswers(q("What should the release note say about the beta?")).isEmpty)
}
