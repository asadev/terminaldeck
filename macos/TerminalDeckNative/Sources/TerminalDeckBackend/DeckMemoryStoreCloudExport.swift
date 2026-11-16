import Foundation
import TerminalDeckNativeCore

extension DeckMemoryStore {
    /// Record ids when app data was copied between Macs (sync review round 5, item 3). Rule (a):
    /// - A version id comes from the content and its parents only, so two Macs holding a copied store mint the SAME
    ///   version for the same change. The OPERATION id of a newly built part therefore also names what makes its bytes
    ///   differ, the exporting device: `uuid(version \n index \n originDevice)`. Its `parents` are the real operation ids
    ///   of the parent versions' parts, looked up from the stored parts, so links point at operations that exist.
    /// - `originDevice` is always this Mac on a newly built operation; another device's id is never stamped on one.
    /// - A part this Mac already stores for that version (made here or received) is replayed byte for byte, as before,
    ///   so nothing is re-published that is not re-published today, and records exported before a copy keep their bytes.
    /// - The same version arriving from both Macs is the same content: the receiver records it as already present.
    /// Older parts with `uuid(version \n index)` ids and derived parents stay valid (`cloudValidatePart` accepts both).
    func cloudCanonicalExportOperation(_ proposed: CloudOperation, row: String) throws -> CloudOperation {
        let p = try cloudValidatePart(proposed, row: row)
        if let existing = try db.first("SELECT operation,body,parents,total,bytes FROM cloud_memory_parts WHERE store_id=? AND resource_key=? AND revision=? AND part=? ORDER BY rowid LIMIT 1",
                                       [.text(p.storeId),.text(p.key),.text(p.version),.int(Int64(p.index))]) {
            guard let original = existing.data(0), existing.data(1) == Data(base64Encoded: p.data), existing.data(2) == (try CloudWire.canonical(p.parents)),
                  existing.int(3) == p.count, existing.int(4) == Int64(p.bytes) else { throw CloudFailure.idReused }
            let operation = try JSONDecoder().decode(CloudOperation.self, from: original)
            // 13 Nov blocker: a part saved by a build that made version-5 operation ids could never be sent (none ever
            // left the Mac). It is made again below with the id the sync core sends (checked before the part check,
            // which no longer knows that id form).
            if BackendCloudBrainMemoryHash.isOperationId(operation.opId), operation.parents.allSatisfy(BackendCloudBrainMemoryHash.isOperationId) {
                _ = try cloudValidatePart(operation, row: row)
                return operation
            }
            try db.run("DELETE FROM cloud_memory_parts WHERE op_id=?", [.text(operation.opId)])
        }
        // M4b: the stamp is written once, here, when this version is first published, and replayed after.
        let stamped = try cloudStampForExport(p, createdAt: proposed.createdAt)
        let payload = CloudBrainMemoryPart(storeId: p.storeId, inventoryRow: p.inventoryRow, key: p.key, version: p.version, resourceHash: p.resourceHash,
                                           bytes: p.bytes, index: p.index, count: p.count, parents: p.parents, data: p.data,
                                           stamp: String(stamped.stamp), baseline: stamped.baseline)
        let value = try JSONDecoder().decode(CloudValue.self, from: CloudWire.canonical(payload))
        let opId = Self.cloudOperationId(version: p.version, index: p.index, device: proposed.originDevice)
        var parentOps: [String] = []
        for parent in p.parents {
            // The real operation of the parent version's matching part (or its first part when it had fewer parts).
            if let id = try db.first("SELECT op_id FROM cloud_memory_parts WHERE resource_key=? AND revision=? AND part IN (?,0) ORDER BY part DESC, rowid LIMIT 1",
                                     [.text(p.key),.text(parent),.int(Int64(p.index))])?.string(0), !parentOps.contains(id),
               BackendCloudBrainMemoryHash.isOperationId(id) { parentOps.append(id) }
        }
        let operation = CloudOperation(v: proposed.v, opId: opId, originDevice: proposed.originDevice, domain: proposed.domain, entityId: proposed.entityId,
                                       revision: opId, parents: parentOps, kind: proposed.kind, projectId: proposed.projectId, rootId: proposed.rootId,
                                       source: proposed.source, createdAt: proposed.createdAt, payload: value,
                                       payloadHash: BackendCloudBrainMemoryHash.bytes(try CloudWire.canonical(value)))
        _ = try cloudValidatePart(operation, row: row)
        let bytes = try CloudWire.canonical(operation)
        try db.run("INSERT INTO cloud_memory_parts(op_id,op_hash,operation,entity_id,parents,store_id,inventory,resource_key,revision,content_hash,part,total,bytes,body) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                   [.text(operation.opId),.text(DeckMemoryFiles.hash(bytes)),.blob(bytes),.text(operation.entityId),.blob(try CloudWire.canonical(p.parents)),.text(p.storeId),.text(row),.text(p.key),.text(p.version),.text(p.resourceHash),.int(Int64(p.index)),.int(Int64(p.count)),.int(Int64(p.bytes)!),.blob(Data(base64Encoded: p.data)!)])
        // D1: this Mac's own removal of a shared setting becomes the record's current version, so a concurrent edit that
        // arrives later is decided against the removal instead of being re-inserted.
        if p.index == 0, p.count == 1, let body = Data(base64Encoded: p.data), let decoded = try? DeckMemoryCloudSchema.decodeRow(body),
           DeckMemoryCloudSchema.isSettingTombstone(decoded.0, decoded.1) {
            try cloudRecordRemovalVersion(p, table: decoded.0, values: decoded.1)
        }
        return operation
    }
    /// New operation ids name the exporting device (rule (a) above).
    static func cloudOperationId(version: String, index: Int, device: String) -> String {
        BackendCloudBrainMemoryHash.operationId(version + "\n" + String(index) + "\n" + device)
    }
}
