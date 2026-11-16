import AppKit
import Foundation
import Observation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Lane L4 (owner, 14 Nov: "a proper file manager"): open an item, its earlier versions, use one, Remove to the Bin,
/// Put back, Empty Bin, Clean up. The page model's actions. Changes go through this Mac's memory store and lane F's
/// safe put-back only: nothing here sends anything itself and no socket message changes.

/// What is open in the details: the item's text, or one earlier version's.
struct NativeCloudOpened: Equatable {
    let itemId: String
    let versionId: String?
    /// nil = nothing readable (its facts are shown instead).
    let text: String?
    /// CLOUD-FILES-4: when an item that has text could not show it, the one plain line that says why (never an empty area).
    var line: String? = nil
}

/// A change waiting out its 10 seconds behind one "Undo" line (as the Devices page does for "Sign out this device").
struct NativeCloudUndo: Equatable {
    enum What: Hashable { case remove(itemId: String), group(String), emptyBin, cleanUp }
    let what: What
    /// "Removing…", "Emptying the Bin…", "Cleaning up…".
    let line: String
}

/// What the page may do with memory files. Injected, so the page's own tests run without a memory store.
/// One rule phase 2 (Memory seat): ONE Bin and ONE delete path. Every change is the memory store's own function
/// (`DeckMemoryStoreCloudFiles.swift` → `memoryRemove`, `memoryPutBack`, `memoryUseVersion`, `memoryEmptyBin`,
/// `memoryCleanUpVersions`); nothing here names files to delete.
struct NativeCloudFileOps: Sendable {
    /// A file's text, or (for an item in the Bin) its kept text.
    var text: @Sendable (String) async -> String?
    /// A kept earlier text of `item` by its keeper id.
    var keptText: @Sendable (_ item: String, _ versionId: String) async -> String?
    var useVersion: @Sendable (_ item: String, _ versionId: String) async throws -> Void
    var remove: @Sendable (_ path: String, _ fromAI: Bool) async throws -> Void
    var putBack: @Sendable (String) async throws -> Void
    var emptyBin: @Sendable () async throws -> Int
    var cleanUp: @Sendable () async throws -> Int
    /// What Empty Bin and Clean up would remove right now (Bin items, kept texts), for the approved-count check.
    var counts: @Sendable () async -> (bin: Int, kept: Int)?
    var folderKept: @Sendable (_ path: String) async -> URL? = { path in
        guard let folder = await MainActor.run(body: { NativeCloudFolder.current }),
              let newest = (try? await folder.versions(path: path))?.first else { return nil }
        return try? await folder.openable(path: path, sha256: newest.sha256)
    }

    static let live = NativeCloudFileOps(
        text: { path in
            guard let store = await NativeCloudFileOps.store() else { return nil }
            if let text = await store.cloudFileText(path) { return text }
            return try? await store.memoryBinText(path: path)
        },
        keptText: { item, id in try? await NativeCloudFileOps.store()?.memoryVersionText(path: item, versionId: id) },
        useVersion: { item, id in try await NativeCloudFileOps.required().cloudFileUseVersion(item: item, versionId: id) },
        remove: { path, fromAI in _ = try await NativeCloudFileOps.required().cloudFileRemove(path, fromAI: fromAI) },
        putBack: { path in _ = try await NativeCloudFileOps.required().cloudFilePutBack(path) },
        emptyBin: { try await NativeCloudFileOps.required().cloudFileEmptyBin() },
        cleanUp: { try await NativeCloudFileOps.required().cloudFileCleanUp() },
        counts: {
            guard let store = await NativeCloudFileOps.store(), let bin = try? await store.memoryBin().count,
                  let kept = try? await store.memoryCleanUpCount() else { return nil }
            return (bin, kept)
        })

    static func store() async -> DeckMemoryStore? {
        await MainActor.run { DeckMemoryCenter.shared.isReady ? DeckMemoryCenter.shared.store as? DeckMemoryStore : nil }
    }
    static func required() async throws -> DeckMemoryStore {
        guard let store = await store() else { throw NativeRPCError(code: "unavailable", message: "Memory is still starting on this Mac. Try again in a moment.") }
        return store
    }
}

extension NativeCloudContentsModel {
    static let couldNotRemove = "Some items could not be removed. Check the list and try again."
    static let couldNotPutBack = "That could not be put back. Nothing was changed."
    static let couldNotUse = "That version could not be used. Nothing was changed."
    static let couldNotDelete = "That could not be finished. What is left stays as it was."
    static let changedSinceAsked = "The Bin or the kept versions changed during the change. Try again."
    /// CLOUD-FILES-4: an instruction file whose project folder (or AI settings folder) is not on this Mac.
    static let textNotHere = BackendCloudFilesReadFence.refusedLine
    static let textUnreadable = "Its text could not be read on this Mac."

    // MARK: Opening and versions

    /// The open item's earlier versions, newest first (memory notes from the page; instruction files from their keeper).
    func versions(_ item: BackendCloudContents.Item) -> [BackendCloudContents.Version] {
        item.kind == .instructionFiles ? (fileVersions[item.id] ?? []) : item.versions
    }
    var chosenVersion: BackendCloudContents.Version? {
        guard let item = selectedItem, let chosen = versionChosen else { return nil }
        return versions(item).first { $0.id == chosen }
    }
    /// Opens an item in the reading pane (nil closes it). A shown saved password's value goes with any change.
    func choose(_ item: BackendCloudContents.Item?) {
        selected = item?.id
        versionChosen = nil
        revealed = nil
    }
    /// A place on the left (nil = the Bin). Cloud file manager: it opens at its top and back / forward remember it.
    func chooseShelf(kind: BackendCloudContents.Kind?) {
        go(to: NativeCloudPlace(kind: kind ?? self.kind, bin: kind == nil, code: false, path: []))
    }
    /// Reads what is open now: the chosen version's text, else the item's. Called whenever the selection changes.
    func open() async {
        guard let item = selectedItem else { opened = nil; return }
        if item.kind == .instructionFiles, fileVersions[item.id] == nil { await loadFileVersions(item) }
        let versionId = versionChosen
        var text: String?
        var line: String?
        if let versionId {
            if item.kind == .instructionFiles {
                // CLOUD-FILES-5: a kept copy with a zero byte (or not text) is never turned into text.
                if let hash = keptHashes[versionId], let data = await NativeCloudBoot.shared.keptText(hash) { text = BackendCloudFilesReadFence.text(data) }
            } else if let handle = handles[item.id], let kept = BackendCloudFilesPlan.keptId(handle.versions[versionId]), let relative = handle.relative {
                text = await files.keptText(relative, kept)
            } else if let path = handles[item.id]?.versions[versionId] {
                text = await files.text(path)
            }
        } else if item.kind == .memory, let path = handles[item.id]?.relative, item.canOpen {
            text = await files.text(path)
        } else if item.kind == .instructionFiles {
            // CLOUD-FILES-5: through the one fence; refused (or not readable) = the one plain line, never the text.
            text = await preview(item)
            if text == nil { line = Self.textNotHere }
        }
        if text == nil, line == nil, item.canOpen { line = item.kind == .instructionFiles ? Self.textNotHere : Self.textUnreadable }
        // Only if nothing else was chosen while reading.
        guard selected == item.id, versionChosen == versionId else { return }
        opened = NativeCloudOpened(itemId: item.id, versionId: versionId, text: text.map(Self.shownText), line: line)
    }
    /// A note's text without its label block (the `---` lines the app keeps for itself).
    nonisolated static func shownText(_ text: String) -> String {
        guard text.hasPrefix("---\n"), let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) else { return text }
        return String(text[end.upperBound...]).trimmingCharacters(in: .newlines)
    }
    private func loadFileVersions(_ item: BackendCloudContents.Item) async {
        // CLOUD-FILES-5: earlier versions only for a path the one fence allows (never an AI settings folder's file).
        guard let handle = handles[item.id], let relative = handle.relative, BackendCloudFilesReadFence.allowed(relative, home: handle.home) else {
            fileVersions[item.id] = []; return
        }
        let kept = await NativeCloudBoot.shared.keptVersions(home: handle.home, projectId: handle.projectId, relative: relative)
        var names: [String: String] = [:]
        for device in account.snapshot.devices { names[device.deviceId] = BackendCloudContentsWords.plain(device.shownName) }
        var made: [BackendCloudContents.Version] = []
        for (index, version) in kept.enumerated() {
            let id = item.id + "|" + String(version.at) + "|" + String(index)
            keptHashes[id] = version.hash
            made.append(.init(id: id, at: version.at, device: names[version.device] ?? BackendCloudContentsWords.unknownDevice, bytes: version.bytes,
                              keptUntil: version.keptUntil, canUse: NativeCloudBoot.shared.restorable(relative: relative, hash: version.hash) != nil))
        }
        fileVersions[item.id] = made
    }

    // MARK: Changes the person makes on the page

    /// "Use this version": acts at once (the person just read it here); the version it replaces is kept.
    func useChosenVersion() {
        guard let item = selectedItem, let version = chosenVersion, version.canUse else { return }
        NativeCloudSheetGuard.shared.pagePress(model: account) {
            Task {
                if let line = await self.performUseVersion(item, version) { self.account.say(line) }
                self.versionChosen = nil
                self.fileVersions[item.id] = nil
                await self.refresh()
                await self.open()
            }
        }
    }
    /// One press uses one actor/group, including a selection spanning several owners.
    func startRemove(_ item: BackendCloudContents.Item) { startDelete(deleteSelection(for: item), scope: .everywhere) }
    func deleteSelection(for item: BackendCloudContents.Item) -> [BackendCloudContents.Item] {
        selection.contains(item.id) ? selectedRows : [item]
    }
    func startDelete(_ rows: [BackendCloudContents.Item], scope: CloudDeleteScope) {
        guard !rows.contains(where: { pendingWhat(for: $0) != nil }) else { return }
        var seen: Set<String> = []
        let targets = rows.filter(\.canRemove).flatMap(\.deleteItems).filter { seen.insert(BackendCloudDeletePage.key($0)).inserted }
        guard !targets.isEmpty, scope != .cloud || (deleteGateOpen && !targets.contains { ["task", "agent"].contains($0.kind) }) else { return }
        // While an older Mac exists a secret kind's delete would stay on this Mac (L3: nothing secret travels while
        // the gate is closed), so the page offers none for them.
        guard deleteGateOpen || !targets.contains(where: { BackendCloudDeletePage.kind($0) == .passwords }) else { return }
        guard !targets.contains(where: { deleteRefusedRoutes.contains(BackendCloudDeletePage.route($0)) }) else { return }
        let actor = personDeleteActor()
        let what: NativeCloudUndo.What = rows.count == 1 ? .remove(itemId: rows[0].id) : .group(actor.group)
        NativeCloudSheetGuard.shared.pagePress(model: account) {
            later(.init(what: what, line: BackendCloudFilesWords.removing)) { model in
                do { _ = try await model.deletions.delete(targets, scope, actor); model.actionLine = "Moved to the Bin for 30 days." }
                catch { model.actionLine = Self.couldNotRemove; model.account.say(Self.couldNotRemove) }
                model.selection.subtract(rows.map(\.id))
            }
            pendingRows[what] = Set(rows.map(\.id))
        }
    }
    func bringBack(_ rows: [BackendCloudContents.Item], to destination: CloudBringBackDestination) {
        let items = rows.flatMap(\.deleteItems)
        guard !items.isEmpty else { return }
        NativeCloudSheetGuard.shared.pagePress(model: account) {
            runPageChange {
                self.actionLine = destination == .thisMac ? "Bringing back…" : "Putting in Cloud again…"
                do { _ = try await self.deletions.bringBack(items, destination); self.actionLine = destination == .thisMac ? "Brought back to this Mac." : "Put in Cloud again." }
                catch { self.actionLine = Self.couldNotPutBack; self.account.say(Self.couldNotPutBack) }
                await self.refresh()
            }
        }
    }
    func putBack(_ item: BackendCloudContents.Item) {
        NativeCloudSheetGuard.shared.pagePress(model: account) {
            runPageChange {
                if let line = await self.performPutBack(item) { self.account.say(line) }
                await self.refresh()
            }
        }
    }
    func putBackGroup(_ group: CloudBinGroup) {
        guard !busyBin.contains(group.id) else { return }
        NativeCloudSheetGuard.shared.pagePress(model: account) {
            busyBin.insert(group.id)
            runPageChange {
                defer { self.busyBin.remove(group.id) }
                self.actionLine = "Putting back…"
                do { self.actionLine = try await self.deletions.putBackGroup(group) ?? "Put back from the Bin." }
                catch { self.actionLine = Self.couldNotPutBack; self.account.say(Self.couldNotPutBack) }
                await self.refresh()
            }
        }
    }
    func putBackBinItem(_ item: CloudDeleteItem, group: CloudBinGroup) {
        NativeCloudSheetGuard.shared.pagePress(model: account) {
            runPageChange {
                self.actionLine = "Putting back…"
                do { try await self.deletions.putBackItem(item, group); self.actionLine = "Put back from the Bin." }
                catch { self.actionLine = Self.couldNotPutBack; self.account.say(Self.couldNotPutBack) }
                await self.refresh()
            }
        }
    }
    func deleteForGood(_ items: [CloudDeleteItem]) {
        NativeCloudSheetGuard.shared.pagePress(model: account) {
            runPageChange {
                self.actionLine = "Removing from the Bin…"
                do { try await self.deletions.deleteForGood(items); self.actionLine = "Removed from the Bin." }
                catch { self.actionLine = Self.couldNotDelete; self.account.say(Self.couldNotDelete) }
                await self.refresh()
            }
        }
    }
    func startEmptyBin() {
        // Capture what he saw. A new group arriving meanwhile is never silently included.
        let items = binGroups.flatMap(\.items)
        guard !items.isEmpty else { return }
        deleteForGood(items)
    }
    func makeRootAgain(_ kind: BackendCloudContents.Kind) {
        NativeCloudSheetGuard.shared.pagePress(model: account) {
            runPageChange {
                do { try await self.deletions.makeRoot(kind) }
                catch { self.account.say("That folder could not be made again.") }
                await self.refresh()
            }
        }
    }
    private func runPageChange(_ work: @escaping @MainActor () async -> Void) {
        let id = UUID()
        pageTasks[id] = Task {
            await work()
            self.pageTasks[id] = nil
        }
    }
    func personDeleteActor() -> CloudDeleteActor {
        let this = account.snapshot.devices.first { device in account.snapshot.trust.contains { $0.deviceId == device.deviceId && $0.standing == .thisMac } }
        let id = this?.deviceId ?? account.snapshot.trust.first { $0.standing == .thisMac }?.deviceId ?? ""
        return .init(by: .person, mac: id, macName: BackendCloudContentsWords.plain(this?.shownName) ?? "This Mac",
                     at: Int64(Date().timeIntervalSince1970 * 1000), group: UUID().uuidString.lowercased())
    }
    /// "Clean up N earlier versions": only kept earlier versions, never an item in use.
    func startCleanUp() {
        guard let count = model?.versionsToClean, count > 0 else { return }
        NativeCloudSheetGuard.shared.pagePress(model: account) {
            // His own press is the answer; never more than the button counted.
            later(.init(what: .cleanUp, line: BackendCloudFilesWords.cleaning)) { model in
                if let line = await model.performCleanUp(approved: count) { model.account.say(line) }
            }
        }
    }
    /// Review 14 Nov (point 4): "Show" on a "newer one is in use" line: this Mac's kept version opens as a file (a copy
    /// in the app's own folder). His own press; refused after remote control like the page's other presses.
    static let couldNotShow = "That version could not be opened. Nothing was changed."
    func showFolderKept(_ path: String) {
        NativeCloudSheetGuard.shared.pagePress(model: account) {
            Task {
                if let url = await self.files.folderKept(path) { NSWorkspace.shared.open(url) } else { self.account.say(Self.couldNotShow) }
            }
        }
    }
    /// Cancels one change waiting behind its Undo line.
    func undo(_ what: NativeCloudUndo.What) {
        pendingTasks[what]?.cancel()
        pendingTasks[what] = nil
        pending[what] = nil
        pendingRows[what] = nil
    }
    /// Cancels every waiting change: when the page is left or the window closes.
    func undoAll() {
        for task in pendingTasks.values { task.cancel() }
        pendingTasks = [:]
        pending = [:]
        pendingRows = [:]
    }
    /// Each change waits on its own: a second one never cancels the first; each has its own Undo.
    private func later(_ change: NativeCloudUndo, _ act: @escaping @MainActor (NativeCloudContentsModel) async -> Void) {
        undo(change.what)
        pending[change.what] = change
        let wait = undoSeconds, waitOut = undoWait
        pendingTasks[change.what] = Task { [weak self] in
            await waitOut(wait)
            guard !Task.isCancelled, let self, self.pending[change.what] == change else { return }
            self.pending[change.what] = nil
            self.pendingTasks[change.what] = nil
            self.pendingRows[change.what] = nil
            await act(self)
            if case .remove(let id) = change.what, self.selected == id { self.choose(nil) }
            await self.refresh()
        }
    }

    // MARK: The changes themselves (the page after its Undo time, and the tools after the person's approval)

    /// nil when done; otherwise the one plain line to say.
    /// The page's own Remove (the owner at this Mac).
    func performRemove(_ item: BackendCloudContents.Item) async -> String? {
        guard item.canRemove, let path = handles[item.id]?.relative else { return Self.couldNotRemove }
        do { try await files.remove(path, false); return nil } catch { return Self.couldNotRemove }
    }
    /// A tool's Remove: an AI asked (notes only; never shown as his own removal).
    func performRemove(path: String) async -> String? {
        do { try await files.remove(path, true); return nil } catch { return Self.couldNotRemove }
    }
    func performPutBack(_ item: BackendCloudContents.Item) async -> String? {
        guard item.canPutBack, let path = handles[item.id]?.relative else { return Self.couldNotPutBack }
        if item.kind == .cloudFolder || item.kind == .artifacts {
            let target = CloudDeleteItem(id: path, kind: item.kind.rawValue, name: item.name, place: path)
            do { try await deletions.putBackItem(target, nil); return nil } catch { return Self.couldNotPutBack }
        }
        do { try await files.putBack(path); return nil } catch { return Self.couldNotPutBack }
    }
    func performUseVersion(_ item: BackendCloudContents.Item, _ version: BackendCloudContents.Version) async -> String? {
        guard version.canUse, let handle = handles[item.id], let relative = handle.relative else { return Self.couldNotUse }
        if item.kind == .instructionFiles {
            guard let hash = keptHashes[version.id] else { return Self.couldNotUse }
            return await NativeCloudBoot.shared.useKept(relative: relative, hash: hash)
        }
        // One rule phase 2: only a kept text (keeper id) can be made the newest; a copy in the folder is history.
        guard item.kind == .memory, let kept = BackendCloudFilesPlan.keptId(handle.versions[version.id]) else { return Self.couldNotUse }
        do { try await files.useVersion(relative, kept); return nil } catch { return Self.couldNotUse }
    }
    /// Empty Bin through the store. `approved`: how many items the owner was shown; when more are in the Bin now,
    /// nothing is removed.
    func performEmptyBin(approved: Int) async -> String? {
        if let now = await files.counts(), now.bin > approved { return Self.changedSinceAsked }
        do { _ = try await files.emptyBin(); return nil } catch { return Self.couldNotDelete }
    }
    /// Clean up through the store, with the same check against the count the owner was shown.
    func performCleanUp(approved: Int) async -> String? {
        if let now = await files.counts(), now.kept > approved { return Self.changedSinceAsked }
        do { _ = try await files.cleanUp(); return nil } catch { return Self.couldNotDelete }
    }

    // MARK: The tools (cloud.*): one fresh read, then the same actions as the page, with no Undo time (the approval
    // the person answered is the protection).

    /// The item an AI names by kind, name and place (as `cloud.items` lists them). Bin items too.
    func find(kind: String?, name: String, place: String?) -> BackendCloudContents.Item? {
        let wantedKind = kind.flatMap { want in BackendCloudContents.Kind.allCases.first { $0.title.caseInsensitiveCompare(want) == .orderedSame || $0.rawValue == want } }
        let matches = (model?.items ?? []).filter { item in
            guard !BackendCloudNoteIdentity.isBin(item.state) else { return false }
            return item.name.caseInsensitiveCompare(name) == .orderedSame && (wantedKind == nil || item.kind == wantedKind)
                && (place == nil || item.place?.caseInsensitiveCompare(place!) == .orderedSame)
        }
        return matches.count == 1 ? matches[0] : nil
    }
    func openText(_ item: BackendCloudContents.Item, version: BackendCloudContents.Version?) async -> String? {
        choose(item)
        versionChosen = version?.id
        await open()
        return opened?.text
    }
    /// The tools' actions, each on one fresh read of the page's lists.
    nonisolated static func toolActions() -> BackendCloudManagerTools.Actions {
        BackendCloudManagerTools.Actions(contents: { await toolContents() },
                                         read: { ref, at in try await toolRead(ref, at: at) },
                                         change: { change in try await toolChange(change) },
                                         folder: { projectId in await MainActor.run { NativeCloudBoot.shared.projectRoot(projectId)?.path } })
    }
    static func toolContents() async -> BackendCloudManagerTools.Snapshot? {
        guard let probe = await freshModel(), let model = probe.model else { return nil }
        return .init(contents: model, handles: probe.handles)
    }
    static func freshModel() async -> NativeCloudContentsModel? {
        let probe = NativeCloudContentsModel()
        await probe.refresh(includeBin: false)
        return probe.model == nil ? nil : probe
    }
    func toolItem(_ ref: BackendCloudManagerTools.Ref) async throws -> BackendCloudContents.Item {
        guard let found = find(kind: ref.kind, name: ref.name, place: ref.place) else { throw BackendCloudManagerTools.notFound(ref) }
        // An instruction file's versions are read from its keeper when it is opened.
        if found.kind == .instructionFiles { choose(found); await open() }
        return found
    }
    static func toolRead(_ ref: BackendCloudManagerTools.Ref, at: String?) async throws -> BackendCloudManagerTools.Opened {
        guard let probe = await freshModel() else { throw BackendCloudManagerTools.signedOut }
        let found = try await probe.toolItem(ref)
        let versions = probe.versions(found)
        let version = try BackendCloudManagerTools.version(versions, at: at)
        return .init(item: found, versions: versions, text: await probe.openText(found, version: version))
    }
    static func toolChange(_ change: BackendCloudManagerTools.Change) async throws -> String {
        switch change {
        // The approved paths only: no second read decides what is deleted.
        case .remove(let ref, let path):
            if let line = await NativeCloudContentsModel(files: .live).performRemove(path: path) { throw BackendCloudManagerTools.cannot(line) }
            return "In the Bin: " + ref.name
        case .emptyBin:
            throw BackendCloudManagerTools.cannot("The Bin is opened by hand in Your Cloud.")
        case .cleanUp(let count):
            if let line = await NativeCloudContentsModel(files: .live).performCleanUp(approved: count) { throw BackendCloudManagerTools.cannot(line) }
            return BackendCloudFilesWords.cleaned(count)
        case .restore(let ref, let at):
            guard let probe = await freshModel() else { throw BackendCloudManagerTools.signedOut }
            let found = try await probe.toolItem(ref)
            if at == nil, BackendCloudNoteIdentity.isBin(found.state) {
                throw BackendCloudManagerTools.cannot("The Bin is opened by hand in Your Cloud.")
            }
            guard let version = try BackendCloudManagerTools.version(probe.versions(found), at: at) else {
                throw BackendCloudManagerTools.cannot("Give version: the date of an earlier version from cloud_item_versions.")
            }
            if let line = await probe.performUseVersion(found, version) { throw BackendCloudManagerTools.cannot(line) }
            return "In use now: the version of " + found.name + " from " + BackendCloudContentsWords.time(version.at)
        }
    }
}

/// Injected page operations. Bin closures have no tool registration and are called only by guarded page presses.
struct NativeCloudDeleteOps: Sendable {
    struct Read: Sendable {
        var marks: [CloudNotHereItem] = []
        var groups: [CloudBinGroup] = []
        var gateOpen = false
        /// The file owners' row lines (`rowErrors()`), by `BackendCloudDeletePage.key`.
        var rowErrors: [String: String] = [:]
        /// Owner routes that cannot delete right now (`canDeleteEverywhere()` false): their rows show no delete button.
        var refusedRoutes: Set<String> = []
        /// The sealed Bins' one line (`binNotice`), said once by the page.
        var notices: [String] = []
    }
    var read: @Sendable (_ includeBin: Bool) async throws -> Read = { _ in Read() }
    var delete: @Sendable ([CloudDeleteItem], CloudDeleteScope, CloudDeleteActor) async throws -> [CloudBinGroup] = { _, _, _ in throw CloudFailure.unavailable }
    var bringBack: @Sendable ([CloudDeleteItem], CloudBringBackDestination) async throws -> [CloudDeleteItem] = { _, _ in throw CloudFailure.unavailable }
    /// "Put back all": the owners' one-line answer (names only: what came back, what did not), nil = no line.
    var putBackGroup: @Sendable (CloudBinGroup) async throws -> String? = { _ in throw CloudFailure.unavailable }
    /// One Bin row. `group` is the shown removal it belongs to (nil for the older own-kind Put back).
    var putBackItem: @Sendable (CloudDeleteItem, CloudBinGroup?) async throws -> Void = { _, _ in throw CloudFailure.unavailable }
    var deleteForGood: @Sendable ([CloudDeleteItem]) async throws -> Void = { _ in throw CloudFailure.unavailable }
    var makeRoot: @Sendable (BackendCloudContents.Kind) async throws -> Void = { _ in throw CloudFailure.unavailable }

    static let live = NativeCloudDeleteOps(read: { includeBin in
        let owners = await NativeCloudDeleteOwners.all()
        var read = Read()
        if let store = await NativeCloudFileOps.store() { read.gateOpen = await store.cloudDeleteRuleIsOpen() }
        for (route, owner) in owners {
            read.marks += try await owner.notHere()
            if includeBin { read.groups += try await owner.binGroups() }
            if !(await owner.canDeleteEverywhere()) { read.refusedRoutes.insert(route) }
            if let saved = owner as? BackendProjectSecretFilesSavedDeleteOwner, let line = await saved.binNotice() { read.notices.append(line) }
            if let files = owner as? BackendProjectSecretFilesStore, let line = await files.status()?.binNotice { read.notices.append(line) }
        }
        read.groups = BackendCloudDeletePage.merge(read.groups)
        // L2: a row whose press the owner could not do as asked says so on that row (by item id).
        let files: [(String, [String: String]?)] = [
            ("cloudFolder", try? await MainActor.run(body: { NativeCloudFolder.current })?.rowErrors()),
            ("artifacts", try? await MainActor.run(body: { NativeCloudArtifacts.shared.owner })?.owner.rowErrors()),
            ("boot", try? await MainActor.run(body: { NativeCloudBoot.shared.boot })?.rowErrors())]
        for (kind, lines) in files { for (id, line) in lines ?? [:] { read.rowErrors[kind + "|" + id] = line } }
        return read
    }, delete: { items, scope, actor in
        let owners = await NativeCloudDeleteOwners.all()
        var groups: [CloudBinGroup] = []
        for (route, batch) in Dictionary(grouping: items, by: BackendCloudDeletePage.route).sorted(by: { $0.key < $1.key }) {
            guard let owner = owners[route] else { throw CloudFailure.unavailable }
            groups.append(try await owner.deleteItems(batch, scope: scope, by: actor))
        }
        return BackendCloudDeletePage.merge(groups)
    }, bringBack: { items, destination in
        let owners = await NativeCloudDeleteOwners.all()
        var restored: [CloudDeleteItem] = []
        for (route, batch) in Dictionary(grouping: items, by: BackendCloudDeletePage.route) {
            guard let owner = owners[route] else { throw CloudFailure.unavailable }
            restored += try await owner.bringBack(batch, to: destination)
        }
        return restored
    }, putBackGroup: { group in
        let owners = await NativeCloudDeleteOwners.all()
        var lines: [String] = []
        for route in Set(group.items.map(BackendCloudDeletePage.route)).sorted() {
            guard let owner = owners[route] else { throw CloudFailure.unavailable }
            // Memory, tasks, agents and projects try every item and say what came back and what did not.
            if let memory = owner as? DeckMemoryStore { lines.append(try await memory.memoryPutBackGroup(group.id).line) }
            else if let tasks = owner as? BackendCloudKindsTasks { lines.append(try await tasks.putBackAll(group.id).line) }
            else if let agents = owner as? BackendCloudLeanAgents { lines.append(try await agents.putBackAll(group.id).line) }
            else if let projects = owner as? BackendCloudLeanProjects { lines.append(try await projects.putBackAll(group.id).line) }
            else { _ = try await owner.putBackGroup(group.id) }
        }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }, putBackItem: { item, group in
        switch item.kind {
        case "memory":
            _ = try await NativeCloudFileOps.required().cloudFilePutBack(item.place ?? String(item.id.dropFirst("memory:".count)))
        case "cloudFolder":
            guard let owner = await MainActor.run(body: { NativeCloudFolder.current }), try await owner.putBack(path: item.id) else { throw CloudFailure.unavailable }
        case "artifacts":
            guard let owner = await MainActor.run(body: { NativeCloudArtifacts.shared.owner }), try await owner.putBack(path: item.id) else { throw CloudFailure.unavailable }
        case "boot", "agent", "project":
            // These owners put back by removal only (L0's `putBackGroup`). A row is offered alone only when it is
            // that owner's whole part of the removal (`BackendCloudDeletePage.canPutBackAlone`), so nothing more returns.
            guard let group, BackendCloudDeletePage.canPutBackAlone(item, in: group) else { throw CloudFailure.invalidRequest }
            let owner: any CloudDeleteOwning
            if item.kind == "project" { owner = try await NativeCloudDeleteOwners.projectOwner() }
            else {
                guard let found = await NativeCloudDeleteOwners.all()[item.kind] else { throw CloudFailure.unavailable }
                owner = found
            }
            _ = try await owner.putBackGroup(group.id)
        case "saved-passwords", "mcp-servers", "project-secret-files":
            // The sealed Bin puts back by removal (L3 `putBackGroup`), offered alone only as that owner's whole part.
            guard let group, BackendCloudDeletePage.canPutBackAlone(item, in: group),
                  let owner = await NativeCloudDeleteOwners.all()[BackendCloudDeletePage.route(item)] else { throw CloudFailure.unavailable }
            _ = try await owner.putBackGroup(group.id)
        case BackendCloudChatsDeleteOwner.kind:
            guard let owner = await MainActor.run(body: { NativeCloudChats.shared.deleteOwner }),
                  try await owner.bringBack([item], to: .cloud).count == 1 else { throw CloudFailure.unavailable }
        case "task":
            // The tasks' Bin is their existing Trash; its owner's Bring back restores one task from it.
            guard let owner = await NativeCloudDeleteOwners.all()["task"] else { throw CloudFailure.unavailable }
            _ = try await owner.bringBack([item], to: .cloud)
        default:
            throw CloudFailure.unavailable
        }
    }, deleteForGood: { items in
        let owners = await NativeCloudDeleteOwners.all()
        for (route, batch) in Dictionary(grouping: items, by: BackendCloudDeletePage.route) {
            guard let owner = owners[route] else { throw CloudFailure.unavailable }
            try await owner.deleteForGood(batch)
        }
    }, makeRoot: { kind in
        if kind == .cloudFolder, let owner = await MainActor.run(body: { NativeCloudFolder.current }) { try await owner.makeFolderAgain() }
        else if kind == .artifacts, let owner = await MainActor.run(body: { NativeCloudArtifacts.shared.owner }) { try await owner.owner.makeFolderAgain() }
        else { throw CloudFailure.unavailable }
    })
}

@MainActor
enum NativeCloudDeleteOwners {
    private static var offlineProjects: BackendCloudLeanProjects?
    /// One persistent owner while signed out too. Its state root is the signed-in factory's same Mac-local root.
    static func projectOwner() throws -> BackendCloudLeanProjects {
        if let owner = NativeCloudRecords.shared.records?.projects { return owner }
        if let offlineProjects { return offlineProjects }
        guard let registry = BackendPROJRegistry.installed else { throw CloudFailure.unavailable }
        let root = registry.logoDirectory.deletingLastPathComponent().appendingPathComponent("cloud/records-projects", isDirectory: true)
        let owner = BackendCloudLeanProjects(registry: registry, display: {
            await MainActor.run { SIDEBARProjectStore.shared.refresh(); NativeCloudRecords.shared.refresh() }
        }, deleteStateRoot: root, removeEntry: { id in try await registry.cloudDeleteEntryOnly(id) },
           restoreEntry: { project in try await registry.cloudPutBackEntryOnly(project) })
        offlineProjects = owner
        return owner
    }
    /// The saved-password sources with a delete owner (L3: servers, voice; MCP once its store is bound).
    static let secretSources = ["servers", "voice", "mcp-user"]
    /// Every owner by its route (`BackendCloudDeletePage.route`): one entry per owner, so reads never count twice.
    static func all() async -> [String: any CloudDeleteOwning] {
        var owners: [String: any CloudDeleteOwning] = [:]
        if let memory = await NativeCloudFileOps.store() { owners["memory"] = memory }
        if let folder = NativeCloudFolder.current { owners["cloudFolder"] = folder }
        if let artifacts = NativeCloudArtifacts.shared.owner { owners["artifacts"] = artifacts }
        // Sessions in the Cloud: a chat's copy (into the Bin by hand, or by an AI's `cloud.delete`).
        if let chats = NativeCloudChats.shared.deleteOwner { owners[BackendCloudChatsDeleteOwner.kind] = chats }
        if let boot = NativeCloudBoot.shared.boot { owners["boot"] = boot }
        if let tasks = NativeCloudBrainRegistration.kinds?.tasks { owners["task"] = tasks }
        if let agents = NativeCloudRecords.shared.records?.agents { owners["agent"] = agents }
        if let projects = NativeCloudRecords.shared.records?.projects ?? offlineProjects { owners["project"] = projects }
        // Lane L3: the sealed Bin's owners. Project secret files are one store; saved passwords and MCP servers are
        // one owner per source (nil while saved passwords are sealed).
        if let secretFiles = BackendProjectSecretFilesHolder.shared.store { owners["project-secret-files"] = secretFiles }
        if let graph = NativeCloudSecrets.shared.graph {
            for source in secretSources {
                if let owner = await graph.deleteOwner(sourceId: source) { owners["secrets|" + source] = owner }
            }
        }
        return owners
    }
    /// J-4: "Remove from this Mac" for the registered project at `path`: its entry gets the "Not on this Mac" mark
    /// (Bring back in Your Cloud). Nothing is sent, no session is closed, no folder is touched. False = the path is
    /// no registered project (only the open list holds it).
    @discardableResult
    static func removeFromThisMac(path: String) async throws -> Bool {
        guard let registry = BackendPROJRegistry.installed else { throw CloudFailure.unavailable }
        let projects = try await registry.projects()
        let id = PROJProjects.resolve(projectID: nil, folder: path, projects: projects)
        guard id != PROJProjects.independentID else { return false }
        let owner = try projectOwner()
        try await owner.removeFromThisMac(id)
        SIDEBARProjectStore.shared.refresh()
        return true
    }
    /// The status line's small read: Bin groups only (no marks), person UI only, never a tool.
    static func binGroups() async -> [CloudBinGroup]? {
        var groups: [CloudBinGroup] = []
        for owner in await all().values {
            guard let more = try? await owner.binGroups() else { return nil }
            groups += more
        }
        return BackendCloudDeletePage.merge(groups)
    }
}
