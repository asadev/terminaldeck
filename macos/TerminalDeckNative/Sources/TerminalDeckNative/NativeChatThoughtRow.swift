import SwiftUI
import TerminalDeckNativeCore

struct NativeChatThoughtRow: View {
    let thought: NativeRPCValue
    @State private var expanded = false
    private var title: String {
        if thought["live"].bool == true { return "Thinking..." }
        if let seconds = thought["seconds"].number { return "Thought for \(Int(seconds))s" }
        return "Thought"
    }
    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ScrollView {
                NativeChatMarkdown(text: thought["text"].string ?? "")
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
            }.frame(maxHeight: 260)
        } label: { Label(title, systemImage: "brain").foregroundStyle(.secondary) }
            .font(.system(size: 12)).help("Reasoning summary emitted by the model")
    }
}
