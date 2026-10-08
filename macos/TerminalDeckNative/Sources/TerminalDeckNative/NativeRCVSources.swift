import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// Sources: every place things come from, each with its address to paste into the
/// sender, and one source's own page in place of the list (as Machines swaps to a server).
struct NativeRCVSourcesPage: View {
    let model: NativeRCVModel

    var body: some View {
        if let id = model.openSourceID, let view = model.sourceView(id) {
            NativeRCVSourcePage(model: model, view: view)
                .id(id)
        } else {
            list
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Text("Each source has its own address. Paste it into the service that sends to it; what arrives shows up in Flow.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 560, alignment: .leading)
                Spacer(minLength: 12)
                Button("Add source") { model.openSheet(.addSource) }
            }
            NativeRCVActionLine(model: model)
            if model.sources.isEmpty {
                let empty = RCVPresentation.emptySources
                NativePageEmpty(symbol: empty.symbol, title: empty.title,
                                action: PageEmptyAction(label: empty.action ?? "Add a source", primary: true, perform: { model.openSheet(.addSource) })) {
                    Text(empty.message)
                }
            } else {
                TimelineView(.everyMinute) { context in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(model.sources) { view in
                                NativeRCVSourceRow(view: view, symbol: RCVPresentation.sourceSymbol(view.source, presets: model.presets), now: context.date) {
                                    model.actionError = nil; model.actionNote = nil
                                    model.openSourceID = view.id
                                }
                            }
                        }
                        .padding(.trailing, 6)
                    }
                }
            }
        }
    }
}

/// One source: symbol, name, state and counts, then its address with Copy.
private struct NativeRCVSourceRow: View {
    let view: RCVSourceView
    let symbol: String
    let now: Date
    let open: () -> Void

    var body: some View {
        let state = RCVPresentation.state(view)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: SymbolName.resolve(symbol, fallback: "arrow.down.circle"))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(view.source.name).fontWeight(.medium).lineLimit(1)
                    NativeRCVStatusLabel(word: state.word, symbol: state.symbol, tone: state.tone).font(.caption)
                    Spacer(minLength: 8)
                    Text(RCVPresentation.summary(view, now: now)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let address = view.address {
                    HStack(spacing: 8) {
                        Text(address)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        NativeRCVCopyButton(value: address).controlSize(.small)
                    }
                } else {
                    Text(RCVPresentation.addressLine(view)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).padding(.top, 3)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(NativeRCVPick(selected: false))
        .onTapGesture(perform: open)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(view.source.name), \(state.word)")
        .accessibilityAction(named: "Open", open)
    }
}

// MARK: - One source

private struct NativeRCVSourcePage: View {
    let model: NativeRCVModel
    let view: RCVSourceView
    @State private var draft: RCVSource
    @State private var ipText: String
    @State private var replyKey = ""
    @State private var showMapping = false
    @State private var confirmDelete = false
    @State private var confirmRotate = false
    @State private var namingPreset = false
    @State private var presetName = ""

    init(model: NativeRCVModel, view: RCVSourceView) {
        self.model = model
        self.view = view
        _draft = State(initialValue: view.source)
        _ipText = State(initialValue: RCVPresentation.addressesText(view.source.auth.ipAllow))
    }

    private var builtIn: Bool { draft.origin == .terminalDeck || RCVPresets.isInternal(draft.id) }
    private var edited: RCVSource {
        var copy = draft
        copy.auth.ipAllow = RCVPresentation.addresses(ipText)
        return copy
    }
    private var changed: Bool { edited != view.source }
    private var problem: String? {
        do { try RCVEngine.validate(edited); return nil } catch { return RCVPresentation.sentence(error) }
    }
    private var latest: RCVEvent? { model.recentEvents(of: [view.id]).first }

    var body: some View {
        VStack(spacing: 0) {
            head
            Form {
                if let error = model.actionError { Section { NativeCodingAINotice(tone: .error, text: error) } }
                address
                basics
                if !builtIn {
                    proof
                    replies
                    reading
                }
                more
            }
            .formStyle(.grouped)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            NativeRCVSheetBar {
                if let busy = model.busy, ["save-source", "learn", "rotate", "reveal", "secret-set", "reply-credential", "save-preset", "delete-source"].contains(busy) {
                    NativePageNote("Working…", busy: true).frame(maxHeight: 24)
                } else if changed, let problem {
                    Text(problem).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if let note = model.actionNote {
                    Text(note).font(.callout).foregroundStyle(.secondary)
                }
            } trailing: {
                Button("Undo changes") { draft = view.source; ipText = RCVPresentation.addressesText(view.source.auth.ipAllow) }
                    .disabled(!changed || model.busy != nil)
                Button("Save") { Task { await model.saveSource(edited) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!changed || problem != nil || model.busy != nil)
            }
        }
        .onChange(of: view.source) { old, new in
            // A refresh brings the saved source; keep what the owner is typing.
            if draft == old { draft = new; ipText = RCVPresentation.addressesText(new.auth.ipAllow) }
        }
        .confirmationDialog(RCVPresentation.deleteQuestion(view.source), isPresented: $confirmDelete) {
            Button("Delete “\(view.source.name)”", role: .destructive) { Task { await model.deleteSource(view.id) } }
        } message: {
            Text(RCVPresentation.deleteWarning(view.source))
        }
        .confirmationDialog(RCVPresentation.rotateQuestion, isPresented: $confirmRotate) {
            Button("Replace the secret", role: .destructive) { Task { await model.revealSecret(view.id, replace: true) } }
        } message: {
            Text(RCVPresentation.rotateWarning)
        }
        .alert("Save as a preset", isPresented: $namingPreset) {
            TextField("Preset name", text: $presetName)
            Button("Save") { Task { await model.savePreset(view.id, name: presetName) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its sign-in, how its messages are read and its reply settings are offered as a starting point when you add a source. Secrets are never copied.")
        }
    }

    private var head: some View {
        let state = RCVPresentation.state(view)
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button {
                model.openSourceID = nil
                model.actionError = nil; model.actionNote = nil
            } label: {
                Label("Sources", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            Image(systemName: SymbolName.resolve(RCVPresentation.sourceSymbol(view.source, presets: model.presets), fallback: "arrow.down.circle"))
                .foregroundStyle(.secondary)
            Text(view.source.name).font(.title3.weight(.semibold)).lineLimit(1)
            NativeRCVStatusLabel(word: state.word, symbol: state.symbol, tone: state.tone).font(.callout)
            Spacer()
            Text(RCVPresentation.summary(view)).font(.caption).foregroundStyle(.secondary)
            Button("Show its events") {
                model.sourceFilter = view.id
                model.go(.flow)
            }
            .disabled(view.eventCount == 0)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
    }

    // MARK: Sections

    @ViewBuilder private var address: some View {
        Section {
            if let address = view.address {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Address")
                        Spacer()
                        NativeRCVCopyButton(value: address)
                    }
                    NativeRCVMonoBlock(text: address, lineLimit: 2)
                    Text(RCVPresentation.addressLine(view)).font(.callout).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Text("Secret")
                    Spacer()
                    Button("Show secret") { Task { await model.revealSecret(view.id, replace: false) } }
                        .disabled(model.busy != nil)
                    Button("Replace secret…") { confirmRotate = true }
                        .disabled(model.busy != nil)
                }
                if RCVPresentation.offersOwnSecret(view.source) {
                    NativeRCVOwnSecretRow(model: model, sourceID: view.id) { reveal in
                        // A token source's address with the secret built in changed with it.
                        if reveal.addressWithSecret != nil {
                            model.openSheet(.reveal(reveal, help: RCVPresentation.revealHelp(view, presets: model.presets)))
                            model.actionNote = RCVPresentation.ownSecretSaved
                        }
                    }
                }
            } else {
                Text(RCVPresentation.addressLine(view)).foregroundStyle(.secondary)
            }
        }
    }

    private var basics: some View {
        Section {
            NativeSettingRow(label: "Name", help: "What this page and the rules call it.") {
                TextField("Name", text: $draft.name)
                    .labelsHidden()
                    .frame(minWidth: 200, maxWidth: 260)
                    .disabled(builtIn)
            }
            NativeSettingRow(label: "Receiving", help: draft.enabled ? "On. What it sends is handed to the rules." : "Paused. Nothing it sends is handed on until you turn it back on.") {
                Toggle("Receiving", isOn: $draft.enabled).labelsHidden().toggleStyle(.switch)
            }
        }
    }

    @ViewBuilder private var proof: some View {
        Section("How the sender proves itself") {
            NativeRCVAuthFields(auth: $draft.auth, ipText: $ipText, preset: RCVPresets.named(draft.preset, custom: model.presets))
        }
    }

    @ViewBuilder private var replies: some View {
        Section("Replies") {
            NativeSettingRow(label: "Answer through this source", help: "Agents can reply to the sender; you approve each reply unless a rule says otherwise.") {
                Toggle("Answer through this source", isOn: Binding(get: { draft.reply != nil }, set: { on in
                    draft.reply = on ? (RCVPresets.named(draft.preset, custom: model.presets)?.reply ?? RCVReplyChannel()) : nil
                }))
                .labelsHidden()
                .toggleStyle(.switch)
            }
            if draft.reply != nil {
                NativeRCVReplyFields(reply: Binding(get: { draft.reply ?? RCVReplyChannel() }, set: { draft.reply = $0 }))
                NativeSettingRow(label: "Reply key", help: view.hasReplyCredential
                                 ? "Set. It is kept in the secure store and never shown again. Fills {{secret.reply}}."
                                 : "Not set. The key the sender’s service gave you for sending; it fills {{secret.reply}}.") {
                    HStack(spacing: 6) {
                        SecureField(view.hasReplyCredential ? "Replace the key" : "Paste the key", text: $replyKey)
                            .labelsHidden()
                            .frame(minWidth: 160, maxWidth: 220)
                        Button("Save key") {
                            Task {
                                if await model.setReplyCredential(view.id, value: replyKey) { replyKey = "" }
                            }
                        }
                        .disabled(replyKey.isEmpty || model.busy != nil)
                        if view.hasReplyCredential {
                            Button("Remove") { Task { await model.setReplyCredential(view.id, value: "") } }
                                .disabled(model.busy != nil)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var reading: some View {
        Section {
            DisclosureGroup(isExpanded: $showMapping) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Each value can read the message with {{path}}, try several with {{a|b}}, or give a fallback with {{a|\"text\"}}.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button(model.busy == "learn" ? "Learning…" : "Learn from the last event") {
                            Task {
                                if let mapping = await model.learn(view.id, eventID: latest?.id) { draft.mapping = mapping }
                            }
                        }
                        .disabled(latest == nil || model.busy != nil)
                        .help(latest == nil ? "Nothing has arrived from it yet." : "Guess how its messages are read from the newest one")
                    }
                    NativeRCVMappingFields(mapping: $draft.mapping,
                                           suggestions: RCVPresentation.paths(sources: [draft], events: model.recentEvents(of: [view.id])))
                    preview
                }
                .padding(.top, 8)
            } label: {
                Text("Advanced: how the message is read")
            }
        }
    }

    @ViewBuilder private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            NativeRCVHeading("Preview with the last event")
            if let latest {
                let events = RCVPresentation.preview(edited, sample: latest)
                if let first = events.first {
                    NativeRCVPairs(pairs: [
                        .init("Title", first.title), .init("Text", first.text), .init("Type", first.kind),
                        .init("Level", first.severity.rawValue), .init("Sender’s id", first.upstreamId ?? "—"),
                    ] + RCVPresentation.fields(first).map { RCVPresentation.Pair("fields." + $0.name, $0.value) })
                    if first.status == .ignored {
                        Text("Its ignore list matches this one, so it would not be sent anywhere.").font(.callout).foregroundStyle(.secondary)
                    }
                    if events.count > 1 {
                        Text("One delivery like this becomes \(events.count) events.").font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    Text("Nothing came out of the last event with these settings.").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Text("Nothing has arrived yet. The preview appears with the first event.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var more: some View {
        Section {
            HStack(spacing: 8) {
                if !builtIn {
                    Button("Save as a preset…") { presetName = view.source.name; namingPreset = true }
                        .disabled(model.busy != nil)
                        .help("Offer these settings as a starting point when adding a source")
                }
                Spacer()
                if RCVPresentation.canDelete(view.source) {
                    Button("Delete source…", role: .destructive) { confirmDelete = true }
                        .disabled(model.busy != nil)
                } else {
                    Text("Built in. It can be paused, not deleted.").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
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

/// Where replies go: an https address with headers and a body, or GitHub.
private struct NativeRCVReplyFields: View {
    @Binding var reply: RCVReplyChannel

    var body: some View {
        NativeSettingRow(label: "Send replies by", help: reply.via == .github ? "Comments on the issue or pull request, with your GitHub sign-in." : "A web request to the sender’s service.") {
            Picker("Send replies by", selection: $reply.via) {
                Text("Web request").tag(RCVReplyChannel.Via.http)
                Text("GitHub comment").tag(RCVReplyChannel.Via.github)
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
private struct NativeRCVMappingFields: View {
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
            Text("Named values rules and replies can use as {{fields.name}}.").font(.callout).foregroundStyle(.secondary)
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

// MARK: - Add a source

/// Pick what sends to it, name it, choose how it proves itself, create — then its
/// secret, shown once.
struct NativeRCVAddSourceSheet: View {
    let model: NativeRCVModel
    @State private var preset: RCVPreset?
    @State private var name = ""
    @State private var auth = RCVAuth(scheme: .token)
    @State private var ipText = ""
    @State private var created: RCVPresentation.Created?

    init(model: NativeRCVModel, preset: RCVPreset? = nil) {
        self.model = model
        _preset = State(initialValue: preset)
        _auth = State(initialValue: preset?.auth ?? RCVAuth(scheme: .token))
    }

    var body: some View {
        if let created {
            NativeRCVCreatedView(model: model, created: created, help: preset?.help ?? RCVPresentation.revealHelp(created.source, presets: model.presets)) {
                model.openSheet(nil)
                model.go(.sources)
                model.openSourceID = created.source.id
            }
        } else {
            form
        }
    }

    private var draftAuth: RCVAuth {
        var copy = auth
        copy.ipAllow = RCVPresentation.addresses(ipText)
        return copy
    }

    private var problem: String? {
        guard preset != nil else { return "Choose what sends to it." }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give it a name." }
        return nil
    }

    private var form: some View {
        VStack(spacing: 0) {
            NativeSettingsHead(title: "Add a source", blurb: "It gets its own address. You paste that into the service that sends to it.")
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 30)
                .padding(.top, 18)
            Form {
                if let error = model.actionError { Section { NativeCodingAINotice(tone: .error, text: error) } }
                Section("What sends to it") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(RCVPresentation.creatable(model.presets)) { choice in
                            NativeRCVPresetCard(preset: choice, on: preset?.id == choice.id) { pick(choice) }
                        }
                    }
                    .padding(.vertical, 4)
                }
                if let preset {
                    Section {
                        Text(preset.help).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        NativeSettingRow(label: "Name", help: "What this page and the rules call it.") {
                            TextField(preset.name, text: $name)
                                .labelsHidden()
                                .frame(minWidth: 200, maxWidth: 260)
                        }
                    }
                    if RCVPresentation.authChoosable(preset) {
                        Section("How the sender proves itself") {
                            NativeRCVAuthFields(auth: $auth, ipText: $ipText, preset: preset)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            .disabled(model.busy == "create-source")
            NativeRCVSheetBar {
                if model.busy == "create-source" {
                    NativePageNote("Making the address…", busy: true).frame(maxHeight: 24)
                } else if let problem {
                    Text(problem).font(.callout).foregroundStyle(.secondary)
                }
            } trailing: {
                Button("Cancel") { model.openSheet(nil) }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.busy == "create-source")
                Button("Add source") { create() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(problem != nil || model.busy != nil)
            }
        }
        .frame(width: 680, height: 640)
        .interactiveDismissDisabled(model.busy == "create-source")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Add a source")
    }

    private func pick(_ choice: RCVPreset) {
        let previousName = preset?.name ?? ""
        preset = choice
        if name.isEmpty || name == previousName { name = choice.name }
        auth = choice.auth
        ipText = RCVPresentation.addressesText(choice.auth.ipAllow)
    }

    private func create() {
        guard let preset, problem == nil else { return }
        let chosen: RCVAuth? = RCVPresentation.authChoosable(preset) ? draftAuth : nil
        Task {
            if let answer = await model.createSource(preset: preset, name: name, auth: chosen) { created = answer }
        }
    }
}

/// One preset to start from: symbol, name, and its sentence.
private struct NativeRCVPresetCard: View {
    let preset: RCVPreset
    let on: Bool
    let pick: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: pick) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: SymbolName.resolve(preset.symbol, fallback: "arrow.down.circle")).foregroundStyle(.secondary)
                    Text(preset.name).fontWeight(.medium).foregroundStyle(on ? Color.primary : Color.primary.opacity(0.85))
                    Spacer(minLength: 4)
                    if on { Image(systemName: "checkmark").foregroundStyle(.secondary) }
                }
                Text(preset.help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
            .background(on ? Color.primary.opacity(0.1) : hover ? Color.primary.opacity(0.06) : Color.primary.opacity(0.03), in: .rect(cornerRadius: 8))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(on ? .isSelected : [])
        .help(preset.help)
    }
}

/// "Use the sender’s own secret": paste it, Save. Never shown back.
private struct NativeRCVOwnSecretRow: View {
    let model: NativeRCVModel
    let sourceID: String
    var saved: (RCVSecretReveal) -> Void = { _ in }
    @State private var value = ""

    var body: some View {
        NativeSettingRow(label: RCVPresentation.ownSecretTitle, help: RCVPresentation.ownSecretHelp) {
            HStack(spacing: 6) {
                SecureField("Paste their secret", text: $value)
                    .labelsHidden()
                    .frame(minWidth: 160, maxWidth: 220)
                Button(model.busy == "secret-set" ? "Saving…" : "Save") {
                    Task {
                        if let reveal = await model.setSecret(sourceID, value: value) {
                            value = ""
                            saved(reveal)
                        }
                    }
                }
                .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy != nil)
            }
        }
    }
}

/// Right after "Add source": the address, and the secret shown once.
private struct NativeRCVCreatedView: View {
    let model: NativeRCVModel
    let created: RCVPresentation.Created
    let help: String
    let done: () -> Void
    @State private var ownSaved = false

    /// Sentry-like senders bring their own secret: ask for it instead of showing ours.
    private var ownFirst: Bool { RCVPresentation.ownSecretFirst(created.source.source) }

    var body: some View {
        VStack(spacing: 0) {
            NativeSettingsHead(title: "“\(created.source.source.name)” is ready", blurb: help)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 30)
                .padding(.top, 18)
            Form {
                if let error = model.actionError { Section { NativeCodingAINotice(tone: .error, text: error) } }
                if created.reveal != nil && !ownFirst { Section { NativeCodingAINotice(tone: .warn, text: RCVPresentation.revealWarning) } }
                Section {
                    if let address = created.source.address {
                        row("Address", "Paste it into the service that sends to it.", address)
                    } else {
                        Text(RCVPresentation.addressLine(created.source)).foregroundStyle(.secondary)
                    }
                    if ownFirst {
                        if ownSaved {
                            Label(RCVPresentation.ownSecretSaved, systemImage: "checkmark.circle").foregroundStyle(.secondary)
                        } else {
                            NativeRCVOwnSecretRow(model: model, sourceID: created.source.id) { _ in ownSaved = true }
                        }
                    } else if let reveal = created.reveal {
                        row("Secret", "Paste it where the sender asks for a secret or a token.", reveal.secret)
                        if let withSecret = reveal.addressWithSecret {
                            row("Address with the secret built in", "For senders that only take an address. Keep it private: anyone with it can send.", withSecret)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            NativeRCVSheetBar {
                EmptyView()
            } trailing: {
                Button(created.reveal == nil || ownFirst ? "Done" : "I’ve copied it", action: done)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 640, height: 520)
        .interactiveDismissDisabled(true)
    }

    private func row(_ label: String, _ hint: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                Spacer()
                NativeRCVCopyButton(value: value)
            }
            NativeRCVMonoBlock(text: value, lineLimit: 3)
            Text(hint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
