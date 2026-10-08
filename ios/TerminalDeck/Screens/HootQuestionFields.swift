import SwiftUI

struct HootQuestionFields: View {
    let form: HootQuestionForm
    @Binding var values: [String: String]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let unsupported = form.unsupported { Text(unsupported).foregroundStyle(Theme.warning) }
            ForEach(form.fields) { field in
                VStack(alignment: .leading, spacing: 6) {
                    Text(field.label + (field.required ? " (required)" : "")).font(.headline)
                    if !field.detail.isEmpty { Text(field.detail).font(.footnote).foregroundStyle(Theme.secondary) }
                    let binding = Binding(get: { values[field.id] ?? "" }, set: { values[field.id] = $0 })
                    if field.kind == .boolean || !field.choices.isEmpty {
                        Picker(field.label, selection: binding) {
                            Text("Choose…").tag("")
                            if field.kind == .boolean { Text("Yes").tag("true"); Text("No").tag("false") }
                            else { ForEach(field.choices, id: \.self) { Text($0).tag($0) } }
                        }
                    } else if field.secret { SecureField(field.label, text: binding).textFieldStyle(.roundedBorder) }
                    else {
                        TextField(field.label, text: binding).textFieldStyle(.roundedBorder)
                            .keyboardType(field.kind == .string ? .default : .numbersAndPunctuation)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                }
                .accessibilityIdentifier("hoot.answer.\(field.id)")
            }
        }.padding(.vertical, 12)
    }
}
