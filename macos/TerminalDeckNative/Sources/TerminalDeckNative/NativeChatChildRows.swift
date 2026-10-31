import SwiftUI
import TerminalDeckNativeCore

struct NativeChatChildRows: View {
    @Bindable var model: NativeHootChatModel
    /// 29 Oct (Asad): in the conversation, among the other steps, not pinned above the box.
    var inline = false
    private var tasks: [NativeRPCValue] { model.childTasks.filter { ChatChildTasks.running($0) || $0["status"].string == "stopping" } }
    var body: some View {
        if inline {
            rows.padding(.leading, 40).accessibilityIdentifier("chat.runningTasks")
        } else {
            ScrollView { rows.padding(.horizontal, 8) }.frame(height: min(180, CGFloat(tasks.count) * 54)).scrollBounceBehavior(.basedOnSize)
        }
    }
    private var rows: some View {
            VStack(spacing: 8) {
                ForEach(tasks, id: \.compact) { task in
                    HStack(spacing: 8) {
                        Image(systemName: task["kind"].string == "local_bash" ? "terminal" : "person.crop.circle").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task["title"].string ?? "Background task").font(.callout).lineLimit(2)
                            if let summary = task["summary"].string { Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        }
                        Spacer(minLength: 8)
                        if task["status"].string == "stopping" || model.stoppingChild == task["id"].string {
                            ProgressView().controlSize(.small).accessibilityLabel("Stopping task")
                        } else {
                            Button { if let id = task["id"].string { model.requestChildStop(id) } } label: { Image(systemName: "stop.fill").frame(width: 28, height: 28) }
                                .buttonStyle(.plain).help(task["limitation"].string ?? "Stop only this task").accessibilityLabel("Stop " + (task["title"].string ?? "background task"))
                                .disabled(model.stoppingChild != nil || model.readOnly || task["canStop"].bool == false)
                        }
                    }
                }
            }
    }
}
