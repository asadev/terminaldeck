import AppKit
import SwiftUI
import Testing
@testable import TerminalDeckNative

@MainActor @Suite struct TaskSharedPresentationTests {
    @Test func agentAndRoutineCardsUseShellSurfaces() {
        #expect(AGKITStyle.card == DeckTokens.card)
        #expect(AGKITStyle.hairline == DeckTokens.hairline)
        #expect(AWStyle.cardHover == DeckTokens.cardHover)
        #expect(AWStyle.hairline == DeckTokens.hairline)
        #expect(ROUTINESKit.card == DeckTokens.card)
        #expect(ROUTINESKit.selection == DeckTokens.selection)
        #expect(DeckTokens.projectColourNS("slate") == DeckTokens.projectColourNS("blue"))
        #expect(DeckTokens.projectColourNS("rose") == DeckTokens.projectColourNS("pink"))
    }
    @Test func sharedFlowWrapsAtTheProposedWidth() {
        let view = TasksFlow(spacing: 4, lineSpacing: 6) {
            Color.clear.frame(width: 40, height: 20)
            Color.clear.frame(width: 40, height: 30)
            Color.clear.frame(width: 40, height: 10)
        }.frame(width: 90)
        let host = NSHostingView(rootView: view)
        #expect(host.fittingSize.width == 90)
        #expect(host.fittingSize.height == 46)
    }
}
