import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// A2: compatibility entry point; the frame alone owns all five view modes.
struct AGTAgentsScreen: View {
    typealias Mode = AGFRAMEAgentsPage.Mode
    var mode: Mode? = nil
    var live = true
    var body: some View { AGFRAMEAgentsPage(mode: mode, live: live) }
}

/// One quiet line for a refused change; it goes when dismissed or on the next good change.
struct AGTMessageLine: View {
    let text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("Dismiss") { AGTAgentsStore.shared.message = nil }.buttonStyle(.borderless).controlSize(.small)
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - All agents

/// Plain-words time since, e.g. "5 min ago".
enum AGTTime {
    static func ago(_ ms: Double?, none: String = "No activity yet") -> String {
        guard let ms, ms > 0 else { return none }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: Date(timeIntervalSince1970: ms / 1000), relativeTo: AGTTime.now())
    }
    /// Renders pin the clock so pictures do not drift.
    nonisolated(unsafe) static var fixedNow: Date?
    static func now() -> Date { fixedNow ?? Date() }
}

/// Working spinner, the waiting hand (as the sidebar shows them), or a quiet word.
struct AGTStatusMark: View {
    let agent: AGTAgent
    var body: some View {
        HStack(spacing: 4) {
            switch agent.live {
            case .working?: ProgressView().controlSize(.mini)
            case .waiting?: Image(systemName: "hand.raised.fill").font(.caption).foregroundStyle(.orange)
            default: EmptyView()
            }
            Text(agent.statusLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Color.primary.opacity(0.05), in: Capsule())
        .fixedSize()
    }
}

/// Who an agent reports to, in words.
@MainActor
func agtReportsLine(_ agent: AGTAgent, short: Bool = false) -> String {
    if agent.kind == .session { return short ? "—" : "Live session, no profile" }
    guard let boss = agent.reportsTo else {
        let reports = AGTAgentsStore.shared.agents.filter { $0.reportsTo == agent.id }.count
        return reports > 0 ? "Leads \(reports)" : "Independent"
    }
    return (short ? "" : "Reports to ") + (AGTAgentsStore.shared.agent(boss)?.name ?? boss)
}

/// What it is doing now, in one line.
func agtNowLine(_ agent: AGTAgent) -> String {
    if let title = agent.taskTitle, agent.live == .working || agent.live == .waiting || agent.live == .queued {
        return "\(agent.activity) · \(title)"
    }
    if agent.live == nil, let title = agent.taskTitle { return "\(agent.activity) · last: \(title)" }
    return agent.activity
}
