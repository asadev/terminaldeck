import Foundation
import Observation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Mac shelf (owner, 15 Nov): this Mac keeps the Cloud service's shelf of what is in his Cloud now, so his phones and the
/// web show his content when every Mac is off. Quiet and in the background: it builds the SAME model the Your Cloud page
/// draws (one fresh read, as `cloud.contents` does), puts only kinds whose view changed, 30 s after that view settles,
/// once at launch after the first full pull and once a day; texts only when the service asks. Nothing here can delay
/// or block sync: its calls go through the transport's own shelf door, which never touches sync's back-off.
/// Does nothing while signed out, while Cloud is off on this Mac ("Use Cloud on this Mac"), while Cloud is paused or
/// still catching up, or while the setting is off. A service without the shelf routes (404) is silent until next launch.
@MainActor @Observable
final class NativeCloudShelf {
    static let shared = NativeCloudShelf()
    /// Settings → Cloud, beside the other Cloud switches. ON by default.
    static let switchTitle = "Show my Cloud on my phones when my Macs are off"
    /// Its info popover (owner, 15 Nov: no sentence on the page).
    static let switchInfo = "This Mac keeps a copy of what is in your Cloud with the Cloud service, so your phones and the web can show your work while every Mac is off. Off: that copy is emptied and no longer kept."
    private(set) var on = true
    /// A signed-in identity's putter exists (the switch can say something to the service).
    private(set) var attached = false
    @ObservationIgnored private var putter: BackendCloudShelfPutter?
    /// 15 Nov: the sealed kinds (saved passwords, project secret files), sealed here with the saved-passwords key.
    @ObservationIgnored private var sealedPutter: BackendCloudShelfSealedPutter?
    /// 15 Nov fix: the sealed round itself (what goes up, what is kept, one log line per outcome) lives in the backend.
    @ObservationIgnored private var sealedRounds: BackendCloudShelfSealedRound?
    /// This Mac's name as the last build saw it (a retry between builds uses it).
    @ObservationIgnored private var sealedFrom: String?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var probe: NativeCloudContentsModel?
    /// Per kind, the view last seen and since when (the 30 s settle).
    @ObservationIgnored private var seen: [BackendCloudContents.Kind: (fingerprint: String, since: Int64)] = [:]
    @ObservationIgnored private var lastSignal: [String] = []
    @ObservationIgnored private var lastBuild: Int64 = 0
    @ObservationIgnored private var launchPending = true
    @ObservationIgnored private var unsettled = false
    /// 15 Nov (MacBook short shelf): when the running round started, and its token (was a plain flag: one round that
    /// never returned kept every later round out for the rest of the launch).
    @ObservationIgnored private var busy: (token: UUID, since: Int64)?
    /// The page item each listed text hash is read from (texts are read again only when the service asks).
    @ObservationIgnored private var textSources: [String: (kind: BackendCloudContents.Kind, item: String)] = [:]
    /// Open files (15 Nov): files still going up ("12 of 80" in the Cloud status line); nil when idle.
    private(set) var filesProgress: (done: Int, total: Int)?
    /// Each listed file's place on this Mac, by kind + hash (read again only when the service asks for its bytes).
    @ObservationIgnored private var fileSources: [String: (kind: BackendCloudContents.Kind, root: URL, relative: String)] = [:]
    /// The Cloud folder's and artifacts' ONE daily send budget of this Mac (the same file the folder books in).
    @ObservationIgnored private var dayBudget: CloudDayBudget?
    @ObservationIgnored private var filesLookTried: Int64 = 0
    /// How often it looks; a build happens only when something could have changed (or every 10 minutes).
    @ObservationIgnored var tick: Duration = .seconds(30)
    static let rebuildMs: Int64 = 600_000

    static func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// Called once the identity's sync core exists (after `POST /v1/brain-key`): one putter per identity.
    func attach(send: @escaping BackendCloudShelfPutter.Send, file: URL) {
        detach()
        let putter = BackendCloudShelfPutter(send: send, file: file)
        self.putter = putter
        dayBudget = CloudDayBudget(file: file.deletingLastPathComponent().appendingPathComponent("file-day-budget.json"))
        let sealed = BackendCloudShelfSealedPutter(send: send, file: file.deletingLastPathComponent().appendingPathComponent("shelf-sealed.json"))
        sealedPutter = sealed
        sealedRounds = BackendCloudShelfSealedRound(putter: sealed, material: {
            guard let graph = await MainActor.run(body: { NativeCloudSecrets.shared.graph }) else { return .notNow }
            return await graph.shelfSealed()
        }, note: { NativeCompositionRoot.note($0) })
        attached = true
        launchPending = true
        loop = Task { [weak self] in
            // The account's setting and the newest put, once per launch (one GET; 404 = not live yet: silent).
            _ = await putter.status()
            let saved = await putter.state.on
            if self?.putter === putter { self?.on = saved }
            while !Task.isCancelled {
                await self?.round(putter)
                let pause = self?.tick ?? .seconds(30)
                try? await Task.sleep(for: pause)
            }
        }
    }
    /// Sign-out: nothing more is built or sent for that identity.
    func detach() {
        loop?.cancel(); loop = nil
        putter = nil; probe = nil; attached = false
        sealedPutter = nil; sealedRounds = nil; sealedFrom = nil
        seen = [:]; lastSignal = []; lastBuild = 0; textSources = [:]; unsettled = false
        fileSources = [:]; dayBudget = nil; filesLookTried = 0; filesProgress = nil
    }

    /// The person's switch. OFF tells the service (which empties the shelf) and stops; ON puts everything again.
    func setOn(_ value: Bool) {
        guard NativeCloudOffers.shows(.phonesCopy) else { return }
        on = value
        guard let putter else { return }
        Task { [weak self] in
            await putter.setOn(value)
            guard value else { return }
            await MainActor.run { self?.launchPending = true }
            await self?.round(putter)
        }
    }

    /// `cloud.status`'s one line: when the shelf was last put and from which Mac. Read only.
    func wire() async -> NativeRPCValue? { await putter?.wire() }

    /// Ready to read and put: signed in, Cloud on here, not paused, the first full pull done, the setting on.
    var ready: Bool {
        let account = NativeCloudAccount.shared
        let snapshot = account.snapshot
        return on && snapshot.visible(at: Self.now()) && account.memoryIncluded != false && snapshot.phase != .paused
            && snapshot.catchingUp != true && !BackendCloudOverviewWords.preparingNow(snapshot.baseline) && snapshot.fetched != nil
    }

    func round(_ putter: BackendCloudShelfPutter) async {
        guard self.putter === putter, ready, BackendCloudShelf.roundMayStart(running: busy?.since, now: Self.now()) else { return }
        if busy != nil { NativeCompositionRoot.note("cloud shelf: a round has not finished for 10 minutes; starting a new one") }
        let token = UUID()
        busy = (token, Self.now())
        defer { if busy?.token == token { busy = nil } }
        if await putter.missing { return }
        let now = Self.now()
        // Open files (15 Nov): once a day, which kinds the service keeps files for (an older service: none, so rows carry
        // no file fields and nothing is hashed or sent). A failed look is tried again at most every 10 minutes.
        if await putter.filesLookDue(now: now), now - filesLookTried >= Self.rebuildMs {
            filesLookTried = now
            _ = await putter.status()
        }
        let snapshot = NativeCloudAccount.shared.snapshot
        // Cheap: build the view only when the feed, the queue or what waits moved, a kind still settles, or now and then
        // (a local "Only on this Mac" mark moves nothing in the feed).
        let signal = [snapshot.fetched?.rawValue ?? "", snapshot.cloudHead?.rawValue ?? "", String(snapshot.waitingRecords), String(snapshot.blockedRecords)]
        let state = await putter.state
        let dailyDue = BackendCloudShelf.servedKinds.contains { now - (state.kinds[$0.rawValue]?.putAt ?? 0) >= BackendCloudShelf.dayMs }
        let owed = state.kinds.values.contains { $0.textsOwed }
        let sealedSettling = await sealedRounds?.settling ?? false
        guard launchPending || unsettled || owed || dailyDue || sealedSettling || signal != lastSignal || now - lastBuild >= Self.rebuildMs else {
            // 15 Nov fix: a sealed retry (a source that could not be read, a refused put, an owner that became ready)
            // runs without rebuilding the plain view.
            if let sealedRounds, await sealedRounds.retryDue() {
                await sealedRounds.run(throughSeq: snapshot.fetched?.rawValue ?? "0", from: sealedFrom, atLaunch: false, signal: signal)
            }
            await sendFiles(putter)
            return
        }
        lastSignal = signal; lastBuild = now
        let probe = self.probe ?? NativeCloudContentsModel()
        self.probe = probe
        await probe.refresh(includeBin: false)
        guard self.putter === putter, ready, let model = probe.model else { return }
        let entries = BackendCloudShelf.entries(model: model, status: statuses(model, handles: probe.handles))

        // Open files (15 Nov): the Cloud folder's and artifacts' FILES, hashed at low priority off the main thread, each
        // only when its size or change time moved; only for kinds the service keeps files for and this Mac syncs.
        var asks: [BackendCloudShelf.FileAsk] = []
        let byId = Dictionary(model.items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for kind in BackendCloudShelf.fileKinds.sorted(by: { $0.rawValue < $1.rawValue }) where Self.syncsHere(kind) {
            guard await putter.filesLive(kind), let root = Self.fileRoot(kind) else { continue }
            for entry in entries[kind] ?? [] {
                guard let id = entry.fileItem, let item = byId[id], let relative = probe.handles[id]?.relative else { continue }
                asks.append(.init(item: id, kind: kind, root: root, relative: relative, isText: item.isText))
            }
        }
        var found = BackendCloudShelf.FilesFound()
        if !asks.isEmpty {
            let known = await putter.knownFiles()
            let made = asks
            found = await Task.detached(priority: .background) { BackendCloudShelf.fileFacts(made, known: known) }.value
        }
        var files: [String: (kind: BackendCloudContents.Kind, root: URL, relative: String)] = [:]
        let askedBy = Dictionary(asks.map { ($0.item, $0) }, uniquingKeysWith: { first, _ in first })

        // Texts: read and hashed only when the item changed since its hash was kept.
        var facts: [String: BackendCloudShelf.TextFact] = [:]
        var sources: [String: (kind: BackendCloudContents.Kind, item: String)] = [:]
        var rows: [BackendCloudContents.Kind: [BackendCloudShelf.Row]] = [:]
        for kind in BackendCloudShelf.servedKinds {
            var made: [BackendCloudShelf.Row] = []
            for entry in entries[kind] ?? [] {
                var row = entry.row
                if let item = entry.textItem, let stamp = entry.textStamp {
                    var fact = await putter.knownText(stamp)
                    if fact == nil, let text = await Self.text(of: item, probe: probe) { fact = BackendCloudShelf.fact(text) }
                    if let fact, fact.bytes <= BackendCloudShelf.textMaxBytes {
                        row.textHash = fact.hash; row.textBytes = fact.bytes; row.textPieces = fact.pieces
                        facts[stamp] = fact
                        sources[fact.hash] = (kind, item)
                    }
                }
                if let id = entry.fileItem, let fact = found.byItem[id]?.fact, let ask = askedBy[id] {
                    row = BackendCloudShelf.withFile(row, fact)
                    if let hash = row.fileHash { files[kind.rawValue + "|" + hash] = (kind, ask.root, ask.relative) }
                }
                made.append(row)
            }
            rows[kind] = made
        }
        guard self.putter === putter, ready else { return }
        await putter.remember(facts)
        textSources = sources
        await putter.rememberFiles(found.keep)
        fileSources = files
        // Hashing not finished this round (the first fill): look again soon; the list is put once its view settles.
        if found.pending { unsettled = true }
        let from = model.devices.first(where: \.isThisMac)?.name
        let throughSeq = snapshot.fetched?.rawValue ?? "0"
        let atLaunch = launchPending
        unsettled = false
        for kind in BackendCloudShelf.servedKinds {
            let list = rows[kind] ?? []
            let fingerprint = BackendCloudShelf.fingerprint(list)
            let known = await putter.state.kinds[kind.rawValue]
            let changed = known?.fingerprint != fingerprint
            let daily = Self.now() - (known?.putAt ?? 0) >= BackendCloudShelf.dayMs
            guard changed || daily || known?.textsOwed == true else { seen[kind] = nil; continue }
            // 30 s after the kind's view settles, at launch too (15 Nov: the MacBook's launch view was taken while the
            // other Mac's changes were still arriving and put 12 of 21 tasks).
            if changed {
                guard BackendCloudShelf.settled(held: seen[kind], fingerprint: fingerprint, now: Self.now()) else {
                    if seen[kind]?.fingerprint != fingerprint { seen[kind] = (fingerprint, Self.now()) }
                    unsettled = true; continue
                }
            }
            let outcome = await putter.put(kind, rows: list, throughSeq: throughSeq, from: from, force: daily && !changed) { [weak self] hash in
                await self?.text(hash: hash)
            }
            switch outcome {
            case .missing: return
            case .off: on = false; return
            case .later: unsettled = true
            case .put(let count, _):
                seen[kind] = nil
                if changed || daily { NativeCompositionRoot.note("cloud shelf: \(kind.rawValue) put, \(count) items, through position \(throughSeq)") }
            case .behind:
                seen[kind] = nil
                NativeCompositionRoot.note("cloud shelf: \(kind.rawValue) not put: another Mac put a newer view")
            case .unchanged: seen[kind] = nil
            }
            guard self.putter === putter, ready else { return }
        }
        await sealedRound(throughSeq: throughSeq, from: from, atLaunch: atLaunch, signal: signal)
        launchPending = false
        await sendFiles(putter)
    }

    /// Open files (15 Nov): the kind syncs on this Mac ("Keep in sync on this Mac").
    static func syncsHere(_ kind: BackendCloudContents.Kind) -> Bool {
        switch kind {
        case .cloudFolder: return NativeCloudSyncChoices.shared.isOn(.cloudFolder)
        case .artifacts: return NativeCloudSyncChoices.shared.isOn(.artifacts)
        default: return false
        }
    }
    static func fileRoot(_ kind: BackendCloudContents.Kind) -> URL? {
        kind == .cloudFolder ? NativeCloudFolder.current?.folder : kind == .artifacts ? NativeCloudArtifacts.shared.owner?.store : nil
    }
    /// Open files (15 Nov): the files the service asked for, one at a time, at most 8 MiB a round, inside half of the
    /// Cloud folder's daily send allowance (booked in the same budget). Never before the first build of this launch
    /// (the files' places are known only then); nothing while the shelf is not ready (switch off, paused, signed out).
    func sendFiles(_ putter: BackendCloudShelfPutter) async {
        guard self.putter === putter else { return }
        guard ready, !launchPending, let budget = dayBudget else { filesProgress = await putter.filesProgress(); return }
        let sources = fileSources
        let kindsOn = Set(BackendCloudShelf.fileKinds.filter { Self.syncsHere($0) })
        let share = BackendCloudShelf.filesDayShare, dayMs = BackendCloudShelf.dayMs
        await putter.sendFiles(
            maySend: { bytes in budget.sent(day: Int64(Date().timeIntervalSince1970 * 1000) / dayMs) + bytes <= share },
            spent: { bytes in budget.add(bytes, day: Int64(Date().timeIntervalSince1970 * 1000) / dayMs) },
            bytes: { kind, hash in
                guard kindsOn.contains(kind), let source = sources[kind.rawValue + "|" + hash] else { return nil }
                return await Task.detached(priority: .utility) {
                    BackendCloudShelf.fileBytes(root: source.root, relative: source.relative, hash: hash)
                }.value
            })
        if self.putter === putter { filesProgress = await putter.filesProgress() }
    }

    /// 15 Nov: the sealed kinds. Read from the saved-passwords owner (the records his Macs sync), sealed here, put with the
    /// same quiet rules: only when the keyed fingerprint changed and stayed for 30 s, at launch, once a day; nothing while
    /// saved passwords are locked; both kinds taken off the shelf while his setting keeps them off his phones. Reading
    /// the sources costs a little, so it happens when the feed or the queue moved, at launch, or every 10 minutes.
    func sealedRound(throughSeq: String, from: String?, atLaunch: Bool, signal: [String]) async {
        guard let sealedRounds else { return }
        if let from { sealedFrom = from }
        await sealedRounds.run(throughSeq: throughSeq, from: from ?? sealedFrom, atLaunch: atLaunch, signal: signal)
    }
    /// 15 Nov fix: an owner a saved-passwords source waits for became ready (API accounts once the session helper is
    /// connected): the sealed round runs now, not in 10 minutes.
    func sealedSoon() {
        guard let putter, let sealedRounds else { return }
        Task { [weak self] in
            await sealedRounds.soon()
            await self?.round(putter)
        }
    }

    /// A listed text, read again when the service asks for it (the same read the page's details use).
    func text(hash: String) async -> String? {
        guard let source = textSources[hash], let probe, let item = probe.model?.items.first(where: { $0.id == source.item }) else { return nil }
        return await Self.text(of: item.id, probe: probe)
    }
    /// The text the page shows when the item is opened: a memory note without its label block, an instruction file
    /// through THE one read fence. nil = not readable here (the row is listed without text).
    /// Slice 2: a task's description and comments (from the Tasks page's own store), and a Cloud folder or artifact text
    /// file read from its folder on this Mac with the folder sync's own reader (at most 1 MB; binary files never).
    static func text(of itemId: String, probe: NativeCloudContentsModel) async -> String? {
        guard let item = probe.model?.items.first(where: { $0.id == itemId }) else { return nil }
        switch item.kind {
        case .memory:
            guard item.isText, item.canOpen, let path = probe.handles[item.id]?.relative, let text = await probe.files.text(path) else { return nil }
            return NativeCloudContentsModel.shownText(text)
        case .instructionFiles:
            guard item.isText, item.canOpen else { return nil }
            return await probe.preview(item)
        case .tasks:
            guard let record = probe.handles[item.id]?.recordId else { return nil }
            let id = record.hasPrefix("task:") ? String(record.dropFirst(5)) : record
            guard let task = TasksStore.shared.state?.tasks.first(where: { $0.id == id }) else { return nil }
            return BackendCloudShelf.taskText(task)
        case .cloudFolder, .artifacts:
            guard item.isText, let relative = probe.handles[item.id]?.relative else { return nil }
            let root = item.kind == .cloudFolder ? NativeCloudFolder.current?.folder : NativeCloudArtifacts.shared.owner?.store
            guard let root else { return nil }
            return await Task.detached { BackendCloudShelf.fileText(root: root, relative: relative) }.value
        default:
            return nil
        }
    }
    /// A task's state and an agent's role in words, from their owners on this Mac (by page item id).
    func statuses(_ model: BackendCloudContents, handles: [String: BackendCloudContentsHandle]) -> [String: String] {
        var made: [String: String] = [:]
        let tasks = Dictionary((TasksStore.shared.state?.tasks ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let wantsAgents = model.items.contains { $0.kind == .agents }
        var roles: [String: String] = [:]
        if wantsAgents {
            for agent in AGTAgentsStore.shared.agents where !agent.role.isEmpty {
                roles[agent.id] = agent.role
                if let profile = agent.profileID { roles[profile] = agent.role }
            }
        }
        for item in model.items {
            guard let record = handles[item.id]?.recordId else { continue }
            switch item.kind {
            case .tasks:
                let id = record.hasPrefix("task:") ? String(record.dropFirst(5)) : record
                guard let task = tasks[id] else { continue }
                if task.completedAt != nil { made[item.id] = "Done" }
                else if let words = BackendCloudContentsWords.plain(task.crmStatus) { made[item.id] = words }
            case .agents:
                var id = record.hasPrefix("agent:") ? String(record.dropFirst(6)) : record
                if id.hasPrefix("instruction:") { id = String(id.dropFirst(12)); if id.hasSuffix(".md") { id = String(id.dropLast(3)) } }
                if let role = roles[id] { made[item.id] = role }
            default: continue
            }
        }
        return made
    }
}
