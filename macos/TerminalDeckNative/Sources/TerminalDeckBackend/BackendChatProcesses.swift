import Foundation
import Darwin
import TerminalDeckNativeCore

/// 9 Nov (stale "Working · 1 running"): what is alive under a chat's AI process, read from the kernel with the same
/// calls the keeper's descendant watch uses (`BackendHOSTOrphanDarwin`). Reads only: nothing is ever signalled.
enum BackendChatProcesses {
    /// The AI process and its live descendants, one generation at a time. Stops early once `enough` is satisfied
    /// (normally after the AI's own children); nil when the kernel cannot say or the tree is too big to be sure.
    static func tree(root: Int32, limit: Int = 512, enough: (ChatProcessTree) -> Bool = { _ in false }) -> ChatProcessTree? {
        guard root > 1, let info = try? BackendHOSTOrphanDarwin.bsd(root), info.pbi_status != UInt32(SZOMB) else { return nil }
        let top = ChatProcessTree.Process(pid: root, started: started(info))
        var found: [ChatProcessTree.Process] = [], generation = [root], seen: Set<Int32> = [root]
        while !generation.isEmpty {
            var next: [Int32] = []
            for parent in generation {
                guard let children = try? BackendHOSTOrphanDarwin.children(parent) else { return nil }
                for pid in children where seen.insert(pid).inserted {
                    // Gone since the list was read: skip it. Unreadable: the tree cannot be told, so nothing is judged.
                    let read: proc_bsdinfo?
                    do { read = try BackendHOSTOrphanDarwin.bsd(pid) } catch { return nil }
                    guard let child = read, child.pbi_ppid == UInt32(parent), child.pbi_status != UInt32(SZOMB) else { continue }
                    found.append(.init(pid: pid, started: started(child))); next.append(pid)
                    guard found.count <= limit else { return nil }
                }
            }
            let partial = ChatProcessTree(root: top, descendants: found)
            if next.isEmpty || enough(partial) { return partial }
            generation = next
        }
        return .init(root: top, descendants: found)
    }
    private static func started(_ info: proc_bsdinfo) -> Double {
        Double(info.pbi_start_tvsec) * 1000 + Double(info.pbi_start_tvusec) / 1000
    }
}

/// For a chat that runs its AI itself (Hoot in the app; any chat outside the keeper): the kernel's own fork and exit
/// events for the AI process and the processes a read found under it wake the chat. No timer, no polling; the keeper's
/// chats use the keeper's descendant watch instead (`BackendHOSTOrphanInventory.onChange`).
final class BackendChatProcessWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var sources: [Int32: DispatchSourceProcess] = [:]
    private var tokens: [Int32: UUID] = [:]
    private var closed = false
    private let root: Int32
    private let changed: @Sendable () -> Void
    init(root: Int32, changed: @escaping @Sendable () -> Void) {
        self.root = root; self.changed = changed
        arm(root, events: [.fork, .exit])
    }
    /// Also wake the chat when one of these ends.
    func watch(_ pids: [Int32]) {
        for pid in pids where pid > 1 && arm(pid, events: [.exit]) {
            // One that ended between the read and its watch sends no exit any more: say so now.
            let info = try? BackendHOSTOrphanDarwin.bsd(pid)
            if info == nil || info?.pbi_status == UInt32(SZOMB) { changed() }
        }
    }
    deinit { for source in sources.values { source.cancel() } }
    func cancel() {
        let all = lock.withLock { () -> [DispatchSourceProcess] in
            closed = true; defer { sources = [:]; tokens = [:] }; return Array(sources.values)
        }
        all.forEach { $0.cancel() }
    }
    @discardableResult private func arm(_ pid: Int32, events: DispatchSource.ProcessEvent) -> Bool {
        lock.withLock {
            guard !closed, sources[pid] == nil else { return false }
            let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: events, queue: .global(qos: .utility))
            let token = UUID()
            source.setEventHandler { [weak self, weak source] in
                guard let self, let source else { return }
                if source.data.contains(.exit) {
                    if pid == root { cancel() } else { lock.withLock { if tokens[pid] == token { sources[pid] = nil; tokens[pid] = nil } } }
                    source.cancel()
                }
                changed()
            }
            sources[pid] = source; tokens[pid] = token
            source.resume()
            return true
        }
    }
}
