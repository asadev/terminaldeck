import AppKit
import SwiftUI
import TerminalDeckNativeCore

// Shared agent avatar.
typealias ROUTINESAgentAvatar = AgentAvatar

/// Routine views use the shared shell surfaces and project colours.
@MainActor
enum ROUTINESKit {
    static let page = DeckTokens.page
    static let card = DeckTokens.card
    static let selection = DeckTokens.selection
    static let switchOn = DeckTokens.switchOn
    static let good = DeckTokens.good
    static let warn = DeckTokens.warn
    static let bad = DeckTokens.bad
    static func projectColor(_ id: String?) -> Color {
        guard let id, id != "every-project" else { return .orange }
        return Color(nsColor: DeckTokens.projectColourNS(NativePROJLabels.shared.projects.first { $0.id == id }?.colour ?? "graphite"))
    }
    static func avatar(agentID: String, size: CGFloat = 22) -> some View {
        let agent = AGTAgentsStore.shared.agents.first { $0.id == agentID || $0.profileID == agentID }
        let hoot = agentID == "@hoot" || agent?.isHoot == true
        return ROUTINESAgentAvatar(icon: agent?.icon ?? .symbol("person"), size: size, hoot: hoot,
                                   id: agent.map { $0.profileID ?? $0.id } ?? agentID, colour: agent?.iconColour)
    }
}

struct ROUTINESNotice: View {
    enum Tone { case info, warn, error }
    let tone: Tone
    let text: String
    var body: some View {
        NativeCodingAINotice(tone: tone == .info ? .info : tone == .warn ? .warn : .error, text: text)
    }
}

struct ROUTINESCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content.frame(maxWidth: .infinity, alignment: .leading)
            .background(ROUTINESKit.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DeckTokens.hairline, lineWidth: 0.5))
    }
}
