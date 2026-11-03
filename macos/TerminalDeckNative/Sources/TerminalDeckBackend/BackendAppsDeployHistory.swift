import Foundation
import TerminalDeckNativeCore

/// The ONE rule for an app's deploy history, used by both Mac deploy engines
/// (BackendAppsDeploy, BackendAppsSRV2Deployer) and mirrored by the server's
/// td-deploy, td-cleanup and td-check: newest first by `createdAt`, at most
/// `limit` rows (the active and pending rows are never trimmed), and a row
/// whose saved version the server removed is marked `imageRemoved`, so it is
/// never offered for Roll back.
enum BackendAppsDeployHistory {
    static let limit = 50

    static func rows(_ record: NativeRPCValue) -> [NativeRPCValue] { record["deployments"].elements ?? [] }

    /// Newest first and trimmed; rows without a time keep their saved order after the timed ones.
    static func ordered(_ record: NativeRPCValue) -> [NativeRPCValue] { trimmed(sorted(rows(record)), record: record) }

    static func appending(_ row: NativeRPCValue, to record: NativeRPCValue) -> NativeRPCValue {
        record.setting("deployments", .array(trimmed(sorted([row] + rows(record).filter { $0["id"] != row["id"] }), record: record)))
    }

    /// Marks every row that used one of `images` (image IDs the server just removed).
    static func markingRemoved(_ images: Set<String>, in record: NativeRPCValue) -> NativeRPCValue {
        guard !images.isEmpty else { return record }
        return record.setting("deployments", .array(rows(record).map { images.contains($0["imageId"].string ?? "") ? $0.setting("imageRemoved", .bool(true)) : $0 }))
    }

    /// A finished, successful deploy whose saved version the server still keeps.
    static func canRollBack(_ row: NativeRPCValue) -> Bool { row["status"].string == "running" && row["imageRemoved"].bool != true }

    private static func sorted(_ rows: [NativeRPCValue]) -> [NativeRPCValue] {
        rows.enumerated().sorted { a, b in
            let x = a.element["createdAt"].number ?? 0, y = b.element["createdAt"].number ?? 0
            return x != y ? x > y : a.offset < b.offset
        }.map(\.element)
    }

    private static func trimmed(_ rows: [NativeRPCValue], record: NativeRPCValue) -> [NativeRPCValue] {
        let pinned = Set([record["activeDeploymentId"].string, record["pendingDeploymentId"].string].compactMap { $0 })
        return Array(rows.prefix(limit)) + rows.dropFirst(limit).filter { pinned.contains($0["id"].string ?? "") }
    }
}
