import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// The one place brain adapters join the signed-in SYNC engine.
/// A row registers only after the integrator proved it end-to-end; an unproven row has no adapter, pump, coverage or tool.
enum NativeCloudBrainRegistration {
    /// Inventory rows (and "paths" for the device path map) proven by cloud-int, switched on for 0.22.0: memory
    /// I01-I06, boot files I09, agents I10, projects I11 (no "paths"). They still run ONLY for a signed-in account the
    /// service allow-lists (`gate.entitlesCloud`); with no account or a closed gate nothing is built or run.
    /// Lane L3 (14 Nov, the owner's "everything in the app in the Cloud"): tasks I12 and settings I21 (their own row;
    /// I11 is the project list) are switched on.
    /// Lane L3 slice 1 (14 Nov): the Cloud folder I24. It sends nothing until every Mac of the account announced that it
    /// understands Cloud folder records (`BackendCloudFolder`'s gate), so turning the row on harms no older build.
    /// Lane L3 slice 2 (14 Nov): artifacts I23, behind the same gate (every Mac understands artifacts records).
    static let provenRows: Set<String> = ["I01", "I02", "I03", "I04", "I05", "I06", "I09", "I10", "I11", "I12", "I21", "I23", "I24", "I26"]
    /// The lean first version's memory (spec AM10, scope item 2): rows I01 to I06 as built. Prepared, not switched on.
    static let leanMemoryRows: Set<String> = ["I01", "I02", "I03", "I04", "I05", "I06"]
    /// What is switched on in THIS process: the proven rows and, in a DEBUG build running proof P3's scratch plan
    /// only, the lean memory rows (`NativeCloudScratch`). In a release build this is exactly `provenRows`.
    static var enabledRows: Set<String> {
        provenRows.union(NativeCloudScratch.memoryRows).union(NativeCloudScratch.recordRows).union(NativeCloudScratch.bootRows)
    }
    /// Lane F's boot files (lean scope item 8, row I09) are switched on. False in the app until proven.
    static var bootFilesOn: Bool { enabledRows.contains(CloudBootFilesFormat.inventoryRow) }
    static var memoryRows: [String] { CloudBrainMemoryFormat.inventoryRows.filter(enabledRows.contains) }
    /// Lane A2's rows that are switched on (lean scope item 7): I11 the project list, I10 agents with their
    /// instruction files. Empty in the app until they are proven; the scratch plan's `"records": true` in a debug build.
    static var recordRows: Set<String> { enabledRows.intersection(BackendCloudLeanRecords.rows) }
    /// Lane L3's rows that are switched on: tasks (I12) and settings (I21).
    static var kindsRows: Set<String> { enabledRows.intersection(BackendCloudKinds.rows) }
    /// Same everywhere (15 Nov): the switched-on rows this device keeps in sync, after his "Keep in sync on this Mac"
    /// choices (a kind off here is not started here; the account's shared marks, I05, always are).
    static func rowsHere(_ dataRoot: URL) -> Set<String> { NativeCloudSyncChoices.load(dataRoot: dataRoot).rows(enabledRows) }

    /// Project folders (19 Nov): every project of this Mac whose folder is chosen, real, and inside the home folder (never
    /// the home itself), by its key. The same project id gives the same key on every Mac.
    static func projectFolderRoots(_ places: [BackendCloudBootFilesPlace], home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String: URL] {
        let homePath = home.resolvingSymlinksInPath().standardizedFileURL.path
        var roots: [String: URL] = [:]
        for place in places where place.kind == .project && place.chosen {
            let root = place.root.resolvingSymlinksInPath().standardizedFileURL
            guard root.path.hasPrefix(homePath + "/"), CloudProjectFoldersRules.realFolder(root) else { continue }
            roots[CloudProjectFoldersRules.key(projectId: place.identity)] = root
        }
        return roots
    }

    /// Every domain SYNC may admit as brain content: only switched-on rows (finding 27: built in steps).
    static var brainDomains: Set<String> {
        let rows = enabledRows
        var domains: Set<String> = []
        for row in CloudBrainMemoryFormat.inventoryRows where rows.contains(row) { domains.insert(CloudBrainMemoryFormat.domain(row)) }
        for row in CloudBrainFilesFormat.inventoryRows where rows.contains(row) { domains.insert(CloudBrainFilesFormat.domain(row)) }
        if rows.contains("paths") { domains.insert("machines/paths") }
        domains.formUnion((try? BackendCloudLeanRecords.domains(rows)) ?? [])
        domains.formUnion((try? BackendCloudKinds.domains(rows)) ?? [])
        if rows.contains(CloudFolderFormat.inventoryRow) { domains.insert(CloudFolderFormat.domain) }
        if rows.contains(CloudArtifactsFormat.inventoryRow) { domains.insert(CloudArtifactsFormat.domain) }
        if rows.contains(CloudProjectFoldersRules.inventoryRow) { domains.insert(CloudFileKind.projectFolders.domain) }
        return domains
    }

    /// M11: the ONE serialised place where memory sync is enabled and stopped for one signed-in identity.
    /// Every step runs in this actor; a stop bumps the generation, so an enable that was waiting can never switch
    /// capture back on or leave pumps running after sign-out or a closed gate.
    actor Running {
        struct Context: Sendable {
            let engine: any CloudOutboxPort; let deviceId: String; let subjectHash: String; let dataRoot: URL; let displayName: String?
            /// The app's live owners for lane A2's rows (the project registry, the task configuration); nil = those
            /// rows are not built in this run.
            var records: NativeCloudRecordsLive? = nil
            /// True once the person has trusted, by a press in this Mac's own window, at least one device other than
            /// this Mac (this Mac's trusted list answers). Without it lane A2 keeps a new agent's project and seat waiting.
            /// nil answer = this Mac's trusted list could not be read (lane A2 then waits instead of deciding).
            var firstArrivalConfirmed: (@Sendable () async -> Bool?)? = nil
        }
        private var activation: BackendCloudBrainMemoryActivation?
        /// One renewal per active account. The memory pump sleeps on events when idle, so it cannot promise a
        /// 12-hour announcement by itself. This deadline reuses its writer/clock, not another transport or setting.
        private var deleteRuleRenewal: Task<Void, Never>?
        private var deleteRuleLaunchPending = true
        /// Lane A2's projects and agents for this identity, once built. Stopped and dropped at sign-out.
        private var records: BackendCloudLeanRecords?
        /// Lane F's boot files for this identity, once built.
        private var boot: BackendCloudBootFiles?
        /// Lane L3's tasks and settings for this identity, once built.
        private var kinds: BackendCloudKinds?
        /// Lane L3's Cloud folder for this identity, once built.
        private var cloudFolder: BackendCloudFolder?
        /// Lane L3 slice 2: artifacts for this identity, once built.
        private var artifacts: BackendCloudArtifacts?
        /// Lane L3 slice 2: the ONE daily send budget of the Cloud folder and artifacts on this Mac (200 MB together).
        private var dayBudget: CloudDayBudget?
        private func budget(_ context: Context) -> CloudDayBudget {
            if let dayBudget { return dayBudget }
            let made = CloudDayBudget(file: NativeCloudLaunch.folder(context.dataRoot).appendingPathComponent(context.subjectHash + "/file-day-budget.json"))
            dayBudget = made
            return made
        }
        private var enabling = false
        private var context: Context?
        private var generation = 0
        private var stopped = false
        func attach(_ context: Context) async {
            self.context = context
            let choice = NativeCloudLaunch.memoryChoice(dataRoot: context.dataRoot, subjectHash: context.subjectHash)
            await MainActor.run {
                NativeCloudAccount.shared.memoryIncluded = choice
                NativeCloudSyncChoices.shared.use(dataRoot: context.dataRoot)
            }
        }
        /// A "Keep in sync on this Mac" switch moved: every part stops (nothing is deleted anywhere) and the parts that
        /// are on start again, each by its own joining rule, so a kind switched on again joins like a device that was off.
        func choicesChanged() async {
            guard context != nil, !stopped else { return }
            await pauseMemory()
            try? await enable()
        }
        /// "See what is in your Cloud": the sync store's local read. nil before this identity's sync core exists;
        /// it is never built for this read.
        func contents(limit: Int) async -> CloudSyncContents? {
            guard let context, !stopped else { return nil }
            return try? await context.engine.contents(limit: limit)
        }
        /// The Cloud page switch (N6). No → Yes starts the first snapshot; Yes → No stops uploading and deletes nothing in Cloud.
        func setChoice(_ include: Bool) async {
            guard let context, !stopped else { return }
            NativeCloudLaunch.setMemoryChoice(include, dataRoot: context.dataRoot, subjectHash: context.subjectHash)
            await MainActor.run { NativeCloudAccount.shared.memoryIncluded = include }
            if include { try? await enable() } else { await pauseMemory() }
        }
        /// Starts what is switched on for this identity, in one order: memory first, then projects and agents (the
        /// sync core takes one setup at a time). Safe to call again: each part starts once.
        func enable() async throws {
            // One at a time: a second call while one is under way (the page opening while the memory question is
            // still on screen) sets nothing up twice. Proof 2 (13 Nov): it is not lost either: a folder chosen or
            // files that arrived meanwhile are looked at once more as soon as the running call ends.
            guard !stopped, context != nil else { return }
            guard !enabling else { enableAgain = true; return }
            enabling = true
            defer { enabling = false }
            repeat {
                enableAgain = false
                try await enableOnce()
            } while enableAgain && !stopped
        }
        private var enableAgain = false
        private func enableOnce() async throws {
            guard !stopped, let context else { return }
            // Sync trust core review, hand-back 4: on a Mac that has just signed in, nothing of its own is set up (no
            // baseline is cut or sent) until the person has answered the new-Mac sheet. The answer calls
            // `newMacAnswered()`, which comes back here.
            guard await MainActor.run(body: { !NativeCloudAccount.shared.newMacPending }) else { return }
            do {
                try await enableMemory(context)
                await startDeleteRuleAnnouncements()
                try await enableRecords(context)
                try await enableBoot(context)
                try await enableKinds(context)
                try await enableCloudFolder(context)
                try await enableArtifacts(context)
                try await enableProjectFolders(context)
                await announceKindsOffHere(context)
                setupRetries = 0
            } catch {
                // 13 Nov blocker: a setup that stops is never silent (one line; the sync core's own line is not repeated),
                // and it is tried again by itself. Before, projects, agents and boot files that met the sync core busy
                // with memory's first copy waited for the Cloud page to be opened.
                if !(error is CancellationError) {
                    CloudSyncDiagnostics.shared.report("Cloud setup on this Mac", error)
                    scheduleSetupRetry()
                }
                throw error
            }
        }
        private var setupRetries = 0
        private var setupRetry: Task<Void, Never>?
        private func scheduleSetupRetry() {
            let delays: [UInt64] = [10, 30, 60, 120, 300, 600]
            guard !stopped, setupRetry == nil, setupRetries < delays.count else { return }
            let delay = delays[setupRetries], mine = generation
            setupRetries += 1
            setupRetry = Task { [weak self] in
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                await self?.retrySetup(generation: mine)
            }
        }
        private func retrySetup(generation mine: Int) async {
            setupRetry = nil
            guard mine == generation, !stopped else { return }
            try? await enable()
        }
        /// Boot files (lane F, lean scope item 8), after memory and after projects. They follow the "Use Cloud here"
        /// answer, memory rows on or not: a Mac whose person said "Not now" sends and applies nothing. Called again (the
        /// Cloud page opened, a session ended, the app came to the front) it hands lane F the current folders and
        /// has it look at them; lane F has no watcher and no timer of its own.
        private func enableBoot(_ context: Context) async throws {
            guard NativeCloudBrainRegistration.rowsHere(context.dataRoot).contains(CloudBootFilesFormat.inventoryRow), !stopped else { return }
            // Security look (13 Nov): the "Use Cloud here" answer governs boot files whether or not memory rows are
            // on: no answer yet = the question is asked; "Not now" = nothing is sent or applied.
            guard await useCloudHere(context), !stopped else { return }
            // Decker's ruling on S2: the folder chosen for each project's AI instruction files, kept on this Mac only.
            let foldersFile = NativeCloudBootPlaces.choicesFile(dataRoot: context.dataRoot, subjectHash: context.subjectHash)
            let found = await NativeCloudBootPlaces.current(file: foldersFile)
            let places = found.places, choices = found.choices
            let automatic = await MainActor.run { NativeCloudAccount.shared.trustMode == .account }
            if let existing = boot {
                await existing.setAutoAccept(automatic)
                try? await existing.setPlaces(places)
                try? await existing.refresh()
                await MainActor.run { NativeCloudBoot.shared.update(places: places, choices: choices) }
                return
            }
            let mine = generation
            let engine = context.engine
            let made = try BackendCloudBootFiles(deviceId: context.deviceId,
                stateRoot: NativeCloudLaunch.folder(context.dataRoot).appendingPathComponent(context.subjectHash + "/boot-files", isDirectory: true),
                now: { engine.serviceTime() ?? Int64(Date().timeIntervalSince1970 * 1000) })
            boot = made
            await made.setAutoAccept(automatic)
            await made.setSetupKeeper { root in BackendAISetupKeeper.align(project: root) }
            // Delete rule (L2): gate, which Macs announced the rule, and one name per Mac, before the first engine event.
            await made.setDeleteRuleGate(NativeCloudFolder.deleteRuleIsOpen)
            await made.setDeleteRuleAnnounced(NativeCloudFolder.deleteRuleAnnounced)
            await made.setMacName(NativeCloudDeleteNames.macName)
            // Proof 2 (13 Nov): files from another device are applied by themselves as they arrive (lane F settles a
            // place it has); the list and the places are then looked at again, with no page visit. A project that gets
            // its first folder (made here, or chosen for a project that came from Cloud) does the same.
            await made.setArrivalNotice { await MainActor.run { NativeCloudBrainRegistration.pageOpened() } }
            if !watchingFolders, let registry = BackendPROJRegistry.installed {
                watchingFolders = true
                await registry.cloudLeanWhenFolderAdded { [weak self] in
                    guard let self, await self.bootRunning() else { return false }
                    await MainActor.run { NativeCloudBrainRegistration.pageOpened() }
                    return true
                }
            }
            do { try await made.start(outbox: engine, subjectHash: context.subjectHash) }
            catch { if boot === made { boot = nil }; throw error }
            // What Cloud already holds comes in first (it waits), so identical files are not sent again and a
            // differing local file is listed instead of going up as a rival.
            _ = try? await engine.pull()
            try? await made.setPlaces(places)
            // A stop that landed meanwhile wins: undo at once.
            if mine != generation || stopped { await stopBoot(); return }
            await MainActor.run { NativeCloudBoot.shared.attach(made, places: places, choices: choices, foldersFile: foldersFile) }
        }
        /// Tasks and settings (lane L3), after projects (a task waits for its project). They follow the "Use Cloud here"
        /// answer like projects and agents. Nothing from the Cloud starts work: a task arrives stopped and unassigned.
        private func enableKinds(_ context: Context) async throws {
            let rows = NativeCloudBrainRegistration.rowsHere(context.dataRoot).intersection(BackendCloudKinds.rows)
            guard !rows.isEmpty, !stopped, let live = context.records else { return }
            guard await useCloudHere(context), !stopped else { return }
            let engine = context.engine
            if let existing = kinds {
                if !(await existing.activation.isRunning) { try await existing.activation.start(outbox: engine) }
                return
            }
            let mine = generation
            let registry = live.registry
            guard let made = try BackendCloudKinds.make(enabledRows: rows, cloudFolder: NativeCloudLaunch.folder(context.dataRoot),
                subjectHash: context.subjectHash, deviceId: context.deviceId, serviceTime: { engine.serviceTime() },
                taskStore: live.taskStore,
                projects: {
                    guard let registry, let all = try? await registry.projects() else { return nil }
                    return all.map { BackendCloudKindsProject(id: $0.id, folders: $0.folders) }
                },
                appSettings: live.appSettings, state: live.state, tasksChanged: live.tasksChanged,
                settingsChanged: live.settingsChanged,
                fullAccess: { await MainActor.run { NativeCloudAccount.shared.trustMode == .account } },
                // Same everywhere (15 Nov): the screens' choices travel too, once every computer knows them.
                choices: BackendCloudKindsChoices(),
                newKindsOpen: { await NativeCloudFolder.deleteRuleIsOpen() }) else { return }
            guard mine == generation, !stopped else { return }
            // Delete rule (L4): the gate, Mac names (one name per Mac: the device list's shown name) and the service clock.
            made.tasks?.configureDeleteRule(gate: NativeCloudDeleteNames.gate, macNames: NativeCloudDeleteNames.recordMacName,
                                            serviceTime: { engine.serviceTime() })
            // Tasks everywhere: the connections to connected task systems and this Mac's CRM task links travel too.
            await made.tasks?.setConnectedSystems(live.connectedTasks, links: live.roster)
            kinds = made
            await MainActor.run { NativeCloudBrainRegistration.kinds = made }
            try await made.activation.start(outbox: engine)
            if mine != generation || stopped { await stopKinds() }
        }
        /// The Cloud folder (lane L3 slice 1), last. It follows the "Use Cloud here" answer. Order on a Mac: the folder is
        /// made (first time only), the adapter joins, the Cloud is read (pull), and only then may this Mac's own files be
        /// recorded; the gate (every Mac understands) is asked at every look.
        private func enableCloudFolder(_ context: Context) async throws {
            guard NativeCloudBrainRegistration.rowsHere(context.dataRoot).contains(CloudFolderFormat.inventoryRow), !stopped else { return }
            guard await useCloudHere(context), !stopped else { return }
            if let existing = cloudFolder {
                // A first read that failed earlier is tried again here (the page opened, a retry).
                if (try? await existing.hasReadCloud()) != true, (try? await context.engine.pull()) != nil { try? await existing.markCloudRead() }
                return
            }
            let mine = generation, engine = context.engine
            let folder = NativeCloudFolder.prepare(dataRoot: context.dataRoot)
            let stateRoot = NativeCloudLaunch.folder(context.dataRoot).appendingPathComponent(context.subjectHash + "/cloud-folder", isDirectory: true)
            let made = try BackendCloudFolder(deviceId: context.deviceId, folder: folder, stateRoot: stateRoot,
                everyMacUnderstands: {
                    guard let store = await MainActor.run(body: { DeckMemoryCenter.shared.isReady ? DeckMemoryCenter.shared.store as? DeckMemoryStore : nil }) else { return false }
                    _ = try? await store.cloudFeatureAnnounce(CloudFolderFormat.feature, format: CloudFolderFormat.format)
                    return await store.cloudFeatureEveryMacUnderstands(CloudFolderFormat.feature, format: CloudFolderFormat.format)
                },
                now: { engine.serviceTime() ?? Int64(Date().timeIntervalSince1970 * 1000) })
            await made.setDeleteRuleGate(NativeCloudFolder.deleteRuleIsOpen)
            await made.setDeleteRuleAnnounced(NativeCloudFolder.deleteRuleAnnounced)
            // Review 14 Nov: the page names the Mac that keeps the gate closed, and a file kept beside another by capitals
            // names the Mac it came from.
            await made.setWhoWaits {
                guard let store = await MainActor.run(body: { DeckMemoryCenter.shared.isReady ? DeckMemoryCenter.shared.store as? DeckMemoryStore : nil }) else { return [] }
                let ids = await store.cloudFeatureMacsWaiting(CloudFolderFormat.feature, format: CloudFolderFormat.format)
                return await MainActor.run {
                    ids.map { id in
                        NativeCloudAccount.shared.snapshot.devices.first { $0.deviceId.lowercased() == id.lowercased() }
                            .flatMap { BackendCloudContentsWords.plain($0.shownName) } ?? "One of your devices"
                    }
                }
            }
            // Review 14 Nov (cost): the account's room left, as the service answered (`/state` budget `bytesLeft`).
            await made.setRoomLeft { await MainActor.run { NativeCloudAccount.shared.storageLeft } }
            // Lane L3 slice 2: one daily budget for the Cloud folder and artifacts together.
            await made.setDayBudget(budget(context))
            await made.setMacName { id in
                await MainActor.run {
                    NativeCloudAccount.shared.snapshot.devices.first { $0.deviceId.lowercased() == id.lowercased() }.flatMap { BackendCloudContentsWords.plain($0.shownName) }
                }
            }
            guard mine == generation, !stopped else { return }
            cloudFolder = made
            try await made.start(outbox: engine, subjectHash: context.subjectHash)
            // A Mac that joins reads the Cloud before it sends anything of its own.
            if (try? await made.hasReadCloud()) != true {
                if (try? await engine.pull()) != nil { try? await made.markCloudRead() }
            }
            await MainActor.run { NativeCloudFolder.current = made }
            if mine != generation || stopped { await stopCloudFolder() }
        }
        private func stopCloudFolder() async {
            let current = cloudFolder; cloudFolder = nil
            await current?.stop()
            await MainActor.run { NativeCloudFolder.current = nil }
            await stopArtifacts()
            await stopProjectFolders()
        }
        /// Lane L3 slice 2: artifacts, after the Cloud folder, the same way: the store is made (first time only), the
        /// owner joins, the Cloud is read (pull), and only then is anything of this Mac's own copied in and recorded; the
        /// gate (every Mac understands artifacts records) is asked at every look.
        private func enableArtifacts(_ context: Context) async throws {
            guard NativeCloudBrainRegistration.rowsHere(context.dataRoot).contains(CloudArtifactsFormat.inventoryRow), !stopped else { return }
            guard await useCloudHere(context), !stopped else { return }
            if let existing = artifacts {
                if (try? await existing.owner.hasReadCloud()) != true, (try? await context.engine.pull()) != nil { try? await existing.owner.markCloudRead() }
                return
            }
            let mine = generation, engine = context.engine
            let subject = NativeCloudLaunch.folder(context.dataRoot).appendingPathComponent(context.subjectHash, isDirectory: true)
            let made = try BackendCloudArtifacts(deviceId: context.deviceId, store: subject.appendingPathComponent("artifacts-files", isDirectory: true),
                stateRoot: subject.appendingPathComponent("artifacts", isDirectory: true),
                everyMacUnderstands: {
                    guard let store = await MainActor.run(body: { DeckMemoryCenter.shared.isReady ? DeckMemoryCenter.shared.store as? DeckMemoryStore : nil }) else { return false }
                    _ = try? await store.cloudFeatureAnnounce(CloudArtifactsFormat.feature, format: CloudArtifactsFormat.format)
                    return await store.cloudFeatureEveryMacUnderstands(CloudArtifactsFormat.feature, format: CloudArtifactsFormat.format)
                },
                now: { engine.serviceTime() ?? Int64(Date().timeIntervalSince1970 * 1000) })
            let owner = made.owner
            await owner.setDeleteRuleGate(NativeCloudFolder.deleteRuleIsOpen)
            await owner.setDeleteRuleAnnounced(NativeCloudFolder.deleteRuleAnnounced)
            await owner.setWhoWaits {
                guard let store = await MainActor.run(body: { DeckMemoryCenter.shared.isReady ? DeckMemoryCenter.shared.store as? DeckMemoryStore : nil }) else { return [] }
                let ids = await store.cloudFeatureMacsWaiting(CloudArtifactsFormat.feature, format: CloudArtifactsFormat.format)
                return await MainActor.run {
                    ids.map { id in
                        NativeCloudAccount.shared.snapshot.devices.first { $0.deviceId.lowercased() == id.lowercased() }
                            .flatMap { BackendCloudContentsWords.plain($0.shownName) } ?? "One of your devices"
                    }
                }
            }
            await owner.setRoomLeft { await MainActor.run { NativeCloudAccount.shared.storageLeft } }
            await owner.setDayBudget(budget(context))
            await owner.setMacName { id in
                await MainActor.run {
                    NativeCloudAccount.shared.snapshot.devices.first { $0.deviceId.lowercased() == id.lowercased() }.flatMap { BackendCloudContentsWords.plain($0.shownName) }
                }
            }
            guard mine == generation, !stopped else { return }
            try await made.prepareStore()
            artifacts = made
            try await owner.start(outbox: engine, subjectHash: context.subjectHash)
            if (try? await owner.hasReadCloud()) != true {
                if (try? await engine.pull()) != nil { try? await owner.markCloudRead() }
            }
            await MainActor.run { NativeCloudArtifacts.shared.attach(made) }
            if mine != generation || stopped { await stopArtifacts() }
        }
        /// Folders that travel with a project (19 Nov): one owner over every project folder of this Mac (row I26), the Cloud
        /// folder's way (read the Cloud first, the every-Mac gate, nothing overwritten without a kept version). Called again
        /// (page opened, a project added or moved), it hands the owner the current project folders.
        private var projectFolders: BackendCloudFolder?
        private func enableProjectFolders(_ context: Context) async throws {
            guard NativeCloudBrainRegistration.rowsHere(context.dataRoot).contains(CloudProjectFoldersRules.inventoryRow), !stopped,
                  CloudProjectFoldersRules.isOn() else { return }
            guard await useCloudHere(context), !stopped else { return }
            let found = await NativeCloudBootPlaces.current(file: NativeCloudBootPlaces.choicesFile(dataRoot: context.dataRoot, subjectHash: context.subjectHash))
            let roots = NativeCloudBrainRegistration.projectFolderRoots(found.places)
            if let existing = projectFolders {
                await existing.setRoots(roots)
                if (try? await existing.hasReadCloud()) != true, (try? await context.engine.pull()) != nil { try? await existing.markCloudRead() }
                return
            }
            let mine = generation, engine = context.engine
            let subject = NativeCloudLaunch.folder(context.dataRoot).appendingPathComponent(context.subjectHash, isDirectory: true)
            let made = try BackendCloudFolder(deviceId: context.deviceId, folder: subject.appendingPathComponent("project-folders-root", isDirectory: true),
                stateRoot: subject.appendingPathComponent("project-folders", isDirectory: true), kind: .projectFolders,
                roots: CloudFolderRoots(many: roots),
                everyMacUnderstands: {
                    guard let store = await MainActor.run(body: { DeckMemoryCenter.shared.isReady ? DeckMemoryCenter.shared.store as? DeckMemoryStore : nil }) else { return false }
                    _ = try? await store.cloudFeatureAnnounce(CloudProjectFoldersRules.feature, format: CloudProjectFoldersRules.format)
                    return await store.cloudFeatureEveryMacUnderstands(CloudProjectFoldersRules.feature, format: CloudProjectFoldersRules.format)
                },
                now: { engine.serviceTime() ?? Int64(Date().timeIntervalSince1970 * 1000) })
            await made.setDeleteRuleGate(NativeCloudFolder.deleteRuleIsOpen)
            await made.setDeleteRuleAnnounced(NativeCloudFolder.deleteRuleAnnounced)
            await made.setMacName { id in
                await MainActor.run {
                    NativeCloudAccount.shared.snapshot.devices.first { $0.deviceId.lowercased() == id.lowercased() }.flatMap { BackendCloudContentsWords.plain($0.shownName) }
                }
            }
            guard mine == generation, !stopped else { return }
            projectFolders = made
            try await made.start(outbox: engine, subjectHash: context.subjectHash)
            if (try? await made.hasReadCloud()) != true {
                if (try? await engine.pull()) != nil { try? await made.markCloudRead() }
            }
            if mine != generation || stopped { await stopProjectFolders() }
        }
        private func stopProjectFolders() async {
            let current = projectFolders; projectFolders = nil
            await current?.stop()
        }
        private func stopArtifacts() async {
            let current = artifacts; artifacts = nil
            await current?.owner.stop()
            await MainActor.run { NativeCloudArtifacts.shared.attach(nil) }
        }
        private func stopKinds() async {
            let current = kinds; kinds = nil
            await current?.activation.stop()
            await MainActor.run { NativeCloudBrainRegistration.kinds = nil }
        }
        private var watchingFolders = false
        private func bootRunning() -> Bool {
            let running = boot != nil && !stopped
            if !running { watchingFolders = false }
            return running
        }
        private func stopBoot() async {
            let current = boot; boot = nil
            await current?.stop()
            if let current { await MainActor.run { NativeCloudBoot.shared.detach(current) } }
        }
        /// Projects and agents (lane A2, lean scope item 7), after memory's own setup has returned. They follow the
        /// "Use Cloud here" answer, memory rows on or not: a Mac whose person said "Not now" sends and applies nothing. Nothing from the Cloud starts work here; lane A2's own rules decide what is
        /// applied and what waits.
        private func enableRecords(_ context: Context) async throws {
            let rows = NativeCloudBrainRegistration.rowsHere(context.dataRoot).intersection(BackendCloudLeanRecords.rows)
            guard !rows.isEmpty, !stopped, let live = context.records else { return }
            // Security look (13 Nov): the same answer governs projects and agents, with or without memory rows.
            guard await useCloudHere(context), !stopped else { return }
            let engine = context.engine
            if let existing = records {
                // Built earlier; a start that met the sync core busy with another setup is tried again (the saved
                // cut is reused, and a running activation is left alone).
                let alreadyRunning = await existing.activation.isRunning
                if !alreadyRunning { try await existing.activation.start(outbox: engine) }
                return
            }
            let mine = generation
            let memoryStore = DeckMemoryCenter.shared.isReady ? DeckMemoryCenter.shared.store as? DeckMemoryStore : nil
            let built = try BackendCloudLeanRecords.make(enabledRows: rows, cloudFolder: NativeCloudLaunch.folder(context.dataRoot),
                subjectHash: context.subjectHash, deviceId: context.deviceId, serviceTime: { engine.serviceTime() },
                registry: live.registry, roster: live.roster, defaultProvider: live.defaultProvider,
                projectsChanged: live.projectsChanged, agentsChanged: live.agentsChanged,
                // MAC-NEXT-7 (B): never awaited by the caller. These are called from INSIDE the sync core's apply of a
                // project or agent record; awaiting a release of 37,000 rows there held the fetch for 228 s (MacBook,
                // 13 Nov 14:57:58 -> 15:01:46). The release runs on its own; fetch and send go on.
                placeMemory: { _ = Task.detached { await NativeCloudBrainRegistration.placeWaitingMemory(memoryStore) } },
                recordsApplied: { _ = Task.detached { await NativeCloudBrainRegistration.placeWaitingMemory(memoryStore, retrySetAside: true) } },
                firstArrivalConfirmed: context.firstArrivalConfirmed ?? { false },
                // Y2 (13 Nov): "full access always with the account". With the device-trust setting at its default,
                // "Automatically, with my account", project and agent changes from the account's own trusted devices
                // are applied in full; "Ask me for each new device" keeps them held and listed.
                fullAccess: { await MainActor.run { NativeCloudAccount.shared.trustMode == .account } },
                // Project folders (owner, 14 Nov): a project with no folder on this Mac gets one by itself.
                folders: BackendProjectFolders.installed)
            guard let made = built else { return }
            // Delete rule (L4): gate, one name per Mac, the service clock and the registry's entry-only writers, before start.
            made.agents?.configureDeleteRule(gate: NativeCloudDeleteNames.gate, macNames: NativeCloudDeleteNames.recordMacName,
                                             serviceTime: { engine.serviceTime() })
            made.projects?.configureDeleteRule(gate: NativeCloudDeleteNames.gate, macNames: NativeCloudDeleteNames.recordMacName,
                                               serviceTime: { engine.serviceTime() })
            if let registry = live.registry, let projects = made.projects {
                await projects.setEntryWriters(
                    remove: { id in try await registry.cloudDeleteEntryOnly(id) },
                    restore: { project in try await registry.cloudPutBackEntryOnly(project) })
            }
            // Lane A2's project rule joins the lean one: memory for a project that arrived through Cloud is merged
            // once the person has chosen a folder for it on this Mac (the same id); anything else still waits.
            if let projects = made.projects, let memoryStore {
                // MAC-NEXT-7: the arrived projects are confirmed BEFORE the rule's first release runs.
                await projects.confirmProjects()
                _ = try? await memoryStore.cloudUseLeanProjectRule(then: projects.memoryResolver())
                // Y1: whatever that first release could not do is said (and tried again) here, never swallowed.
                await NativeCloudBrainRegistration.placeWaitingMemory(memoryStore)
            }
            guard mine == generation, !stopped else { return }
            records = made
            await MainActor.run { NativeCloudRecords.shared.attach(made) }
            try await made.activation.start(outbox: engine)
            // A stop that landed while start was waiting wins: undo at once.
            if mine != generation || stopped { await stopRecords() }
        }
        private func stopRecords() async {
            let current = records; records = nil
            await current?.activation.stop()
            if let current { await MainActor.run { NativeCloudRecords.shared.detach(current) } }
        }
        /// The recorded "Use Cloud here" answer for this identity; asked once (N6) when there is none yet. true only for
        /// "Use Cloud here". Memory, projects and agents, and boot files all follow it (security look, 13 Nov).
        private func useCloudHere(_ context: Context) async -> Bool {
            if let recorded = NativeCloudLaunch.memoryChoice(dataRoot: context.dataRoot, subjectHash: context.subjectHash) { return recorded }
            // Owner, 13 Nov: joining is automatic. Signing in IS the choice: Cloud is on for this Mac, both
            // directions, with no question. The Cloud page's switch turns it off.
            guard !stopped else { return false }
            NativeCloudLaunch.setMemoryChoice(true, dataRoot: context.dataRoot, subjectHash: context.subjectHash)
            await MainActor.run {
                NativeCloudAccount.shared.memoryIncluded = true
                NativeCloudAccount.log("cloud sign-in: join ok")
            }
            return true
        }
        /// Starts memory rows if the person chose to include this Mac's memory. Asks once, here, when the first memory
        /// row is about to be enabled (N6). Never at sign-in.
        private func enableMemory(_ context: Context) async throws {
            let here = NativeCloudBrainRegistration.rowsHere(context.dataRoot)
            let rows = NativeCloudBrainRegistration.memoryRows.filter(here.contains)
            guard !rows.isEmpty, !stopped, activation == nil else { return }
            let mine = generation
            guard await useCloudHere(context), mine == generation, !stopped else { return }
            guard DeckMemoryCenter.shared.isReady, let store = DeckMemoryCenter.shared.store as? DeckMemoryStore else { return }
            // Round 5: stamps use the sync core's service clock once its offset is known and this Mac's clock until then
            // (the offset is learned from the first pack commit, which this very setup produces), so nothing waits here.
            let engine = context.engine
            await store.cloudSetClock { engine.serviceTime() }
            // Lean project rule (spec AM10): project memory is merged only into a project with the SAME id on this
            // Mac; anything else waits and is listed. Set before anything can be imported. With lane A2's projects
            // already built for this identity, its rule stays joined to it.
            _ = try? await store.cloudUseLeanProjectRule(then: records?.projects?.memoryResolver())
            guard mine == generation, !stopped else { return }
            let stateRoot = NativeCloudLaunch.folder(context.dataRoot).appendingPathComponent(context.subjectHash + "/memory", isDirectory: true)
            let made = try BackendCloudBrainMemoryActivation(store: store, deviceId: context.deviceId, subjectHash: context.subjectHash, stateRoot: stateRoot, rows: rows)
            activation = made
            do { try await made.start(outbox: context.engine) }
            catch { if activation === made, mine == generation { activation = nil }; throw error }
            // A stop that landed while start was waiting wins: undo at once.
            if mine != generation || stopped { await made.stop(); return }
            // Memory seat (one rule, phase 2): the account's Macs as known now (the account wiring keeps it current).
            // Read with its number in one step: a newer status published meanwhile is never replaced by this one.
            let (macs, generation, devices) = await MainActor.run {
                let snapshot = NativeCloudAccount.shared.snapshot
                return (DeckMemoryStore.oneRuleAccountMacs(snapshot), NativeCloudAccount.shared.oneRuleMacsGeneration, snapshot.devices)
            }
            await store.cloudOneRuleSetAccountMacs(macs, generation: generation)
            // Delete rule (L1): the Macs' shown names for the Bin's groups (never an id as a name).
            try? await store.cloudDeleteSetDevices(devices)
            // Memory that waited for a project which now exists on this Mac is placed. MAC-NEXT-7: when projects travel
            // and their owner is not built yet, the release (and its line) waits for it: `enableRecords`, right after
            // this, confirms this Mac's project list first and then releases, so no arrived project is called absent.
            let projectsPending = records?.projects == nil && NativeCloudBrainRegistration.recordRows.contains(BackendCloudLeanRecords.projectsRow)
            if !projectsPending { await NativeCloudBrainRegistration.placeWaitingMemory(store) }
        }
        /// L1 adds the defaulted `force` argument to the EXISTING feature announcer (exact edit in L0's result).
        /// Force the first successful write and each 12-hour deadline; intervening events use the writer's deduplication.
        private func startDeleteRuleAnnouncements() async {
            guard activation != nil, !stopped, DeckMemoryCenter.shared.isReady,
                  let store = DeckMemoryCenter.shared.store as? DeckMemoryStore else { return }
            let mine = generation
            guard await renewDeleteRule(store, generation: mine), mine == generation, !stopped,
                  deleteRuleRenewal == nil else { return }
            deleteRuleRenewal = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(CloudDeleteGate.renewAfter)) }
                    catch { return }
                    guard !Task.isCancelled, let self,
                          await self.renewDeleteRule(store, generation: mine, force: true) else { return }
                }
            }
        }
        private func renewDeleteRule(_ store: DeckMemoryStore, generation mine: Int, force: Bool = false) async -> Bool {
            guard mine == generation, !stopped, activation != nil, !Task.isCancelled else { return false }
            do {
                let written = try await store.cloudFeatureAnnounce(CloudDeleteGate.feature, format: CloudDeleteGate.format,
                                                                 force: force || deleteRuleLaunchPending)
                guard mine == generation, !stopped else { return false }
                if written { deleteRuleLaunchPending = false }
                if let context { await announceKindsOffHere(context) }
            } catch {
                CloudSyncDiagnostics.shared.report("Cloud delete-rule announcement", error)
            }
            return mine == generation && !stopped && activation != nil
        }
        /// A kind switched off here never holds the other devices back: this device still says it understands the Cloud
        /// folder's and the artifacts' records (it does), so their gates do not wait for it. Renewed with the delete rule.
        private func announceKindsOffHere(_ context: Context) async {
            let here = NativeCloudBrainRegistration.rowsHere(context.dataRoot)
            guard DeckMemoryCenter.shared.isReady, let store = DeckMemoryCenter.shared.store as? DeckMemoryStore else { return }
            if NativeCloudBrainRegistration.enabledRows.contains(CloudFolderFormat.inventoryRow), !here.contains(CloudFolderFormat.inventoryRow) {
                _ = try? await store.cloudFeatureAnnounce(CloudFolderFormat.feature, format: CloudFolderFormat.format)
            }
            if NativeCloudBrainRegistration.enabledRows.contains(CloudArtifactsFormat.inventoryRow), !here.contains(CloudArtifactsFormat.inventoryRow) {
                _ = try? await store.cloudFeatureAnnounce(CloudArtifactsFormat.feature, format: CloudArtifactsFormat.format)
            }
            if NativeCloudBrainRegistration.enabledRows.contains(CloudProjectFoldersRules.inventoryRow), !here.contains(CloudProjectFoldersRules.inventoryRow) {
                _ = try? await store.cloudFeatureAnnounce(CloudProjectFoldersRules.feature, format: CloudProjectFoldersRules.format)
            }
        }
        private func stopDeleteRuleAnnouncements() {
            deleteRuleRenewal?.cancel()
            deleteRuleRenewal = nil
            deleteRuleLaunchPending = true
        }
        /// The Cloud page opened: place memory whose project has appeared on this Mac since the last look, and
        /// start anything that could not start earlier (the sync core was busy with another setup).
        func retryWaitingProjects() async {
            try? await enable()
            guard activation != nil, !stopped, DeckMemoryCenter.shared.isReady, let store = DeckMemoryCenter.shared.store as? DeckMemoryStore else { return }
            await NativeCloudBrainRegistration.placeWaitingMemory(store)
        }
        /// Yes → No on the Cloud page: uploading stops; nothing is deleted in Cloud.
        func pauseMemory() async {
            generation += 1
            stopDeleteRuleAnnouncements()
            let current = activation; activation = nil
            await current?.stop()
            // Projects, agents and boot files follow the same choice: nothing of this Mac's own goes up after a "no".
            await stopRecords()
            await stopBoot()
            await stopKinds()
            await stopCloudFolder()
            // Round 3 M1b limit 3: capture may be on with no activation held (after failed attempts); stop it on the store too.
            await NativeCloudBrainRegistration.suspendMemory()
        }
        /// Sign-out or a closed gate: final for this identity in this run.
        func stop() async {
            stopped = true; generation += 1
            stopDeleteRuleAnnouncements()
            let current = activation; activation = nil
            await current?.stop()
            // Final for these objects: a later sign-in builds new ones. Nothing is deleted.
            await stopRecords()
            await stopBoot()
            await stopKinds()
            await stopCloudFolder()
            await NativeCloudBrainRegistration.suspendMemory()
        }
    }

    /// Y1 (13 Nov): every release of waiting project memory goes through here, so none is silent. One `cloud memory:`
    /// line per pass: released n, still waiting m and for which project, rows set aside and why (numbers and project
    /// ids only, never content). A call that joined a pass already running writes nothing (that pass reports).
    /// A failure is reported, never swallowed (before: `try?` at three places hid the stop after 8,000 rows).
    /// MAC-NEXT-7 (3): `retrySetAside` (a project or agent record was just applied) tries every set-aside row again
    /// now; otherwise they are tried again every 10 minutes (a timer armed while any is set aside), never only at the
    /// next app start.
    static func placeWaitingMemory(_ store: DeckMemoryStore?, retrySetAside: Bool = false) async {
        guard let store else { return }
        if retrySetAside { await store.cloudRetrySetAsideNow() }
        do {
            let result = try await store.cloudReleaseWaitingProjects(announce: { line in await MainActor.run { NativeCloudAccount.log(line) } })
            if let at = try? await store.cloudSetAsideRetryAt() { await retrySetAsideAt(at, store) }
            guard !result.joinedRunning else { return }
            // Nothing placed, nothing waiting, nothing set aside: no line (the page and the project list call often).
            let quiet = result.placed == 0 && result.parked == 0 && result.waiting.isEmpty && result.parkedNow == 0
            if quiet {
                // MAC-NEXT-8 (real check 4): the first pass of a run always says it ran, so the log shows the launch
                // pass even when there was nothing to place; later quiet passes stay silent (pages call this often).
                let first = await MainActor.run { () -> Bool in defer { quietPassLogged = true }; return !quietPassLogged }
                if first { await MainActor.run { NativeCloudAccount.log(result.line.replacingOccurrences(of: "released 0; still waiting 0", with: "nothing waiting to place")) } }
                return
            }
            let line = result.line
            await MainActor.run { NativeCloudAccount.log(line) }
            // Rows of a project here that are still waiting (they arrived during the very last round): once more soon.
            if !result.waiting.isEmpty { await placeAgainSoon(store) }
        } catch let failure as CloudFailure where failure == .unavailable {
            // Memory is not switched on for this account on this Mac (yet): nothing to place, nothing to say.
            return
        } catch {
            let kind = String(describing: type(of: error))
            await MainActor.run { NativeCloudAccount.log("cloud memory: placing waiting memory failed: " + kind + "; tried again in 60 s") }
            await placeAgainSoon(store)
        }
    }
    /// One timed retry at a time (60 s), so a release that failed or left releasable rows finishes by itself, with no
    /// page visit and no new arrival needed.
    @MainActor private static var retryPending = false
    @MainActor private static var quietPassLogged = false
    private static func placeAgainSoon(_ store: DeckMemoryStore) async {
        let start = await MainActor.run { () -> Bool in
            guard !retryPending else { return false }
            retryPending = true
            return true
        }
        guard start else { return }
        Task.detached {
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            await MainActor.run { retryPending = false }
            await placeWaitingMemory(store)
        }
    }

    /// One 10-minute timer at a time for set-aside memory rows (MAC-NEXT-7 (3)).
    @MainActor private static var setAsideTimerPending = false
    private static func retrySetAsideAt(_ at: Date, _ store: DeckMemoryStore) async {
        let start = await MainActor.run { () -> Bool in
            guard !setAsideTimerPending else { return false }
            setAsideTimerPending = true
            return true
        }
        guard start else { return }
        let wait = max(1, at.timeIntervalSinceNow)
        Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            await MainActor.run { setAsideTimerPending = false }
            await placeWaitingMemory(store)
        }
    }

    /// The running identity's place, so the Cloud page can change the memory choice (N6).
    @MainActor static var current: Running?
    /// Lane L3's tasks and settings of the running identity, for the Cloud pages' counts. nil while not built.
    @MainActor static var kinds: BackendCloudKinds?

    /// Stops memory capture on the live store directly; safe when nothing was started this launch (finding 2).
    static func suspendMemory() async {
        guard DeckMemoryCenter.shared.isReady, let store = DeckMemoryCenter.shared.store as? DeckMemoryStore else { return }
        try? await store.cloudSuspendCapture()
    }

    /// The person answered the new-Mac sheet: this Mac's memory may be set up now (see `Running.enable`).
    @MainActor static func newMacAnswered() {
        guard let running = current else { return }
        Task { try? await running.enable() }
    }
    /// The Cloud page opened (see `Running.retryWaitingProjects`).
    @MainActor static func pageOpened() {
        guard let running = current else { return }
        Task { await running.retryWaitingProjects() }
    }
    /// A "Keep in sync on this Mac" switch moved (see `Running.choicesChanged`).
    @MainActor static func choicesChanged() {
        guard let running = current else { return }
        Task { await running.choicesChanged() }
    }
    /// The Cloud page switch, routed to the running identity's serialised place.
    @MainActor static func setMemoryIncluded(_ include: Bool) {
        guard let running = current else { return }
        Task { await running.setChoice(include) }
    }
}
