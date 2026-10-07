import Foundation
import Darwin
import TerminalDeckNativeCore

public enum BackendUsageCodex {
    public struct Candidate: Sendable {
        public let path: String; public let modifiedAt: Double; public let conversationID: String?
        public init(path: String, modifiedAt: Double, conversationID: String? = nil) { self.path = path; self.modifiedAt = modifiedAt; self.conversationID = conversationID }
    }
    public static func projectCandidates(home: String, cwd: String, conversationID: String?) throws -> [Candidate] {
        let base = URL(fileURLWithPath: home).resolvingSymlinksInPath(); var candidates: [Candidate] = [], count = 0, bytes = 0
        for subdir in ["sessions", "archived_sessions"] {
            let directory = base.appendingPathComponent(subdir)
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { throw NativeRPCError.malformed("The Codex conversation directory could not be enumerated.") }
            for case let url as URL in enumerator {
                count += 1; guard count <= 100_000 else { throw NativeRPCError.malformed("The Codex context scan exceeded its directory budget.") }
                let info = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .contentModificationDateKey])
                if info.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                if enumerator.level > 4 { enumerator.skipDescendants(); continue }
                guard info.isRegularFile == true, url.pathExtension == "jsonl", NativeTranscriptPaths.isDescendant(url.resolvingSymlinksInPath().path, of: base.path) else { continue }
                let fd = try BackendUsageIO.openChecked(url.path, roots: [home]).0; defer { Darwin.close(fd) }
                var head = [UInt8](repeating: 0, count: 32_768), length = Darwin.read(fd, &head, head.count)
                guard length >= 0 else { throw NativeRPCError.malformed("The Codex conversation metadata could not be read.") }
                bytes += length; guard bytes <= 16 * 1024 * 1024 else { throw NativeRPCError.malformed("The Codex metadata scan exceeded its byte budget.") }
                if let cut = head.prefix(length).firstIndex(of: 10) { length = cut }
                guard let raw = try? NativeRPCValue.parseJSON(Data(head.prefix(length))), raw["type"].string == "session_meta", let recorded = raw["payload"]["cwd"].string,
                      NativeTranscriptPaths.canonical(recorded) == NativeTranscriptPaths.canonical(cwd), conversationID == nil || raw["payload"]["id"].string == conversationID else { continue }
                candidates.append(Candidate(path: url.path, modifiedAt: (info.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000, conversationID: raw["payload"]["id"].string))
            }
        }
        return Array(candidates.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(8))
    }
    public static func candidates(home: String) throws -> [Candidate] {
        let root = URL(fileURLWithPath: home).resolvingSymlinksInPath(), manager = FileManager.default
        var found: [Candidate] = [], days = 0, entriesSeen = 0
        func entries(_ directory: URL) throws -> [URL] {
            guard manager.fileExists(atPath: directory.path) else { return [] }
            let values = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .contentModificationDateKey], options: [])
            entriesSeen += values.count
            guard entriesSeen <= 100_000 else { throw NativeRPCError.malformed("The Codex rollout directory exceeded its scan budget.") }
            return values.filter { (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true && NativeTranscriptPaths.isDescendant($0.resolvingSymlinksInPath().path, of: root.path) }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        }
        func appendFiles(_ directory: URL) throws {
            for file in try entries(directory) where file.pathExtension == "jsonl" {
                let info = try file.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
                if info.isRegularFile == true { found.append(Candidate(path: file.path, modifiedAt: (info.contentModificationDate?.timeIntervalSince1970 ?? 0) * 1000)) }
            }
        }
        for year in try entries(root.appendingPathComponent("sessions")) {
            if days >= 5 { break }; guard year.lastPathComponent.range(of: "^\\d{4}$", options: .regularExpression) != nil else { continue }
            for month in try entries(year) {
                if days >= 5 { break }; guard month.lastPathComponent.range(of: "^\\d{2}$", options: .regularExpression) != nil else { continue }
                for day in try entries(month) {
                    if days >= 5 { break }; guard day.lastPathComponent.range(of: "^\\d{2}$", options: .regularExpression) != nil else { continue }
                    days += 1; try appendFiles(day)
                }
            }
        }
        try appendFiles(root.appendingPathComponent("archived_sessions"))
        return Array(found.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(8))
    }
    public static func read(account: BackendUsageAccount, cancellation: BackendMCPCancellation? = nil) async throws -> [BackendUsageReading] {
        guard let home = account.configDirectory else { return [] }
        var best: (raw: NativeRPCValue, at: Double)?
        var examined = 0
        for file in try candidates(home: home) {
            try Task.checkCancellation(); if cancellation?.isCancelled == true { throw CancellationError() }
            examined += 1
            for limit in [256 * 1024, 4 * 1024 * 1024] {
                let (tail, fallback) = try BackendUsageIO.tail(path: file.path, roots: [home], bytes: limit)
                var found = false
                for line in tail.components(separatedBy: "\n").reversed() where line.contains("\"rate_limits\"") {
                    guard let raw = try? NativeRPCValue.parseJSON(Data(line.utf8)), raw["payload"]["rate_limits"].fields != nil else { continue }
                    let windows = raw["payload"]["rate_limits"]
                    guard ["primary", "secondary"].contains(where: { windows[$0]["used_percent"].number != nil }) else { continue }
                    let stamped = BackendUsageIO.timestamp(raw["timestamp"]), at = stamped > 0 ? stamped : fallback
                    if best == nil || best!.at < at { best = (windows, at) }; found = true; break
                }
                if found { break }
            }
            if best != nil && examined >= 3 { break }; await Task.yield()
        }
        guard let best else { return [] }
        var result: [BackendUsageReading] = [], seen = Set<Double>(), now = BackendUsageIO.now()
        for key in ["primary", "secondary"] {
            let window = best.raw[key]
            guard let percent = window["used_percent"].number else { continue }
            let minutes = window["window_minutes"].number.flatMap { $0 > 0 && $0 <= 1_000_000 ? $0 : nil }
            if let minutes, !seen.insert(minutes).inserted { continue }
            let kind = BackendUsageReading.window(minutes: minutes)
            let label: String
            switch kind {
            case .fiveHour: label = "5-hour limit"
            case .weekly: label = "Weekly limit"
            case .monthly: label = "30-day limit"
            case .other: if let minutes { label = minutes.truncatingRemainder(dividingBy: 1440) == 0 ? "\(Int(minutes / 1440))-day limit" : minutes.truncatingRemainder(dividingBy: 60) == 0 ? "\(Int(minutes / 60))-hour limit" : "\(Int(minutes))-minute limit" } else { label = "Usage limit" }
            }
            result.append(BackendUsageReading(account: account, window: kind, qualifier: kind == .other ? minutes.map { String($0) } : nil, windowMinutes: minutes, label: label, used: .percent(percent), resets: .epoch(window["resets_at"].number), observedAt: now, reportedAt: best.at, source: "codex-rollout"))
        }
        return result
    }
}
