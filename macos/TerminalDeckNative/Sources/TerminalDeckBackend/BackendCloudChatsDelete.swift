import Foundation
import TerminalDeckNativeCore

/// Sessions in the Cloud, step 1: deleting a chat under the delete rule (owner, 15 Nov: "kept until I delete it").
/// Only from the Your Cloud page's "Sessions and chats" (its existing rows and bin buttons) or an AI's `cloud.delete`;
/// no button anywhere else, and closing a session never deletes its chat.
/// - One scope, "Everywhere": the chat leaves the Cloud and every device's lists, into the Bin for 30 days (the
///   service's `POST /v1/chats/bin`); it is never uploaded again by itself. The AI's own history file on the Mac that
///   ran it is not touched (it is the AI's working file, and its session may still be open there).
/// - The Bin: this owner keeps the removals made from this Mac (name, who, when) so the Bin shows them with "Put back"
///   and "Put back all"; the service removes a binned chat 30 days after it was binned. "Remove now" (`deleteForGood`)
///   is the person's alone. No AI tool reaches the Bin (the delete rule's contract).
public actor BackendCloudChatsDeleteOwner: CloudDeleteOwning {
    /// The delete rule's kind word for a chat (`CloudDeleteItem.kind`): id = the service's session ref, place = the
    /// session id when it is this Mac's own (so this Mac stops copying it at once).
    public static let kind = "chat"
    public typealias Bin = @Sendable (_ ref: String, _ session: String?, _ action: String) async -> Bool
    let bin: Bin
    let file: URL?
    let clock: @Sendable () -> Int64
    public private(set) var groups: [CloudBinGroup]

    public init(bin: @escaping Bin, file: URL?, clock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }) {
        self.bin = bin
        self.file = file
        self.clock = clock
        if let file, let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([CloudBinGroup].self, from: data) { groups = saved }
        else { groups = [] }
    }
    func save() {
        guard let file else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(groups) { try? data.write(to: file, options: .atomic) }
    }
    /// The service sweeps a binned chat after 30 days; its Bin row goes with it.
    func sweep() {
        let now = clock()
        let kept = groups.filter { now - $0.at < CloudBinGroup.retentionMilliseconds }
        if kept.count != groups.count { groups = kept; save() }
    }
    func forget(_ items: [CloudDeleteItem]) {
        let keys = Set(items.map(BackendCloudDeletePage.key))
        groups = groups.compactMap { group in
            let left = group.items.filter { !keys.contains(BackendCloudDeletePage.key($0)) }
            return left.isEmpty ? nil : CloudBinGroup(id: group.id, by: group.by, macName: group.macName, session: group.session,
                                                      agent: group.agent, at: group.at, items: left, era: group.era)
        }
        save()
    }

    public func deleteItems(_ items: [CloudDeleteItem], scope: CloudDeleteScope, by actor: CloudDeleteActor) async throws -> CloudBinGroup {
        let chats = items.filter { $0.kind == Self.kind }
        guard !chats.isEmpty, chats.count == items.count else { throw CloudFailure.invalidRequest }
        var binned: [CloudDeleteItem] = []
        for item in chats where await bin(item.id, item.place, "bin") { binned.append(item) }
        guard !binned.isEmpty else { throw CloudFailure.unavailable }
        let group = CloudBinGroup(id: actor.group, by: actor.by, macName: actor.macName, session: actor.session, agent: actor.agent,
                                  at: actor.at, items: (groups.first { $0.id == actor.group }?.items ?? []) + binned)
        groups.removeAll { $0.id == actor.group }
        groups.append(group)
        save()
        return group
    }
    public func bringBack(_ items: [CloudDeleteItem], to: CloudBringBackDestination) async throws -> [CloudDeleteItem] {
        var restored: [CloudDeleteItem] = []
        for item in items where item.kind == Self.kind {
            if await bin(item.id, item.place, "restore") { restored.append(item) }
        }
        forget(restored)
        return restored
    }
    /// Nothing is ever "Not on this Mac": a chat is in the Cloud or in the Bin.
    public func notHere() async throws -> [CloudNotHereItem] { [] }
    public func binGroups() async throws -> [CloudBinGroup] { sweep(); return groups }
    public func putBackGroup(_ group: String) async throws -> [CloudDeleteItem] {
        guard let found = groups.first(where: { $0.id == group }) else { return [] }
        return try await bringBack(found.items, to: .cloud)
    }
    public func deleteForGood(_ items: [CloudDeleteItem]) async throws {
        var removed: [CloudDeleteItem] = []
        for item in items where item.kind == Self.kind {
            if await bin(item.id, item.place, "remove") { removed.append(item) }
        }
        forget(removed)
        if removed.count != items.count { throw CloudFailure.unavailable }
    }
}

/// The Your Cloud page's "Sessions and chats": every session's and earlier chat's copy in the Cloud, as the page's
/// existing rows (name; its project; which machine; its date) with the bin buttons every kind has.
public enum BackendCloudChatsContents {
    public static func items(_ rows: [BackendCloudSessionsRead.Row]) -> [BackendCloudContents.Item] {
        rows.map { row in
            let name = BackendCloudContentsWords.plain(row.name) ?? "Session"
            let machine = BackendCloudContentsWords.plain(row.machineName) ?? "another Mac"
            let place = [row.project?.name.isEmpty == false ? row.project?.name : nil, row.closedAt != nil ? "Earlier chat" : nil].compactMap { $0 }
            var item = BackendCloudContents.Item(id: "sessions|" + row.ref, kind: .sessions, name: name,
                                                 place: place.isEmpty ? nil : place.joined(separator: " · "), changedBy: machine,
                                                 changedAt: Int64(row.lastUsedAt ?? row.closedAt ?? 0), presence: ["On " + machine],
                                                 onDevices: [machine], history: [], bytes: nil, entries: nil, note: nil, isText: false)
            item.canRemove = true
            // Cloud file manager: Sessions and chats › project › its sessions, and "Earlier chats" inside the project.
            let project = row.project.flatMap { BackendCloudContentsWords.plain($0.name) } ?? BackendCloudManagerTree.noProject
            item.folder = [project] + (row.closedAt != nil ? [BackendCloudManagerTree.earlierChats] : [])
            item.deleteItems = [CloudDeleteItem(id: row.ref, kind: BackendCloudChatsDeleteOwner.kind, name: name,
                                                place: row.mine == true ? row.sessionId : nil)]
            return item
        }
    }
    /// The page's model with the chats added (and their count, so the kind is listed while the Cloud holds any).
    public static func adding(_ rows: [BackendCloudSessionsRead.Row], to model: BackendCloudContents) -> BackendCloudContents {
        var made = model
        let items = items(rows)
        made.items.removeAll { $0.kind == .sessions }
        made.items += items
        made.items.sort { $0.changedAt != $1.changedAt ? $0.changedAt > $1.changedAt : $0.name < $1.name }
        made.counts[.sessions] = items.count
        return made
    }
}
