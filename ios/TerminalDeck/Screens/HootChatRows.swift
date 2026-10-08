import SwiftUI

struct HootChatRows: View {
    let stream: HootEventStream

    var body: some View {
        ForEach(stream.items) { item in
            Group {
                switch item.kind {
                case .toolCall, .toolResult:
                    DisclosureGroup {
                        if let input = item.input { Text(input).font(.caption.monospaced()).textSelection(.enabled) }
                        Text(item.text).font(.callout).textSelection(.enabled)
                    } label: {
                        Label(item.name ?? "Tool step", systemImage: item.failed ? "exclamationmark.circle" : item.kind == .toolCall ? "gearshape" : "checkmark.circle")
                            .font(.callout).foregroundStyle(item.failed ? Theme.warning : Theme.secondary)
                            .frame(minHeight: 44)
                    }
                case .approval:
                    Label("Hoot is waiting for you", systemImage: "hand.raised")
                        .font(.callout).foregroundStyle(Theme.secondary)
                    Text(item.text).font(.callout)
                case .error:
                    Label(item.text.isEmpty ? "Hoot could not finish that turn." : item.text, systemImage: "exclamationmark.circle")
                        .foregroundStyle(Theme.warning).textSelection(.enabled)
                default:
                    Text(item.text)
                        .font(.body).foregroundStyle(Theme.primary)
                        .textSelection(.enabled)
                        .padding(12)
                        .background(item.kind == .user ? Theme.surface : Theme.background,
                                    in: RoundedRectangle(cornerRadius: 16))
                        .frame(maxWidth: .infinity, alignment: item.kind == .user ? .trailing : .leading)
                }
            }
            .accessibilityIdentifier("hoot.event.\(item.id)")
        }
        if stream.needsReplay {
            Label("Catching up with Hoot…", systemImage: "arrow.clockwise")
                .font(.footnote).foregroundStyle(Theme.secondary)
        }
    }
}
