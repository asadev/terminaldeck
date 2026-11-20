import Foundation

/// File-shaped brain rows (I08 memory flow and Hoot knowledge, I09 provider instructions, I20 app chats).
/// Contents travel as `td-memory-part-1` parts (CloudBrainMemoryPart); a local removal travels as an archive marker,
/// never as a cloud deletion.
public enum CloudBrainFilesFormat {
    public static let inventoryRows = ["I08", "I09", "I20"]
    /// Lane L3 (14 Nov): rows that use the same file engine under a domain of their own (CLOUD-CONTRACTS-1114 section 5):
    /// I23 artifacts, I24 the Cloud folder. Not in `inventoryRows`: those are the `brain/files/*` rows.
    public static let ownDomainRows: [String: String] = ["I23": "artifacts", "I24": "cloud-folder", "I26": "project-folders"]
    /// Every row the file engine may run.
    public static var engineRows: [String] { inventoryRows + ownDomainRows.keys.sorted() }
    public static let partBytes = CloudBrainMemoryFormat.partBytes
    /// Lower-case per the service's domain rule (`brain/files/i08` …).
    public static func domain(_ row: String) -> String {
        let name = ownDomainRows[row] ?? "brain/files/" + row.lowercased()
        precondition(CloudWire.isValidDomain(name), "invalid Cloud domain")
        return name
    }
}

/// A local file stopped existing. The bytes of every earlier version stay in Cloud and on every device that has them.
public struct CloudBrainFilesArchiveMarker: Codable, Equatable, Sendable {
    public let format: String
    public let storeId: String
    public let inventoryRow: String
    public let key: String
    public let version: String
    public let resourceHash: String
    public let parents: [String]
    public init(storeId: String, inventoryRow: String, key: String, version: String, resourceHash: String, parents: [String]) {
        format = "td-file-archive-1"; self.storeId = storeId; self.inventoryRow = inventoryRow
        self.key = key; self.version = version; self.resourceHash = resourceHash; self.parents = parents
    }
}
