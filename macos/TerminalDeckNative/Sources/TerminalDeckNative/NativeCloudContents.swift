import AppKit
import Observation
import SwiftUI
import TerminalDeckBackend
import TerminalDeckNativeCore

/// "See what is in your Cloud" (owner, 13 Nov): a window of its own, opened from Settings → Cloud, in three parts:
/// Devices at the top, the browser of everything in your Cloud in the middle, Activity at the bottom.
/// It reads only this Mac's local state (the sync store's `contents` read and the account snapshot the Cloud page
/// already holds). Signed out, or before this identity's sync core exists, nothing is read, built or asked.
@MainActor @Observable
final class NativeCloudContentsModel {
    static let shared = NativeCloudContentsModel()
    private(set) var model: BackendCloudContents?
    @ObservationIgnored private(set) var handles: [String: BackendCloudContentsHandle] = [:]
    var kind: BackendCloudContents.Kind = .memory
    var selected: String?
    var search = ""
    /// The device filter, by device name; nil = every device.
    var device: String?
    @ObservationIgnored let account: NativeCloudAccount
    /// The sync store's read; nil = nothing known yet (no sync core for this identity).
    @ObservationIgnored var read: @MainActor () async -> CloudSyncContents?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private(set) var reads = 0

    /// Status-line lane: space used per kind, from the one source (`NativeCloudPageCounts`).
    var space: BackendCloudSpace?
    /// Lane L4: the Bin is chosen in the list of kinds (instead of a kind).
    var showingBin = false
    /// Mac tidy (Owner, 15 Nov: code backup is managed from the Cloud page): "Code" is chosen in the list of kinds.
    /// It shows the Code page's own content (`NativeCodeBackupContent`) over the Code page's own model.
    var showingCode = false
    @ObservationIgnored let code: NativeCodeBackupPageModel
    func chooseCode() {
        go(to: NativeCloudPlace(kind: kind, bin: false, code: true, path: []))
    }
    /// Lane L4: the earlier version chosen inside the open item; nil = the version in use.
    var versionChosen: String?
    /// Lane L4: the open item's (or chosen version's) text, once read.
    var opened: NativeCloudOpened?
    /// Lane L4: an instruction file's versions, read from its keeper when it is opened (by item id).
    var fileVersions: [String: [BackendCloudContents.Version]] = [:]
    @ObservationIgnored var keptHashes: [String: String] = [:]
    /// Lane L4: changes waiting out their 5 seconds ("Removing… Undo"), each with its own Undo line. Leaving the page
    /// cancels them all.
    var pending: [NativeCloudUndo.What: NativeCloudUndo] = [:]
    @ObservationIgnored var pendingTasks: [NativeCloudUndo.What: Task<Void, Never>] = [:]
    /// Delete rule: memory changes are always offered (the old switch is gone); the "Cloud" button follows the gate.
    @ObservationIgnored var memoryChanges = true
    var deleteGateOpen = false
    /// Owner routes that cannot delete right now (secret kinds: locked, no sealed Bin, an older Mac): no buttons.
    var deleteRefusedRoutes: Set<String> = []
    @ObservationIgnored private var saidNotices: Set<String> = []
    var selection: Set<String> = []
    var binGroups: [CloudBinGroup] = []
    var expandedBinGroups: Set<String> = []
    var deleteReadProblem: String?
    var actionLine: String?
    var busyBin: Set<String> = []
    var pendingRows: [NativeCloudUndo.What: Set<String>] = [:]
    @ObservationIgnored let deletions: NativeCloudDeleteOps
    @ObservationIgnored var pageTasks: [UUID: Task<Void, Never>] = [:]
    /// How long the Undo line stays before the change is made.
    @ObservationIgnored var undoSeconds: Double = 10
    /// CLOUD-FILES-6: the wait itself, injected so a test holds the Undo time open and lets it end when it chooses
    /// (never a guess at how long a busy test machine takes).
    @ObservationIgnored var undoWait: @Sendable (Double) async -> Void = { seconds in try? await Task.sleep(for: .seconds(seconds)) }
    @ObservationIgnored let files: NativeCloudFileOps
    /// Cloud file manager (15 Nov): the folder open inside the chosen place (its names, as the crumbs show them).
    var path: [String] = []
    /// Back and forward walk every place and folder opened on this page.
    var backStack: [NativeCloudPlace] = []
    var forwardStack: [NativeCloudPlace] = []
    /// Selected folders (their `BackendCloudManagerTree.folderId`); selected items are `selection`.
    var folderSelection: Set<String> = []
    /// Where a Shift-click range starts.
    @ObservationIgnored var anchor: String?
    /// A saved password's value, only after his click on Show, only for the item it belongs to; gone when the
    /// selection changes or the reading pane closes.
    var revealed: NativeCloudRevealed?
    /// Reads one saved password's value from this Mac's own store (the person's Show press only; never a tool).
    @ObservationIgnored var secretReveal: @MainActor (BackendCloudContentsHandle) async -> String? = { handle in
        guard let source = handle.sourceId, let record = handle.recordId, let graph = NativeCloudSecrets.shared.graph else { return nil }
        return await graph.revealValue(sourceId: source, recordId: record)
    }

    init(account: NativeCloudAccount = .shared, read: (@MainActor () async -> CloudSyncContents?)? = nil, files: NativeCloudFileOps = .live,
         deletions: NativeCloudDeleteOps = .live, code: NativeCodeBackupPageModel? = nil) {
        self.account = account
        self.code = code ?? .shared
        self.read = read ?? { await NativeCloudBrainRegistration.current?.contents(limit: 20_000) }
        self.files = files
        self.deletions = deletions
    }
    var signedIn: Bool { account.snapshot.visible(at: Int64(Date().timeIntervalSince1970 * 1000)) }

    /// Names this Mac already knows: its projects and agents. Saved passwords stay by kind (no value is ever read).
    static func names() -> BackendCloudContentsNames {
        var names = BackendCloudContentsNames()
        for project in NativePROJLabels.shared.projects { names.projects[project.id] = project.name }
        // CLOUD-FILES-6: each registered project's folders by their own name, named as the side panel names them.
        let registry = SHELLRoutes.registry
        for project in registry where project.id != PROJProjects.independentID {
            for folder in project.folders {
                let own = URL(fileURLWithPath: PROJProjects.normalize(folder)).lastPathComponent
                names.projectFolders[own] = NativeProjectNames.folderRowName(folder, registry: registry)
            }
        }
        for agent in AGTAgentsStore.shared.agents {
            names.agents[agent.id] = agent.name
            if let profile = agent.profileID { names.agents[profile] = agent.name }
        }
        for task in TasksStore.shared.state?.tasks ?? [] { names.tasks[task.id] = task.title }
        return names
    }
    @ObservationIgnored private var devicesAskedAt: Date?
    /// Page-names 2: each device's last reported position and when this window saw it move. A number of changes still to
    /// fetch is said only for a position seen moving lately; the first one seen is not known to be current.
    @ObservationIgnored private var positions: [String: (seq: String, movedAt: Int64?)] = [:]
    func notePositions(_ devices: [CloudDevice], now: Int64) -> [String: Int64] {
        var moved: [String: Int64] = [:]
        for device in devices {
            // MAC-NEXT-7 (6): a device whose report carries its time (`lastPulledAt`) needs no guess here.
            guard device.lastPulledAt == nil, let seq = device.lastPulledSeq?.rawValue else { continue }
            if let before = positions[device.deviceId] {
                let at = before.seq == seq ? before.movedAt : now
                positions[device.deviceId] = (seq, at)
                if let at { moved[device.deviceId] = at }
            } else {
                positions[device.deviceId] = (seq, nil)
            }
        }
        return moved
    }
    func refresh(includeBin: Bool = true) async {
        guard signedIn else { model = nil; handles = [:]; binGroups = []; deleteGateOpen = false; return }
        reads += 1
        // Proof 2 (13 Nov): "On 1 of 2 devices" stayed stale because the device list (who has read how far) was read
        // only by the Cloud page. While this window refreshes its lists it asks for the device list too, at most every
        // 30 seconds; the counts follow on the next refresh.
        if devicesAskedAt.map({ Date().timeIntervalSince($0) >= 30 }) ?? true {
            devicesAskedAt = Date()
            account.refreshDevices()
        }
        let contents = await read() ?? .empty
        // Page-names lane: every number from the one source Settings → Cloud reads too; notes by their titles.
        let counts = NativeCloudPageCounts.shared
        await counts.refresh(snapshot: account.snapshot, includeBin: includeBin)
        var names = Self.names()
        if let tasks = NativeCloudRecordsOwners.taskStore, let rows = try? await tasks.all() {
            for row in rows where row.isLocal { names.tasks[row.id] = BackendCloudContentsWords.plain(row.value["title"].string) }
        }
        if let roster = NativeCloudRecordsOwners.roster, let rows = try? await roster.allAgents() {
            for row in rows { if let id = row["id"].string { names.agents[id] = BackendCloudContentsWords.plain(row["name"].string) } }
        }
        names.notes = counts.titles
        // Cloud file manager: each setting's value in plain words, read from this Mac's own settings.
        if let settings = NativeCloudBrainRegistration.kinds?.settings { names.settingValues = await settings.shownValues() }
        // Lane L4: which item each memory record belongs to, from this Mac's own memory index.
        names.noteFacts = counts.noteFacts
        names.keptCopies = counts.keptCopies
        names.deletedHere = counts.deletedHere
        // One rule phase 2: the ONE Bin and the kept texts come from the memory store's keeper.
        names.memoryBin = includeBin ? counts.memoryBin : []
        names.memoryKept = counts.memoryKept
        names.memoryKeptCount = counts.memoryKeptCount
        names.folderAnswer = counts.folderAnswer
        names.folderBin = includeBin ? counts.folderBin : []
        names.folderReplaced = counts.folderReplaced
        names.folderLines = counts.folderLines
        names.artifactsAnswer = counts.artifactsAnswer
        names.artifactsBin = includeBin ? counts.artifactsBin : []
        names.artifactsLines = counts.artifactsLines
        if space != counts.counts?.space { space = counts.counts?.space }
        let moved = notePositions(account.snapshot.devices, now: Int64(Date().timeIntervalSince1970 * 1000))
        guard signedIn, var built = BackendCloudContentsBuilder.build(contents: contents, snapshot: account.snapshot, names: names,
                                                                      counts: counts.counts, positionMovedAt: moved, memoryChanges: memoryChanges) else {
            model = nil; handles = [:]; return
        }
        // Sessions in the Cloud: "Sessions and chats", every session's and earlier chat's copy, with the bin buttons.
        let chats = NativeCloudChats.shared.all
        if !chats.isEmpty { built.model = BackendCloudChatsContents.adding(chats, to: built.model) }
        do {
            let state = try await deletions.read(includeBin)
            guard signedIn else { return }
            deleteGateOpen = state.gateOpen
            deleteRefusedRoutes = state.refusedRoutes
            for line in state.notices where saidNotices.insert(line).inserted { account.say(line) }
            if includeBin { binGroups = state.groups }
            deleteReadProblem = nil
            show(BackendCloudDeletePage.applying(state.marks, groups: state.groups, to: built.model, rowErrors: state.rowErrors), handles: built.handles)
        } catch {
            deleteGateOpen = false
            deleteReadProblem = "Some Cloud items could not be checked. Try again."
            // A failed read must not make a marked item look present or empty a known Bin.
            if model == nil { show(built.model, handles: built.handles) }
        }
    }
    func show(_ model: BackendCloudContents, handles: [String: BackendCloudContentsHandle] = [:]) {
        self.handles = handles
        if self.model != model { self.model = model }
        selection.formIntersection(model.items.map(\.id))
        // Cloud file manager: a folder emptied by a removal or a change on another device closes to its nearest parent.
        if !showingBin, !showingCode {
            while !path.isEmpty, !BackendCloudManagerTree.exists(path, kind: kind, in: model) { path.removeLast() }
            folderSelection = folderSelection.filter { id in BackendCloudManagerTree.path(ofFolderId: id).map { BackendCloudManagerTree.exists($0, kind: kind, in: model) } ?? false }
        }
        if let selected, !model.items.contains(where: { $0.id == selected }) { self.selected = nil; versionChosen = nil }
        if let chosen = versionChosen, !(selectedItem.map { versions($0).contains { $0.id == chosen } } ?? false) { versionChosen = nil }
    }
    /// Updates by itself while the window is open.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
    func stop() { loop?.cancel(); loop = nil; undoAll() }
    func pendingWhat(for item: BackendCloudContents.Item) -> NativeCloudUndo.What? { pendingRows.first { $0.value.contains(item.id) }?.key }

    /// `cloud.contents`: one fresh read, never the window's own state.
    static func wire() async -> NativeRPCValue? {
        let probe = NativeCloudContentsModel()
        await probe.refresh(includeBin: false)
        return probe.model?.wireValue()
    }

    /// Cloud file manager: the files of the open folder (or, while searching, every match inside it).
    var shownItems: [BackendCloudContents.Item] { listing.files }
    /// The open folder as the page lists it: folders first, then files. The same listing `cloud.items` gives.
    var listing: BackendCloudManagerTree.Listing {
        guard !showingBin, !showingCode, let model else { return .init(folders: [], files: []) }
        return BackendCloudManagerTree.listing(model, kind: kind, path: path, device: device, search: search)
    }
    var selectedItem: BackendCloudContents.Item? { selected.flatMap { id in model?.items.first { $0.id == id } } }

    // MARK: Managing: only what already exists underneath.

    /// The same press as Settings → Cloud's Sync now: fetch what Cloud holds, then send what this Mac holds.
    func syncNow() { account.change("now"); NativeCloudSecrets.shared.syncNow() }
    /// The file on this Mac, for an instruction file in a project's folder ("Show in Finder" only; nothing is read).
    /// CLOUD-FILES-5: only a path the instruction-file rule allows, in the folder the sync uses for that project, and
    /// only when that path is a normal file there (`lstat`: a link is not followed).
    func localFile(_ item: BackendCloudContents.Item) -> URL? {
        guard item.kind == .instructionFiles, let handle = handles[item.id], let relative = handle.relative, let projectId = handle.projectId,
              BackendCloudFilesReadFence.allowed(relative, home: handle.home), let root = NativeCloudBoot.shared.projectRoot(projectId) else { return nil }
        let url = root.appendingPathComponent(relative)
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return url
    }
    func showInFinder(_ item: BackendCloudContents.Item) {
        guard let url = localFile(item) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    func copyName(_ item: BackendCloudContents.Item) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.name, forType: .string)
    }
    /// The current text of an instruction file, through THE one fence (`BackendCloudFilesReadFence`): an allowed path,
    /// listed by this Mac's own scan of the sync's folder for that project, read without following any link. The same
    /// read serves the page and `cloud.item_open`. nil = not shown.
    func preview(_ item: BackendCloudContents.Item) async -> String? {
        guard item.isText, item.kind == .instructionFiles, let handle = handles[item.id], let relative = handle.relative,
              let projectId = handle.projectId, BackendCloudFilesReadFence.allowed(relative, home: handle.home),
              let root = NativeCloudBoot.shared.projectRoot(projectId), let boot = NativeCloudBoot.shared.boot else { return nil }
        let listed = await boot.listedHere(projectId: projectId, relative: relative)
        let home = handle.home
        return await Task.detached { BackendCloudFilesReadFence.read(root: root, relative: relative, listed: listed, home: home) }.value
    }
    /// The text of the first `limit` bytes; nil for a file that is not text (the fence's own rule).
    nonisolated static func previewText(_ data: Data, limit: Int) -> String? { BackendCloudFilesReadFence.text(data, limit: limit) }
}

/// The window: resizable, named "Your Cloud". One at a time.
@MainActor
final class NativeCloudContentsWindow: NSWindowController, NSWindowDelegate {
    private static var open: NativeCloudContentsWindow?
    let model: NativeCloudContentsModel
    /// Front gate (0.21.4 typing fixes): the window comes forward for the person's own press of "Open"; a request
    /// that is not theirs waits until they bring the app forward themselves.
    static func show() {
        NativeFront.whenPersonActs("cloud-contents") {
            if let shown = NativeCloudContentsWindow.open { shown.window?.makeKeyAndOrderFront(nil); return }
            let made = NativeCloudContentsWindow(model: .shared)
            NativeCloudContentsWindow.open = made
            made.showWindow(nil)
            made.window?.makeKeyAndOrderFront(nil)
        }
    }
    init(model: NativeCloudContentsModel) {
        self.model = model
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1120, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = BackendCloudContentsWords.windowTitle
        window.contentMinSize = CGSize(width: 820, height: 560)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("CloudContents")
        window.contentView = NSHostingView(rootView: NativeCloudContentsView(model: model))
        window.center()
        super.init(window: window)
        window.delegate = self
        model.start()
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    func windowWillClose(_ notification: Notification) {
        model.stop()
        Self.open = nil
    }
}

struct NativeCloudContentsView: View {
    let model: NativeCloudContentsModel
    var body: some View {
        Group {
            if let contents = model.model {
                VStack(alignment: .leading, spacing: DeckTokens.Spacing.s16) {
                    NativeCloudContentsDevices(model: model, devices: contents.devices, catchingUp: contents.catchingUp)
                    NativeCloudContentsBrowser(model: model, contents: contents)
                        .frame(maxHeight: .infinity)
                    NativeCloudContentsActivity(activity: contents.activity)
                }
                .padding(.horizontal, DeckTokens.Metrics.pageHorizontal)
                .padding(.top, DeckTokens.Metrics.pageTop)
                .padding(.bottom, DeckTokens.Spacing.s20)
            } else {
                VStack(spacing: DeckTokens.Spacing.s12) {
                    // Page-names 3 (real check 4: the window first read "Icloud / Checking…"): decorative, hidden from
                    // accessibility so the window reads only "Checking…".
                    Image(systemName: "icloud").font(.system(size: 32)).foregroundStyle(DeckTokens.textSecondary).accessibilityHidden(true)
                    Text(model.signedIn ? BackendCloudOverviewWords.checking : BackendCloudContentsWords.signedOut)
                        .foregroundStyle(DeckTokens.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(DeckTokens.frame)
    }
}

/// The side panel's Cloud page (owner, 14 Nov: "See what is in your Cloud" must stop being a mystery button that opens a
/// separate grey window). Cloud file manager (owner, 15 Nov: "I need a proper file manager where I can go inside and see
/// things"): the whole page is one Finder-like window: places on the left, a top bar with back / forward, the crumbs,
/// search and the actions for the selection, then the list (Name · Changed · On · Size) and a closable reading pane.
/// No big heading (the window's bar names the page), no device cards, no Sync now, no history list, no Space used
/// (Settings › Profile › Cloud has it).
struct NativeCloudContentsPage: View {
    var model: NativeCloudContentsModel = .shared
    /// Pictures pass a filled model and no reading loop.
    var live = true
    var body: some View {
        Group {
            if let contents = model.model {
                NativeCloudContentsBrowser(model: model, contents: contents)
            } else if model.signedIn {
                Text(BackendCloudOverviewWords.checking).foregroundStyle(DeckTokens.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Review 14 Nov: signed out, one Sign in button that works (the page exists only where Cloud can be used).
                VStack(spacing: DeckTokens.Spacing.s12) {
                    Text(BackendCloudContentsWords.signedOut).foregroundStyle(DeckTokens.textSecondary)
                    let stage = model.account.signInStage
                    Button(stage == .signedOut(waiting: true) ? "Signing in…" : "Sign in") { model.account.pressSignIn() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.account.busy || stage == .signedOut(waiting: true))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .font(DeckTokens.Typography.body)
        .background(DeckTokens.page, ignoresSafeAreaEdges: [.horizontal, .bottom])
        // Mac tidy: the Code shelf's number (projects) is read once on opening the page, as the Code page reads it.
        .onAppear { if live { model.start(); model.code.load(refresh: false) } }
        .onDisappear { if live { model.stop() } }
    }
}

// MARK: Devices

struct NativeCloudContentsDevices: View {
    let model: NativeCloudContentsModel
    let devices: [BackendCloudContents.Device]
    /// Page-names lane: one date per card. Another device: when it was last seen (its newest check-in or change);
    /// this Mac: when it last sent. Refreshed with the window.
    static func dates(_ device: BackendCloudContents.Device, now: Date = Date()) -> String {
        if device.isThisMac { return device.lastSent.map { BackendCloudPageWords.lastSent($0, now: now) } ?? "" }
        return device.lastSeen.map { BackendCloudPageWords.lastSeen($0, now: now) } ?? ""
    }
    let catchingUp: String?
    var body: some View {
        VStack(alignment: .leading, spacing: DeckTokens.Spacing.s8) {
            HStack(alignment: .firstTextBaseline) {
                Text(BackendCloudContentsWords.devicesTitle).font(DeckTokens.Typography.section)
                Spacer()
                // Proof 3: while this Mac prepares its first copy, Sync now waits with it and says so. Page-names lane:
                // only while preparation really runs (never once every change is prepared).
                let preparing = BackendCloudOverviewWords.preparingNow(model.account.snapshot.baseline)
                Button("Sync now") { model.syncNow() }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.account.busy || preparing)
                    .help(preparing ? BackendCloudOverviewWords.syncNowWhilePreparing(model.account.snapshot.baseline) : "")
            }
            // Page-names lane: which device is still catching up, said once here instead of on every row below.
            if let catchingUp {
                Text(catchingUp).font(DeckTokens.Typography.callout).foregroundStyle(DeckTokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Every device in view at once: the cards wrap instead of running off the edge. Page-names 2 (each Mac showed
            // ONE card while its model held two): an eager layout that places every card, never a lazy grid that may
            // leave one out of the window and out of what is read aloud.
            NativeCloudCardFlow(minimum: 230, spacing: DeckTokens.Metrics.cardGap) {
                ForEach(devices) { device in card(device) }
            }
        }
    }
    private func card(_ device: BackendCloudContents.Device) -> some View {
        VStack(alignment: .leading, spacing: DeckTokens.Spacing.s4) {
            HStack(spacing: DeckTokens.Spacing.s8) {
                Image(systemName: device.isThisMac ? "laptopcomputer" : "desktopcomputer").foregroundStyle(DeckTokens.textSecondary)
                    .accessibilityHidden(true)
                Text(device.name).font(DeckTokens.Typography.rowTitle).lineLimit(1)
                if device.isThisMac {
                    Text(BackendCloudContentsWords.thisMac).font(DeckTokens.Typography.caption).foregroundStyle(DeckTokens.textSecondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(DeckTokens.textSecondary.opacity(0.12), in: .capsule)
                }
            }
            HStack(spacing: DeckTokens.Spacing.s8) {
                if device.moving {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle().fill(tint(device)).frame(width: DeckTokens.Metrics.projectDot, height: DeckTokens.Metrics.projectDot)
                }
                Text(device.state).font(DeckTokens.Typography.callout).foregroundStyle(device.needsLook ? DeckTokens.warn : DeckTokens.textPrimary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            let dates = Self.dates(device)
            if !dates.isEmpty {
                Text(dates).font(DeckTokens.Typography.caption).foregroundStyle(DeckTokens.textSecondary)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DeckTokens.Metrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DeckTokens.card, in: RoundedRectangle(cornerRadius: DeckTokens.Metrics.cardRadius))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(device))
    }
    /// One card as one line to read: name, "This Mac", state, date.
    static func spoken(_ device: BackendCloudContents.Device, now: Date = Date()) -> String {
        ([device.name] + (device.isThisMac ? [BackendCloudContentsWords.thisMac] : []) + [device.state, dates(device, now: now)])
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }
    private func tint(_ device: BackendCloudContents.Device) -> Color {
        if device.needsLook { return DeckTokens.warn }
        return device.state == BackendCloudContentsWords.upToDate ? DeckTokens.good : DeckTokens.textTertiary
    }
}

// The browser, its rows, the reading pane and the Bin: `NativeCloudManager.swift` (Cloud file manager, 15 Nov).

// MARK: Activity

struct NativeCloudContentsActivity: View {
    let activity: [BackendCloudContents.Activity]
    var body: some View {
        VStack(alignment: .leading, spacing: DeckTokens.Spacing.s8) {
            Text(BackendCloudContentsWords.activityTitle).font(DeckTokens.Typography.section)
            Group {
                if activity.isEmpty {
                    Text(BackendCloudContentsWords.nothingMoved).foregroundStyle(DeckTokens.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(DeckTokens.Spacing.s12)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: DeckTokens.Spacing.s8) {
                            ForEach(activity) { line in
                                HStack(alignment: .firstTextBaseline, spacing: DeckTokens.Spacing.s12) {
                                    Text(BackendCloudContentsWords.time(line.at)).foregroundStyle(DeckTokens.textSecondary)
                                        .frame(width: 130, alignment: .leading)
                                    Text(line.text).foregroundStyle(line.problem ? DeckTokens.warn : DeckTokens.textPrimary)
                                    Spacer(minLength: 0)
                                }
                                .font(DeckTokens.Typography.callout)
                            }
                        }
                        .padding(DeckTokens.Spacing.s12)
                    }
                }
            }
            .frame(height: 170)
            .background(DeckTokens.card, in: RoundedRectangle(cornerRadius: DeckTokens.Metrics.cardRadius))
        }
    }
}

/// Page-names 2: device cards side by side, as many columns as fit (each at least `minimum` wide), wrapping to the next
/// row. Every card is placed (nothing is lazy), so each device's card is always on screen.
struct NativeCloudCardFlow: Layout {
    var minimum: CGFloat
    var spacing: CGFloat
    private func columns(_ width: CGFloat, count: Int) -> Int {
        guard width.isFinite, width > 0 else { return max(1, count) }
        return max(1, min(count, Int((width + spacing) / (minimum + spacing))))
    }
    private func rows(_ subviews: Subviews, columns: Int, cellWidth: CGFloat) -> [CGFloat] {
        stride(from: 0, to: subviews.count, by: columns).map { start in
            subviews[start..<min(start + columns, subviews.count)].map { $0.sizeThatFits(.init(width: cellWidth, height: nil)).height }.max() ?? 0
        }
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let width = proposal.width ?? (minimum * CGFloat(subviews.count) + spacing * CGFloat(subviews.count - 1))
        let count = columns(width, count: subviews.count)
        let cell = (width - spacing * CGFloat(count - 1)) / CGFloat(count)
        let heights = rows(subviews, columns: count, cellWidth: cell)
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(0, heights.count - 1)))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let count = columns(bounds.width, count: subviews.count)
        let cell = (bounds.width - spacing * CGFloat(count - 1)) / CGFloat(count)
        let heights = rows(subviews, columns: count, cellWidth: cell)
        var y = bounds.minY
        for (row, height) in heights.enumerated() {
            for column in 0..<count {
                let index = row * count + column
                guard index < subviews.count else { break }
                let x = bounds.minX + CGFloat(column) * (cell + spacing)
                subviews[index].place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .init(width: cell, height: height))
            }
            y += height + spacing
        }
    }
}
