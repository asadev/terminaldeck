import AppKit
import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// browser-binding-ipc.ts openForSession → browser-route.ts routeOpen: the one
/// routing call behind the hook shim's `open`. A session's link goes to the
/// window that session already has, else to a new window the app's browser
/// opens (asked on `link:open-tab`, answered on `link:opened`, two seconds or
/// the system browser) and attaches to the session. `system` answers make the
/// shim run the real opener itself, so nothing here opens the page twice.
extension NativeCompositionProduction {
    static var noSessionLine: String { "No \(BackendSharedBrand.name) session here — opened in your default browser." }
    static func openedLine(_ n: Int) -> String { "Opened in \(BrowserWindowName.name(n)) — \(BackendSharedBrand.name)." }
    /// PHONE2: what the agent reads when the page went to the phone.
    static func openedOnPhoneLine(_ phone: String) -> String {
        "Opened on \(BackendRemoteProtocol.displayLabel(phone, maximumUnits: 64)) — the phone this session is being used from."
    }
    /// PHONE2: when somebody last touched this Mac (any key, click or pointer move), ms since 1970.
    static func macLastInputMilliseconds() -> Double? {
        guard let any = CGEventType(rawValue: ~0) else { return nil }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: any)
        guard idle.isFinite, idle >= 0 else { return nil }
        return (Date().timeIntervalSince1970 - idle) * 1000
    }
    static func openedNewLine(_ n: Int) -> String {
        "Opened in \(BrowserWindowName.name(n)) — \(BackendSharedBrand.name) (new window, attached to this session)."
    }

    /// index.ts machineOfSession: '' for a pty on this Mac, the linked machine's id
    /// for a session shown from one, the server for a server shell, else nil.
    func machineOfSession(_ id: String) async -> String? {
        if id.isEmpty { return nil }
        if sessions?.manager.list().contains(where: { $0.id == id }) == true { return "" }
        if let view = try? await machineCoordinator?.view() {
            for link in view["links"].elements ?? [] where (link["sessions"].elements ?? []).contains(where: { $0["id"].string == id }) {
                if let linkID = link["id"].string { return linkID }
            }
        }
        return await serversOwner?.shells.serverOfShell(id)
    }

    /// routeOpen({ url, sessionId, machineId?, newWindow? }). An absent machine is
    /// asked of machineOfSession; an empty one means this Mac.
    func openForSession(url: String, sessionID: String?, machineID: String? = nil, newWindow: Bool = false) async -> BackendSessionHookOpenAnswer {
        let resolvedMachine: String?
        if let machineID { resolvedMachine = machineID }
        else if let sessionID { resolvedMachine = await machineOfSession(sessionID) }
        else { resolvedMachine = "" }
        let machine = resolvedMachine ?? ""
        // resolve(): no session at all is the system browser.
        guard let sessionID, !sessionID.isEmpty else { return .init(route: .system, line: Self.noSessionLine) }
        // PHONE2: he is driving this session from his phone, so the phone opens the page (in-app
        // Safari; localhost through this Mac). A phone that cannot (older build) is never asked.
        if machine.isEmpty, !newWindow, let endpoint = remoteEndpoint,
           let phone = await endpoint.openLinkOnPhone(url, sessionID: sessionID, macLastInput: Self.macLastInputMilliseconds()) {
            return .init(route: .tab, line: Self.openedOnPhoneLine(phone))
        }
        let known = await machineOfSession(sessionID) == machine
        let session = BrowserDriverSession(sessionId: sessionID, machineId: machine)
        let browser = try? NativeCompositionRoot.shared.browserForComposition()
        let binding = browser.flatMap { browser -> [BrowserBoundWindow]? in
            browser.bindings.bindings(for: .init(ownerID: BackendCompositionRoot.appOwnerID, managesWindows: true))
                .windows[BrowserBindings.key(session)].map { $0.sorted { $0.n < $1.n } }
        }
        if binding == nil, !known { return .init(route: .system, line: Self.noSessionLine) }
        // A bound window that is still open is navigated (WKWebView has no
        // beforeunload veto, so a live page always navigates).
        if !newWindow, let first = binding?.first, let browser, browser.tabs.tab(first.tabID) != nil,
           let target = URL(string: url) {
            browser.runtime.load(first.tabID, url: target)
            return .init(route: .tab, line: Self.openedLine(first.n))
        }
        // A new window: the app's browser opens it, then it is attached here.
        let registry = root.registry
        let reply = await linkRequests.ask(url: url, sessionID: sessionID, machineID: machine) { request in
            try await registry.publish(BackendMacAppHandoffLinkRules.tabChannel, arguments: [request], ownerID: BackendCompositionRoot.appOwnerID)
        }
        guard let tabID = reply["tabId"].string, !tabID.isEmpty else {
            return .init(route: .system, line: reply["refused"].string ?? Self.noSessionLine)
        }
        guard let browser, let bound = try? browser.bindings.attach(tabID, to: session) else {
            return .init(route: .system, line: Self.noSessionLine)
        }
        let first = browser.bindings.bindings(for: .init(ownerID: BackendCompositionRoot.appOwnerID, managesWindows: true)).of(session).count == 1
        return .init(route: .tab, line: first ? Self.openedNewLine(bound.n) : Self.openedLine(bound.n))
    }
}

/// The window's half of `link:open-tab` (the renderer's in TS): open the tab in
/// the app's own browser and say which, or why not, on `link:opened`.
@MainActor
final class NativeCompositionLinkTabWindow {
    private var subscription: EngineSubscription?
    func start() {
        guard subscription == nil else { return }
        subscription = EngineBridge.shared.on(BackendMacAppHandoffLinkRules.tabChannel) { args in Self.answer(args.first) }
    }
    func stop() { subscription?.cancel(); subscription = nil }
    private static func answer(_ raw: Any?) {
        guard let request = raw as? [String: Any], let text = request["url"] as? String,
              let requestID = request["requestId"] as? String, !requestID.isEmpty else { return }
        guard let url = try? BrowserStepRules.openableURL(text) else {
            EngineBridge.shared.send("link:opened", [["requestId": requestID,
                "refused": "That link is not a web page, so no tab was opened for it."]])
            return
        }
        let tab = NativeBrowserTabs.shared.create(url: url, show: true)
        EngineBridge.shared.send("link:opened", [["requestId": requestID, "tabId": tab.id]])
    }
}
