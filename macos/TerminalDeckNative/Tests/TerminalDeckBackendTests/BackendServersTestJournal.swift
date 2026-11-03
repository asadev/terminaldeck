import Foundation
@testable import TerminalDeckBackend

/// An in-memory way-back journal for tests; the app keeps its journal on disk.
actor BackendServersMemoryJournal: BackendServersWayBackJournal {
    private struct Key: Hashable { var serverId: String; var cardId: String }
    private var rows: [Key: BackendServersWayBack] = [:]
    init() {}
    func put(serverId: String, cardId: String, record: BackendServersWayBack) { rows[.init(serverId: serverId, cardId: cardId)] = record }
    func get(serverId: String, cardId: String) -> BackendServersWayBack? { rows[.init(serverId: serverId, cardId: cardId)] }
    func clear(serverId: String, cardId: String) { rows[.init(serverId: serverId, cardId: cardId)] = nil }
}
