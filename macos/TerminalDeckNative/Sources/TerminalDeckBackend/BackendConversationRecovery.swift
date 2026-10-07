import Foundation

/// Metadata-only conversation attribution from conversation-id.ts. The account
/// adapter supplies its own canonical project transcript directories; contents
/// are never opened, copied, inferred across accounts, or logged.
public enum BackendConversationRecovery {
    public struct Transcript: Sendable {
        public let sessionID: String
        public let bytes: Int
        public let modifiedAt: Date
        public init(sessionID: String, bytes: Int, modifiedAt: Date) {
            self.sessionID = sessionID; self.bytes = bytes; self.modifiedAt = modifiedAt
        }
    }

    public static func select(_ transcripts: [Transcript], startedAt: Date, claimed: Set<String>) -> String? {
        var seen: [String: Transcript] = [:]
        for file in transcripts where file.bytes > 0 && !claimed.contains(file.sessionID) {
            if seen[file.sessionID].map({ $0.modifiedAt >= file.modifiedAt }) == true { continue }
            seen[file.sessionID] = file
        }
        let ordered = seen.values.sorted { $0.modifiedAt > $1.modifiedAt }
        let since = ordered.filter { $0.modifiedAt >= startedAt }
        if since.count == 1 { return since[0].sessionID }
        if since.count > 1 { return nil }
        return ordered.first?.sessionID
    }

    /// Call off the main actor, using paths resolved by the account domain.
    /// Missing directories contain no transcripts; read/access failures stay
    /// visible instead of changing which account/conversation is selected.
    public static func read(directories: [URL], startedAt: Date, claimed: Set<String>) throws -> String? {
        var files: [Transcript] = []
        for directory in directories {
            guard directory.isFileURL, directory.path.hasPrefix("/") else {
                throw BackendSessionFailure.invalidInput("A conversation metadata directory must be an absolute file URL.")
            }
            let entries: [URL]
            do {
                entries = try FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile { continue }
            guard entries.count <= 100_000 else { throw BackendSessionFailure.invalidInput("The conversation metadata directory exceeds the supported file limit.") }
            // TS transcript.ts listTranscripts: every `<id>.jsonl` that stats as a
            // file, named after its id — whatever the id looks like.
            for entry in entries {
                let name = entry.lastPathComponent
                guard name.hasSuffix(".jsonl"), name.count > ".jsonl".count else { continue }
                let id = String(name.dropLast(".jsonl".count))
                guard !claimed.contains(id) else { continue }
                guard let values = try? entry.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                      values.isRegularFile == true, let bytes = values.fileSize, let modified = values.contentModificationDate else { continue }
                files.append(Transcript(sessionID: id, bytes: bytes, modifiedAt: modified))
            }
        }
        return select(files, startedAt: startedAt, claimed: claimed)
    }
}
