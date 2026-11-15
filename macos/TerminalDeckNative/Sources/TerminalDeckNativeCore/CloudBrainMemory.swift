import Foundation

/// Logical memory resource. Integers use decimal strings so row identities survive JSON exactly.
/// Each resource is split into bounded operations, including a single very large diary message.
public struct CloudBrainMemoryPart: Codable, Equatable, Sendable {
    public let format: String
    public let storeId: String
    public let inventoryRow: String
    public let key: String
    public let version: String
    public let resourceHash: String
    public let bytes: String
    public let index: Int
    public let count: Int
    public let parents: [String]
    public let data: String
    /// M4b: the version's stamp, milliseconds on the sync owner's server-corrected clock, written ONCE when this version
    /// was first made (never earlier than its parent's stamp + 1) and replayed unchanged. Decimal string; absent in older parts.
    public let stamp: String?
    /// Rule J (lane A2 C1): true only when the Mac that made this version already held a Cloud version of the record
    /// (or could not know). A baseline loses to any unrelated non-baseline version. Absent means false.
    public let baseline: Bool?
    public init(storeId: String, inventoryRow: String, key: String, version: String, resourceHash: String, bytes: String,
                index: Int, count: Int, parents: [String] = [], data: String, stamp: String? = nil, baseline: Bool? = nil) {
        format = "td-memory-part-1"; self.storeId = storeId; self.inventoryRow = inventoryRow
        self.key = key; self.version = version; self.resourceHash = resourceHash; self.bytes = bytes
        self.index = index; self.count = count; self.parents = parents; self.data = data
        self.stamp = stamp; self.baseline = baseline
    }
}

public struct CloudBrainMemoryCell: Codable, Equatable, Sendable {
    public let type: String
    public let value: String?
    public init(type: String, value: String?) { self.type = type; self.value = value }
}

public struct CloudBrainMemoryReference: Codable, Equatable, Sendable {
    public let storeId: String
    public let table: String
    public let id: CloudBrainMemoryCell
    public init(storeId: String, table: String, id: CloudBrainMemoryCell) { self.storeId = storeId; self.table = table; self.id = id }
}

public struct CloudBrainMemoryRow: Codable, Equatable, Sendable {
    public let table: String
    public let columns: [String]
    public let cells: [CloudBrainMemoryCell]
    public let references: [String: CloudBrainMemoryReference]
    private enum CodingKeys: String, CodingKey { case table, columns, cells, references }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        table = try c.decode(String.self, forKey: .table); columns = try c.decode([String].self, forKey: .columns)
        cells = try c.decode([CloudBrainMemoryCell].self, forKey: .cells)
        references = try c.decodeIfPresent([String:CloudBrainMemoryReference].self, forKey: .references) ?? [:]
    }
    public init(table: String, columns: [String], cells: [CloudBrainMemoryCell], references: [String: CloudBrainMemoryReference] = [:]) {
        self.table = table; self.columns = columns; self.cells = cells; self.references = references
    }
}

public enum CloudBrainMemoryFormat {
    public static let partBytes = 32 * 1024
    public static let inventoryRows = ["I01", "I02", "I03", "I04", "I05", "I06"]
    /// MAC-NEXT-8 (Decker, 13 Nov): the board (I03: who is working, idle or quiet on THIS Mac now, and its history of
    /// those flips) is machine-local state. It changes every few seconds, is stale on another device at once and alone used
    /// up the service's requests; it does not travel in this version. Arrivals from older builds are ignored.
    public static let localOnlyRows: Set<String> = ["I03"]
    public static var localOnlyDomains: Set<String> { Set(localOnlyRows.map(domain)) }
    /// Lower-case per the service's domain rule (`brain/memory/i01` …); validated by CloudWire.domain.
    public static func domain(_ row: String) -> String {
        let name = "brain/memory/" + row.lowercased()
        precondition(CloudWire.isValidDomain(name), "invalid Cloud domain")
        return name
    }
}
