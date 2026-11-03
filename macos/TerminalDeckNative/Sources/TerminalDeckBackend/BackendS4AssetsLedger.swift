import Foundation
import CryptoKit
import TerminalDeckNativeCore

/// Port of src/main/browser-asset-ledger.ts and the fingerprint half of
/// browser-asset-digest.ts: the resume ledger keyed on the URL AND the bytes on
/// disk. Append-only JSONL, later lines win, a bad line costs exactly one entry.
/// Plugs into BackendDeckToolsAssetLedger (the existing asset-tools seam).
enum BackendS4AssetsObject {
    static func make(_ pairs: [(String, NativeRPCValue)]) -> NativeRPCValue { .object(pairs.map { NativeRPCValue.Field($0.0, $0.1) }) }
    static func number(_ value: Int) -> NativeRPCValue { .number(Double(value)) }
}

/// What the TypeScript `fingerprintFile` does: follow symlinks like `statSync`,
/// refuse anything that is not a regular file, hash it sequentially.
enum BackendS4AssetsFiles {
    struct Fingerprint: Equatable, Sendable { let bytes: Int; let digest: String }
    static func fingerprint(_ path: String) -> Fingerprint? {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: resolved),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, let handle = FileHandle(forReadingAtPath: resolved) else { return nil }
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            let part: Data
            do { part = try handle.read(upToCount: 256 * 1_024) ?? Data() } catch { return nil }
            if part.isEmpty { break }
            hash.update(data: part)
        }
        return Fingerprint(bytes: size.intValue, digest: "sha256:" + hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
    static func sha256Hex(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }
}

struct BackendS4AssetsLedgerEntry: Sendable, Equatable {
    var url: String, fetchedUrl: String, ruleId: String, digest: String
    var bytes: Int, path: String, at: Double
    var value: NativeRPCValue {
        BackendS4AssetsObject.make([("url", .string(url)), ("fetchedUrl", .string(fetchedUrl)), ("ruleId", .string(ruleId)), ("digest", .string(digest)),
                                    ("bytes", BackendS4AssetsObject.number(bytes)), ("path", .string(path)), ("at", .number(at))])
    }
    /// entryOf(): url required and non-empty; every other field is defaulted.
    static func read(_ raw: NativeRPCValue) -> BackendS4AssetsLedgerEntry? {
        guard raw.fields != nil, let url = raw["url"].string, !url.isEmpty else { return nil }
        var bytes = 0
        if let number = raw["bytes"].number, number.isFinite { bytes = number < 0 ? 0 : Int(number) }
        var at = 0.0
        if let number = raw["at"].number, number.isFinite { at = number }
        return .init(url: url, fetchedUrl: raw["fetchedUrl"].string ?? url, ruleId: raw["ruleId"].string ?? "", digest: raw["digest"].string ?? "",
                     bytes: bytes, path: raw["path"].string ?? "", at: at)
    }
}

struct BackendS4AssetsLedgerDecision: Sendable {
    let action: String, reason: String, line: String
    let entry: BackendS4AssetsLedgerEntry?, ledgerWasWrong: Bool
    var value: NativeRPCValue {
        BackendS4AssetsObject.make([("action", .string(action)), ("reason", .string(reason)), ("line", .string(line)),
                                    ("entry", entry?.value ?? .null), ("ledgerWasWrong", .bool(ledgerWasWrong))])
    }
}

enum BackendS4AssetsLedgerRules {
    /// readLedgerFile(): last entry per URL; the order is first appearance (a JS Map keeps it).
    static func read(_ text: String) -> (entries: [String: BackendS4AssetsLedgerEntry], order: [String], skipped: Int) {
        var entries: [String: BackendS4AssetsLedgerEntry] = [:], order: [String] = [], skipped = 0
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            guard let parsed = try? NativeRPCValue.parseJSON(Data(trimmed.utf8)) else { skipped += 1; continue }
            guard let entry = BackendS4AssetsLedgerEntry.read(parsed) else { skipped += 1; continue }
            if entries[entry.url] == nil { order.append(entry.url) }
            entries[entry.url] = entry
        }
        return (entries, order, skipped)
    }

    /// decideFromFingerprint(): pure, ordered exactly as the source orders it.
    static func decide(url: String, mode: String, entry: BackendS4AssetsLedgerEntry?, found: BackendS4AssetsFiles.Fingerprint?,
                       expectDigest: String?) -> BackendS4AssetsLedgerDecision {
        func no(_ reason: String, _ line: String, wrong: Bool = false) -> BackendS4AssetsLedgerDecision {
            .init(action: "fetch", reason: reason, line: line, entry: entry, ledgerWasWrong: wrong)
        }
        let shown = BackendDeckToolsAssets.scrubURL(url)
        if mode == "refetch" { return no("refetch-requested", "A deliberate refetch was asked for, so the ledger was not consulted for this asset.") }
        guard let entry else { return no("not-in-ledger", "Nothing in the ledger for \(shown).") }
        if entry.path.isEmpty { return no("file-missing", "The ledger has \(shown) but never recorded where the file went.", wrong: true) }
        guard let found else {
            return no("file-missing", "The ledger says \(shown) was written to \(entry.path), and there is no readable file there.", wrong: true)
        }
        if entry.digest.isEmpty {
            return no("unreadable", "The ledger has \(shown) but no digest for it, so there is no way to tell the right file from a bad one.", wrong: true)
        }
        if entry.bytes != found.bytes { return no("wrong-size", "\(entry.path) is \(found.bytes) bytes and the ledger recorded \(entry.bytes).", wrong: true) }
        if entry.digest != found.digest {
            return no("wrong-digest", "\(entry.path) is the right length and the wrong file — it does not match the digest recorded for it.", wrong: true)
        }
        let expected = expectDigest ?? ""
        if !expected.isEmpty && expected != entry.digest {
            return no("digest-not-expected", "\(shown) is on disk and intact, and it is not the file this run expects — fetching it again.")
        }
        return .init(action: "skip", reason: "verified", line: "\(shown) is already on disk and matches its digest.", entry: entry, ledgerWasWrong: false)
    }
}

/// One live ledger per (mode, path) — the domain caches it, and the fetch uses
/// the very same object, so the tally and the in-memory entries stay one truth.
final class BackendS4AssetsLedger: BackendDeckToolsAssetLedger, @unchecked Sendable {
    let path: String, mode: String
    private let lock = NSLock()
    private let clock: @Sendable () -> Double
    private var entries: [String: BackendS4AssetsLedgerEntry] = [:], order: [String] = []
    private var known = 0, unreadable = 0, skipped = 0, fetched = 0, wrong = 0, recorded = 0

    init(path: String, mode: String, now: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 * 1_000 }) {
        self.path = path; self.mode = mode == "refetch" ? "refetch" : "resume"; clock = now
        // A missing or unreadable file is an empty ledger, never an error.
        if let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) {
            let read = BackendS4AssetsLedgerRules.read(text)
            entries = read.entries; order = read.order; unreadable = read.skipped
        }
        known = entries.count
    }
    var size: Int { lock.withLock { entries.count } }
    func entryFor(_ url: String) -> BackendS4AssetsLedgerEntry? { lock.withLock { entries[url] } }

    func decideTyped(url: String, expectDigest: String?) async -> BackendS4AssetsLedgerDecision {
        let entry: BackendS4AssetsLedgerEntry? = mode == "refetch" ? nil : entryFor(url)
        // Only hash when an entry points at a file; refetch deliberately costs nothing.
        let found = (entry == nil || entry!.path.isEmpty) ? nil : BackendS4AssetsFiles.fingerprint(entry!.path)
        let decision = BackendS4AssetsLedgerRules.decide(url: url, mode: mode, entry: entry, found: found, expectDigest: expectDigest)
        lock.withLock {
            if decision.action == "skip" { skipped += 1 } else { fetched += 1; if decision.ledgerWasWrong { wrong += 1 } }
        }
        return decision
    }
    func decide(url: String, expectDigest: String?) async throws -> NativeRPCValue { await decideTyped(url: url, expectDigest: expectDigest).value }

    func recordTyped(_ input: BackendS4AssetsLedgerEntry) -> BackendS4AssetsLedgerEntry {
        var entry = input
        if entry.fetchedUrl.isEmpty { entry.fetchedUrl = entry.url }
        lock.withLock {
            if entries[entry.url] == nil { order.append(entry.url) }
            entries[entry.url] = entry; recorded += 1
        }
        // A ledger line that will not write is not thrown: the download itself
        // succeeded, and the entry stays in memory for the rest of this run.
        do {
            let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: path) { try Data().write(to: URL(fileURLWithPath: path)) }
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: try entry.value.encodedJSON() + Data([10]))
        } catch {}
        return entry
    }
    func record(_ raw: NativeRPCValue) async throws -> NativeRPCValue {
        guard let url = raw["url"].string, !url.isEmpty else { throw NativeRPCError.invalidArguments("A ledger entry needs a url.") }
        let bytes = raw["bytes"].number.flatMap { $0.isFinite ? Int($0) : nil } ?? 0
        let entry = BackendS4AssetsLedgerEntry(url: url, fetchedUrl: raw["fetchedUrl"].string ?? "", ruleId: raw["ruleId"].string ?? "",
                                               digest: raw["digest"].string ?? "", bytes: bytes, path: raw["path"].string ?? "",
                                               at: raw["at"].number ?? clock())
        return recordTyped(entry).value
    }

    func verify() async throws -> NativeRPCValue {
        let snapshot = lock.withLock { order.compactMap { entries[$0] } }
        var missing: [BackendS4AssetsLedgerEntry] = [], corrupt: [BackendS4AssetsLedgerEntry] = [], ok = 0
        for entry in snapshot {
            try Task.checkCancellation()
            let found = entry.path.isEmpty ? nil : BackendS4AssetsFiles.fingerprint(entry.path)
            guard let found else { missing.append(entry); continue }
            if entry.digest.isEmpty || found.digest != entry.digest || found.bytes != entry.bytes { corrupt.append(entry); continue }
            ok += 1
        }
        let total = snapshot.count
        let line = missing.isEmpty && corrupt.isEmpty
            ? "All \(total) assets in this ledger are on disk and match their digests."
            : "\(ok) of \(total) assets are intact. \(missing.count) are missing from disk and \(corrupt.count) do not match the digest recorded for them. This run is not complete."
        return BackendS4AssetsObject.make([("total", BackendS4AssetsObject.number(total)), ("ok", BackendS4AssetsObject.number(ok)),
                                           ("missing", .array(missing.map(\.value))), ("corrupt", .array(corrupt.map(\.value))), ("line", .string(line))])
    }
    func tally() async throws -> NativeRPCValue {
        lock.withLock {
            BackendS4AssetsObject.make([("known", BackendS4AssetsObject.number(known)), ("unreadable", BackendS4AssetsObject.number(unreadable)),
                                        ("skipped", BackendS4AssetsObject.number(skipped)), ("fetched", BackendS4AssetsObject.number(fetched)),
                                        ("ledgerWasWrong", BackendS4AssetsObject.number(wrong)), ("recorded", BackendS4AssetsObject.number(recorded))])
        }
    }
    func summary() async throws -> String {
        let state = lock.withLock { (known, unreadable, skipped, fetched, wrong, recorded) }
        if mode == "refetch" { return "Deliberate refetch: the ledger was not consulted. \(state.5) recorded so far." }
        var parts = ["\(state.0) known", "\(state.2) skipped", "\(state.3) fetched", "\(state.5) recorded"]
        if state.4 > 0 {
            parts.append("\(state.4) of those were fetched because the ledger claimed a file that was missing or did not match — do not read this run as a resume")
        }
        if state.1 > 0 { parts.append("\(state.1) ledger lines were unreadable") }
        return parts.joined(separator: ", ")
    }
}
