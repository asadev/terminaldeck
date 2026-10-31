import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// Exact GLITCH-CONTRACT v1 seam; enable only after READY GLITCH.
/// Its grouped Form owns scrolling; the frame adds no ScrollView.
private struct NativeRCVSourceSettingsFrame<Switcher: View, Content: View>: View {
    let title: String
    private let switcher: Switcher
    private let content: Content
    init(title: String, @ViewBuilder switcher: () -> Switcher, @ViewBuilder content: () -> Content) {
        self.title = title; self.switcher = switcher(); self.content = content()
    }
    var body: some View {
        // Preserve the existing toolbar/form look while the shared frame is a draft.
        VStack(spacing: 0) {
            switcher.frame(maxWidth: .infinity).padding(.vertical, 10).background(.bar)
            content
        }.frame(minWidth: 560, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
            .background(NativeRCVSurface.page).accessibilityLabel(title)
    }
}

/// One remembered window per source; it never changes the main page's size.
/// Production-only fallback: no tests may instantiate or open this manager.
/// ObjectWindows replaces it after the shared registration/close contract is ready.
@MainActor final class NativeRCVSourceWindows {
    static let shared = NativeRCVSourceWindows()
    private var windows: [String: NSWindow] = [:]
    private var closers: [String: NSObjectProtocol] = [:]
    func open(model: NativeRCVModel, view: RCVSourceView) {
        // Only for the person: a window is never raised over the app they are working in (NativeFront).
        NativeFront.whenPersonActs("receiver-source-" + view.id) { [self] in
            if let window = windows[view.id] { window.makeKeyAndOrderFront(nil); return }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = view.source.name
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 560, height: 420)
            window.contentView = NSHostingView(rootView: NativeRCVSourceSettingsView(model: model, view: view, close: { [weak window] in
                window?.close()
            }))
            closers[view.id] = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.closed(view.id) }
            }
            window.setFrameAutosaveName("receiver-source-" + view.id)
            if !window.setFrameUsingName("receiver-source-" + view.id), let main = NSApp.mainWindow {
                window.setFrameOrigin(NSPoint(x: main.frame.maxX - 80, y: main.frame.maxY - 560))
            }
            windows[view.id] = window
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// The red button only orders a window out, which sends its view no onDisappear. Taking the view
    /// out does: the source's model finishes its save and stops listening, and the window is let go.
    private func closed(_ id: String) {
        if let closer = closers.removeValue(forKey: id) { NotificationCenter.default.removeObserver(closer) }
        guard let window = windows.removeValue(forKey: id) else { return }
        Task { @MainActor in window.contentView = nil }
    }
}

struct NativeRCVSourceSettingsView: View {
    // Required root seam: sourceWindowModel() copies overview/projects and shares
    // the read closure, but owns its own busy/errors/sheet and subscriptions.
    @State private var model: NativeRCVModel
    private let initialView: RCVSourceView
    private let close: () -> Void
    private let ownsModelLifecycle: Bool
    @State private var draft: RCVSource
    @State private var baseline: RCVSource
    @State private var tab: String
    @State private var ips: String
    @State private var ownSecret = ""
    @State private var replyKey = ""
    @State private var remove = false
    @State private var replace = false
    @State private var namingPreset = false
    @State private var presetName = ""
    @State private var saveTask: Task<Void, Never>?
    @State private var editGeneration = 0
    @State private var pending = false
    @State private var saving = false
    @State private var saveError: String?
    @State private var closing = false
    @State private var deleted = false

    init(model: NativeRCVModel, view: RCVSourceView, initialTab: String = "General", sourceModel: NativeRCVModel? = nil, close: @escaping () -> Void = {}) {
        initialView = view; self.close = close
        ownsModelLifecycle = sourceModel == nil
        // Fixed-host fixtures may supply an isolated, already populated child
        // rather than depending on appearance to run an asynchronous read.
        _model = State(initialValue: sourceModel ?? model.sourceWindowModel(sourceID: view.id))
        _draft = State(initialValue: view.source); _baseline = State(initialValue: view.source)
        _tab = State(initialValue: initialTab)
        _ips = State(initialValue: RCVPresentation.addressesText(view.source.auth.ipAllow))
    }
    private var view: RCVSourceView { model.sourceView(initialView.id) ?? initialView }
    private var builtIn: Bool { draft.origin == .terminalDeck }
    private let tabs = ["General", "Events", "Rules", "Address", "Log"]
    private var dirty: Bool { draft != baseline }
    private var working: Bool { pending || saving || model.busy != nil }
    private var sourceMissing: Bool {
        guard let overview = model.overview, !model.loading else { return false }
        return !overview.sources.contains { $0.id == initialView.id }
    }

    var body: some View {
        NativeRCVSourceSettingsFrame(title: view.source.name, switcher: { tabToolbar }) {
            VStack(spacing: 0) { settingsForm; saveFooter }
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        }
        .onAppear {
            closing = false
            if sourceMissing { finishDeletedSource() }
            else if ownsModelLifecycle { model.start(); model.search() }
        }
        .onChange(of: draft) { _, _ in scheduleSave() }
        .onChange(of: ips) { _, _ in
            let addresses = RCVPresentation.addresses(ips)
            if draft.auth.ipAllow != addresses { draft.auth.ipAllow = addresses }
        }
        .onChange(of: view.source) { _, incoming in accept(incoming) }
        .onChange(of: sourceMissing) { _, missing in if missing { finishDeletedSource() } }
        .onDisappear {
            guard ownsModelLifecycle else { return }
            closing = true
            // Let one existing writer finish, then flush any newer edits in order.
            // Do not cancel an in-flight write and race it with a second save.
            if deleted || (!pending && !saving) { model.stop() }
            else if saveTask == nil { scheduleSave() }
        }
        .sheet(item: $model.sheet) { sheet in NativeRCVSheetView(model: model, sheet: sheet) }
        .confirmationDialog("Delete “\(draft.name)” and its address?", isPresented: $remove) {
            Button("Delete source", role: .destructive) {
                Task {
                    await model.deleteSource(view.id)
                    if model.actionError == nil { finishDeletedSource() }
                }
            }
        }
        .confirmationDialog(RCVPresentation.rotateQuestion, isPresented: $replace) {
            Button("Replace the secret", role: .destructive) { Task { await model.revealSecret(view.id, replace: true) } }
        } message: { Text(RCVPresentation.rotateWarning) }
        .alert("Save as a preset", isPresented: $namingPreset) {
            TextField("Preset name", text: $presetName)
            Button("Save") { Task { await model.savePreset(view.id, name: presetName) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Its proof, message reading and reply settings become a starting point. Secrets are never copied.") }
    }

    private var tabToolbar: some View {
        HStack(spacing: 4) {
            ForEach(tabs, id: \.self) { item in
                Button { tab = item } label: {
                    VStack(spacing: 4) {
                        Image(systemName: symbol(item)).font(.system(size: 17)).foregroundStyle(.secondary)
                        Text(item).font(.caption)
                    }
                        .foregroundStyle(.primary).frame(width: 72, height: 52)
                        .background(tab == item ? Color.primary.opacity(0.07) : .clear, in: .rect(cornerRadius: 10)).contentShape(.rect)
                }.buttonStyle(.plain).help("Show " + item.lowercased() + " settings")
                    .accessibilityLabel(item).accessibilityAddTraits(tab == item ? .isSelected : [])
            }
        }.accessibilityElement(children: .contain).accessibilityLabel("Source settings tabs")
    }
    private var settingsForm: some View {
        Form {
            if let error = saveError ?? model.actionError ?? model.error {
                Section { Text(error).font(.callout).foregroundStyle(.red) }
            }
            switch tab {
            case "Address": address
            case "Events": events
            case "Rules": rules
            case "Log": log
            default: general
            }
        }.formStyle(.grouped).textFieldStyle(.roundedBorder)
            .frame(minHeight: 0, maxHeight: .infinity)
    }
    private var saveFooter: some View {
        HStack {
            if saving { ProgressView().controlSize(.small); Text("Saving…") }
            else if pending { Text("Changes waiting to save…") }
            else if saveError != nil {
                Text("Changes haven’t saved.")
                Button("Try again") { scheduleSave() }.disabled(model.busy != nil)
                    .help("Try saving these source changes again")
            } else if let note = model.actionNote { Text(note).lineLimit(1) }
            Spacer()
        }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20).frame(height: 28)
            .accessibilityElement(children: .contain).accessibilityLabel("Save status")
    }

    private func symbol(_ item: String) -> String {
        switch item { case "General": "gearshape"; case "Address": "link"; case "Events": "tray"; case "Rules": "line.3.horizontal.decrease"; default: "list.bullet.rectangle" }
    }
    private var general: some View {
        Group {
            Section {
                LabeledContent("Name") { TextField("Name", text: $draft.name).labelsHidden().frame(maxWidth: 250).accessibilityLabel("Source name") }
                LabeledContent("Type", value: builtIn ? "Built in" : NativeRCVSourceType.of(draft).rawValue)
                LabeledContent("Project") {
                    Picker("Project", selection: Binding<String?>(get: { draft.projectId }, set: { newValue in
                        draft.projectId = newValue
                        draft.projectScope = builtIn && newValue == nil ? .all : .project
                    })) {
                        // Every row shows the project's logo (or letter tile) beside its name.
                        if builtIn { DeckRowLabel.allProjects.tag(nil as String?) }
                        else if draft.projectId == nil { Text("Choose a project").tag(nil as String?) }
                        DeckRowLabel.independent.tag(Optional(PROJProjects.independentID))
                        ForEach(model.projects.filter { $0.id != PROJProjects.independentID }) { DeckRowLabel.project($0).tag(Optional($0.id)) }
                        if let id = draft.projectId, id != PROJProjects.independentID, !model.projects.contains(where: { $0.id == id }) {
                            DeckRowLabel(PROJProjects.name(for: id, projects: model.projects), image: DeckRowIcon.project(nil, name: PROJProjects.name(for: id, projects: model.projects))).tag(Optional(id))
                        }
                    }.labelsHidden().accessibilityLabel("Source project")
                        .help(builtIn ? "All projects and Independent are separate choices" : "Choose the project for this source")
                }
                Toggle("Receiving", isOn: $draft.enabled).toggleStyle(.switch).tint(Color.accentColor).help("Pause or resume this source")
            }
            Section {
                Button("Send a test event") { Task { await model.testSource(view) } }.disabled(working || dirty)
                    .help("Check a sample through parsing and rules without sending it to an AI")
                if builtIn { Text("Built in · can be paused, not deleted").font(.callout).foregroundStyle(.secondary) }
                else { Button("Delete source…", role: .destructive) { remove = true }.disabled(working || dirty).help("Confirm removal of this source and its address") }
            }
            if !builtIn { replies }
        }
    }
    private var address: some View {
        Group {
            if builtIn {
                Section {
                    Label("Built in · no address or secret needed", systemImage: "checkmark.circle")
                    Text("Terminal Deck sends these events directly. Receiving and event choices are in General and Events.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Section("Paste this address") {
                    if let address = view.address {
                        HStack { Text(address).font(.system(size: 12, design: .monospaced)).textSelection(.enabled); Spacer(); NativeRCVCopyButton(value: address) }
                        Text(NativeRCVSourceType.of(draft).pasteHelp).font(.callout).foregroundStyle(.secondary)
                    } else { Text("The relay address is unavailable.").foregroundStyle(.secondary) }
                    HStack {
                        Button("Show secret") { Task { await model.revealSecret(view.id, replace: false) } }.help("Show this source’s secret in a private sheet")
                        Button("Replace secret…") { replace = true }.help("Confirm replacing the secret used by senders")
                    }.disabled(working || dirty || draft.auth.scheme == .none)
                }
                Section("Proof") { NativeRCVAuthFields(auth: $draft.auth, ipText: $ips, preset: RCVPresets.named(draft.preset, custom: model.presets)) }
                if draft.auth.scheme != .none {
                    Section("Use the sender’s own secret") {
                        SecureField("Paste the sender’s secret", text: $ownSecret).accessibilityLabel("Sender’s secret")
                        Button("Save secret") {
                            Task { if await model.setSecret(view.id, value: ownSecret) != nil { ownSecret = "" } }
                        }.disabled(working || dirty || ownSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .help("Store the sender’s signing secret for this source")
                        Text("For senders that supply their own signing secret. It is never shown back.").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    private var events: some View {
        Group {
            if builtIn {
                Section("Which events") {
                    Text("Selected events pass on to your rules.").font(.callout).foregroundStyle(.secondary)
                    ForEach(eventKinds, id: \.self) { kind in
                        Toggle(kind.replacingOccurrences(of: ".", with: " · "), isOn: Binding(get: { !draft.mapping.ignore.contains { $0.path == "kind" && $0.operation == .equals && $0.value == kind } }, set: { on in
                            draft.mapping.ignore.removeAll { $0.path == "kind" && $0.operation == .equals && $0.value == kind }
                            if !on { draft.mapping.ignore.append(.init("kind", .equals, kind)) }
                        })).tint(Color.accentColor)
                    }
                }
            }
            if view.id == "terminaldeck.tasks" {
                Section {
                    Text("Tasks from your CRM (iMatch and iLoop CRM projects) arrive here through the CRM’s task link: what each one carried and the task it became. Another task system can send to a source of its own (Add source → CRM).")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            NativeRCVFieldMapSections(model: model, source: draft, mapping: $draft.mapping, working: working)
            Section("How the message is read") {
                NativeRCVMappingFields(mapping: $draft.mapping, suggestions: RCVPresentation.paths(sources: [draft], events: model.recentEvents(of: [view.id])))
            }
            if !builtIn {
                Section {
                    Button("Learn from the latest event") {
                        Task { if let mapping = await model.learn(view.id, eventID: model.recentEvents(of: [view.id]).first?.id) { draft.mapping = mapping } }
                    }.disabled(working || dirty || model.searchLoading || model.searchError != nil || model.searched == nil || model.recentEvents(of: [view.id]).isEmpty)
                        .help("Suggest message reading fields from the latest payload")
                    Button("Save as a preset…") { presetName = draft.name; namingPreset = true }.disabled(working || dirty).help("Save these source settings as a reusable preset without its secrets")
                }
            }
        }
    }
    private var eventKinds: [String] {
        let observed = model.recentEvents(of: [view.id]).map(\.kind)
        let defaults: [String]
        // Replace these defaults with the event publisher's accepted contract.
        switch view.id {
        case "terminaldeck.tasks": defaults = ["task.created", "task.assigned", "task.changed", "task.comment", "task.cancelled"]
        case "terminaldeck.sessions": defaults = ["session.started", "session.waiting", "session.finished"]
        case "terminaldeck.containers": defaults = ["docker.container.started", "docker.container.stopped", "docker.container.died", "docker.container.unhealthy"]
        case "terminaldeck.servers": defaults = ["server.unreachable", "apps.deploy.failed"]
        case "terminaldeck.staysfixed": defaults = ["staysfixed.failed", "staysfixed.passed"]
        case "terminaldeck.approvals": defaults = ["approval.requested", "approval.allowed", "approval.refused"]
        default: defaults = []
        }
        let paused = draft.mapping.ignore.filter { $0.path == "kind" && $0.operation == .equals }.map(\.value)
        return Array(Set(defaults + observed + paused)).sorted()
    }
    private var rules: some View {
        Section("Rules for this source") {
            ForEach(model.rules.filter { $0.sourceIds.isEmpty || $0.sourceIds.contains(view.id) }) { rule in
                HStack {
                    Button { model.openSheet(.rule(rule, isNew: false)) } label: {
                        VStack(alignment: .leading, spacing: 3) { Text(rule.name); Text("When this source sends an event → \(rule.target.kind.title)").font(.caption).foregroundStyle(.secondary) }
                            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).contentShape(.rect)
                    }.buttonStyle(.plain).disabled(working || dirty).help("Edit “\(rule.name)”")
                    Toggle("Enable \(rule.name)", isOn: Binding(get: { rule.enabled }, set: { on in Task { await model.setEnabled(rule, on) } }))
                        .labelsHidden().tint(Color.accentColor).disabled(working || dirty).help("Pause or resume “\(rule.name)”")
                }
            }
            Button("Add a rule") { model.openSheet(.rule(RCVPresentation.newRule(sourceIDs: [view.id]), isNew: true)) }.disabled(working || dirty).help("Create a routing rule for this source")
        }
    }
    private var replies: some View {
        Group {
            Section("Replies") {
                Toggle("Allow replies through this source", isOn: Binding(get: { draft.reply != nil }, set: { draft.reply = $0 ? RCVPresets.named(draft.preset, custom: model.presets)?.reply ?? RCVReplyChannel() : nil })).tint(Color.accentColor)
                if draft.reply != nil { NativeRCVReplyFields(reply: Binding(get: { draft.reply ?? RCVReplyChannel() }, set: { draft.reply = $0 })) }
            }
            if draft.reply != nil {
                Section("Reply key") {
                    SecureField("Paste the reply key", text: $replyKey).accessibilityLabel("Reply key")
                    HStack {
                        Button("Save key") { Task { if await model.setReplyCredential(view.id, value: replyKey) { replyKey = "" } } }
                            .disabled(replyKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working || dirty).help("Store the reply key for this source")
                        Button("Remove key", role: .destructive) { Task { if await model.setReplyCredential(view.id, value: "") { replyKey = "" } } }
                            .disabled(!view.hasReplyCredential || working || dirty).help("Remove this source’s saved reply key")
                    }
                }
            }
        }
    }
    private var log: some View {
        Section("Recent events") {
            if let error = model.searchError {
                Text(error).font(.callout).foregroundStyle(.red)
                DeckRetryButton("Try again", autoRetry: true) { model.search() }.disabled(model.searchLoading).help("Read this source’s recent events again") // autoRetry: re-reads this source's recent events
            } else if model.searched == nil {
                HStack { ProgressView().controlSize(.small); Text("Reading events…").foregroundStyle(.secondary) }
                ForEach(0..<3) { _ in RoundedRectangle(cornerRadius: 6).fill(.quaternary).frame(height: 28).redacted(reason: .placeholder) }
            } else {
                let recent = model.eventsForSource(view.id)
                if recent.isEmpty { Text("No events yet.").foregroundStyle(.secondary) }
                if model.searchLoading { HStack { ProgressView().controlSize(.small); Text("Updating…").font(.caption).foregroundStyle(.secondary) } }
                ForEach(recent.prefix(30)) { event in
                    DisclosureGroup {
                        ForEach(Array(event.trail.enumerated()), id: \.offset) { item in
                            Text(item.element.words).font(.callout).foregroundStyle(.secondary)
                        }
                        Text(String(data: event.raw, encoding: .utf8) ?? "Payload unavailable")
                            .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    } label: {
                        HStack { Text(event.title).lineLimit(1); Spacer(); Text(event.status.rawValue).font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
        }
    }

    private func finishDeletedSource() {
        guard !deleted else { return }
        deleted = true; pending = false
        saveTask?.cancel()
        model.stop()
        close()
    }

    /// Preserve only fields edited locally, taking all other values from a push.
    private func merging(_ local: RCVSource, from previous: RCVSource, onto incoming: RCVSource) -> RCVSource {
        var result = incoming
        if local.name != previous.name { result.name = local.name }
        // All projects (nil) must stay distinct from Independent's explicit id.
        if local.projectId != previous.projectId { result.projectId = local.projectId }
        if local.projectScope != previous.projectScope { result.projectScope = local.projectScope }
        if local.enabled != previous.enabled { result.enabled = local.enabled }
        if local.auth != previous.auth { result.auth = local.auth }
        if local.mapping != previous.mapping { result.mapping = local.mapping }
        if local.reply != previous.reply { result.reply = local.reply }
        return result
    }
    private func accept(_ incoming: RCVSource) {
        guard incoming != baseline else { return }
        let merged = merging(draft, from: baseline, onto: incoming)
        baseline = incoming
        draft = merged
        let addresses = RCVPresentation.addressesText(merged.auth.ipAllow)
        if ips != addresses { ips = addresses }
    }
    private func scheduleSave() {
        guard !deleted else { return }
        editGeneration += 1; saveError = nil
        pending = dirty
        guard pending, saveTask == nil else { return }
        // Exactly one writer. Edits during a save become its next iteration.
        saveTask = Task { await drainSaves() }
    }
    private func drainSaves() async {
        defer { saveTask = nil; if closing { model.stop() } }
        while pending && !deleted {
            let generation = editGeneration
            if !closing { try? await Task.sleep(for: .milliseconds(450)) }
            guard !deleted else { return }
            if generation != editGeneration { continue }
            await model.waitUntilIdle()
            guard !deleted else { return }
            if generation != editGeneration { continue }
            let next = draft
            do { try RCVEngine.validate(next) }
            catch { pending = false; saveError = RCVPresentation.sentence(error); return }
            saving = true
            let succeeded = await model.saveSource(next)
            saving = false
            guard !deleted else { return }
            if succeeded {
                let saved = model.sourceView(initialView.id)?.source ?? next
                let merged = merging(draft, from: next, onto: saved)
                baseline = saved; draft = merged
                pending = dirty
                if generation == editGeneration { saveError = nil }
            } else if generation == editGeneration {
                pending = false
                saveError = model.actionError ?? "The source could not be saved."
                return
            }
        }
    }
}
