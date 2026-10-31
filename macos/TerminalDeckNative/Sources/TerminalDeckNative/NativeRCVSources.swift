import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// Content only: the shared page owns scrolling and the source opens its own window.
struct NativeRCVSourcesPage: View {
    let model: NativeRCVModel
    private var visible: [RCVSourceView] { model.sources.filter { model.projectFilter == nil || $0.source.effectiveProjectScope == .all || $0.source.projectID == model.projectFilter } }
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            NativeRCVActionLine(model: model)
            group("Yours", note: "Each has its own address to paste into the sender", sources: visible.filter { $0.source.origin == .relay })
            group("Built in", note: "Terminal Deck’s own events · pause any, nothing to paste", sources: visible.filter { $0.source.origin == .terminalDeck })
        }
    }
    private func group(_ title: String, note: String, sources: [RCVSourceView]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 8)
                Text(note).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            if sources.isEmpty {
                Text(title == "Yours" ? "Add a source to receive messages and alerts." : "No sources match this project.")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 20)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)], spacing: 12) {
                    ForEach(sources) { view in NativeRCVSourceCard(model: model, view: view) }
                }
            }
        }
    }
}

struct NativeRCVSourceCard: View {
    let model: NativeRCVModel
    let view: RCVSourceView
    private var builtIn: Bool { view.source.origin == .terminalDeck }
    private var title: String { view.id == "terminaldeck.servers" && view.source.name == "Servers and apps" ? "Servers" : view.source.name }
    private var subtitle: String {
        guard builtIn else { return NativeRCVSourceType.of(view.source).rawValue }
        switch view.id {
        case "terminaldeck.tasks": return "Tasks from your CRM"
        case "terminaldeck.sessions": return "Started, waiting, finished"
        case "terminaldeck.servers": return "Alerts from your servers"
        case "terminaldeck.containers": return "Started, stopped, crashed"
        case "terminaldeck.staysfixed": return "Checks that broke"
        case "terminaldeck.approvals": return "Asked, allowed, refused"
        default: return "Events from Terminal Deck"
        }
    }
    private var symbol: String {
        guard builtIn else { return NativeRCVSourceType.of(view.source).symbol }
        return switch view.id {
        case "terminaldeck.tasks": "checklist"; case "terminaldeck.sessions": "terminal"
        case "terminaldeck.servers": "server.rack"; case "terminaldeck.containers": "shippingbox"
        case "terminaldeck.staysfixed": "shield"; case "terminaldeck.approvals": "lock"
        default: "tray.and.arrow.down"
        }
    }
    private var today: Int {
        let start = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 * 1000
        return view.todayCount ?? model.overview?.events.filter { $0.sourceId == view.id && $0.receivedAt >= start }.count ?? 0
    }
    private var status: String {
        if !view.source.enabled { return "Paused" }
        if !builtIn && !view.active { return "Waiting for relay" }
        return view.eventCount == 0 && !builtIn ? "Nothing yet" : "Receiving"
    }
    private var statusColour: Color {
        if !view.source.enabled { return .gray }
        if !builtIn && !view.active { return .orange }
        return view.eventCount == 0 && !builtIn ? .gray : .green
    }
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button { NativeRCVSourceWindows.shared.open(model: model, view: view) } label: {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(.secondary)
                            .frame(width: 32, height: 32).background(.quaternary, in: .rect(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                            Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 44)
                    }
                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Circle().fill(projectColour).frame(width: 8, height: 8)
                            Text(view.source.effectiveProjectScope == .all ? "Every project" : PROJProjects.name(for: view.source.projectID, projects: model.projects))
                        }
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.quaternary, in: .rect(cornerRadius: 6))
                        Circle().fill(statusColour).frame(width: 6, height: 6)
                        Text(status)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 2)
                        Text(today == 0 ? "—" : "\(today) today").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .padding(16).frame(maxWidth: .infinity, minHeight: 98, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5))
                .contentShape(.rect)
            }
            .buttonStyle(NativeRCVRowStyle())
            .background(NativeRCVSurface.card, in: .rect(cornerRadius: 12))
            Toggle("Receive from \(title)", isOn: Binding(get: { view.source.enabled }, set: { on in Task { await model.setEnabled(view, on) } }))
                .labelsHidden().toggleStyle(.switch).tint(.accentColor).controlSize(.small).padding(.top, 21).padding(.trailing, 16)
                .disabled(model.busy != nil)
        }
        .contextMenu {
            Button("Source settings…") { NativeRCVSourceWindows.shared.open(model: model, view: view) }
            Button(view.source.enabled ? "Pause" : "Resume") { Task { await model.setEnabled(view, !view.source.enabled) } }
            Button("Send a test event") { Task { await model.testSource(view) } }
        }
    }
    private var projectColour: Color {
        view.source.effectiveProjectScope == .all ? .gray : NativeRCVSurface.projectColour(model.projects.first(where: { $0.id == view.source.projectID })?.colour ?? "graphite")
    }
}

struct NativeRCVAddSourceSheet: View {
    let model: NativeRCVModel
    @State private var type: NativeRCVSourceType = .webhook
    @State private var name = ""
    @State private var projectID = "independent"
    @State private var target = RCVTarget()
    @State private var created: RCVPresentation.Created?
    @State private var configured = false
    @State private var savedPreset: RCVPreset?
    init(model: NativeRCVModel, preset: RCVPreset? = nil, created: RCVPresentation.Created? = nil, initialName: String = "") {
        self.model = model
        _type = State(initialValue: NativeRCVSourceType.allCases.first { $0.presetID == preset?.id } ?? .webhook)
        _projectID = State(initialValue: model.projectFilter ?? "independent")
        _created = State(initialValue: created)
        _configured = State(initialValue: created != nil)
        _name = State(initialValue: initialName)
        _savedPreset = State(initialValue: preset?.builtIn == false ? preset : nil)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(created == nil ? "Add source" : "Paste this address").font(.system(size: 20, weight: .semibold))
            Text(created == nil ? "Choose what sends events to you." : type.pasteHelp).font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let created { address(created) } else { fields }
                    if let error = model.actionError { Text(error).font(.callout).foregroundStyle(.red).lineLimit(2) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            HStack {
                if model.busy != nil { ProgressView().controlSize(.small); Text("Working…").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if let created {
                    if !configured { Button("Finish setup") { configure(created) }.disabled(model.busy != nil) }
                    Button("Done") { model.openSheet(nil) }.buttonStyle(.borderedProminent).tint(.accentColor).keyboardShortcut(.defaultAction)
                        .disabled(!configured || model.busy != nil)
                } else {
                    Button("Cancel") { model.openSheet(nil) }.keyboardShortcut(.cancelAction)
                    Button("Add source") { create() }.buttonStyle(.borderedProminent).tint(.accentColor).keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || target.id.isEmpty || model.busy != nil)
                }
            }
        }
        .padding(24).frame(width: 640, height: 560).background(NativeRCVSurface.page)
        .interactiveDismissDisabled(model.busy != nil)
    }
    private var fields: some View {
        VStack(spacing: 14) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(NativeRCVSourceType.allCases) { choice in
                    Button { type = choice; savedPreset = nil } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: choice.symbol).font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 22)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(choice == .webhook ? "Webhook" : choice.rawValue).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                Text(typeCaption(choice)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(12).frame(maxWidth: .infinity, minHeight: 72).background(NativeRCVSurface.card, in: .rect(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(type == choice ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: type == choice ? 2 : 1))
                        .contentShape(.rect)
                    }.buttonStyle(.plain).accessibilityAddTraits(type == choice ? .isSelected : [])
                }
            }
            if model.presets.contains(where: { !$0.builtIn }) {
                Menu(savedPreset.map { "Preset: " + $0.name } ?? "Use a saved preset…") {
                    Button("Use the type’s defaults") { savedPreset = nil }
                    ForEach(model.presets.filter { !$0.builtIn }) { preset in Button(preset.name) { savedPreset = preset } }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow { Text("Name"); TextField("e.g. Website alerts", text: $name).textFieldStyle(.roundedBorder) }
                GridRow { Text("Project"); projectPicker }
                GridRow {
                    Text("Send to")
                    Picker("Send to", selection: destination) {
                        // The shared row: Hoot's owl, each agent's avatar, the same marks as the rule's own lists.
                        DeckRowLabel("Hoot decides", image: DeckRowIcon.hoot).tag("hoot")
                        DeckRowLabel("A task list", image: DeckRowIcon.symbolIcon("checklist")).tag("task")
                        ForEach(model.overview?.agents ?? []) { DeckRowLabel("Agent · \($0.name)", image: DeckRowIcon.agent(id: $0.id)).tag("agent:" + $0.id) }
                        ForEach(model.overview?.sessions ?? []) { DeckRowLabel("Session · \($0.name)", image: DeckRowIcon.session(id: $0.id)).tag("session:" + $0.id) }
                    }.labelsHidden()
                }
            }.padding(16).background(NativeRCVSurface.card, in: .rect(cornerRadius: 12))
        }
    }
    private func typeCaption(_ type: NativeRCVSourceType) -> String {
        switch type {
        case .webhook: "Any service that posts JSON"; case .whatsapp: "Messages to your number"; case .code: "Pushes, pull requests, runs"
        case .errors: "New and repeating errors"; case .crm: "Leads, tasks, deals"; case .uptime: "Site down and back up"
        case .server: "Disk, memory, crashes"; case .chat: "Messages in a channel"; case .containers: "Containers start and stop"
        }
    }
    private var projectPicker: some View {
        Picker("Project", selection: $projectID) { ForEach(model.projects) { DeckRowLabel.project($0).tag($0.id) } }.labelsHidden()
    }
    private var destination: Binding<String> {
        Binding(get: {
            switch target.kind { case .hoot: "hoot"; case .newTask: "task"; case .agent: "agent:" + target.id; case .session: "session:" + target.id }
        }, set: { value in
            if value == "hoot" { target = .init() }
            else if value == "task" { target = .init(kind: .newTask, id: "none") }
            else if value.hasPrefix("agent:") { target = .init(kind: .agent, id: String(value.dropFirst(6))) }
            else { target = .init(kind: .session, id: String(value.dropFirst(8))) }
        })
    }
    private func address(_ created: RCVPresentation.Created) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            let value = created.reveal?.addressWithSecret ?? created.source.address ?? ""
            HStack { Text(value).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).lineLimit(4); Spacer(); NativeRCVCopyButton(value: value) }
                .padding(16).background(NativeRCVSurface.card, in: .rect(cornerRadius: 12))
            Text("Keep this address private. Proof and headers are in Source settings.").font(.callout).foregroundStyle(.secondary)
            Button(model.busy == "test-source" ? "Checking…" : "Send a test event") { Task { await model.testSource(created.source) } }.disabled(model.busy != nil)
            if let note = model.actionNote { Text(note).font(.callout).foregroundStyle(.secondary) }
            Button("Source settings…") { NativeRCVSourceWindows.shared.open(model: model, view: created.source) }
        }
    }
    private func create() {
        Task { if let answer = await model.createSource(preset: savedPreset ?? type.preset(in: model.presets), name: name, auth: nil, type: type, projectID: projectID) { created = answer; configure(answer) } }
    }
    private func configure(_ answer: RCVPresentation.Created) {
        Task { if let result = await model.configureCreated(answer, type: type, projectID: projectID, target: target) { created = result; configured = true } }
    }
}
// MARK: - Sign-in, replies and reading fields

/// How a sender proves itself: the scheme, its settings, and the allow-list.
struct NativeRCVAuthFields: View {
    @Binding var auth: RCVAuth
    @Binding var ipText: String
    let preset: RCVPreset?

    var body: some View {
        NativeSettingRow(label: "Proof", help: RCVPresentation.authHelp(auth.scheme)) {
            Picker("Proof", selection: Binding(get: { auth.scheme }, set: { auth = RCVPresentation.auth($0, from: auth, preset: preset) })) {
                ForEach(RCVAuthScheme.allCases, id: \.self) { scheme in Text(scheme.title).tag(scheme) }
            }
            .labelsHidden()
            .fixedSize()
        }
        switch auth.scheme {
        case .hmac:
            let hmac = Binding(get: { auth.hmac ?? RCVHMAC(header: "") }, set: { auth.hmac = $0 })
            NativeSettingRow(label: "Signature header", help: "The header the sender puts its signature in, in lowercase.") {
                monoField("x-hub-signature-256", hmac.header)
            }
            NativeSettingRow(label: "Method") {
                HStack(spacing: 6) {
                    Picker("Algorithm", selection: hmac.algorithm) {
                        ForEach(RCVHMAC.Algorithm.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    Picker("Encoding", selection: hmac.encoding) {
                        ForEach(RCVHMAC.Encoding.allCases, id: \.self) { Text($0 == .hex ? "Hex" : "Base64").tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
            NativeSettingRow(label: "Text before the signature", help: "For example sha256=. Empty when there is none.") {
                monoField("sha256=", hmac.prefix)
            }
            NativeSettingRow(label: "What is signed", help: "{body} is the delivery. Some senders sign {timestamp}.{body}.") {
                monoField("{body}", hmac.signedPayload)
            }
            if hmac.wrappedValue.signedPayload.contains("{timestamp}") {
                NativeSettingRow(label: "Timestamp header") {
                    monoField("x-timestamp", Binding(get: { hmac.wrappedValue.timestampHeader ?? "" },
                                                     set: { hmac.wrappedValue.timestampHeader = $0.isEmpty ? nil : $0 }))
                }
                NativeSettingRow(label: "Oldest accepted", help: "In seconds. Older signed deliveries are rejected.") {
                    TextField("300", value: hmac.toleranceSeconds, format: .number)
                        .labelsHidden().frame(width: 80)
                }
            }
        case .token:
            NativeSettingRow(label: "Extra header", help: "Optional: a header the secret may also arrive in, besides “Authorization: Bearer”.") {
                monoField("x-api-key", Binding(get: { auth.tokenHeader ?? "" }, set: { auth.tokenHeader = $0.isEmpty ? nil : $0.lowercased() }))
            }
        case .basic:
            NativeSettingRow(label: "User name", help: "The password is the source’s secret.") {
                TextField("receiver", text: Binding(get: { auth.basicUser ?? "" }, set: { auth.basicUser = $0 }))
                    .labelsHidden().frame(minWidth: 160, maxWidth: 220)
            }
        case .none:
            EmptyView()
        }
        NativeSettingRow(label: "Only from these addresses", help: "Optional. One IP address or range per line, like 203.0.113.0/24. Empty: anyone with the address.") {
            TextField("Any address", text: $ipText, axis: .vertical)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1...6)
                .labelsHidden()
                .frame(minWidth: 180, maxWidth: 240)
        }
    }

    private func monoField(_ prompt: String, _ text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .font(.system(.body, design: .monospaced))
            .labelsHidden()
            .frame(minWidth: 180, maxWidth: 240)
    }
}

/// Replies use a web request or the code host's comment API.
struct NativeRCVReplyFields: View {
    @Binding var reply: RCVReplyChannel

    var body: some View {
        NativeSettingRow(label: "Send replies by", help: reply.via == .github ? "Comments on the issue or pull request, using your code host sign-in." : "A web request to the sender’s service.") {
            Picker("Send replies by", selection: $reply.via) {
                Text("Web request").tag(RCVReplyChannel.Via.http)
                Text("Code host comment").tag(RCVReplyChannel.Via.github)
            }
            .labelsHidden().fixedSize()
        }
        switch reply.via {
        case .http:
            NativeSettingRow(label: "Address", help: "Must be https. The host is fixed; the message may fill the rest, like {{fields.chat}}.") {
                HStack(spacing: 6) {
                    Picker("Method", selection: $reply.method) {
                        ForEach(["POST", "PUT", "PATCH"], id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    TextField("https://", text: $reply.url)
                        .font(.system(.body, design: .monospaced))
                        .labelsHidden()
                        .frame(minWidth: 220, maxWidth: 320)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Headers")
                Text("{{secret.reply}} is the reply key below.").font(.callout).foregroundStyle(.secondary)
                NativeRCVPairsEditor(pairs: $reply.headers, namePrompt: "Header", valuePrompt: "Value", addLabel: "Add a header")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Body")
                Text("{{reply}} is the agent’s text.").font(.callout).foregroundStyle(.secondary)
                TextField("{\"text\":\"{{reply}}\"}", text: $reply.body, axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(2...8)
                    .labelsHidden()
            }
        case .github:
            NativeSettingRow(label: "Repository", help: "owner/name, usually {{fields.repo}}.") {
                TextField("{{fields.repo}}", text: Binding(get: { reply.repository ?? "" }, set: { reply.repository = $0 }))
                    .font(.system(.body, design: .monospaced)).labelsHidden().frame(minWidth: 180, maxWidth: 240)
            }
            NativeSettingRow(label: "Issue or pull request", help: "Its number, usually {{fields.number}}.") {
                TextField("{{fields.number}}", text: Binding(get: { reply.number ?? "" }, set: { reply.number = $0 }))
                    .font(.system(.body, design: .monospaced)).labelsHidden().frame(minWidth: 180, maxWidth: 240)
            }
        }
    }
}

/// How a delivery becomes an event: the envelope's values, extra fields, what to ignore, and the split.
struct NativeRCVMappingFields: View {
    @Binding var mapping: RCVMapping
    let suggestions: [String]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
            row("Title", "{{title|subject}}", $mapping.title)
            row("Text", "{{message|text}}", $mapping.text)
            row("Type", "{{type|\"event\"}}", $mapping.kind)
            row("Level", "{{severity|\"info\"}}", $mapping.severity)
            row("Time", "{{timestamp}}", Binding(get: { mapping.time ?? "" }, set: { mapping.time = $0.isEmpty ? nil : $0 }))
            row("Sender’s id", "{{id}}", Binding(get: { mapping.upstreamId ?? "" }, set: { mapping.upstreamId = $0.isEmpty ? nil : $0 }))
            row("One event per item of", "messages", Binding(get: { mapping.split ?? "" }, set: { mapping.split = $0.isEmpty ? nil : $0 }))
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("Fields")
            Text("Your own fields: a name and a {{path}}. Rules and replies use them as {{fields.name}}; a task made from the event gets each one (task fields by name, the rest as custom fields).")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            NativeRCVPairsEditor(pairs: $mapping.fields, namePrompt: "name", valuePrompt: "{{path}}", addLabel: "Add a field")
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("Ignore")
            Text("Messages matching any of these are kept but never sent anywhere, like echoes of your own replies.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            NativeRCVConditionsEditor(conditions: $mapping.ignore, suggestions: suggestions, addLabel: "Add an ignore condition")
        }
    }

    private func row(_ label: String, _ prompt: String, _ text: Binding<String>) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            TextField(prompt, text: text)
                .font(.system(.body, design: .monospaced))
                .labelsHidden()
        }
    }
}

/// Name · value rows with remove buttons, and "Add".
struct NativeRCVPairsEditor: View {
    @Binding var pairs: [RCVFieldMap]
    let namePrompt: String
    let valuePrompt: String
    let addLabel: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(pairs.indices), id: \.self) { index in
                HStack(spacing: 6) {
                    TextField(namePrompt, text: binding(index, \.name))
                        .font(.system(.body, design: .monospaced))
                        .labelsHidden()
                        .frame(width: 150)
                    TextField(valuePrompt, text: binding(index, \.value))
                        .font(.system(.body, design: .monospaced))
                        .labelsHidden()
                    Button {
                        if pairs.indices.contains(index) { pairs.remove(at: index) }
                    } label: {
                        Image(systemName: "minus.circle")
                            .frame(width: 28, height: 28)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove")
                    .accessibilityLabel("Remove")
                }
            }
            Button(addLabel) { pairs.append(RCVFieldMap("", "")) }
                .buttonStyle(.borderless)
        }
    }

    private func binding(_ index: Int, _ key: WritableKeyPath<RCVFieldMap, String>) -> Binding<String> {
        Binding(get: { pairs.indices.contains(index) ? pairs[index][keyPath: key] : "" },
                set: { if pairs.indices.contains(index) { pairs[index][keyPath: key] = $0 } })
    }
}
