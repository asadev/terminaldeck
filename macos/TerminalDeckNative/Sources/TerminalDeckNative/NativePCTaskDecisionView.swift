import SwiftUI
import Observation
import TerminalDeckNativeCore

@MainActor @Observable final class PCTaskDecisionModel {
    let taskID: String
    var state = NativeRPCValue.null
    var loading = true
    var pending = false
    var editing = false
    var problem: String?
    var message: String?
    var title = ""
    var proposal = ""
    var rationale = ""
    var discussion = ""
    var workflowName = ""
    var workflowID = ""
    var workflowMode = "off"
    @ObservationIgnored private let invoke: @MainActor @Sendable (NativeRPCValue) async throws -> NativeRPCValue
    init(taskID: String, invoke: (@MainActor @Sendable (NativeRPCValue) async throws -> NativeRPCValue)? = nil) {
        self.taskID = taskID
        self.invoke = invoke ?? { try await EngineBridge.shared.invokeNativeValue("decisions:perform", [$0]) }
    }
    func load(discardEdits: Bool = false) async {
        guard !editing || discardEdits else { return }
        do {
            state = try await invoke(.object([.init("action", .string("get")), .init("task", .string(taskID))]))
            editing = false; applyFields(); problem = nil
        } catch { problem = error.localizedDescription }
        loading = false
    }
    private func applyFields() {
        title = state["decision"]["title"].string ?? ""
        proposal = state["decision"]["body"].string ?? ""
        rationale = state["decision"]["rationale"].string ?? ""
        workflowID = state["decision"]["policy"].string ?? ""
    }
    /// #313: what the decision can do at its stage (the engine's own rule); the other buttons are not shown.
    func can(_ action: String) -> Bool {
        let decision = state["decision"]
        guard (try? PCDecisions.next(decision["state"].string ?? "draft", action: action)) != nil else { return false }
        return action != "release" || decision["released"].bool != true
    }
    func act(_ action: String, extra: [NativeRPCValue.Field] = []) async {
        guard !pending else { return }; pending = true; defer { pending = false }
        problem = nil; message = nil
        var fields: [NativeRPCValue.Field] = [.init("action", .string(action)), .init("task", .string(taskID)), .init("expected", state["decision"]["revision"].number.map(NativeRPCValue.number) ?? .number(0)), .init("request", .string(UUID().uuidString.lowercased()))]
        fields += extra
        do {
            let result = try await invoke(.object(fields))
            if action == "policy" { await load(discardEdits: true); message = "Workflow saved." }
            else if action == "create" { message = "Created unassigned workflow task " + (result["task"].string ?? "") + ". Open it from Tasks, then choose an agent and submit its proposal." }
            else {
                state = result
                if !(editing && action == "comment") { editing = false; applyFields() }
                message = result["started"].bool == true ? "Started this approved task." : result["held"].string ?? "Saved. No task was started."
            }
            discussion = ""
        } catch { problem = error.localizedDescription }
    }
}

struct NativePCTaskDecisionView: View {
    @State private var model: PCTaskDecisionModel
    @State private var feed: EngineSubscription?
    init(taskID: String, model: PCTaskDecisionModel? = nil) { _model = State(initialValue: model ?? .init(taskID: taskID)) }
    var body: some View {
        Group {
            if model.loading { ProgressView("Reading optional business review…").controlSize(.small) }
            else if model.state["eligible"].bool == true {
                @Bindable var fields = model
                DisclosureGroup("Business decision · " + (model.state["decision"]["state"].string ?? "Off")) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Optional business review. AI tool permissions stay as they are.").font(.caption).foregroundStyle(.secondary)
                        Text(model.state["executionCapability"].string ?? "").font(.caption).foregroundStyle(.secondary)
                        Picker("Workflow", selection: $fields.workflowID) {
                            Text("Off").tag("")
                            ForEach(Array((model.state["policies"].elements ?? []).enumerated()), id: \.offset) { _, row in Text((row["name"].string ?? "Workflow") + " · " + (row["mode"].string ?? "off")).tag(row["id"].string ?? "") }
                        }
                        HStack {
                            NativeSessionButton("Use workflow") { Task { await model.act("bind", extra: [.init("policy", model.workflowID.isEmpty ? .null : .string(model.workflowID))]) } }.disabled(model.state["bindable"].bool != true)
                            NativeSessionButton("New task in this workflow") { Task { await model.act("create", extra: [.init("policy", .string(model.workflowID))]) } }.disabled(model.workflowID.isEmpty)
                        }
                        HStack {
                            NativeSessionTextField("Workflow name", text: $fields.workflowName)
                            Picker("Requirement", selection: $fields.workflowMode) { Text("Off").tag("off"); Text("Owner before start").tag("owner-before-start") }
                            NativeSessionButton("Create workflow") { Task { await model.act("policy", extra: [.init("name", .string(model.workflowName)), .init("mode", .string(model.workflowMode)), .init("policyExpected", .number(0))]) } }.disabled(model.workflowName.isEmpty || model.editing)
                            NativeSessionButton("Update selected") {
                                let selected = (model.state["policies"].elements ?? []).first { $0["id"].string == model.workflowID } ?? .null
                                Task { await model.act("policy", extra: [.init("policy", .string(model.workflowID)), .init("name", .string(model.workflowName)), .init("mode", .string(model.workflowMode)), .init("policyExpected", selected["revision"])]) }
                            }.disabled(model.workflowID.isEmpty || model.workflowName.isEmpty || model.editing)
                        }
                        if model.state["decision"].fields != nil, model.state["decision"]["required"].bool == true {
                            Text("Proposal revision \(Int(model.state["decision"]["proposalRevision"].number ?? 0))").font(.headline)
                            NativeSessionTextField("Proposal title", text: userText(\.title))
                            NativeSessionTextEditor(text: userText(\.proposal)).frame(height: 90).accessibilityLabel("Proposal")
                            NativeSessionTextField("Why this approach", text: userText(\.rationale))
                            HStack {
                                NativeSessionButton("Save revised proposal") { Task { await model.act("draft", extra: [.init("title", .string(model.title)), .init("body", .string(model.proposal)), .init("rationale", .string(model.rationale))]) } }
                                if model.can("submit") { NativeSessionButton("Submit / resubmit") { Task { await model.act("submit") } }.disabled(model.editing) }
                            }
                            NativeSessionTextField("Discussion or decision reason", text: $fields.discussion)
                            HStack {
                                NativeSessionButton("Comment") { Task { await model.act("comment", extra: [.init("text", .string(model.discussion))]) } }.disabled(model.discussion.isEmpty)
                                if model.can("changes") { NativeSessionButton("Request changes") { decide("changes") }.disabled(model.discussion.isEmpty || model.editing) }
                                if model.can("reject") { NativeSessionButton("Reject") { decide("reject") }.disabled(model.discussion.isEmpty || model.editing) }
                            }
                            if model.can("approve") || model.can("release") {
                                HStack {
                                    if model.can("approve") {
                                        NativeSessionButton("Approve") { decide("approve") }
                                        NativeSessionButton("Approve and start") { decide("approve-start") }
                                    }
                                    if model.can("release") { NativeSessionButton("Start approved work") { decide("release") } }
                                }.disabled(model.editing)
                            }
                            if let held = model.state["held"].string { Text(held).font(.callout).foregroundStyle(.orange) }
                            DisclosureGroup("Earlier revisions and discussion") {
                                ForEach(Array((model.state["decision"]["history"].elements ?? []).enumerated()), id: \.offset) { _, event in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text((event["action"].string ?? "") + " · " + (event["by"].string ?? "")).font(.caption.weight(.semibold))
                                        Text(event["text"].string ?? "").font(.caption)
                                        if let body = event["body"].string { Text(body).font(.caption).textSelection(.enabled) }
                                    }
                                }
                            }
                        }
                        NativeSessionButton(model.editing ? "Reload and discard my edits" : "Refresh") { Task { await model.load(discardEdits: true) } }
                        if model.pending { ProgressView("Saving decision…").controlSize(.small) }
                        if let problem = model.problem { Text(problem).foregroundStyle(.red).font(.callout).textSelection(.enabled) }
                        if let message = model.message { Text(message).font(.caption).textSelection(.enabled) }
                    }.disabled(model.pending).padding(.vertical, 8)
                }
            } else if let problem = model.problem {
                VStack(alignment: .leading) { Text("Optional business review could not be read: " + problem).font(.callout).foregroundStyle(.red); NativeSessionButton("Retry review") { Task { await model.load() } } }
            }
        }.task {
            await model.load()
            feed = EngineBridge.shared.on("tasks:changed") { _ in Task { @MainActor in await model.load() } }
        }.onDisappear { feed?.cancel(); feed = nil }
    }
    private func userText(_ keyPath: ReferenceWritableKeyPath<PCTaskDecisionModel, String>) -> Binding<String> {
        Binding(get: { model[keyPath: keyPath] }, set: { model[keyPath: keyPath] = $0; model.editing = true })
    }
    private func decide(_ action: String) { Task { await model.act(action, extra: [.init("text", .string(model.discussion)), .init("review", model.state["ownerReview"])]) } }
}
