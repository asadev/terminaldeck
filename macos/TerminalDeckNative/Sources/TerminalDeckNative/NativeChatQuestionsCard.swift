import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

struct NativeChatQuestionsCard: View {
    let request: NativeRPCValue
    let disabled: Bool
    let answer: (Bool, NativeRPCValue) -> Void
    @State private var selected: [String: Set<String>] = [:]
    @State private var text: [String: String] = [:]
    private var questions: [BackendChatQuestions.Question] { BackendChatQuestions.questions(request) }
    private var values: [String: [String]] {
        Dictionary(uniqueKeysWithValues: questions.map { question in
            let custom = (text[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let picks = question.options.filter { selected[question.id]?.contains($0.label) == true }.map(\.label)
            return (question.id, custom.isEmpty ? picks : question.multiple ? picks + [custom] : [custom])
        })
    }
    private var complete: Bool { !questions.isEmpty && questions.allSatisfy { !(values[$0.id] ?? []).isEmpty } }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(questions) { question in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(question.title).font(.headline)
                            Text(question.text).fixedSize(horizontal: false, vertical: true)
                            ForEach(question.options) { option in
                                Button {
                                    var picks = selected[question.id] ?? []
                                    if question.multiple {
                                        if picks.contains(option.label) { picks.remove(option.label) } else { picks.insert(option.label) }
                                    } else { picks = [option.label]; text[question.id] = "" }
                                    selected[question.id] = picks
                                } label: {
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: selected[question.id]?.contains(option.label) == true ? (question.multiple ? "checkmark.square.fill" : "largecircle.fill.circle") : (question.multiple ? "square" : "circle"))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(option.label)
                                            if !option.detail.isEmpty { Text(option.detail).font(.caption).foregroundStyle(.secondary) }
                                        }
                                        Spacer(minLength: 0)
                                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                            }
                            let binding = Binding(get: { text[question.id] ?? "" }, set: { text[question.id] = $0 })
                            if question.secret { SecureField("Your answer", text: binding).textFieldStyle(.roundedBorder) }
                            else { TextField("Your answer", text: binding, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...3) }
                        }
                    }
                }
            }.frame(height: min(280, CGFloat(max(1, questions.count) * 190)))
            HStack {
                Spacer()
                Button("Cancel") { answer(false, .object([])) }.buttonStyle(.bordered)
                Button("Submit answers") { answer(true, BackendChatQuestions.answers(request, values: values)) }
                    .buttonStyle(.borderedProminent).disabled(!complete)
            }
        }.font(.system(size: 12)).padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).disabled(disabled)
    }
}
