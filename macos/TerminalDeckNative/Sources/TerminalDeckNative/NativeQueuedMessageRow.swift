import SwiftUI

struct NativeQueuedMessageRow: View {
    let model: NativeHootChatModel
    let item: NativeHootChatModel.QueuedMessage
    /// 29 Oct (Asad): in the conversation as a pending bubble of his own, not a card above the box.
    var bubble = false
    private var locked: Bool { model.steeringQueuedID != nil || model.sending || model.stopping }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if item.editing {
                TextField("Message", text: Binding(get: { model.queuedText(item.id) }, set: { model.setQueuedText(item.id, text: $0) }), axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...4)
                    .onSubmit { model.editQueued(item.id, editing: false) }
            } else {
                Text(item.draft.plainText.isEmpty ? "\(item.draft.attachments.count) attachments" : item.draft.plainText)
                    .foregroundStyle(.secondary).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let problem = item.problem { Text(problem).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 8) {
                Text(model.steeringQueuedID == item.id ? "Sending now..." : item.held ? "Needs attention" : "Queued")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Image(systemName: "line.3.horizontal").frame(width: 22, height: 22)
                    .draggable(item.id).help("Drag to reorder queued messages").opacity(locked ? 0.3 : 1)
                Spacer(minLength: 8)
                if item.editing {
                    Button { model.editQueued(item.id, editing: false) } label: { Image(systemName: "checkmark").frame(width: 22, height: 22) }
                        .help("Save queued message").accessibilityLabel("Save queued message").disabled(!item.draft.canSend)
                    Button { model.cancelQueuedEdit(item.id) } label: { Image(systemName: "arrow.uturn.backward").frame(width: 22, height: 22) }
                        .help("Cancel edit").accessibilityLabel("Cancel edit")
                } else {
                    Button("Send now", systemImage: "paperplane") { model.sendQueuedNow(item.id) }
                        .help("Deliver this queued message now").fixedSize().disabled(locked || item.held || model.readOnly || !model.acceptingMessages)
                    Button {
                        model.editQueued(item.id, editing: true)
                    } label: { Image(systemName: "pencil").frame(width: 22, height: 22) }
                        .help("Edit queued message").accessibilityLabel("Edit queued message").disabled(locked)
                }
                Button { model.removeQueued(item.id) } label: { Image(systemName: "xmark").frame(width: 22, height: 22) }
                    .help("Remove queued message").accessibilityLabel("Remove queued message").disabled(locked)
            }
            .buttonStyle(.borderless).controlSize(.small)
        }
        .font(.system(size: bubble ? 13 : 12)).padding(bubble ? 14 : 10)
        .frame(maxWidth: bubble ? 520 : .infinity, alignment: .leading)
        .background(bubble ? AnyShapeStyle(Color.accentColor.opacity(0.06)) : AnyShapeStyle(DeckTokens.card),
                    in: bubble ? AnyShape(UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 6, topTrailingRadius: 18))
                               : AnyShape(RoundedRectangle(cornerRadius: 8)))
        .overlay {
            if bubble {
                UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 18, bottomTrailingRadius: 6, topTrailingRadius: 18)
                    .strokeBorder(Color.accentColor.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
        .frame(maxWidth: bubble ? .infinity : nil, alignment: .trailing)
        .accessibilityIdentifier("chat.queued." + item.id)
        .dropDestination(for: String.self) { values, _ in
            guard !locked, let id = values.first else { return false }
            return model.moveQueued(id, before: item.id)
        }
    }
}
