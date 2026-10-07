import Foundation
import TerminalDeckNativeCore

/// The source's Codex rollout carry: metadata-selected and copied, never
/// linked. This preserves the conversation snapshot without two account locks
/// accidentally writing to the same inode.
public enum BackendSessionSwitchCodexCarry {
    public struct Thread: Sendable {
        public let id: String
        public let file: URL
        public let relative: String
    }
    private static let filename = try! NSRegularExpression(pattern: #"^rollout-(\d{4})-(\d{2})-(\d{2})T(\d{2})-(\d{2})-(\d{2})-([0-9a-f-]{36})(?:_[0-9a-f-]{36})?\.jsonl$"#)
    private static func firstLine(_ file: URL) throws -> NativeRPCValue? {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        let bytes = try handle.read(upToCount: 1024 * 1024) ?? Data()
        let line = bytes.prefix { $0 != 0x0a }
        return try? NativeRPCValue.parseJSON(Data(line), maximumBytes: 1024 * 1024)
    }
    public static func find(home: String, cwd: String, startedAt: Double, knownID: String? = nil,
                            claimed: Set<String> = [], now: Date = Date()) throws -> Thread? {
        let root = URL(fileURLWithPath: home).appendingPathComponent("sessions", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let earliest = floor(startedAt / 1000) - 2
        let start = knownID == nil ? Date(timeIntervalSince1970: startedAt / 1000 - 86_400) : Date(timeIntervalSince1970: 0)
        var found: [String: Thread] = [:], scanned = 0
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            throw BackendSessionFailure.invalidInput("The Codex conversation directory could not be read.")
        }
        for case let file as URL in enumerator {
            scanned += 1
            guard scanned <= 100_000 else { throw BackendSessionFailure.invalidInput("The Codex conversation search exceeded its file budget.") }
            let name = file.lastPathComponent
            guard let match = filename.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                  let idRange = Range(match.range(at: 7), in: name) else { continue }
            let filenameID = String(name[idRange])
            if let knownID, filenameID != knownID { continue }
            guard !claimed.contains(filenameID), NativeTranscriptPaths.isDescendant(NativeTranscriptPaths.canonical(file.path), of: NativeTranscriptPaths.canonical(root.path)) else { continue }
            var components = DateComponents()
            let values = (1...6).compactMap { index -> Int? in Range(match.range(at: index), in: name).flatMap { Int(name[$0]) } }
            guard values.count == 6 else { continue }
            components.year = values[0]; components.month = values[1]; components.day = values[2]
            components.hour = values[3]; components.minute = values[4]; components.second = values[5]
            guard let at = calendar.date(from: components), at <= now, knownID != nil || at >= start && at.timeIntervalSince1970 >= earliest,
                  let meta = try firstLine(file), meta["type"].string == "session_meta", let id = meta["payload"]["id"].string,
                  id == filenameID, let recordedCwd = meta["payload"]["cwd"].string,
                  NativeTranscriptPaths.canonical(recordedCwd) == NativeTranscriptPaths.canonical(cwd) else { continue }
            let prefix = root.standardizedFileURL.path + "/"
            guard file.standardizedFileURL.path.hasPrefix(prefix) else { continue }
            let relative = String(file.standardizedFileURL.path.dropFirst(prefix.count))
            // TS: `{ id, file, relative: relative(sessions, file) }` — the file named by its place under sessions/.
            found[id] = Thread(id: id, file: root.appendingPathComponent(relative), relative: relative)
        }
        return found.count == 1 ? found.values.first : nil
    }
    /// TS carryCodexThread: the path it was put at, or nil when it could not be
    /// put there (the switch then starts fresh). Never throws.
    public static func carry(_ thread: Thread, targetHome: String) -> URL? {
        let parts = thread.relative.split(separator: "/").map(String.init)
        guard parts.count == 4, parts.prefix(3).allSatisfy({ $0.range(of: #"^\d{2,4}$"#, options: .regularExpression) != nil }),
              !parts.contains(".."), filename.firstMatch(in: parts[3], range: NSRange(parts[3].startIndex..., in: parts[3])) != nil else { return nil }
        // TS: a source that is gone, or not a file, answers null before anything is made.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: thread.file.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        let root = URL(fileURLWithPath: targetHome).appendingPathComponent("sessions", isDirectory: true)
        let target = root.appendingPathComponent(thread.relative)
        let directory = target.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            guard NativeTranscriptPaths.isDescendant(NativeTranscriptPaths.canonical(directory.path), of: NativeTranscriptPaths.canonical(root.path)) else { return nil }
            let temporary = directory.appendingPathComponent(".carry-" + UUID().uuidString + ".jsonl")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try FileManager.default.copyItem(at: thread.file, to: temporary)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            if FileManager.default.fileExists(atPath: target.path) { _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary) }
            else { try FileManager.default.moveItem(at: temporary, to: target) }
            return target
        } catch { return nil }
    }
}
