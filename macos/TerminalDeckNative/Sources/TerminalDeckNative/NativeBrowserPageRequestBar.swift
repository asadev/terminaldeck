import SwiftUI

/// The page's own status line, below its chrome. It never opens or focuses a window.
struct NativeBrowserPageRequestBar: View {
    let tab: NativeBrowserTab
    var body: some View {
        if let line = tab.pageRequests.line {
            HStack {
                Text(line).font(.callout).textSelection(.enabled)
                Spacer(minLength: DeckTokens.Spacing.s4)
                Button(tab.pageRequests.questions.isEmpty ? "Dismiss" : "Review") { tab.pageRequests.review() }
                    .disabled(!tab.pageRequests.canReview)
            }
            .padding(DeckTokens.Spacing.s8)
            .background(.quaternary)
            .accessibilityElement(children: .contain)
        }
    }
}
