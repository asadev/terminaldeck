import Observation
import SwiftUI
import TerminalDeckNativeCore

/// Settings → Scraping, drawn in Swift — `ScrapingSection.tsx` with the
/// `ScrapingBody` it renders, one-to-one: the "Where scraping runs" switch
/// (this Mac by name, Servers, each linked device); for this Mac the profile
/// the settings are for, the headful line, then Workers, Session, Requests,
/// Capture, Assets, Checks and Store, each head naming whose settings they are.
/// The servers and device scopes say where their settings live instead.
/// Every control calls the engine channel the page calls.
/// Kept for the stable MCP section route; Capture lives inside Browser.
struct NativeScrapingSettings: View {
    var body: some View { NativeBrowserSettings() }
}

struct NativeBrowserCaptureSettings: View {
    @State private var model = NativeScrapingModel()
    @State private var more = false
    var body: some View {
        Section("Capture") {
            if model.profiles.count > 1 {
                NativeSettingRow(label: "Profile") {
                    Picker("Profile", selection: Binding(get: { model.editing }, set: model.edit)) {
                        ForEach(model.profiles) { Text($0.name).tag($0.id) }
                    }.labelsHidden()
                }
            }
            if let fleet = model.config?.fleet {
                NativeSettingRow(label: "Workers") {
                    Stepper("\(model.rows.count)", value: Binding(get: { model.rows.count }, set: model.mint),
                        in: model.rows.count...ScrapingLimits.maxWorkers)
                        .fixedSize().disabled(model.editing.isEmpty)
                }
                NativeSettingRow(label: "At once") {
                    Stepper("\(fleet.concurrency ?? 1)", value: Binding(get: { fleet.concurrency ?? 1 },
                        set: { model.patch(["fleet": ["concurrency": $0]]) }), in: 1...ScrapingLimits.maxWorkers)
                        .fixedSize()
                }
                NativeSettingRow(label: "Wait between requests") {
                    Stepper("\(fleet.delayMs ?? 0) ms", value: Binding(get: { fleet.delayMs ?? 0 },
                        set: { model.patch(["fleet": ["delayMs": $0]]) }), in: 0...ScrapingLimits.maxPaceMs, step: 100)
                        .fixedSize()
                }
            } else {
                HStack { RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 96, height: 12); Spacer() }
            }
            NativeSessionButton("More…") { more = true }
                .popover(isPresented: $more) {
                    Form {
                        if let assets = model.config?.assets {
                            Section("Ledger") {
                                Toggle("Resume downloads", isOn: Binding(get: { assets.ledgerOn ?? true },
                                    set: { model.patch(["assets": ["ledger": ["on": $0]]]) }))
                                Toggle("Fetch every file again", isOn: Binding(get: { assets.refetch ?? false },
                                    set: { model.patch(["assets": ["ledger": ["refetch": $0]]]) }))
                                NativeCodingAIInfo(label: "Ledger", text: "Tracks each downloaded file so the next run can skip it.")
                                if model.ledgerArming {
                                    HStack {
                                        NativeSessionButton("Clear ledger", role: .destructive) { model.clearLedger() }
                                        NativeSessionButton("Cancel") { model.ledgerArming = false }
                                    }
                                } else {
                                    NativeSessionButton("Clear ledger…", role: .destructive) { model.ledgerArming = true }
                                }
                            }
                        }
                        if let camera = model.camera {
                            Section("Blocked pages") {
                                Toggle("Save a screenshot", isOn: Binding(get: { camera }, set: model.setCamera))
                            }
                        }
                    }.formStyle(.grouped).frame(width: 380, height: 320)
                }
            if !model.note.isEmpty { Text(model.note).font(.callout).foregroundStyle(.secondary).lineLimit(1).help(model.note) }
        }
        .task { model.start() }
        .onDisappear { model.stop() }
        // ⋮ ▸ Scraping lands on this page: a worker's ask to borrow a signed-in session is answered here.
        if !model.asks.isEmpty {
            Section("Sign-in requests") {
                NativeSettingsProse(text: "A scraping worker asked to copy a profile’s signed-in session. Nothing is copied until you approve.")
                NativeScrapingLiftAsks(model: model)
            }
        }
    }
}

/// Each waiting session-lift ask with Approve (confirmed once more) and Decline.
private struct NativeScrapingLiftAsks: View {
    @Bindable var model: NativeScrapingModel

    var body: some View {
        ForEach(model.asks) { ask in
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(Scraping.liftRequestLine(askedBy: ask.askedBy, from: model.name(of: ask.fromProfileId), into: ask.intoProfileIds.map(model.name(of:))))
                    Spacer()
                    Text(model.time(ask.at)).font(.callout).foregroundStyle(.secondary)
                }
                if !ask.reason.isEmpty { Text(ask.reason).font(.callout).foregroundStyle(.secondary) }
                HStack {
                    if model.approving == ask.id {
                        NativeSessionButton(Scraping.liftLine(from: model.name(of: ask.fromProfileId), into: ask.intoProfileIds.map(model.name(of:))), role: .destructive) {
                            model.answer(ask, approve: true)
                        }
                        NativeSessionButton("Cancel") { model.approving = "" }
                    } else {
                        NativeSessionButton("Approve this lift") { model.approving = ask.id }.buttonStyle(.borderedProminent)
                        NativeSessionButton("Decline") { model.answer(ask, approve: false) }
                    }
                }
            }
        }
    }
}

// MARK: - The body (`ScrapingBody`, as Settings shows it: no page, so no lift)

// MARK: - Parts (`Head`, `Unavailable`, `Choice`, `OnOff`, `NumberField`, `TextField`)

private struct NativeScrapingHead: View {
    let title: String
    let browserWide: Bool
    let profileName: String
    var body: some View {
        HStack(spacing: 8) {
            Text(title)
            Text(Scraping.scopeLabel(browserWide: browserWide, profileName: profileName))
                .font(.callout).foregroundStyle(.secondary)
        }
        .textCase(nil)
    }
}

private struct NativeScrapingUnavailable: View {
    let what: String
    var body: some View { Text("Not available here — \(what).").foregroundStyle(.secondary) }
}

private struct NativeScrapingAvatar: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 22, height: 22)
            .background(Color.accentColor.opacity(0.18), in: .circle)
    }
}

/// A row of pressable options, any of which may be unset (`Choice`).
private struct NativeScrapingChoice: View {
    let label: String
    let value: String?
    let options: [(String, String)]
    let onPick: (String) -> Void
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { option in
                let on = value == option.0
                NativeSessionButton(option.1) { onPick(option.0) }
                    .buttonStyle(.bordered)
                    .nativeUIGGreyControl()
                    .background(on ? Color.primary.opacity(0.12) : .clear, in: .rect(cornerRadius: 6))
                    .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}

private struct NativeScrapingOnOff: View {
    let label: String
    let value: Bool?
    let onPick: (Bool) -> Void
    var body: some View {
        HStack {
            Text(label)
            Spacer()
            if value == nil { NativeCodingAIBadge(text: "not set") }
            NativeScrapingChoice(label: label, value: value.map { $0 ? "on" : "off" }, options: [("on", "On"), ("off", "Off")]) {
                onPick($0 == "on")
            }
        }
    }
}

private struct NativeScrapingNumber: View {
    let label: String
    let hint: String
    let value: Int?
    let min: Int
    let max: Int
    let onCommit: (Int) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                Spacer()
                NativeSessionTextField("", text: $draft, prompt: Text("not set"))
                    .labelsHidden()
                    .frame(width: 90)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .sessionFocused($focused)
                    .sessionOnSubmit(commit)
                    .onChange(of: focused) { _, now in if !now { commit() } }
            }
            Text(hint).font(.callout).foregroundStyle(.secondary)
        }
        .onAppear { draft = value.map(String.init) ?? "" }
        .onChange(of: value) { _, next in draft = next.map(String.init) ?? "" }
    }

    private func commit() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, let number = Double(text), number.isFinite else {
            draft = value.map(String.init) ?? ""
            return
        }
        onCommit(Swift.min(max, Swift.max(min, Int(number.rounded(.down)))))
    }
}

private struct NativeScrapingText: View {
    let label: String
    let value: String
    let placeholder: String
    let onCommit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
            NativeSessionTextField("", text: $draft, prompt: Text(placeholder))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .sessionFocused($focused)
                .sessionOnSubmit { if draft != value { onCommit(draft) } }
                .onChange(of: focused) { _, now in if !now, draft != value { onCommit(draft) } }
        }
        .onAppear { draft = value }
        .onChange(of: value) { _, next in draft = next }
    }
}

// MARK: - The model

@MainActor
@Observable
final class NativeScrapingModel {
    var scope: CodingAIScope = .thisMachine
    private(set) var machines = CodingAIMachinesView.empty
    private(set) var profiles: [ScrapingProfile] = []
    private(set) var editing = ""
    private(set) var config: ScrapingConfig?
    private(set) var camera: Bool?
    private(set) var status: ScrapingStatus?
    private(set) var asks: [ScrapingLiftRequest] = []
    private(set) var tools: [ScrapingTool] = []
    private(set) var downloads: CodingAIJSON = .null
    var note = ""
    var mintTo = "4"
    var approving = ""
    var ledgerArming = false
    @ObservationIgnored private var subscriptions: [EngineSubscription] = []

    var profileName: String { profiles.first { $0.id == editing }?.name ?? "" }
    var editingProfile: ScrapingProfile? { profiles.first { $0.id == editing } }
    func name(of id: String) -> String { profiles.first { $0.id == id }?.name ?? id }
    var rows: [ScrapingWorkerRow] { Scraping.workerRows(fleet: config?.fleet, status: status, profiles: profiles) }

    /// "They land in <folder> (on <machine>)."
    var landsIn: String? {
        guard downloads.isObject else { return nil }
        let folder = downloads["destination"]["folder"].string ?? ""
        let machine = downloads["destination"]["machineName"].string ?? ""
        let place = folder.isEmpty ? (downloads["defaultFolder"].string ?? "") : folder
        return "They land in \(place)\(machine.isEmpty ? "" : " on \(machine)")."
    }

    func time(_ at: Double) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter.string(from: Date(timeIntervalSince1970: at / 1000))
    }

    private func call(_ channel: String, _ args: [Any?] = []) async throws -> CodingAIJSON {
        CodingAIJSON(try await EngineBridge.shared.invoke(channel, args))
    }

    func start() {
        Task { machines = CodingAIMachinesView.parse((try? await call("machines:list")) ?? .null) }
        Task { downloads = (try? await call("browser-download:list")) ?? .null }
        Task {
            let state = Scraping.profiles((try? await call("browser-profile:list")) ?? .null)
            profiles = state.profiles
            let fallback = state.profiles.first { $0.isDefault }?.id ?? ""
            edit(state.activeId.isEmpty ? fallback : state.activeId)
        }
        loadAsks()
        loadTools()
        guard subscriptions.isEmpty else { return }
        subscriptions = [
            EngineBridge.shared.on("machines:state") { [weak self] args in
                guard let self else { return }
                self.machines = CodingAIMachinesView.parse(CodingAIJSON(args.first))
                self.scope = self.scope.after(devices: self.machines.devices)
            },
            EngineBridge.shared.on("browser-scraping:changed") { [weak self] args in
                if let status = Scraping.status(CodingAIJSON(args.first)) { self?.status = status }
            },
            EngineBridge.shared.on("browser-worker:lift-request") { [weak self] _ in self?.loadAsks() },
            EngineBridge.shared.on("browser:downloads") { [weak self] args in self?.downloads = CodingAIJSON(args.first) },
        ]
    }

    func stop() {
        subscriptions.forEach { $0.cancel() }
        subscriptions = []
    }

    /// Which profile's settings are shown; everything per-profile is read again.
    func edit(_ id: String) {
        editing = id
        config = nil
        status = nil
        camera = nil
        note = ""
        ledgerArming = false
        approving = ""
        guard !id.isEmpty else { return }
        Task { config = Scraping.config((try? await call("browser-scraping:config", [id])) ?? .null) }
        Task { status = Scraping.status((try? await call("browser-scraping:status", [id])) ?? .null) }
        Task { camera = (try? await call("browser:block-capture", [id]))?.bool }
    }

    func loadAsks() { Task { asks = Scraping.liftRequests((try? await call("browser-worker:lift-requests")) ?? .null) } }
    func loadTools() { Task { tools = Scraping.tools((try? await call("browser-store:list")) ?? .null) } }
    private func loadStatus() { let id = editing; Task { status = Scraping.status((try? await call("browser-scraping:status", [id])) ?? .null) } }

    func patch(_ change: [String: Any]) {
        let id = editing
        guard !id.isEmpty else { return }
        Task {
            guard let stored = Scraping.config((try? await call("browser-scraping:config-set", [id, change])) ?? .null) else {
                note = Scraping.notConfirmed
                config = Scraping.config((try? await call("browser-scraping:config", [id])) ?? .null)
                return
            }
            note = ""
            config = stored
        }
    }

    func setCamera(_ on: Bool) {
        let id = editing
        guard !id.isEmpty else { return }
        Task {
            guard let stored = (try? await call("browser:block-capture-set", [id, on]))?.bool else {
                note = Scraping.notConfirmed
                camera = (try? await call("browser:block-capture", [id]))?.bool
                return
            }
            note = ""
            camera = stored
        }
    }

    /// The worker channels answer with the fleet only; it replaces the fleet and
    /// keeps the rest of what this pane shows.
    private func storeFleet(_ channel: String, _ args: [Any?], expect: @escaping ([String]) -> String) {
        Task {
            guard let fleet = Scraping.configFromWorkers((try? await call(channel, args)) ?? .null)?.fleet else {
                note = Scraping.notConfirmed
                config = Scraping.config((try? await call("browser-scraping:config", [editing])) ?? .null)
                return
            }
            if config == nil { config = ScrapingConfig(fleet: fleet) } else { config?.fleet = fleet }
            note = expect(fleet.profileIds)
            loadStatus()
        }
    }

    func enrol(_ id: String) {
        storeFleet("browser-worker:register", [id]) { [weak self] ids in Scraping.enrolledNote(name: self?.name(of: id) ?? id, stored: ids, id: id) }
    }

    func retire(_ id: String) {
        storeFleet("browser-worker:unregister", [id]) { [weak self] ids in Scraping.retiredNote(name: self?.name(of: id) ?? id, stored: ids, id: id) }
    }

    func mint(_ total: Int) { storeFleet("browser-worker:ensure", [total]) { _ in "" } }

    func answer(_ ask: ScrapingLiftRequest, approve: Bool) {
        approving = ""
        Task {
            note = Scraping.outcome((try? await call("browser-worker:lift-answer", [["requestId": ask.id, "approve": approve]])) ?? .null).message
            loadAsks()
            loadStatus()
        }
    }

    func install(_ tool: ScrapingTool) {
        Task {
            let outcome = Scraping.outcome((try? await call("browser-store:install", [tool.id])) ?? .null)
            note = outcome.ok ? "\(tool.name) installed." : outcome.message
            loadTools()
        }
    }

    func remove(_ tool: ScrapingTool) {
        Task {
            let outcome = Scraping.outcome((try? await call("browser-store:remove", [tool.id])) ?? .null)
            note = outcome.ok ? "\(tool.name) removed." : outcome.message
            loadTools()
        }
    }

    func clearCapture() {
        let id = editing
        Task {
            _ = try? await call("browser-scraping:capture-clear", [id])
            loadStatus()
        }
    }

    func revealCapture() {
        let id = editing
        Task { _ = try? await call("browser-scraping:capture-reveal", [id]) }
    }

    func clearLedger() {
        ledgerArming = false
        let id = editing
        Task {
            _ = try? await call("browser-scraping:ledger-clear", [id])
            loadStatus()
        }
    }
}
