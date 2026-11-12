import SwiftUI
import TerminalDeckNativeCore

struct NativeChatPlanCard: View {
    let plan: String
    let disabled: Bool
    let answer: (String, String) -> Void
    @State private var revising = false
    @State private var feedback = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Plan review").font(.headline)
            ScrollView {
                NativeChatMarkdown(text: plan.isEmpty ? "The agent has not included a plan yet." : plan)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 240)
            if revising {
                NativeSessionTextField("What should change?", text: $feedback, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...4)
            }
            HStack {
                NativeSessionButton("Keep planning") { answer("continue", "") }.buttonStyle(.bordered)
                Spacer(minLength: 4)
                if revising {
                    NativeSessionButton("Send feedback") { answer("revise", feedback) }.buttonStyle(.borderedProminent)
                        .disabled(feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    NativeSessionButton("Revise") { revising = true }.buttonStyle(.bordered)
                    NativeSessionButton("Approve") { answer("approve", "") }.buttonStyle(.borderedProminent).disabled(plan.isEmpty)
                }
            }
        }.font(.system(size: 12)).padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).disabled(disabled)
    }
}
