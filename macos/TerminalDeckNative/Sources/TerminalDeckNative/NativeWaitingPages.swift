import Foundation
import TerminalDeckNativeCore

/// Pages an AI handed to the person (browser_handover: a sign-in it cannot finish, a captcha) never come forward by
/// themselves (NativeBackgroundToolsPolicy). Each one waiting has a quiet mark where he looks (review, 13 Nov):
/// - a page tied to a session that has a row in the side panel: the raised hand on that session's row;
/// - any other page (Hoot's own, a Hoot task's, a background agent's with no row): the raised hand on Hoot's line.
/// - a page tied to a session in a collapsed group (Archived chats): the raised hand on that group's header;
/// - Hoot's line scrolled out of sight: the hand on a line at the bottom of the side panel, always in view.
/// His click on the HAND opens exactly that page (`open`, through showForPerson); a click on the row itself opens the
/// session (or Hoot) as always (MAC-NEXT-13 B2). The mark goes when he hands it back
/// (Done / Stop) or closes the tab, because only a page with a handover prompt is counted.
@MainActor
enum NativeWaitingPages {
    /// Pages waiting for the person, in tab-strip order.
    static func waiting(in tabs: NativeBrowserTabs = .shared) -> [NativeBrowserTab] { tabs.tabs.filter { $0.handoverPrompt != nil } }

    /// The waiting page tied to this session, if any.
    static func page(forSession id: String, bindings: BRBindingView = NativeBRBindings.shared.view,
                     tabs: NativeBrowserTabs = .shared) -> String? {
        page(forSessions: [id], bindings: bindings, tabs: tabs)
    }

    /// The first waiting page tied to any of these sessions (a group's header carries it for every row it folds).
    static func page(forSessions ids: Set<String>, bindings: BRBindingView = NativeBRBindings.shared.view,
                     tabs: NativeBrowserTabs = .shared) -> String? {
        guard !ids.isEmpty else { return nil }
        let bound = Set(bindings.sessions.filter { ids.contains($0.sessionId) && !$0.ended }.flatMap { $0.windows.map(\.tabId) })
        return waiting(in: tabs).first { bound.contains($0.id) }?.id
    }

    /// The waiting page no session row shows (Hoot's, a Hoot task's, a background agent's): Hoot's line carries it.
    static func pageForHootLine(sessionRows: Set<String>, bindings: BRBindingView = NativeBRBindings.shared.view,
                                tabs: NativeBrowserTabs = .shared) -> String? {
        let onRows = Set(bindings.sessions.filter { sessionRows.contains($0.sessionId) && !$0.ended }.flatMap { $0.windows.map(\.tabId) })
        return waiting(in: tabs).first { !onRows.contains($0.id) }?.id
    }

    /// His click on the marked row: that page, in front of him.
    static func open(_ id: String, tabs: NativeBrowserTabs = .shared) {
        Task { _ = await tabs.showForPerson(id) } // person-ok: his own click on the marked row
    }

    static let words = "A page is waiting for you: click to open it"
}
