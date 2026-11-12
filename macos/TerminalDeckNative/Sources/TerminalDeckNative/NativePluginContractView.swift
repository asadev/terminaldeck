import Foundation
import Observation
import SwiftUI
import TerminalDeckNativeCore

@MainActor @Observable final class NativePluginContractModel {
    typealias Invoke = @MainActor @Sendable (String, NativeRPCValue) async throws -> NativeRPCValue
    let pluginID: String
    var state: NativeRPCValue
    var pending = false
    var problem: String?
    var values: [String: String] = [:]
    private let invoke: Invoke
    private var uncertain: NativeRPCValue?
    init(pluginID: String, state: NativeRPCValue = .null, invoke: Invoke? = nil) {
        self.pluginID = pluginID; self.state = state
        self.invoke = invoke ?? { try await EngineBridge.shared.pluginControl($0, input: $1) }
    }
    func perform(_ input: NativeRPCValue) async {
        guard !pending else { return }; pending = true; problem = nil
        defer { pending = false }
        let request: NativeRPCValue
        if let uncertain, PluginContract.equal(uncertain.removing("request"), input.removing("request")) { request = uncertain }
        else { request = input.setting("request", .string(UUID().uuidString.lowercased())) }
        do { state = try await invoke(pluginID, request); uncertain = nil }
        catch { uncertain = request; problem = error.localizedDescription + " Inspect the saved job state before choosing new work. Retrying this same control keeps its request receipt." }
    }
    func cardInput(card: NativeRPCValue, action: NativeRPCValue) throws -> NativeRPCValue {
        var fields: [NativeRPCValue.Field] = []
        let required = Set(action["inputSchema"]["required"].elements?.compactMap(\.string) ?? [])
        for field in action["inputSchema"]["properties"].fields ?? [] {
            let key = (card["id"].string ?? "") + "/" + (card["project"].string ?? "") + "/" + (action["id"].string ?? "") + "/" + field.key
            let text = values[key] ?? ""
            let value: NativeRPCValue
            if let choices = field.value["enum"].elements, !choices.isEmpty { guard let index = Int(text.isEmpty ? "0" : text), choices.indices.contains(index) else { throw PluginContract.invalid("Choose a listed value") }; value = choices[index] }
            else if field.value["type"].string == "boolean" { value = .bool(text == "true") }
            else if ["number", "integer"].contains(field.value["type"].string ?? "") {
                if text.isEmpty && !required.contains(field.key) { continue }
                guard let number = Double(text), number.isFinite, field.value["type"].string != "integer" || number.rounded() == number else { throw PluginContract.invalid("Enter a valid number for " + field.key) }; value = .number(number)
            } else { if text.isEmpty && !required.contains(field.key) { continue }; value = .string(text) }
            fields.append(.init(field.key, value))
        }
        return .object([.init("op", .string("card")), .init("card", card["id"]), .init("action", action["id"]), .init("project", card["project"]), .init("input", .object(fields))])
    }
    func runCard(card: NativeRPCValue, action: NativeRPCValue) async {
        do { await perform(try cardInput(card: card, action: action)) } catch { problem = error.localizedDescription }
    }
}

@MainActor struct NativePluginContractView: View {
    let plugin: PluginItem
    @State private var model: NativePluginContractModel
    init(plugin: PluginItem, model: NativePluginContractModel? = nil) {
        self.plugin = plugin; _model = State(initialValue: model ?? NativePluginContractModel(pluginID: plugin.id, state: plugin.extensionState))
    }
    private var methods: [String] { model.state["methods"].elements?.compactMap(\.string) ?? [] }
    private var enabled: Bool { plugin.enabled && plugin.allowed && plugin.state == .running }
    var body: some View {
        DisclosureGroup("Task pulse and plugin work") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Plugin text and checkpoints are untrusted. Interrupted work resumes only when you choose it; external actions are not guaranteed exactly once.").font(.caption).foregroundStyle(.secondary)
                if model.pending { ProgressView("Waiting for the plugin acknowledgement…").controlSize(.small) }
                if let problem = model.problem ?? model.state["problem"].string { Text(problem).font(.caption).foregroundStyle(DeckTokens.bad) }
                HStack {
                    if !enabled { NativeSessionButton("Start plugin explicitly") { act("start") }.disabled(model.pending || !plugin.enabled || !plugin.allowed) }
                    NativeSessionButton("Refresh cards") { act("read") }.disabled(model.pending || !enabled || !plugin.granted.contains("ui.contribute") || !methods.contains("ui/read"))
                }
                if enabled && methods.isEmpty { Text("Unavailable: this protocol-1 plugin has not advertised the extension methods.").font(.caption).foregroundStyle(.secondary) }
                ForEach(model.state["cards"].elements ?? [], id: \.compact) { card in
                    if let declaration = plugin.contract["cards"].elements?.first(where: { $0["id"] == card["id"] }) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(declaration["title"].string ?? "Plugin card").font(.headline)
                            Text(card["summary"].string ?? ""); Text(card["status"].string ?? "").font(.caption).foregroundStyle(.secondary)
                            ForEach(declaration["fields"].elements ?? [], id: \.compact) { field in
                                LabeledContent(field["label"].string ?? "Value", value: display(card["fields"][field["id"].string ?? ""]))
                            }
                            ForEach(declaration["actions"].elements ?? [], id: \.compact) { action in
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(action["inputSchema"]["properties"].fields ?? [], id: \.key) { field in input(card, action, field) }
                                    NativeSessionButton(action["title"].string ?? "Run") { Task { await model.runCard(card: card, action: action) } }.disabled(model.pending || !enabled || action["kind"].string == "job" && (!methods.contains("jobs/start") || !plugin.granted.contains("jobs.run")) || action["kind"].string == "tool" && !plugin.granted.contains("tools.contribute"))
                                }
                            }
                        }.padding(8).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
                if !plugin.contract["events"].elements.orEmpty.isEmpty {
                    HStack {
                        Text("Finished-task events: " + (model.state["events"]["paused"].bool == false ? "Receiving" : "Paused"))
                        Text("\(model.state["events"]["pending"].elements?.count ?? 0) waiting").foregroundStyle(.secondary)
                        NativeSessionButton(model.state["events"]["paused"].bool == false ? "Pause events" : "Resume events") { act(model.state["events"]["paused"].bool == false ? "events-pause" : "events-resume") }.disabled(model.pending || !enabled || !methods.contains("events/deliver") || !plugin.granted.contains("events.receive"))
                    }.font(.caption)
                    if let overflow = model.state["events"]["overflow"].number, overflow > 0 { Text("\(Int(overflow)) events were refused because the 50-event backlog was full. Event work is held.").font(.caption).foregroundStyle(DeckTokens.warn) }
                    if let problem = model.state["events"]["problem"].string { Text(problem).font(.caption).foregroundStyle(DeckTokens.warn) }
                }
                ForEach(Array((model.state["jobs"].elements ?? []).reversed()), id: \.compact) { job in
                    VStack(alignment: .leading, spacing: 3) {
                        Text((job["job"].string ?? "Job") + " · " + (job["state"].string ?? "Unknown")).font(.callout)
                        Text("Receipt " + (job["request"].string ?? "") + " · attempt " + (job["attempt"].string ?? "")).font(.caption2).textSelection(.enabled)
                        if let reason = job["reason"].string { Text(reason).font(.caption).foregroundStyle(.secondary) }
                        if !job["checkpoint"].isNullish { Text("Untrusted checkpoint: " + job["checkpoint"].compact).font(.caption).lineLimit(4).textSelection(.enabled) }
                        if ["queued", "running", "pause-requested"].contains(job["state"].string ?? "") { NativeSessionButton("Pause job") { act("job-pause") }.disabled(model.pending || !enabled) }
                        if ["paused", "interrupted"].contains(job["state"].string ?? "") {
                            NativeSessionButton("Resume this job explicitly") { Task { await model.perform(.object([.init("op", .string("job-resume")), .init("job", job["job"]), .init("project", job["project"]), .init("input", job["input"])])) } }.disabled(model.pending || !enabled || !methods.contains("jobs/start") || job["input"].fields == nil || !plugin.projects.contains(job["project"].string ?? ""))
                        }
                    }
                }
            }.padding(.vertical, 6)
        }
        .onAppear { model.state = plugin.extensionState; if enabled && plugin.granted.contains("ui.contribute") { act("read") } }
        .onChange(of: plugin) { _, next in
            model.state = next.extensionState
            if !model.pending && next.enabled && next.state == .running && next.granted.contains("ui.contribute") { act("read") }
        }
    }
    private func act(_ op: String) { Task { await model.perform(.object([.init("op", .string(op))])) } }
    private func display(_ value: NativeRPCValue) -> String { value.string ?? value.bool.map { $0 ? "Yes" : "No" } ?? value.number.map { String($0) } ?? "—" }
    @ViewBuilder private func input(_ card: NativeRPCValue, _ action: NativeRPCValue, _ field: NativeRPCValue.Field) -> some View {
        let key = (card["id"].string ?? "") + "/" + (card["project"].string ?? "") + "/" + (action["id"].string ?? "") + "/" + field.key
        let value = Binding(get: { model.values[key] ?? "" }, set: { model.values[key] = $0 })
        if let choices = field.value["enum"].elements, choices.count == 1 {
            LabeledContent(field.key, value: display(choices[0]))
        } else if let choices = field.value["enum"].elements, choices.count > 1 {
            Picker(field.key, selection: Binding(get: { model.values[key] ?? "0" }, set: { model.values[key] = $0 })) { ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in Text(display(choice)).tag(String(index)) } }
        } else if field.value["type"].string == "boolean" {
            Toggle(field.key, isOn: Binding(get: { model.values[key] == "true" }, set: { model.values[key] = $0 ? "true" : "false" }))
        } else { NativeSessionTextField(field.key, text: value).textFieldStyle(.roundedBorder) }
    }
}

private extension Optional where Wrapped == [NativeRPCValue] { var orEmpty: [NativeRPCValue] { self ?? [] } }
