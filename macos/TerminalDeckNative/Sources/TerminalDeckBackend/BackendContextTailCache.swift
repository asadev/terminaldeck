import Foundation
import TerminalDeckNativeCore

/// 28 Oct (Asad: the app stayed near a whole core with sessions only lightly working). The usage bar asks how full a
/// session's context is about once a second while the session prints, and every answer read the transcript's last
/// 256 KB (up to 8 MB) again and parsed every line in it. Now what a transcript said is remembered with where the
/// read stopped: a transcript that has not changed is not read at all, and one that grew is read only from that
/// point (its new lines). A file that shrank, was replaced or grew by more than the largest tail is read afresh.
public final class BackendContextTailCache: @unchecked Sendable {
    public struct Prompt: Sendable, Equatable {
        public let tokens: Double, model: String, at: Double
        public init(tokens: Double, model: String, at: Double) { self.tokens = tokens; self.model = model; self.at = at }
    }
    struct Entry: Sendable { var identity: UInt64; var size: Int; var modified: Double; var offset: Int; var latest: Prompt?; var high: Double }
    public struct Read: Sendable { public let latest: Prompt?; public let high: Double; public let bytes: Int }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    static let limit = 64
    public init() {}
    public var count: Int { lock.withLock { entries.count } }
    private func entry(_ path: String) -> Entry? { lock.withLock { entries[path] } }
    private func keep(_ path: String, _ entry: Entry) {
        lock.withLock {
            if entries[path] == nil { order.append(path); while order.count > Self.limit { entries[order.removeFirst()] = nil } }
            entries[path] = entry
        }
    }

    /// The newest prompt line and the highest prompt seen, reading only what is new since the last read.
    func read(path: String, roots: [String], steps: [Int], parse: (String) -> Prompt?) throws -> Read {
        let largest = steps.max() ?? 8 * 1024 * 1024
        if var known = entry(path) {
            let from = known.offset
            let now = try BackendUsageIO.range(path: path, roots: roots, from: from, maxBytes: largest)
            if now.identity == known.identity, now.size >= known.offset, now.size - known.offset <= largest,
               !(now.size == known.size && now.modified != known.modified) {
                if now.size == known.size { return Read(latest: known.latest, high: known.high, bytes: 0) }
                if let end = now.data.lastIndex(of: 10) {
                    for line in String(decoding: now.data[..<end], as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true) {
                        guard let prompt = parse(String(line)) else { continue }
                        // Reviewer (28 Oct): another model (a /model switch) starts its own peak; the old one's says
                        // nothing about this model's window.
                        known.high = prompt.model == known.latest?.model ? max(known.high, prompt.tokens) : prompt.tokens
                        known.latest = prompt
                    }
                    known.offset += end + 1
                }
                // Reviewer MUST-FIX 2 (28 Oct): the bytes actually looked at, not the size the file had at the open.
                known.size = from + now.data.count; known.modified = now.modified
                keep(path, known)
                return Read(latest: known.latest, high: known.high, bytes: now.data.count)
            }
        }
        // Afresh: the tail, widening until a prompt line is found (the reading `contextReading` always made).
        var spent = 0
        let probe = try BackendUsageIO.range(path: path, roots: roots, from: 0, maxBytes: 0)
        for amount in steps {
            let start = max(0, probe.size - amount)
            let tail = try BackendUsageIO.range(path: path, roots: roots, from: start, maxBytes: probe.size - start)
            spent += tail.data.count
            var body = tail.data[...]
            if start > 0 { if let cut = body.firstIndex(of: 10) { body = body[(cut + 1)...] } else { body = body[body.endIndex...] } }
            let lines = String(decoding: body, as: UTF8.self).components(separatedBy: "\n")
            let prompts = lines.compactMap(parse)
            let offset = tail.data.lastIndex(of: 10).map { start + $0 + 1 } ?? start
            if let latest = prompts.last {
                let high = prompts.map(\.tokens).max() ?? latest.tokens
                // Reviewer MUST-FIX 2 (28 Oct): a line appended between the size probe and this read is not counted as
                // read; the next call reads it.
                keep(path, Entry(identity: tail.identity, size: start + tail.data.count, modified: tail.modified, offset: offset, latest: latest, high: high))
                return Read(latest: latest, high: high, bytes: spent)
            }
            if min(amount, tail.size) >= tail.size {
                keep(path, Entry(identity: tail.identity, size: start + tail.data.count, modified: tail.modified, offset: offset, latest: nil, high: 0))
                break
            }
        }
        return Read(latest: nil, high: 0, bytes: spent)
    }
}
