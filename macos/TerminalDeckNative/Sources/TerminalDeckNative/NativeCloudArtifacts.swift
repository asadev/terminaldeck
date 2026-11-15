import Foundation
import Observation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Lane L3 slice 2: his artifacts on all his Macs, on this Mac. Holds the running owner (`BackendCloudArtifacts`, built
/// by `NativeCloudBrainRegistration` once Cloud is used here), feeds it from the Artifacts page's own list, and gives
/// the page what is in the store (made here or on another device). Nothing here asks him anything on the normal path.
///
/// Feeding: whenever the Artifacts page has read its list, and by itself at most once an hour (and two minutes after the
/// app says artifacts changed), from the same reading the page does. The feed only READS his project folders.
@MainActor @Observable
final class NativeCloudArtifacts {
    static let shared = NativeCloudArtifacts()
    /// The running owner; nil while signed out, Cloud not used here, or still starting.
    private(set) var owner: BackendCloudArtifacts?
    /// Everything in the store (made here or on another device), newest change first.
    private(set) var items: [CloudArtifactItem] = []
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var changed: EngineSubscription?
    @ObservationIgnored private var soon: Task<Void, Never>?
    @ObservationIgnored private var feeding = false

    func attach(_ made: BackendCloudArtifacts?) {
        owner = made
        loop?.cancel(); loop = nil
        changed?.cancel(); changed = nil
        soon?.cancel(); soon = nil
        guard let made else { items = []; return }
        Task {
            await made.owner.setDeleteRuleGate(NativeCloudFolder.deleteRuleIsOpen)
            await made.owner.setDeleteRuleAnnounced(NativeCloudFolder.deleteRuleAnnounced)
            await reload()
        }
        guard !NativeCloudApplication.isTestProcess else { return }
        // Two minutes after the app says artifacts changed (a busy session says it often: one reading per two minutes).
        changed = EngineBridge.shared.on("artifacts:changed") { [weak self] _ in
            Task { @MainActor in
                guard let self, self.soon == nil else { return }
                self.soon = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(120))
                    guard !Task.isCancelled, let self else { return }
                    self.soon = nil
                    await self.feedFromProjects()
                }
            }
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.feedFromProjects()
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    /// The same, from outside the main actor (the tools, the Cloud page's actions).
    static func reloadShared() async { await shared.reload() }
    /// The store's items again (after a feed, an arrival, a removal).
    func reload() async {
        guard let owner else { if !items.isEmpty { items = [] }; return }
        let read = (try? await owner.items()) ?? []
        if read != items { items = read }
    }

    /// The page read its list: what is new or changed is copied into the store (his project files are only read).
    func offer(_ rows: [NativeArtifactsCatalogModel.Row], sessionNames: [String: String]) {
        guard let owner else { return }
        let entries = Self.entries(rows, sessionNames: sessionNames)
        Task {
            _ = try? await owner.feed(entries)
            await reload()
        }
    }

    /// The page's list for every project folder, read the way the page reads it, then fed.
    func feedFromProjects() async {
        guard let owner, !feeding, EngineBridge.shared.isReady else { return }
        feeding = true
        defer { feeding = false }
        NativePROJLabels.shared.start()
        let roots = ArtifactRules.scanRoots(open: [], registered: NativePROJLabels.shared.projects.flatMap(\.folders))
        var rows: [NativeArtifactsCatalogModel.Row] = []
        for root in roots {
            if let found = try? await NativeArtifactsCatalogModel.read(root, invoke: { channel, args in try await EngineBridge.shared.invoke(channel, args) }) {
                rows += found.rows
            }
        }
        var names: [String: String] = [:]
        if let value = try? await EngineBridge.shared.invoke("session:list", []) { names = ArtifactsWire.sessionNames(value) }
        _ = try? await owner.feed(Self.entries(NativeArtifactsCatalogModel.oneRowPerFile(rows), sessionNames: names))
        await reload()
    }

    /// The page's rows as the store's entries: inside a registered project's folder only (never an outside file, never
    /// a folder that belongs to no project).
    static func entries(_ rows: [NativeArtifactsCatalogModel.Row], sessionNames: [String: String]) -> [CloudArtifactEntry] {
        let known = Set(NativePROJLabels.shared.projects.map(\.id)).subtracting([PROJProjects.independentID])
        return rows.compactMap { row in
            guard row.cloudPath == nil, !row.artifact.isOutside, known.contains(row.projectID) else { return nil }
            return CloudArtifactEntry(projectId: row.projectID, projectName: NativePROJLabels.shared.name(for: row.projectID), root: row.root,
                                      relPath: row.artifact.relPath, name: row.artifact.name,
                                      madeBy: NativeArtifactsCatalogModel.madeBy(row, sessionNames: sessionNames),
                                      createdAt: Int64(row.artifact.firstAt > 0 ? row.artifact.firstAt : row.artifact.lastAt))
        }
    }

    /// A Mac's name by device id; nil for this Mac (the page says nothing then) and "Another of your devices" when unknown.
    func macName(_ device: String?) -> String? {
        guard let device, !device.isEmpty else { return nil }
        let account = NativeCloudAccount.shared.snapshot
        if device.lowercased() == owner?.deviceId { return nil }
        return account.devices.first { $0.deviceId.lowercased() == device.lowercased() }.flatMap { BackendCloudContentsWords.plain($0.shownName) }
            ?? "Another of your devices"
    }

    /// His Remove on the page: out of the store here; the owner's looks send it (to the Bin on every Mac, 30 days).
    func remove(path: String) async -> Bool {
        guard let owner else { return false }
        let done = (try? await owner.remove(path: path)) ?? false
        await reload()
        return done
    }

    /// The tools' view of the running owner.
    nonisolated static func toolActions() -> BackendCloudArtifactsTools.Actions {
        BackendCloudArtifactsTools.Actions(
            list: {
                guard let owner = await MainActor.run(body: { shared.owner }) else { return nil }
                let items = (try? await owner.items()) ?? []
                let bin: [CloudFolderKept] = []
                let macs = await MainActor.run {
                    Dictionary(NativeCloudAccount.shared.snapshot.devices.map { ($0.deviceId.lowercased(), BackendCloudContentsWords.plain($0.shownName) ?? "Another of your devices") },
                               uniquingKeysWith: { first, _ in first })
                }
                let waiting = (try? await owner.pageLines()) ?? []
                return .init(items: items, bin: bin, macs: macs, waiting: waiting)
            },
            remove: { id in
                guard let owner = await MainActor.run(body: { shared.owner }) else { throw BackendCloudArtifactsTools.signedOut }
                let done = try await owner.remove(path: id, fromAI: true)
                await reloadShared()
                return done
            },
            putBack: { _ in
                guard await MainActor.run(body: { shared.owner != nil }) else { throw BackendCloudArtifactsTools.signedOut }
                throw NativeRPCError.invalidArguments("The Bin is opened by hand in Your Cloud.")
            })
    }
}
