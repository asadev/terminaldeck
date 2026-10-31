import SwiftUI
import TerminalDeckBackend

struct NativeChatDiffCard: View {
    let card: BackendChatDiffs.Card
    @State private var expanded = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "doc.text")
                    Text((card.path as NSString).lastPathComponent).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if card.known {
                        Text("+\(card.plus)").foregroundStyle(.green).monospacedDigit()
                        Text("-\(card.minus)").foregroundStyle(.red).monospacedDigit()
                    }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help(card.path)
            if expanded {
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(card.lines.prefix(300).enumerated()), id: \.offset) { _, line in
                            HStack(alignment: .top, spacing: 8) {
                                Text(line.kind.mark).frame(width: 12)
                                Text(line.text.isEmpty ? " " : line.text).textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(line.kind == .add ? Color.green : line.kind == .del ? Color.red : Color.primary)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(line.kind == .add ? Color.green.opacity(0.08) : line.kind == .del ? Color.red.opacity(0.08) : Color.clear)
                        }
                    }.fixedSize(horizontal: true, vertical: false)
                }.frame(maxHeight: 260)
                if !card.known { Text("Before version unavailable").foregroundStyle(.secondary) }
                if card.truncated { Text("Preview truncated").foregroundStyle(.secondary) }
            }
        }.font(.system(size: 12)).padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }
}
