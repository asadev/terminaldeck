import Observation
import TerminalDeckNativeCore

/// The main page's latest `island` message, handed to the island.
///
/// The `tdNative` handler gives every message to `accept` first; an island
/// message stops here and never reaches the window's own messages.
@MainActor
@Observable
final class IslandRelay {
    static let shared = IslandRelay()

    /// nil until the page has said something — the island is the plain pill until then.
    private(set) var state: IslandState?

    private init() {}

    /// True when `body` was an island message (taken here, well-formed or not).
    @discardableResult
    func accept(_ body: Any) -> Bool {
        guard IslandState.isIslandMessage(body) else { return false }
        if let next = IslandState.parse(body), next != state { state = next }
        return true
    }

    /// The engine went away: what it last said is no longer true.
    func reset() {
        if state != nil { state = nil }
    }
}

/// What the island view draws.
@MainActor
@Observable
final class IslandViewModel {
    var layout: IslandLayout
    /// Grown into the panel (set inside an animation).
    var expanded = false
    /// The engine is up and the main page is loaded.
    var engineUp = false
    /// The island's own page has loaded and can be shown.
    var pageLoaded = false

    init(layout: IslandLayout) {
        self.layout = layout
    }

    /// Only real state: nothing while the engine is down or before the page has spoken.
    var state: IslandState? { engineUp ? IslandRelay.shared.state : nil }
}
