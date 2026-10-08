import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// Rules: checked from the top; the first that matches decides where an event goes.
struct NativeRCVRulesPage: View {
    let model: NativeRCVModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Text(RCVPresentation.rulesExplainer)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 560, alignment: .leading)
                Spacer(minLength: 12)
                Button("New rule") { model.openSheet(.rule(RCVPresentation.newRule(), isNew: true)) }
            }
            NativeRCVActionLine(model: model)
            if model.rules.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.rules.enumerated()), id: \.element.id) { index, rule in
                            NativeRCVRuleRow(model: model, rule: rule, first: index == 0, last: index == model.rules.count - 1)
                        }
                    }
                    .padding(.trailing, 6)
                }
            }
        }
    }

    private var empty: some View {
        let empty = RCVPresentation.emptyRules
        let points = RCVPresentation.startingPoints(sources: model.sources, presets: model.presets)
        return ScrollView {
            NativePageEmpty(symbol: empty.symbol, title: empty.title, message: { Text(empty.message) },
                            action: PageEmptyAction(label: empty.action ?? "New rule", primary: true,
                                                    perform: { model.openSheet(.rule(RCVPresentation.newRule(), isNew: true)) }),
                            hint: { EmptyView() },
                            extra: {
                                if !points.isEmpty {
                                    VStack(alignment: .leading, spacing: 2) {
                                        NativeRCVHeading("Start from an example").padding(.leading, 8).padding(.bottom, 4)
                                        ForEach(points) { point in
                                            NativeRCVStartingPoint(point: point) {
                                                model.openSheet(.rule(RCVPresentation.fresh(point.rule), isNew: true))
                                            }
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            })
        }
    }
}

private struct NativeRCVStartingPoint: View {
    let point: RCVPresentation.StartingPoint
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            VStack(alignment: .leading, spacing: 2) {
                Text(point.title).font(.callout)
                Text(point.detail).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .modifier(NativeRCVPick(selected: false))
    }
}

/// One rule: on/off, name, what it does in a sentence, its limits, and up/down.
private struct NativeRCVRuleRow: View {
    let model: NativeRCVModel
    let rule: RCVRule
    let first: Bool
    let last: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(rule.name, isOn: Binding(get: { rule.enabled }, set: { on in Task { await model.setEnabled(rule, on) } }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(model.busy != nil)
                .help(rule.enabled ? "On. Turn off to stop this rule without deleting it." : "Off")
            VStack(alignment: .leading, spacing: 3) {
                Text(rule.name).fontWeight(.medium).foregroundStyle(rule.enabled ? Color.primary : Color.secondary).lineLimit(1)
                if let overview = model.overview {
                    Text(RCVPresentation.summary(rule, overview: overview))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if let limits = RCVPresentation.limits(rule) {
                    Text(limits).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                Button { Task { await model.moveRule(rule.id, up: true) } } label: { Image(systemName: "chevron.up") }
                    .disabled(first || model.busy != nil)
                    .help("Check it earlier")
                    .accessibilityLabel("Move up")
                Button { Task { await model.moveRule(rule.id, up: false) } } label: { Image(systemName: "chevron.down") }
                    .disabled(last || model.busy != nil)
                    .help("Check it later")
                    .accessibilityLabel("Move down")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(NativeRCVPick(selected: false))
        .onTapGesture { model.openSheet(.rule(rule, isNew: false)) }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: "Edit") { model.openSheet(.rule(rule, isNew: false)) }
    }
}

// MARK: - The rule editor

struct NativeRCVRuleEditor: View {
    let model: NativeRCVModel
    let original: RCVRule
    let isNew: Bool
    @State private var draft: RCVRule
    @State private var testEventID: String?
    @State private var sample = ""
    @State private var answer: RCVPresentation.DecisionWords?
    @State private var showInstruction = false
    @State private var confirmDelete = false

    init(model: NativeRCVModel, original: RCVRule, isNew: Bool) {
        self.model = model
        self.original = original
        self.isNew = isNew
        _draft = State(initialValue: original)
    }

    private var overview: RCVOverview? { model.overview }
    private var chosenSources: [RCVSource] {
        let all = model.sources.map(\.source)
        return draft.sourceIds.isEmpty ? all : all.filter { draft.sourceIds.contains($0.id) }
    }
    private var recent: [RCVEvent] { Array(model.recentEvents(of: draft.sourceIds).prefix(20)) }
    private var problem: String? { RCVPresentation.validation(draft) }

    var body: some View {
        VStack(spacing: 0) {
            NativeSettingsHead(title: isNew ? "New rule" : "Edit rule",
                               blurb: "When something arrives that matches, send it on with your instruction.")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 30)
                .padding(.top, 18)
            Form {
                if let error = model.actionError { Section { NativeCodingAINotice(tone: .error, text: error) } }
                Section {
                    NativeSettingRow(label: "Name", help: "Shown in Flow next to everything it sends on.") {
                        TextField("New errors to Ada", text: $draft.name)
                            .labelsHidden()
                            .frame(minWidth: 220, maxWidth: 280)
                    }
                }
                sourcesSection
                Section("When") {
                    Text(draft.conditions.isEmpty ? "No conditions: everything from the sources above matches." : "Every condition must match.")
                        .font(.callout).foregroundStyle(.secondary)
                    NativeRCVConditionsEditor(conditions: $draft.conditions,
                                              suggestions: RCVPresentation.paths(sources: chosenSources, events: recent),
                                              addLabel: "Add a condition")
                }
                Section("Send to") {
                    NativeRCVTargetFields(target: $draft.target, agents: overview?.agents ?? [], sessions: overview?.sessions ?? [])
                }
                instructionSection
                limitsSection
                Section("Replies") {
                    NativeSettingRow(label: "Send replies without asking", help: RCVPresentation.autoApproveWarning) {
                        Toggle("Send replies without asking", isOn: $draft.autoApproveReplies).labelsHidden().toggleStyle(.switch)
                    }
                    if draft.autoApproveReplies {
                        NativeCodingAINotice(tone: .warn, text: "Only you can turn this on, and only here.")
                    }
                }
                testSection
            }
            .formStyle(.grouped)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            NativeRCVSheetBar {
                if model.busy == "save-rule" || model.busy == "delete-rule" {
                    NativePageNote("Saving…", busy: true).frame(maxHeight: 24)
                } else if let problem {
                    Text(problem).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } trailing: {
                if !isNew {
                    Button("Delete…", role: .destructive) { confirmDelete = true }
                        .disabled(model.busy != nil)
                }
                Button("Cancel") { model.openSheet(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Add rule" : "Save") { Task { await model.saveRule(draft) } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil || model.busy != nil || (!isNew && draft == original))
            }
        }
        .frame(width: 720, height: 760)
        .interactiveDismissDisabled(model.busy == "save-rule")
        .confirmationDialog("Delete the rule “\(original.name)”?", isPresented: $confirmDelete) {
            Button("Delete rule", role: .destructive) { Task { await model.deleteRule(original.id) } }
        } message: {
            Text("What it would have sent on waits in Unrouted instead.")
        }
        .onChange(of: draft) { _, _ in answer = nil }
    }

    // MARK: Sections

    private var sourcesSection: some View {
        Section("Comes from") {
            Text(draft.sourceIds.isEmpty ? "None ticked: any source." : "Only the ticked sources.")
                .font(.callout).foregroundStyle(.secondary)
            ForEach(model.sources) { view in
                Toggle(isOn: Binding(get: { draft.sourceIds.contains(view.id) }, set: { on in
                    if on { if !draft.sourceIds.contains(view.id) { draft.sourceIds.append(view.id) } }
                    else { draft.sourceIds.removeAll { $0 == view.id } }
                })) {
                    Label {
                        Text(view.source.name)
                    } icon: {
                        Image(systemName: SymbolName.resolve(RCVPresentation.sourceSymbol(view.source, presets: model.presets), fallback: "arrow.down.circle"))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.checkbox)
            }
            // A source the rule names that no longer exists stays visible so it can be removed.
            ForEach(draft.sourceIds.filter { id in !model.sources.contains { $0.id == id } }, id: \.self) { id in
                HStack {
                    Text(RCVPresentation.sourceName(id, in: model.sources)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove") { draft.sourceIds.removeAll { $0 == id } }.buttonStyle(.borderless)
                }
            }
        }
    }

    private var instructionSection: some View {
        Section("What to do") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("The instruction it is sent with")
                    Spacer()
                    Menu("Insert") {
                        ForEach(RCVPresentation.placeholders(sources: chosenSources, events: recent), id: \.self) { placeholder in
                            Button(placeholder) {
                                if !draft.instruction.isEmpty && !draft.instruction.hasSuffix("\n") && !draft.instruction.hasSuffix(" ") {
                                    draft.instruction += " "
                                }
                                draft.instruction += placeholder
                            }
                        }
                    }
                    .fixedSize()
                    .help("Add a value from the event")
                }
                TextField("{{title}}\n{{text}}", text: $draft.instruction, axis: .vertical)
                    .lineLimit(4...12)
                    .labelsHidden()
                Text("{{title}}, {{text}} and {{fields.…}} are filled in from the event once; anything inside a message stays plain text.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            NativeSettingRow(label: "Project folder", help: "Optional. The folder an agent’s task works in. Empty: the agent’s own default.") {
                HStack(spacing: 6) {
                    TextField("Default", text: $draft.project)
                        .labelsHidden()
                        .truncationMode(.head)
                        .frame(minWidth: 180, maxWidth: 240)
                    Button("Choose…", action: chooseFolder)
                }
            }
        }
    }

    private var limitsSection: some View {
        Section("Limits") {
            NativeSettingRow(label: "At most per minute", help: "More than this wait a moment and then go out; none are dropped.") {
                Stepper(value: $draft.perMinute, in: 1...120) {
                    Text("\(draft.perMinute)").monospacedDigit()
                }
                .fixedSize()
            }
            NativeSettingRow(label: "Repeats", help: draft.dedupeMinutes == 0
                             ? "Off. The same thing twice is sent twice."
                             : "The same thing within \(draft.dedupeMinutes) minutes is treated as a repeat and not sent again.") {
                Stepper(value: $draft.dedupeMinutes, in: 0...1_440, step: 5) {
                    Text(draft.dedupeMinutes == 0 ? "Off" : "\(draft.dedupeMinutes) min").monospacedDigit()
                }
                .fixedSize()
            }
            NativeSettingRow(label: "Quiet hours", help: "Held until they end, then sent once.") {
                Toggle("Quiet hours", isOn: Binding(get: { draft.quietHours != nil }, set: { on in
                    draft.quietHours = on ? (draft.quietHours ?? RCVQuietHours()) : nil
                }))
                .labelsHidden()
                .toggleStyle(.switch)
            }
            if let quiet = draft.quietHours {
                NativeSettingRow(label: "From", help: quiet.timeZone) {
                    HStack(spacing: 6) {
                        hourPicker("From", Binding(get: { draft.quietHours?.startHour ?? 22 }, set: { draft.quietHours?.startHour = $0 }))
                        Text("to").foregroundStyle(.secondary)
                        hourPicker("To", Binding(get: { draft.quietHours?.endHour ?? 8 }, set: { draft.quietHours?.endHour = $0 }))
                    }
                }
            }
        }
    }

    private func hourPicker(_ label: String, _ hour: Binding<Int>) -> some View {
        Picker(label, selection: hour) {
            ForEach(0..<24, id: \.self) { value in Text(RCVPresentation.hour(value)).tag(value) }
        }
        .labelsHidden()
        .fixedSize()
    }

    private var testSection: some View {
        Section("Try it") {
            NativeSettingRow(label: "Test with", help: recent.isEmpty ? "Nothing has arrived from these sources yet. Paste a sample below." : "Nothing is sent; this only shows what would happen.") {
                Picker("Test with", selection: Binding(get: { testEventID ?? recent.first?.id }, set: { testEventID = $0 })) {
                    ForEach(recent) { event in
                        Text("\(RCVPresentation.title(event)) · \(RCVPresentation.relative(event.receivedAt))").lineLimit(1).tag(String?.some(event.id))
                    }
                    if recent.isEmpty { Text("Nothing yet").tag(String?.none) }
                }
                .labelsHidden()
                .frame(maxWidth: 300)
                .disabled(recent.isEmpty || !sample.isEmpty)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Or paste a sample").font(.callout).foregroundStyle(.secondary)
                TextField("{\"title\": \"Disk full\", \"severity\": \"error\"}", text: $sample, axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(2...8)
                    .labelsHidden()
                if !sample.isEmpty && draft.sourceIds.count != 1 {
                    Text("A pasted sample is read as the first ticked source would read it.").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button(model.busy == "test" ? "Testing…" : "Test") {
                    Task {
                        let eventID = testEventID ?? recent.first?.id
                        if let result = await model.test(draft, eventID: eventID, sourceID: draft.sourceIds.first ?? recent.first?.sourceId, sample: sample),
                           let overview = self.overview {
                            answer = RCVPresentation.decisionWords(result.decision, overview: overview)
                        }
                    }
                }
                .disabled(model.busy != nil || (recent.isEmpty && sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                Spacer()
            }
            if let answer {
                VStack(alignment: .leading, spacing: 6) {
                    Text(answer.headline).fontWeight(.medium).foregroundStyle(answer.tone == .bad ? Color.red : Color.primary)
                    Text(answer.reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let instruction = answer.instruction, !instruction.isEmpty {
                        DisclosureGroup(isExpanded: $showInstruction) {
                            NativeRCVMonoBlock(text: instruction).padding(.top, 4)
                        } label: {
                            Text("What it would be sent").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the folder an agent’s task works in."
        NativeFront.whenPersonActs("main") { guard panel.runModal() == .OK, let folder = panel.url?.path else { return }
            draft.project = folder
        }
    }
}

// MARK: - Conditions

/// Path · operation · value rows, with suggestions from what arrived.
struct NativeRCVConditionsEditor: View {
    @Binding var conditions: [RCVCondition]
    let suggestions: [String]
    let addLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(conditions.indices), id: \.self) { index in
                HStack(spacing: 6) {
                    TextField("fields.chat", text: text(index, \.path))
                        .font(.system(.body, design: .monospaced))
                        .labelsHidden()
                        .frame(minWidth: 130, maxWidth: 200)
                    if !suggestions.isEmpty {
                        Menu {
                            ForEach(suggestions, id: \.self) { path in
                                Button(path) { text(index, \.path).wrappedValue = path }
                            }
                        } label: {
                            Image(systemName: "list.bullet")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .foregroundStyle(.secondary)
                        .help("Pick from what arrived")
                        .accessibilityLabel("Pick a path")
                    }
                    Picker("Operation", selection: operation(index)) {
                        ForEach(RCVCondition.Operation.allCases, id: \.self) { op in Text(op.title).tag(op) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    if RCVPresentation.needsValue(operation(index).wrappedValue) {
                        TextField(prompt(operation(index).wrappedValue), text: text(index, \.value))
                            .labelsHidden()
                    } else {
                        Spacer(minLength: 0)
                    }
                    Button {
                        if conditions.indices.contains(index) { conditions.remove(at: index) }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove")
                    .accessibilityLabel("Remove condition")
                }
            }
            Button(addLabel) { conditions.append(RCVCondition(suggestions.first ?? "kind")) }
                .buttonStyle(.borderless)
        }
    }

    private func prompt(_ op: RCVCondition.Operation) -> String {
        switch op {
        case .oneOf: "a, b, c"
        case .atLeast: "warning"
        case .above, .below: "number"
        case .matches: "pattern"
        default: "value"
        }
    }

    private func text(_ index: Int, _ key: WritableKeyPath<RCVCondition, String>) -> Binding<String> {
        Binding(get: { conditions.indices.contains(index) ? conditions[index][keyPath: key] : "" },
                set: { if conditions.indices.contains(index) { conditions[index][keyPath: key] = $0 } })
    }

    private func operation(_ index: Int) -> Binding<RCVCondition.Operation> {
        Binding(get: { conditions.indices.contains(index) ? conditions[index].operation : .equals },
                set: { if conditions.indices.contains(index) { conditions[index].operation = $0 } })
    }
}
