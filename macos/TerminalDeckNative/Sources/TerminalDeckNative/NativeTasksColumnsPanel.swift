import SwiftUI
import TerminalDeckNativeCore

struct TasksColumnsPanel: View {
    let model: MyWorkModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Columns").font(.headline)
            Text("Drag a row to change the order. Drag a title edge in the list to resize.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(model.view.columns.order, id: \.self) { name in
                if let column = TasksColumns.all.first(where: { $0.name == name }) {
                    HStack {
                        Image(systemName: "line.3.horizontal").foregroundStyle(.secondary)
                        Toggle(column.label, isOn: Binding(get: { model.view.columns[keyPath: column.key] },
                            set: { model.view.columns[keyPath: column.key] = $0 }))
                            .toggleStyle(.checkbox)
                        Spacer()
                    }.padding(6).contentShape(Rectangle())
                        .draggable("tasks-column:" + name)
                        .dropDestination(for: String.self) { items, _ in
                            guard let token = items.first, token.hasPrefix("tasks-column:") else { return false }
                            let moving = String(token.dropFirst("tasks-column:".count))
                            guard moving != name, model.view.columns.order.contains(moving) else { return false }
                            let target = model.view.columns.order.firstIndex(of: name) ?? 0
                            var order = model.view.columns.order.filter { $0 != moving }
                            order.insert(moving, at: min(target, order.count))
                            model.view.columns.reorder(order)
                            return true
                        }
                        .contextMenu {
                            Button("Move up") { move(name, offset: -1) }
                            Button("Move down") { move(name, offset: 1) }
                        }
                }
            }
        }.padding(16).frame(width: 320)
    }
    private func move(_ name: String, offset: Int) {
        var order = model.view.columns.order
        guard let index = order.firstIndex(of: name), order.indices.contains(index + offset) else { return }
        order.swapAt(index, index + offset); model.view.columns.reorder(order)
    }
}
