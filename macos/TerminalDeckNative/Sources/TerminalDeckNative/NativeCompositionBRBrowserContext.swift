import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Lane BR: tell each session's agent which browser windows are attached to it,
/// through the hook endpoint's additional context (TS index.ts `contextFor` over
/// browser-binding.ts `hookContext` / `takeAnnouncement`).
///
/// With the `open` shim, the app map and the "cannot drive" line wired by INT (7 Oct).
extension NativeCompositionProduction {
    func installBrowserSessionContext(_ browser: NativeCompositionBrowser) {
        let context = BRBrowserSessionContext()
        let principal = BackendBrowserPrincipal(ownerID: BackendCompositionRoot.appOwnerID, managesWindows: true)
        let feed: @MainActor () -> Void = { [weak browser] in
            guard let browser else { return }
            context.update(browser.bindings.view(for: principal))
        }
        let previous = browser.bindings.changed
        browser.bindings.changed = { previous?(); feed() }
        feed()
        let sessions = self.sessions, openShim = self.openShim, appContext = self.appContext, verbs = self.verbs
        joins.bindHookContext { event in
            // `known`: a session this app started (TS machineOfSession !== null).
            let known = event.sessionID.map { id in sessions?.manager.list().contains { $0.id == id } ?? false } ?? false
            // index.ts contextFor: opensInApp = the shim is installed; map = bootMapFor (SessionStart /
            // first BeforeAgent); cannotDrive = noVerbsLine (INT, 7 Oct).
            let opensInApp = await openShim.current() != nil
            let map = await appContext.bootMapFor(event: event.event, sessionID: event.sessionID)
            let cannotDrive: String? = if let id = event.sessionID { await verbs.line(for: id) } else { nil }
            return context.answer(event: event.event, sessionID: event.sessionID, known: known, opensInApp: opensInApp,
                                  map: map, cannotDrive: cannotDrive)
        }
    }
}
