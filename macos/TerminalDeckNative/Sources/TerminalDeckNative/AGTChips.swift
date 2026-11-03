import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// Shared shell tokens for agent cards.
typealias AGKITStyle = DeckTokens


/// A project's colour is a dot, never a tinted text background.
struct ProjectChip: View {
    let name: String
    let color: Color
    /// When set, the chip shows the project's logo (or its letter tile) instead of the colour dot.
    var project: PROJProject?
    var showsLogo = false

    init(_ name: String, color: Color) {
        self.name = name
        self.color = color
    }

    init(project: PROJProject?, name: String) {
        self.name = name
        self.color = .secondary
        self.project = project
        self.showsLogo = true
    }

    init(name: String, color: Color) {
        self.init(name, color: color)
    }

    var body: some View {
        HStack(spacing: 5) {
            Group {
                if showsLogo { ProjectLogoView(project: project, name: name, size: 12) }
                else { Circle().fill(color).frame(width: 8, height: 8) }
            }
            .accessibilityHidden(true)
            Text(name).font(.system(size: 11)).foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(AGKITStyle.selection, in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
    }
}

/// Status always includes a word so its meaning never depends on colour alone.
struct StatusLabel: View {
    enum State: String, CaseIterable, Sendable {
        case working, waiting, ready, paused, failed, idle

        var title: String {
            switch self {
            case .working: return "Working"
            case .waiting: return "Waiting for you"
            case .ready: return "Ready"
            case .paused: return "Paused"
            case .failed: return "Failed"
            case .idle: return "Idle"
            }
        }

        @MainActor var color: Color {
            switch self {
            case .working: return AGKITStyle.good
            case .waiting: return AGKITStyle.warn
            case .failed: return AGKITStyle.bad
            case .ready, .paused, .idle: return AGKITStyle.textTertiary
            }
        }
    }

    let state: State
    let text: String?
    let fontSize: CGFloat

    init(_ state: State, text: String? = nil, fontSize: CGFloat = 13) {
        self.state = state
        self.text = text
        self.fontSize = fontSize
    }

    var body: some View {
        HStack(spacing: 6) {
            if state == .paused {
                Circle().strokeBorder(state.color, lineWidth: 1.5)
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            } else {
                Circle().fill(state.color).frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
            Text(text ?? state.title)
                .font(.system(size: fontSize))
                .foregroundStyle(labelColor)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text ?? state.title)
    }

    private var labelColor: Color {
        switch state {
        case .working, .waiting, .failed: return state.color
        case .ready, .paused, .idle: return AGKITStyle.textSecondary
        }
    }
}

struct AGKITFilterItem<ID: Hashable>: Identifiable {
    let id: ID
    let title: String
    var count: Int?
    var dot: Color?

    init(id: ID, title: String, count: Int? = nil, dot: Color? = nil) {
        self.id = id
        self.title = title
        self.count = count
        self.dot = dot
    }
}

/// Neutral filter pills with a single selection and real button hit areas.
/// Horizontal overflow stays inside the component on a smaller window.
struct FilterChips<ID: Hashable>: View {
    typealias Item = AGKITFilterItem<ID>

    @Binding var selection: ID
    let items: [Item]

    init(selection: Binding<ID>, items: [Item]) {
        self._selection = selection
        self.items = items
    }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(items) { item in
                    Button { selection = item.id } label: {
                        HStack(spacing: 6) {
                            if let dot = item.dot {
                                Circle().fill(dot).frame(width: 7, height: 7)
                                    .accessibilityHidden(true)
                            }
                            Text(item.title)
                            if let count = item.count {
                                Text(count, format: .number)
                                    .foregroundStyle(isSelected(item) ?
                                                     AGKITStyle.page.opacity(0.72) :
                                                     AGKITStyle.textSecondary)
                                    .monospacedDigit()
                            }
                        }
                        .font(.system(size: 13))
                        .foregroundStyle(isSelected(item) ? AGKITStyle.page : AGKITStyle.textPrimary)
                        .padding(.horizontal, 12)
                        .frame(minWidth: 28, minHeight: 28)
                        .background(isSelected(item) ? AGKITStyle.textPrimary : Color.clear, in: Capsule())
                        .overlay(Capsule().strokeBorder(isSelected(item) ? Color.clear :
                                                      AGKITStyle.hairline, lineWidth: 1))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(item.title)
                    .accessibilityLabel(item.title)
                    .accessibilityValue(item.count.map(String.init) ?? "")
                    .accessibilityAddTraits(isSelected(item) ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.hidden)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func isSelected(_ item: Item) -> Bool { item.id == selection }
}
