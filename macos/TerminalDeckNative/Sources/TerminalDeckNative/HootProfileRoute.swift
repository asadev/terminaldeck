import Observation
import SwiftUI

/// Hoot's profile lives only on the Hoot page. Every "open Hoot settings / profile" link anywhere
/// (popover, Agents page, menus, old Settings deep links, MCP) calls `HootProfileRoute.open()`.
/// The Hoot page shows `HootProfileView` in place of the chat while `showing` is true.
@MainActor @Observable
final class HootProfileRoute {
    static let shared = HootProfileRoute()
    /// The Hoot page swaps its chat area for the profile while this is true.
    var showing = false
    /// The profile tab to show first: overview, brain, files, instructions, runs.
    var tab = "overview"
    private init() {}

    /// Select the Hoot page and show Hoot's profile there (optionally on one tab).
    static func open(tab: String? = nil) {
        if let tab { shared.tab = tab }
        shared.showing = true
        AppModel.shared.select("hoot")
    }
    /// Back to Hoot's chat on the same page.
    static func close() { shared.showing = false }
}
