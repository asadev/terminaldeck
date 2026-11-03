import Foundation
import CryptoKit
import Darwin
import TerminalDeckNativeCore

/// Profile changes reuse the canonical TAG validation. Only a real owner
/// answer may apply fields that TAG identifies as widening.
public enum BackendAGOPTProfileChanges {
    public static let protectedFields: Set<String> = ["creatorKeyId", "keyInitializedFields", "sourceFile", "sourceDirectory", "syncStatus", "syncedAt", "syncError", "ags", "agsRevision", "status", "statusAt"]
    public static let editableFields: Set<String> = ["id", "name", "role", "provider", "account", "model", "effort", "instructions", "toolsPreferred", "toolsAvoided", "skills", "blockedTools", "skillsOff", "maxConcurrent", "maxRunMinutes", "keepAliveMinutes", "verifyCommand", "claudeAgent", "allowedTools", "permissionMode", "keepAliveUntilClose", "defaultProject", "reviewerAgent", "icon", "reportsTo", "seat", "projectId", "projectIdInferred", "extraTaskInstructions", "toolUseRestrictions"]
    public static func fingerprint(_ value: NativeRPCValue) throws -> String {
        let object = try JSONSerialization.jsonObject(with: value.encodedJSON())
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func split(patch: NativeRPCValue, existing: NativeRPCValue?, callerKeyID: String, inheritedPermissionMode: String, ownerReviewOrdinaryFields: Bool = false) throws -> (narrow: NativeRPCValue, wide: NativeRPCValue) {
        guard let fields = patch.fields else { throw NativeRPCError.invalidArguments("The agent change must be an object.") }
        var narrow = NativeRPCValue.object([]), wide = NativeRPCValue.object([])
        for field in fields {
            if protectedFields.contains(field.key) || field.key == "instructionsFile" {
                guard field.value == existing?[field.key] || field.value.isNullish && (existing?[field.key].isNullish ?? true) else { throw NativeRPCError(code: "not-permitted", message: "Profile ownership, imported source and private settings cannot be changed by this request.") }
                continue
            }
            guard editableFields.contains(field.key) else { throw NativeRPCError.invalidArguments("That field is not part of the existing task agent profile.") }
            if ownerReviewOrdinaryFields, field.key != "id", !BackendTAGProfilePolicy.initialFields.contains(field.key), field.value != existing?[field.key] {
                wide = wide.setting(field.key, field.value); continue
            }
            let one = NativeRPCValue.object([field])
            do {
                _ = try BackendTAGProfilePolicy.validate(input: one, existing: existing, inheritedPermissionMode: inheritedPermissionMode, callerKeyID: callerKeyID)
                narrow = narrow.setting(field.key, field.value)
            } catch let error as NativeRPCError where error.code == "owner-required" {
                guard BackendTAGProfilePolicy.initialFields.contains(field.key) || BackendTAGProfilePolicy.ownerFields.contains(field.key) else { throw error }
                wide = wide.setting(field.key, field.value)
            }
        }
        return (narrow, wide)
    }
    public static func summary(names: [String], wide: NativeRPCValue) -> String {
        let people = names.count == 1 ? names[0] : "\(names.count) agents"
        let list = names.count == 1 ? "" : ": " + names.joined(separator: ", ")
        if wide["keepAliveUntilClose"].bool == true, wide.fields?.count == 1 {
            return "keep \(people) open until you close \(names.count == 1 ? "it" : "them")" + list
        }
        let labels = (wide.fields ?? []).map { field in
            switch field.key {
            case "keepAliveUntilClose": return "keep open until closed"
            case "keepAliveMinutes": return "keep-open minutes"
            case "permissionMode": return "permission mode"
            case "allowedTools": return "allowed tools"
            case "blockedTools": return "blocked tools"
            case "skillsOff": return "skills"
            case "maxConcurrent": return "tasks at once"
            case "maxRunMinutes": return "longest run"
            // #24: the owner sees the very command that would run on this Mac.
            case "verifyCommand": return field.value.string.map { "check command (runs “\(BackendAGTLeadSeats.flat($0, 200))” on this Mac)" } ?? "check command"
            case "instructions": return "instructions"
            case "model": return "model"
            case "effort": return "thinking level"
            case "name": return "name"
            case "provider": return "coding agent"
            case "account": return "account"
            default: return field.key
            }
        }.joined(separator: ", ")
        return "change \(labels) for \(people)" + list
    }
}

/// The historical action log supplies attribution, never executable settings.
/// Missing, malformed or conflicting evidence grants no creator privilege.
public enum BackendAGOPTProfileCreators {
    public static func rows(at file: URL) throws -> [NativeRPCValue] {
        let fd = Darwin.open(file.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0, errno == ENOENT { return [] }
        guard fd >= 0 else { throw NativeRPCError(code: "creator-history-unavailable", message: "The profile creation history could not be read.") }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 16 * 1024 * 1024 else { throw NativeRPCError(code: "creator-history-unavailable", message: "The profile creation history must be a regular file within its read limit.") }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count == 0 { break }
            if count < 0, errno == EINTR { continue }
            guard count > 0, data.count + count <= 16 * 1024 * 1024 else { throw NativeRPCError(code: "creator-history-unavailable", message: "The profile creation history could not be read within its limit.") }
            data.append(contentsOf: bytes.prefix(count))
        }
        return data.split(separator: 10).compactMap { try? NativeRPCValue.parseJSON(Data($0), maximumBytes: 128 * 1024) }
    }
    public static func backfill(_ profile: NativeRPCValue, rows: [NativeRPCValue]) -> NativeRPCValue {
        guard profile["creatorKeyId"].isNullish, let id = profile["id"].string else { return profile }
        var creators = Set<String>(), fields = Set<String>()
        for row in rows {
            guard row["action"].string == "tasks.save" || row["tool"].string == "tasks.save" else { continue }
            guard row["outcome"].string == "ok" || row["ok"].bool == true else { continue }
            let operations = [row["operation"].string, row["kind"].string, row["args"]["do"].string].compactMap { $0 }
            guard !operations.contains(where: { ["edit", "edited", "update", "updated"].contains($0) }),
                  row["created"].bool != false, row["isCreation"].bool != false else { continue }
            let keys = [row["keyId"].string, row["caller"]["keyId"].string].compactMap { $0 }
            guard let key = keys.first, !key.isEmpty, keys.allSatisfy({ $0 == key }) else { continue }
            let agent = row["args"]["agent"].fields == nil ? row["args"] : row["args"]["agent"]
            let ids = [agent["id"].string, row["agentId"].string, row["result"]["saved"]["id"].string].compactMap { $0 }
            guard !ids.isEmpty, ids.allSatisfy({ $0 == id }) else { continue }
            creators.insert(key)
            fields.formUnion(BackendTAGProfilePolicy.initialFields.filter { agent.has($0) && !agent[$0].isNullish })
        }
        guard creators.count == 1, let creator = creators.first else { return profile }
        fields.formUnion((profile["keyInitializedFields"].elements ?? []).compactMap(\.string))
        return profile.setting("creatorKeyId", .string(creator)).setting("keyInitializedFields", .array(fields.sorted().map(NativeRPCValue.string)))
    }
}
