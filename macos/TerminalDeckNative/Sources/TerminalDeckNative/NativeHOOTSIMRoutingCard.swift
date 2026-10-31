import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// The proposal uses the normal conversation and task owners. This view never
/// starts a worker or grants permission; Send invokes the existing approval path.
struct NativeHOOTSIMRoutingCard: View {
    let route: NativeRPCValue
    var fixtureMode = false
    var choices: [HootMention] = []
    var projects: [PROJProject] = []
    let answer: (String, NativeRPCValue) -> Void
    @State private var choosing = false
    @State private var search = ""
    private var target: NativeRPCValue { route["target"] }
    private var name: String { target["name"].string ?? "a task" }
    private var pending: Bool { route["status"].string == "pending" }
    /// "Do it and tell me": already approved by the person's setting, with Undo until it sends.
    private var scheduled: Bool { route["status"].string == "scheduled" }
    private var resolvedProject: (record: PROJProject?, name: String) {
        let id = PROJProjects.resolve(projectID: target["projectId"].string,
            folder: target["folder"].string ?? route["source"]["folder"].string, projects: projects)
        let record = projects.first { $0.id == id }
        return (id == PROJProjects.independentID ? nil : record,
                record?.name ?? target["projectName"].string ?? "Independent")
    }
    var body: some View {
        if route["routineReport"].bool == true { Routines21HootReport(report: route) }
        else { routingProposal }
    }
    private var routingProposal: some View {
        let project = resolvedProject
        return VStack(alignment: .leading, spacing: 12) {
            if scheduled {
                scheduledRow(project: project.record, projectName: project.name)
            } else if pending {
                Label("Send to an agent · needs your OK", systemImage: "arrow.triangle.branch")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 12) {
                    AgentAvatar(icon: AGTIcon.parse(target["icon"].string) ?? .symbol(target["kind"].string == "session" ? "terminal" : "wrench"), size: 38,
                                id: target["id"].string ?? target["name"].string, colour: AGTIcon.colour(target["icon"].string))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(name).font(.system(size: 13, weight: .semibold))
                            ProjectChip(project: project.record, name: project.name)
                        }
                        Text(target["role"].string ?? route["reason"].string ?? "Hoot will keep track of this problem.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).help(route["reason"].string ?? "")
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(route["taskId"].string != nil ? "Uses the open task" : route["newTask"].bool == true ? "Creates a task" : "Tracks a task").font(.caption).foregroundStyle(.secondary)
                        Text(route["problem"].string ?? "Problem").font(.system(size: 12, weight: .medium)).lineLimit(2)
                    }.frame(maxWidth: 220, alignment: .trailing)
                }
                Divider()
                ViewThatFits(in: .horizontal) {
                    HStack {
                        followUp
                        Spacer(minLength: 8)
                        actions
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        followUp
                        HStack { Spacer(); actions }
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Image(systemName: route["status"].string == "sent" ? "checkmark.circle" : "clock")
                    Text(settledLine).font(.callout).lineLimit(2)
                    Spacer(minLength: 8)
                    if let task = route["taskId"].string {
                        Button("Open task") { if !fixtureMode { AppModel.shared.select("tasks"); TasksStore.shared.openTask(task) } }.buttonStyle(.link)
                    }
                }.foregroundStyle(.secondary)
            }
        }
        .padding(16).background(DeckTokens.card, in: .rect(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5) }
        .popover(isPresented: $choosing) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Find an agent or running session", text: $search).textFieldStyle(.roundedBorder)
                ScrollView {
                    ForEach(choices.filter { [.agent, .session].contains($0.kind) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }) { choice in
                        Button {
                            choosing = false
                            answer("other", .object([.init("kind", .string(choice.kind.rawValue)), .init("id", .string(choice.id)), .init("projectId", .string(choice.group))]))
                        } label: {
                            HStack { Image(systemName: choice.symbol); Text(choice.name); Spacer(); Text(choice.project).font(.caption).foregroundStyle(.secondary) }
                                .padding(8).frame(maxWidth: .infinity).contentShape(.rect)
                        }.buttonStyle(.plain)
                    }
                    Button("Make a task only") {
                        choosing = false
                        answer("other", .object([.init("kind", .string("task")), .init("id", .string("task-only")), .init("projectId", target["projectId"])]))
                    }.buttonStyle(.bordered).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 300)
            }.padding(16).frame(width: 320)
        }
    }
    private func scheduledRow(project: PROJProject?, projectName: String) -> some View {
        HStack(spacing: 12) {
            AgentAvatar(icon: AGTIcon.parse(target["icon"].string) ?? .symbol(target["kind"].string == "session" ? "terminal" : "wrench"), size: 28,
                        id: target["id"].string ?? target["name"].string, colour: AGTIcon.colour(target["icon"].string))
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(target["kind"].string == "task" ? "Making a task in \(secondsLeft(at: context.date)) s" : "Sending to \(name) in \(secondsLeft(at: context.date)) s")
                            .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        ProjectChip(project: project, name: projectName)
                    }
                    Text("On your “Do it and tell me” setting · " + (route["problem"].string ?? "this problem"))
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
            Button("Undo") { answer("dismiss", .null) }.buttonStyle(.bordered).controlSize(.regular).buttonBorderShape(.capsule)
                .help("Stop this before it is sent. Nothing will be sent.")
        }
    }
    private func secondsLeft(at date: Date) -> Int {
        if fixtureMode { return Int(route["undoSeconds"].number ?? 10) }
        let at = route["autoAt"].number ?? date.timeIntervalSince1970
        return max(0, Int((at - date.timeIntervalSince1970).rounded(.up)))
    }
    private var followUp: some View {
        Text("Hoot follows up and tells you here when it is finished.").font(.caption).foregroundStyle(.secondary)
    }
    private var actions: some View {
        HStack(spacing: 8) {
            Button("Someone else…") { choosing = true }.buttonStyle(.bordered)
            Button("Not now") { answer("dismiss", .null) }.buttonStyle(.bordered)
            Button(target["kind"].string == "task" ? "Create task" : "Send to \(name)") { answer("approve", .null) }.buttonStyle(.borderedProminent)
        }.controlSize(.regular).buttonBorderShape(.capsule)
    }
    private var settledLine: String {
        switch route["status"].string {
        case "sent": "Sent to \(name) · Task \(route["taskId"].string ?? "created") · Hoot will report back."
        case "dismissed" where route["undone"].bool == true: "Undone · Nothing was sent to \(name)."
        case "dismissed": "Not sent · You can ask Hoot again later."
        case "approving": "Waiting for your OK…"
        case "saving": "Saving…"
        case "dispatching": "Sending to \(name)…"
        case "uncertain": "Delivery needs checking · Hoot will not send it twice."
        default: route["problem"].string ?? "This proposal is waiting."
        }
    }
}
