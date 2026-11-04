import SwiftUI
import TerminalDeckNativeCore

extension NativeHootChatModel {
    var runningTasks: [NativeRPCValue] {
        guard !readOnly, alive else { return [] }
        return childTasks.filter { ChatChildTasks.running($0) || $0["status"].string == "stopping" }
    }
    func runningTasksTool(_ action: String, request: String?) async throws -> NativeRPCValue {
        if action == "open" { runningTasksExpanded = !runningTasks.isEmpty }
        if action == "close" { runningTasksExpanded = false }
        if action == "output" {
            guard let request else { throw NativeRPCError.invalidArguments("Choose a running task.") }
            return try await runningTaskOutput(request)
        }
        if action == "stop" {
            guard let request, let task = runningTasks.first(where: { $0["id"].string == request }), task["canStop"].bool != false else {
                throw NativeRPCError.invalidArguments("Choose a running task with its own Stop.")
            }
            _ = try await stopChild(request)
        }
        return .object([.init("items", .array(runningTasks)), .init("count", .number(Double(runningTasks.count))),
            .init("expanded", .bool(!runningTasks.isEmpty && runningTasksExpanded)), .init("source", .string("provider-events"))])
    }
}

/// The only place to stop an individual background task. It never scrolls away with the transcript.
struct NativeChatChildRows: View {
    @Bindable var model: NativeHootChatModel
    @State private var outputTask: String?
    @State private var output: String?
    @State private var readingOutput = false
    private var tasks: [NativeRPCValue] { model.runningTasks }
    var body: some View {
        if !tasks.isEmpty {
            VStack(alignment: .leading, spacing: DeckTokens.Spacing.s8) {
                Button { model.runningTasksExpanded.toggle() } label: {
                    HStack(spacing: DeckTokens.Spacing.s8) {
                        Text("\(tasks.count) running").monospacedDigit()
                        Image(systemName: model.runningTasksExpanded ? "chevron.up" : "chevron.down").font(.caption)
                    }
                    .padding(.horizontal, DeckTokens.Spacing.s12).padding(.vertical, DeckTokens.Spacing.s8)
                    .background(DeckTokens.cardHover, in: Capsule())
                }
                .buttonStyle(.plain).font(DeckTokens.Typography.callout)
                .help(model.runningTasksExpanded ? "Hide running tasks" : "Show running tasks")
                .accessibilityIdentifier("chat.runningTasks.toggle")
                .accessibilityValue(model.runningTasksExpanded ? "Expanded" : "Collapsed")
                if model.runningTasksExpanded {
                    ScrollView {
                        VStack(spacing: DeckTokens.Spacing.s12) {
                            ForEach(tasks, id: \.selfID) { task in row(task) }
                            if let outputTask, tasks.contains(where: { $0["id"].string == outputTask }) {
                                if readingOutput { ProgressView("Reading task output…").controlSize(.small) }
                                if let output { Text(output).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                            }
                        }
                        .padding(DeckTokens.Spacing.s12)
                    }
                    .frame(height: min(200, CGFloat(tasks.count) * 72))
                    .scrollBounceBehavior(.basedOnSize)
                    .background(DeckTokens.cardHover, in: RoundedRectangle(cornerRadius: DeckTokens.Metrics.rowRadius))
                    .accessibilityIdentifier("chat.runningTasks.list")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: tasks.isEmpty) { _, empty in if empty { model.runningTasksExpanded = false } }
            .accessibilityIdentifier("chat.runningTasks")
        }
    }
    private func row(_ task: NativeRPCValue) -> some View {
        let id = task["id"].string ?? ""
        return HStack(spacing: DeckTokens.Spacing.s8) {
            Image(systemName: ["local_bash", "shell"].contains(task["kind"].string ?? "") ? "terminal" : "person.crop.circle")
                .foregroundStyle(.secondary).frame(width: DeckTokens.Metrics.iconColumn)
            VStack(alignment: .leading, spacing: DeckTokens.Spacing.s4) {
                Text(task["title"].string ?? "Background task").font(.callout).lineLimit(2)
                HStack(spacing: DeckTokens.Spacing.s8) {
                    if let since = task["startedAt"].number, since.isFinite, since > 0, since <= Date().timeIntervalSince1970 * 1000 {
                        Text(Date(timeIntervalSince1970: since / 1000), style: .timer).monospacedDigit()
                    }
                    if task["canStop"].bool == false { Text("No separate Stop").help(task["limitation"].string ?? "No separate Stop is available") }
                    else if let summary = task["summary"].string { Text(summary).lineLimit(1) }
                }.font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if model.reportedChatProvider == "claude" {
                Button("Output") {
                    outputTask = id; output = nil; readingOutput = true
                    Task {
                        defer { readingOutput = false }
                        do {
                            let value = try await model.runningTaskOutput(id)
                            output = value["output"].string.flatMap { $0.isEmpty ? nil : $0 } ?? "This task has written no output."
                        } catch { output = error.localizedDescription }
                    }
                }.buttonStyle(.plain).font(.caption).disabled(readingOutput)
                    .help("Read this task’s latest output")
            }
            if task["status"].string == "stopping" || model.stoppingChild == id {
                ProgressView().controlSize(.small).accessibilityLabel("Stopping this task")
            } else if task["canStop"].bool != false {
                Button { model.requestChildStop(id) } label: {
                    Image(systemName: "stop.fill").frame(width: DeckTokens.Metrics.iconHit, height: DeckTokens.Metrics.iconHit)
                }
                .buttonStyle(.plain).help("Stop this task: " + (task["title"].string ?? "Background task"))
                .accessibilityLabel("Stop this task: " + (task["title"].string ?? "Background task"))
                .accessibilityIdentifier("chat.runningTasks.stop." + id)
                .disabled(model.stoppingChild != nil || model.readOnly)
            }
        }
    }
}

private extension NativeRPCValue {
    var selfID: String { self["id"].string ?? compact }
}
