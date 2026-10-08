import Foundation
import Darwin
import TerminalDeckNativeCore

public struct BackendCopilotMemoryFact: Equatable, Sendable {
    public let name: String
    public let path: String
    public let bytes: Double
    public let modifiedAt: Double
    public let description: String?
    public let type: String?
    public let scope: String?
    public let verified: String?
    public let index: Bool
    public var wireValue: NativeRPCValue {
        BackendCopilotInspect.object([
            ("name", .string(name)), ("path", .string(path)), ("bytes", .number(bytes)), ("modifiedAt", .number(modifiedAt)),
            ("description", BackendCopilotInspect.optional(description)), ("type", BackendCopilotInspect.optional(type)),
            ("scope", BackendCopilotInspect.optional(scope)), ("verified", BackendCopilotInspect.optional(verified)), ("index", .bool(index)),
        ])
    }
}
public struct BackendCopilotMemoryReport: Equatable, Sendable {
    public let dir: String
    public let exists: Bool
    public let facts: [BackendCopilotMemoryFact]
    public let error: String?
    public var wireValue: NativeRPCValue { BackendCopilotInspect.object([("dir", .string(dir)), ("exists", .bool(exists)), ("facts", .array(facts.map(\.wireValue))), ("error", BackendCopilotInspect.optional(error))]) }
}
public struct BackendCopilotLoggedAction: Equatable, Sendable {
    public let at: String
    public let action: String
    public let detail: String
    public let tool: String?
    public let tier: String?
    public let outcome: String?
    public let confirmationRequired: Bool?
    public let confirmed: Bool?
    public let confirmedBy: String?
    public let refusedReason: String?
    public let caller: String?
    public let ms: Double?
    public let error: String?
    public let sessionId: String?
    public var wireValue: NativeRPCValue {
        BackendCopilotInspect.object([
            ("at", .string(at)), ("action", .string(action)), ("detail", .string(detail)),
            ("tool", BackendCopilotInspect.optional(tool)), ("tier", BackendCopilotInspect.optional(tier)),
            ("outcome", BackendCopilotInspect.optional(outcome)), ("confirmationRequired", confirmationRequired.map(NativeRPCValue.bool) ?? .null),
            ("confirmed", confirmed.map(NativeRPCValue.bool) ?? .null), ("confirmedBy", BackendCopilotInspect.optional(confirmedBy)),
            ("refusedReason", BackendCopilotInspect.optional(refusedReason)), ("caller", BackendCopilotInspect.optional(caller)),
            ("ms", ms.map(NativeRPCValue.number) ?? .null), ("error", BackendCopilotInspect.optional(error)), ("sessionId", BackendCopilotInspect.optional(sessionId)),
        ])
    }
}
public struct BackendCopilotActionLogReport: Equatable, Sendable {
    public let dir: String
    public let file: String
    public let exists: Bool
    public let bytes: Double
    public let outsideCopilotFolder: Bool
    public let rows: [BackendCopilotLoggedAction]
    public let more: Bool
    public let error: String?
    public var wireValue: NativeRPCValue {
        BackendCopilotInspect.object([("dir", .string(dir)), ("file", .string(file)), ("exists", .bool(exists)), ("bytes", .number(bytes)),
            ("outsideCopilotFolder", .bool(outsideCopilotFolder)), ("rows", .array(rows.map(\.wireValue))), ("more", .bool(more)), ("error", BackendCopilotInspect.optional(error))])
    }
}
public enum BackendCopilotPlace: String, CaseIterable, Sendable {
    case root, instructions, memory, log, routines, layer, contract, composed
    public var kind: String {
        switch self {
        case .instructions, .contract, .composed: "file"
        case .root, .memory, .log, .routines, .layer: "folder"
        }
    }
    public func path(_ paths: BackendCopilotPaths, userData: String) -> String {
        switch self {
        case .root: paths.root
        case .instructions: paths.instructions
        case .memory: paths.memory
        case .log: paths.log
        case .routines: URL(fileURLWithPath: userData).appendingPathComponent("routines").path
        case .layer: paths.layer.dir
        case .contract: paths.layer.contract
        case .composed: paths.layer.composed
        }
    }
}

/// A native app supplies its actual Finder operation. No host operation is faked.
public protocol BackendCopilotInspectRevealing: Sendable {
    func reveal(path: String, kind: String) async throws -> (opened: Bool, message: String)
}
public struct BackendCopilotInspectDependencies: Sendable {
    public let userData: String
    public let paths: @Sendable () async throws -> BackendCopilotPaths
    public let reveal: (any BackendCopilotInspectRevealing)?
    public init(userData: String, paths: @escaping @Sendable () async throws -> BackendCopilotPaths,
                reveal: (any BackendCopilotInspectRevealing)? = nil) {
        self.userData = userData; self.paths = paths; self.reveal = reveal
    }
}
public enum BackendCopilotInspect {
    public static let maxMemoryReadBytes = 256 * 1024
    public static let defaultActionRows = 200
    public static let maxActionRows = 2000
    public static let channels = ["copilot:scaffold", "copilot:memory", "copilot:memory-read", "copilot:memory-write", "copilot:memory-delete", "copilot:actions", "copilot:reveal"]
    public static func object(_ fields: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(fields.map { .init($0.0, $0.1) }) }
    public static func optional(_ text: String?) -> NativeRPCValue { text.map(NativeRPCValue.string) ?? .null }
    public static func isMemoryName(_ value: NativeRPCValue) -> Bool {
        guard let name = value.string, !name.contains("/"), !name.contains("\0"), !name.contains("..") else { return false }
        return BackendSharedText.matches(name, #"^[A-Za-z0-9][A-Za-z0-9._-]*\.md$"#)
    }
    public static func parseFrontMatter(_ text: String) -> [String: String] {
        guard text.hasPrefix("---") else { return [:] }
        let lines = text.components(separatedBy: "\n")
        guard lines.first.map(BackendSharedText.trim) == "---" else { return [:] }
        var result: [String: String] = [:]
        for line in lines.dropFirst() {
            if BackendSharedText.trim(line) == "---" { break }
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { continue }
            let key = BackendSharedText.trim(String(line[..<colon]))
            var value = BackendSharedText.trim(String(line[line.index(after: colon)...]))
            if value.count >= 2, let first = value.first, let last = value.last,
               (first == "\"" || first == "'"), (last == "\"" || last == "'") {
                value.removeFirst(); value.removeLast()
            }
            if !key.isEmpty && !value.isEmpty { result[key] = value }
        }
        return result
    }
    public static func readMemory(_ paths: BackendCopilotPaths) -> BackendCopilotMemoryReport {
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: paths.memory).filter { $0.hasSuffix(".md") } }
        catch { return .init(dir: paths.memory, exists: false, facts: [], error: BackendCopilotServiceFiles.missing(error) ? nil : error.localizedDescription) }
        let indexName = URL(fileURLWithPath: paths.memoryIndex).lastPathComponent
        let facts = names.enumerated().compactMap { (offset, name) -> (Int, BackendCopilotMemoryFact)? in
            let path = URL(fileURLWithPath: paths.memory).appendingPathComponent(name).path
            guard let info = try? BackendCopilotServiceFiles.stat(path), info.regular else { return nil }
            let head = (try? BackendCopilotServiceFiles.readText(path)) ?? ""
            let front = parseFrontMatter(String(decoding: Array(head.utf16.prefix(2048)), as: UTF16.self))
            return (offset, .init(name: name, path: path, bytes: info.bytes, modifiedAt: info.modifiedAt,
                description: front["description"], type: front["type"], scope: front["scope"], verified: front["verified"], index: name == indexName))
        }.sorted { a, b in a.1.modifiedAt == b.1.modifiedAt ? a.0 < b.0 : a.1.modifiedAt > b.1.modifiedAt }.map { $0.1 }
        return .init(dir: paths.memory, exists: true, facts: facts, error: nil)
    }
    public static func readMemoryFact(_ paths: BackendCopilotPaths, name: NativeRPCValue) -> NativeRPCValue {
        guard isMemoryName(name), let name = name.string else { return object([("ok", .bool(false)), ("error", .string("That is not a memory file."))]) }
        let path = URL(fileURLWithPath: paths.memory).appendingPathComponent(name).path
        do {
            let text = try BackendCopilotServiceFiles.readText(path)
            // JS reads/slices UTF-16 code units, but writes cap UTF-8 bytes.
            let truncated = text.utf16.count > maxMemoryReadBytes
            let returned = truncated ? String(decoding: Array(text.utf16.prefix(maxMemoryReadBytes)), as: UTF16.self) : text
            return object([("ok", .bool(true)), ("name", .string(name)), ("path", .string(path)), ("text", .string(returned)), ("truncated", .bool(truncated))])
        } catch { return object([("ok", .bool(false)), ("error", .string(error.localizedDescription))]) }
    }
    public static func writeMemoryFact(_ paths: BackendCopilotPaths, name: NativeRPCValue, text: NativeRPCValue, where location: String = "Settings") -> NativeRPCValue {
        func answer(_ ok: Bool, _ error: String?) -> NativeRPCValue {
            object([("ok", .bool(ok)), ("error", optional(error)), ("memory", readMemory(paths).wireValue)])
        }
        guard isMemoryName(name), let filename = name.string else { return answer(false, "That is not a memory file.") }
        guard let text = text.string else { return answer(false, "Nothing was supplied to save.") }
        guard text.utf8.count <= maxMemoryReadBytes else { return answer(false, "A memory cannot be larger than 256 KB.") }
        let path = URL(fileURLWithPath: paths.memory).appendingPathComponent(filename).path
        do {
            guard try BackendCopilotServiceFiles.stat(path).regular else { return answer(false, "That is not a memory file.") }
        } catch { return answer(false, "That memory is no longer there — it may have been deleted while this was open.") }
        do { try BackendCopilotServiceFiles.writeText(text, path: path) }
        catch { return answer(false, error.localizedDescription) }
        BackendCopilotHome.appendAction(paths, .init(action: "memory.edited", detail: "you edited memory/\(filename) from \(location)"))
        return answer(true, nil)
    }
    public static func deleteMemoryFact(_ paths: BackendCopilotPaths, name: NativeRPCValue, where location: String = "Settings") -> NativeRPCValue {
        func answer(_ ok: Bool, _ error: String?) -> NativeRPCValue {
            object([("ok", .bool(ok)), ("error", optional(error)), ("memory", readMemory(paths).wireValue)])
        }
        guard isMemoryName(name), let filename = name.string else { return answer(false, "That is not a memory file.") }
        let path = URL(fileURLWithPath: paths.memory).appendingPathComponent(filename).path
        // unlink removes a symlink itself; it never follows a directory or recurses.
        guard Darwin.unlink(path) == 0 else { return answer(false, NSError(domain: NSPOSIXErrorDomain, code: Int(errno)).localizedDescription) }
        BackendCopilotHome.appendAction(paths, .init(action: "memory.deleted", detail: "you deleted memory/\(filename) from \(location)"))
        return answer(true, nil)
    }
    public static func parseActionRow(_ line: String) -> BackendCopilotLoggedAction? {
        guard let row = try? NativeRPCValue.parseJSON(Data(line.utf8), maximumBytes: max(1, line.utf8.count)),
              row.fields != nil else { return nil }
        func string(_ value: NativeRPCValue) -> String? { guard let text = value.string, !text.isEmpty else { return nil }; return text }
        guard let at = string(row["at"]), let action = string(row["action"]) else { return nil }
        let confirmed = row["confirmed"]
        let hasConfirmed = confirmed.fields != nil || confirmed.elements != nil
        let outcome = ["ok", "refused", "error"].contains(row["outcome"].string ?? "") ? row["outcome"].string : nil
        let caller = ["local", "remote"].contains(row["caller"]["kind"].string ?? "") ? row["caller"]["kind"].string : nil
        return .init(at: at, action: action, detail: string(row["detail"]) ?? "", tool: string(row["tool"]), tier: string(row["tier"]), outcome: outcome,
            confirmationRequired: hasConfirmed ? confirmed["required"].bool == true : nil, confirmed: hasConfirmed ? confirmed["granted"].bool == true : nil,
            confirmedBy: hasConfirmed ? string(confirmed["by"]) : nil, refusedReason: hasConfirmed ? string(confirmed["reason"]) : nil,
            caller: caller, ms: row["ms"].number, error: string(row["error"]), sessionId: string(row["sessionId"]))
    }
    public static func readActionLog(_ paths: BackendCopilotPaths, want: Double = Double(defaultActionRows)) -> BackendCopilotActionLogReport {
        readActionLogWithReceipt(paths, want: want).report
    }
    /// Only a successful readText result acknowledges log data. Neither stat
    /// nor the legacy masked UI error result proves that the bytes were read.
    public static func readActionLogWithReceipt(_ paths: BackendCopilotPaths, want: Double = Double(defaultActionRows))
        -> (report: BackendCopilotActionLogReport, successfulRead: Bool) {
        let limit = Int(min(Double(maxActionRows), max(1, want.isFinite ? floor(want) : Double(defaultActionRows))))
        let info = try? BackendCopilotServiceFiles.stat(paths.actions)
        var successfulRead = false
        func lines(_ path: String) -> [String] {
            do {
                let text = try BackendCopilotServiceFiles.readText(path)
                successfulRead = true
                return text.components(separatedBy: "\n").filter { !$0.isEmpty }
            } catch { return [] }
        }
        var collected = lines(paths.actions)
        if collected.count < limit { collected = lines(paths.actions + ".1") + collected }
        let report = BackendCopilotActionLogReport(dir: paths.log, file: paths.actions, exists: info != nil, bytes: info?.bytes ?? 0,
            outsideCopilotFolder: !paths.log.hasPrefix(paths.root + "/") && paths.log != paths.root,
            rows: collected.suffix(limit).compactMap(parseActionRow), more: collected.count > limit, error: nil)
        return (report, successfulRead)
    }
    public static func reveal(_ deps: BackendCopilotInspectDependencies, place: NativeRPCValue) async throws -> NativeRPCValue {
        let paths = try await deps.paths()
        func answer(_ opened: Bool, _ path: String?, _ message: String) -> NativeRPCValue { object([("opened", .bool(opened)), ("path", optional(path)), ("message", .string(message))]) }
        guard let name = place.string, let place = BackendCopilotPlace(rawValue: name) else { return answer(false, nil, "There is nothing by that name to open.") }
        let path = place.path(paths, userData: deps.userData)
        guard (try? BackendCopilotServiceFiles.stat(path)) != nil else { return answer(false, path, "That has not been created yet, so there is nothing to open.") }
        guard let operation = deps.reveal else { return answer(false, path, "This host has no file manager to open — it is a server.") }
        let result = try await operation.reveal(path: path, kind: place.kind)
        return answer(result.opened, path, result.message)
    }
    public static func register(registry: NativeChannelRegistry, ownerID: String, deps: BackendCopilotInspectDependencies) async throws {
        for channel in channels {
            try await registry.register(channel, ownerID: ownerID) { context, args in
                guard context.caller == .nativeApp || context.caller == .internalEngine else {
                    throw NativeRPCError(code: "access-denied", message: "Hoot's Settings controls are available on this computer only.")
                }
                let paths = try await deps.paths()
                let value: (Int) -> NativeRPCValue = { context.argument($0, in: args) }
                switch channel {
                case "copilot:scaffold":
                    let result = BackendCopilotHome.scaffold(paths)
                    if result.error == nil && !result.created.isEmpty {
                        BackendCopilotHome.appendAction(paths, .init(action: "home.created", detail: "created \(result.created.count) of Hoot's files, from Settings"))
                    }
                    return result.wireValue
                case "copilot:memory": return readMemory(paths).wireValue
                case "copilot:memory-read": return readMemoryFact(paths, name: value(0))
                case "copilot:memory-write": return writeMemoryFact(paths, name: value(0), text: value(1))
                case "copilot:memory-delete": return deleteMemoryFact(paths, name: value(0))
                case "copilot:actions": return readActionLog(paths, want: value(0).number ?? Double(defaultActionRows)).wireValue
                case "copilot:reveal": return try await reveal(deps, place: value(0))
                default: throw NativeRPCError(code: "unavailable", message: "Unknown Hoot inspection channel.")
                }
            }
        }
    }
}
