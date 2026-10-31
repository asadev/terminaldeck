import Foundation
import Observation
import SwiftUI
import TerminalDeckBackend

/// 22 Oct (Asad, "remove this 128 limit"): nothing caps how many sessions run. A runaway (an agent starting
/// sessions in a loop) is still visible: above `quietAbove` running sessions the side panel shows one quiet line.
/// It never refuses or stops anything.
@MainActor @Observable
final class NativeSessionRunaway {
    static let shared = NativeSessionRunaway()
    static let quietAbove = 100
    private(set) var running = 0
    func set(_ value: Int) { if running != value { running = value } }

    /// Counted from the app's own list (no helper request) when a session's state, exit or removal changes.
    nonisolated static func watch(_ lifecycle: BackendSessionLifecycleCoordinator) async {
        let last = NativeSessionRunawayCount(), manager = lifecycle.manager
        _ = await lifecycle.observe(output: false) { event in
            if case .data = event { return }
            let count = manager.list().reduce(0) { $0 + ($1.exitCode == nil ? 1 : 0) }
            guard last.swap(count) != count else { return }
            await MainActor.run { NativeSessionRunaway.shared.set(count) }
        }
    }
}

private final class NativeSessionRunawayCount: @unchecked Sendable {
    private let lock = NSLock(); private var value = -1
    func swap(_ next: Int) -> Int { lock.withLock { let old = value; value = next; return old } }
}

/// The sessions on screen now (the active tab, the split's panes, the side panel's choice, pop-out windows): a finished
/// team job there is not taken out of the list under the person's eyes.
@MainActor
enum NativeSessionsOnScreen {
    static func ids() -> Set<String> {
        let model = AppModel.shared
        var ids = Set<String>()
        for tab in model.tabs?.tabs ?? [] where tab.active { ids.insert(tab.id) }
        for leaf in model.tabs?.layout?.root?.leaves ?? [] { if let tab = leaf.tabId { ids.insert(tab) } }
        if let selected = model.sidebarSelection { ids.insert(selected) }
        // 22 Oct (Reviewer, finding 5): a session out in a window of its own is on screen too.
        for popped in NativePoppedSessions.shared.openWindows { ids.insert(popped.sessionID) }
        return ids
    }
}

/// The quiet line under Running. Shown only while more than `quietAbove` sessions run.
@MainActor
struct NativeSessionRunawayNote: View {
    private let count = NativeSessionRunaway.shared
    var body: some View {
        if count.running > NativeSessionRunaway.quietAbove {
            Text("\(count.running) sessions running")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .help("More than \(NativeSessionRunaway.quietAbove) sessions are running at once. Nothing is blocked. If you did not expect this many, the Agents page shows who started them.")
                .accessibilityLabel("\(count.running) sessions running")
        }
    }
}
