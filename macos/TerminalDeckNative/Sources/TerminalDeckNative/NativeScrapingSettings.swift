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
struct NativeScrapingSettings: View {
    @State private var model = NativeScrapingModel()

    var body: some View {
        NativeSettingsPage(sectionId: "scraping") {
            Section {
                Picker("Where scraping runs", selection: $model.scope) {
                    ForEach(CodingAIScopes.seats(here: model.machines.here, devices: model.machines.devices)) { seat in
                        Text(seat.label).tag(seat.scope)
                    }
                }
                .pickerStyle(.segmented).nativeUIGGreyControl()
                .labelsHidden()
                .accessibilityLabel("Where scraping runs")
            }
            switch model.scope {
            case .servers:
                Section {
                    Text("A server you reach over SSH scrapes with a browser here, not one of its own: a session on it drives a window in this app, on this machine, so the settings under **\(CodingAIScopes.hereName(model.machines.here))** are the ones it scrapes with.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    NativeSettingsProse(text: "It cannot start a scrape either: capture, the asset tools and the ledger are refused to every session that is not on the computer the window is on, because the files they answer with are here.")
                }
            case .device(let id):
                let name = model.machines.devices.first { $0.id == id }?.name ?? ""
                let machine = name.isEmpty ? "That machine" : name
                Section {
                    NativeSettingsProse(text: "\(machine) keeps its own scraping settings, on \(machine). Open Settings → Scraping over there to change them.")
                    NativeSettingsProse(text: "Nothing here can: the link between two computers carries browser actions, not this configuration, and connecting \(machine) does not add one.")
                }
            case .thisMachine:
                NativeScrapingBody(model: model)
            }
        }
        .task { model.start() }
        .onDisappear { model.stop() }
    }
}

// MARK: - The body (`ScrapingBody`, as Settings shows it: no page, so no lift)

private struct NativeScrapingBody: View {
    @Bindable var model: NativeScrapingModel

    var body: some View {
        let config = model.config
        Section {
            HStack(spacing: 10) {
                NativeScrapingAvatar(text: Scraping.initial(model.profileName, avatar: model.editingProfile?.avatar ?? ""))
                Picker("Settings for", selection: Binding(get: { model.editing }, set: { model.edit($0) })) {
                    if model.profiles.isEmpty { Text("Loading…").tag(model.editing) }
                    ForEach(model.profiles) { profile in Text(profile.name).tag(profile.id) }
                }
            }
            NativeSettingsProse(text: "Scraping happens in a window you can watch. There is no hidden mode: the sites worth taking apart refuse a browser that has no screen.")
            if !model.note.isEmpty {
                NativeCodingAINotice(tone: .info, text: model.note)
            }
        }

        // Workers
        Section {
            let rows = model.rows
            if rows.isEmpty {
                Text("No workers yet.").foregroundStyle(.secondary)
            } else {
                Text(Scraping.fleetLine(rows, measured: true))
                ForEach(rows) { row in
                    HStack(spacing: 8) {
                        NativeScrapingAvatar(text: Scraping.initial(row.name, avatar: row.avatar))
                        Text(row.name)
                        if row.orphaned { NativeCodingAIBadge(text: "profile deleted") }
                        if !row.enrolled { NativeCodingAIBadge(text: "not enrolled") }
                        Spacer()
                        Text(Scraping.workerStateLabel(row.state)).foregroundStyle(row.state == "busy" ? Color.accentColor : .secondary)
                        Text(Scraping.countLine(row.requests, "request", "requests")).font(.callout).foregroundStyle(.secondary)
                        Button("Retire") { model.retire(row.profileId) }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Retire \(row.name)")
                    }
                }
            }
            let spare = Scraping.enrollable(fleet: config?.fleet, profiles: model.profiles)
            Picker("Profile to enrol as a worker", selection: Binding(get: { "" }, set: { if !$0.isEmpty { model.enrol($0) } })) {
                Text(spare.isEmpty ? "Every profile is a worker" : "Add a worker…").tag("")
                ForEach(spare) { profile in Text(profile.name).tag(profile.id) }
            }
            .labelsHidden()
            .disabled(spare.isEmpty)
            let plan = Scraping.mintPlan(model.mintTo, have: rows.count)
            HStack(spacing: 8) {
                Text("Workers in total")
                TextField("", text: $model.mintTo).labelsHidden().frame(width: 60).textFieldStyle(.roundedBorder)
                if let total = plan.total {
                    Button("Make \(total - rows.count) more") { model.mint(total) }.buttonStyle(.borderedProminent)
                }
                Text(plan.line).font(.callout).foregroundStyle(.secondary)
            }
            NativeScrapingNumber(label: "At once", hint: "How many workers may be working at the same time.",
                                 value: config?.fleet?.concurrency, min: 1, max: ScrapingLimits.maxWorkers) {
                model.patch(["fleet": ["concurrency": $0]])
            }
            NativeScrapingNumber(label: "Between requests", hint: "Milliseconds a worker waits before its next request.",
                                 value: config?.fleet?.delayMs, min: 0, max: ScrapingLimits.maxPaceMs) {
                model.patch(["fleet": ["delayMs": $0]])
            }
        } header: { NativeScrapingHead(title: "Workers", browserWide: true, profileName: model.profileName) }

        // Session
        Section {
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
                            Button(Scraping.liftLine(from: model.name(of: ask.fromProfileId), into: ask.intoProfileIds.map(model.name(of:))), role: .destructive) {
                                model.answer(ask, approve: true)
                            }
                            Button("Cancel") { model.approving = "" }
                        } else {
                            Button("Approve this lift") { model.approving = ask.id }.buttonStyle(.borderedProminent)
                            Button("Decline") { model.answer(ask, approve: false) }
                        }
                    }
                }
            }
            NativeSettingsProse(text: "A lift is taken off the page in front of you, and there is no page here. It is on the browser’s own Scraping panel — three dots, then Scraping — where there is one.")
        } header: { NativeScrapingHead(title: "Session", browserWide: true, profileName: model.profileName) }

        // Requests
        Section {
            if let requests = config?.requests {
                NativeSettingsProse(text: Scraping.fulfillNote)
                ForEach(Scraping.resourceTypes, id: \.self) { type in
                    HStack {
                        Text(Scraping.resourceLabel(type))
                        Spacer()
                        NativeScrapingChoice(label: "\(Scraping.resourceLabel(type)) rule", value: requests[type] ?? nil,
                                             options: Scraping.requestRules.map { ($0, Scraping.ruleLabel($0)) }) {
                            model.patch(["requests": [type: $0]])
                        }
                    }
                }
            } else {
                NativeScrapingUnavailable(what: "this build stores no request rules")
            }
        } header: { NativeScrapingHead(title: "Requests", browserWide: false, profileName: model.profileName) }

        // Capture
        Section {
            if let capture = config?.capture {
                NativeScrapingOnOff(label: "Record background responses", value: capture.on) { model.patch(["capture": ["on": $0]]) }
                NativeSettingsProse(text: "Every XHR and fetch the page makes is written down as it answers, so a page that loads its data after it renders is caught without asking it twice.")
                if capture.directory.isEmpty {
                    NativeSettingsProse(text: "This build did not say where captured responses go.")
                } else {
                    HStack {
                        Text(capture.directory).lineLimit(1).truncationMode(.middle).help(capture.directory)
                        Spacer()
                        Button("Show") { model.revealCapture() }.buttonStyle(.borderless)
                    }
                }
                NativeScrapingNumber(label: "Keep at most", hint: "Megabytes of captured responses. The oldest go when it is reached.",
                                     value: capture.keepMB, min: 1, max: ScrapingLimits.maxKeepMB) {
                    model.patch(["capture": ["keepMB": $0]])
                }
                let status = model.status?.capture
                Text("\(Scraping.countLine(status?.recorded, "response", "responses")) · \(Scraping.bytesLine(status?.bytes)) · \(Scraping.droppedLine(dropped: status?.dropped, reason: status?.droppedReason ?? "", measured: status != nil))")
                Button("Clear what has been captured") { model.clearCapture() }.buttonStyle(.borderless)
            } else {
                NativeScrapingUnavailable(what: "this build records no background responses")
            }
        } header: { NativeScrapingHead(title: "Capture", browserWide: false, profileName: model.profileName) }

        // Assets
        Section {
            if let assets = config?.assets {
                NativeSettingsProse(text: "Files are written byte for byte as the server sent them. Nothing re-encodes, resizes or renames on the way to disk.")
                if let land = model.landsIn { Text(land) }
                NativeScrapingOnOff(label: "Upgrade asset URLs", value: assets.upgradeOn) { model.patch(["assets": ["upgrade": ["on": $0]]]) }
                HStack {
                    NativeScrapingText(label: "Replace", value: assets.from, placeholder: "the part of the URL that names the small one") {
                        model.patch(["assets": ["upgrade": ["from": $0]]])
                    }
                    NativeScrapingText(label: "With", value: assets.to, placeholder: "the part that names the full one") {
                        model.patch(["assets": ["upgrade": ["to": $0]]])
                    }
                }
                NativeSettingsProse(text: "If the upgraded URL answers 404, the original is fetched instead — so an upgrade rule that is wrong about one file costs that file its resolution, never the file itself.")
                NativeScrapingOnOff(label: "Resume ledger", value: assets.ledgerOn) { model.patch(["assets": ["ledger": ["on": $0]]]) }
                Text("Each asset is written down under its URL *and* the digest of what came back, so a re-run skips only files that are byte for byte the ones already on disk.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                NativeScrapingOnOff(label: "Fetch again even where the ledger has it", value: assets.refetch) { model.patch(["assets": ["ledger": ["refetch": $0]]]) }
                NativeSettingsProse(text: "On, the ledger goes on being written but stops skipping — which is how a run is made to go and get everything again on purpose, rather than by emptying what it knows.")
                let a = model.status?.assets
                Text("\(Scraping.countLine(a?.fetched, "asset", "assets")) fetched · \(Scraping.countLine(a?.skipped, "asset", "assets")) skipped by the ledger · \(Scraping.countLine(a?.upgraded, "upgrade", "upgrades")) · \(Scraping.countLine(a?.fellBack, "fallback", "fallbacks")) · \(Scraping.countLine(a?.ledgerEntries, "row", "rows")) in the ledger")
                if model.ledgerArming {
                    HStack {
                        Button("Forget every asset \(model.profileName.isEmpty ? "this profile" : model.profileName) has fetched", role: .destructive) { model.clearLedger() }
                        Button("Cancel") { model.ledgerArming = false }
                    }
                } else {
                    Button("Empty the ledger") { model.ledgerArming = true }.buttonStyle(.borderless)
                }
            } else {
                NativeScrapingUnavailable(what: "this build downloads no assets of its own")
            }
        } header: { NativeScrapingHead(title: "Assets", browserWide: false, profileName: model.profileName) }

        // Checks
        Section {
            if let checks = config?.checks {
                NativeScrapingOnOff(label: "Check coverage against the page's own total", value: checks.coverageOn) { model.patch(["checks": ["coverage": ["on": $0]]]) }
                NativeScrapingText(label: "Where the page states its total", value: checks.pattern, placeholder: "a pattern with one number in it") {
                    model.patch(["checks": ["coverage": ["pattern": $0]]])
                }
                NativeSettingsProse(text: "The number the page prints about itself — the total in a line like “1–24 of 16,498”. What came back is compared against it, and a run that is short says so.")
                let check = model.status?.lastCheck
                let verdict = Scraping.coverageVerdict(stated: check?.stated, got: check?.got, ran: check != nil)
                Text(verdict.line + (check.map { " — \(model.time($0.at))" } ?? ""))
                    .foregroundStyle(verdict.tone == "complete" ? Color.green : verdict.tone == "short" ? Color.orange : .secondary)
            } else {
                NativeScrapingUnavailable(what: "this build checks nothing it has taken")
            }
            NativeScrapingOnOff(label: "Screenshot the page when a request is blocked", value: model.camera) { model.setCamera($0) }
            NativeSettingsProse(text: "A 403, a 429, a challenge or a navigation that ended somewhere it was not sent is photographed as it happens — by then it is too late to ask for the picture. The image and the evidence beside it stay in this app’s own folder, under this profile, and no paired device can read them.")
        } header: { NativeScrapingHead(title: "Checks", browserWide: false, profileName: model.profileName) }

        // Store
        Section {
            if model.tools.isEmpty {
                Text("Nothing in the store yet.").foregroundStyle(.secondary)
            } else {
                ForEach(model.tools) { tool in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(tool.name)
                            if !tool.version.isEmpty { NativeCodingAIBadge(text: tool.version) }
                            Text(tool.identity == "verified" ? "Verified" : "Not verified")
                                .font(.callout).foregroundStyle(tool.identity == "verified" ? Color.green : .orange)
                            Spacer()
                            if tool.installed {
                                Button("Remove") { model.remove(tool) }.buttonStyle(.borderless)
                            } else if Scraping.canInstall(tool) {
                                Button("Install") { model.install(tool) }.buttonStyle(.borderedProminent)
                            }
                        }
                        if !tool.publisher.isEmpty { Text(tool.publisher).font(.callout).foregroundStyle(.secondary) }
                        Text(Scraping.reachLine(tool)).font(.callout).foregroundStyle(.secondary)
                        let refusal = Scraping.installBlockedReason(tool)
                        if !refusal.isEmpty { Text(refusal).font(.callout).foregroundStyle(.orange) }
                    }
                }
            }
        } header: { NativeScrapingHead(title: "Store", browserWide: true, profileName: model.profileName) }
    }
}

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
                Button(option.1) { onPick(option.0) }
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
                TextField("", text: $draft, prompt: Text("not set"))
                    .labelsHidden()
                    .frame(width: 90)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .focused($focused)
                    .onSubmit(commit)
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
            TextField("", text: $draft, prompt: Text(placeholder))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .focused($focused)
                .onSubmit { if draft != value { onCommit(draft) } }
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
