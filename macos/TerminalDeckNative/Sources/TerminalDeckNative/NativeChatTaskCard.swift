import SwiftUI
import TerminalDeckNativeCore

struct NativeChatTaskCard: View {
    struct Step: Identifiable {
        let id: String
        let text: String
        let state: String
        let running: Int
    }
    let todos: [NativeRPCValue]
    private var steps: [Step] {
        todos.enumerated().map { index, value in
            Step(id: value["id"].string ?? String(index), text: value["text"].string ?? "",
                state: value["state"].string ?? "next", running: Int(value["runningTasks"].number ?? 0))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: DeckTokens.Spacing.s8) {
            ForEach(steps) { step in
                HStack(alignment: .top, spacing: DeckTokens.Spacing.s8) {
                    status(step.state).frame(width: 14, height: 18)
                    VStack(alignment: .leading, spacing: DeckTokens.Spacing.s4) {
                        Text(step.text).foregroundStyle(step.state == "next" ? DeckTokens.textSecondary : DeckTokens.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        if step.state == "current", step.running > 0 {
                            Text("\(step.running) running task\(step.running == 1 ? "" : "s")")
                                .font(.system(size: 12)).foregroundStyle(DeckTokens.textSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                }.accessibilityElement(children: .combine)
            }
        }
        .font(.system(size: 13)).padding(DeckTokens.Spacing.s16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DeckTokens.taskCard, in: RoundedRectangle(cornerRadius: DeckTokens.Metrics.rowRadius))
        .overlay(RoundedRectangle(cornerRadius: DeckTokens.Metrics.rowRadius).stroke(DeckTokens.hairline, lineWidth: 1))
        .accessibilityIdentifier("chat-task-progress")
    }
    @ViewBuilder private func status(_ state: String) -> some View {
        switch state {
        case "done":
            ZStack {
                Circle().fill(DeckTokens.taskDone)
                Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(DeckTokens.taskDoneInk)
            }.frame(width: 13, height: 13).accessibilityLabel("Done")
        case "current": Image(systemName: "ellipsis.circle").font(.system(size: 13)).foregroundStyle(DeckTokens.textPrimary).accessibilityLabel("Running")
        default: Image(systemName: "circle.dashed").font(.system(size: 13)).foregroundStyle(DeckTokens.textTertiary).accessibilityLabel("Waiting")
        }
    }
}
