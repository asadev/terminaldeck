import AppKit
import Foundation
import WebKit
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Supplied by the actual app-owned tab/drive-lease table. A profile is fixed
/// for a WKWebView; switching a profile creates a replacement page/store.
struct NativeSafariPasswordsOwnership {
    let profileID: String
    let isolated: Bool
    let agentHolding: Bool
}

/// Password fields live in a private WebKit content world and the top frame.
/// This is an inert adapter: install/bind/connect/didCommit are explicit app
/// integration operations. It never visits another browser or reads Keychain.
@MainActor
final class NativeSafariPasswords: NSObject, WKScriptMessageHandler {
    private final class Page {
        weak var view: WKWebView?
        let tabID: String
        var documentID = UUID().uuidString.lowercased()
        var committedURL: String?
        var documentFromAgent = false
        var nonce: String?
        var hasForm = false
        init(view: WKWebView, tabID: String) { self.view = view; self.tabID = tabID }
    }
    private final class Controller {
        weak var value: WKUserContentController?
        init(_ value: WKUserContentController) { self.value = value }
    }
    static let world = WKContentWorld.world(name: "TerminalDeckPasswords")
    static let handlerName = "terminalDeckPasswordForm"
    private var pages: [String: Page] = [:]
    private var installedControllers: [Controller] = []
    private var service: BackendBrowserPasswords?
    private let ownership: @MainActor @Sendable (String) -> NativeSafariPasswordsOwnership?
    private let signInOffer: @MainActor @Sendable (String, NativeRPCValue?) -> Void
    private let passwordOffer: @MainActor @Sendable (String, BackendBrowserLoginSummary) -> Void
    private let reportFailure: @MainActor @Sendable (String) -> Void
    init(ownership: @escaping @MainActor @Sendable (String) -> NativeSafariPasswordsOwnership?,
         signInOffer: @escaping @MainActor @Sendable (String, NativeRPCValue?) -> Void,
         passwordOffer: @escaping @MainActor @Sendable (String, BackendBrowserLoginSummary) -> Void,
         reportFailure: @escaping @MainActor @Sendable (String) -> Void) {
        self.ownership = ownership; self.signInOffer = signInOffer; self.passwordOffer = passwordOffer; self.reportFailure = reportFailure
        super.init()
    }
    func connect(_ service: BackendBrowserPasswords) { self.service = service }
    func install(into configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        installedControllers.removeAll { $0.value == nil }
        guard !installedControllers.contains(where: { $0.value === controller }) else { return }
        installedControllers.append(Controller(controller))
        controller.addUserScript(WKUserScript(source: Self.formScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.world))
        controller.add(self, contentWorld: Self.world, name: Self.handlerName)
    }
    func bind(_ webView: WKWebView, tabID: String) {
        guard ownership(tabID) != nil else { return }
        pages[tabID] = Page(view: webView, tabID: tabID)
    }
    /// Call from WKNavigationDelegate.didCommit, before document-end messages.
    /// A committed document inherits an agent stamp even if a person typed the
    /// address while an agent's live lease still held that page.
    func didCommit(_ webView: WKWebView, tabID: String) {
        guard let page = pages[tabID], page.view === webView, let owned = ownership(tabID) else { return }
        page.documentID = UUID().uuidString.lowercased(); page.committedURL = webView.url?.absoluteString
        page.documentFromAgent = owned.agentHolding; page.nonce = nil; page.hasForm = false
        signInOffer(tabID, nil)
        if let service { Task { await service.documentChanged(tabID: tabID) } }
    }
    func unbind(tabID: String) {
        pages[tabID] = nil; signInOffer(tabID, nil)
        if let service { Task { await service.tabClosed(tabID: tabID) } }
    }
    /// Close/unbind the native pages before shutdown. Removing only this named
    /// handler preserves the recorder and all unrelated browser integrations.
    func shutdown() {
        for item in installedControllers { item.value?.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: Self.world) }
        service = nil; pages.removeAll(); installedControllers.removeAll()
    }
    func makeHost() -> BackendBrowserPasswordsHost {
        BackendBrowserPasswordsHost(tab: { [weak self] id in await self?.snapshot(id) },
            fill: { [weak self] request, password, replace in
                guard let self else { return false }
                return try await self.fill(request, password: password, replace: replace)
            }, copy: { text in
                try await MainActor.run {
                    NSPasteboard.general.clearContents()
                    guard NSPasteboard.general.setString(text, forType: .string) else {
                        throw NativeRPCError(code: "clipboard-failed", message: "The password could not be copied.")
                    }
                }
            }, reveal: { file in await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([file]) } })
    }
    private func snapshot(_ id: String) -> BackendBrowserPasswordTab? {
        guard let page = pages[id], page.view != nil, let owned = ownership(id), let committedURL = page.committedURL else { return nil }
        return .init(tabID: id, profileID: BackendBrowserProfiles.normalizedID(owned.profileID), committedURL: committedURL,
            documentID: page.documentID, isolated: owned.isolated, agentHolding: owned.agentHolding,
            documentFromAgent: page.documentFromAgent, hasSignInForm: page.hasForm && page.nonce != nil)
    }
    private func fill(_ request: BackendBrowserPasswordFill, password: String, replace: Bool) async throws -> Bool {
        guard let page = pages[request.tabID], let view = page.view, let nonce = page.nonce, let before = snapshot(request.tabID),
              before.hasSignInForm, !before.isolated, before.profileID == request.profileID, before.origin == request.origin,
              before.documentID == request.documentID else { return false }
        try Task.checkCancellation()
        let result: Any?
        do {
            result = try await view.callAsyncJavaScript(
                "return globalThis.__terminalDeckPasswords?.fill(username, password, replace, nonce, origin) === true;",
                arguments: ["username": request.username, "password": password, "replace": replace, "nonce": nonce, "origin": request.origin],
                in: nil, contentWorld: Self.world)
        } catch { throw NativeRPCError(code: "password-fill-failed", message: "The sign-in form could not be filled. No password was returned.") }
        try Task.checkCancellation()
        guard let after = snapshot(request.tabID), after.documentID == request.documentID, after.origin == request.origin,
              after.profileID == request.profileID else { return false }
        return result as? Bool == true
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == Self.handlerName, message.frameInfo.isMainFrame, let view = message.webView,
              let page = pages.values.first(where: { $0.view === view }), let own = ownership(page.tabID), !own.isolated,
              let body = message.body as? [String: Any], let kind = body["kind"] as? String, ["form", "offer"].contains(kind),
              let nonce = body["nonce"] as? String, nonce.count == 32, nonce.range(of: #"^[0-9a-f]{32}$"#, options: .regularExpression) != nil,
              let current = snapshot(page.tabID), let origin = current.origin else { return }
        // WK's frame security origin is engine-owned. The script's URL is never
        // trusted, even though its content world is isolated from the page.
        let frame = message.frameInfo.securityOrigin
        var parts = URLComponents(); parts.scheme = frame.protocol; parts.host = frame.host
        if frame.port != 0 { parts.port = frame.port }
        guard let frameURL = parts.string, BackendBrowserPasswords.origin(frameURL) == origin else { return }
        let documentID = page.documentID
        Task { [weak self, weak view] in
            guard let self, let view, let service = self.service else { return }
            do {
                // Query the current document's isolated-world nonce. A queued
                // message from the previous document must not rebind after a
                // same-origin navigation has already committed.
                let live = try await view.callAsyncJavaScript(
                    "return globalThis.__terminalDeckPasswords?.nonce === nonce && location.origin === origin;",
                    arguments: ["nonce": nonce, "origin": origin], in: nil, contentWorld: Self.world)
                guard live as? Bool == true, let page = self.pages[current.tabID], page.view === view,
                      page.documentID == documentID, self.snapshot(current.tabID)?.origin == origin else { return }
                page.nonce = nonce
                if kind == "form" {
                    page.hasForm = body["present"] as? Bool == true
                    if page.hasForm {
                        let offer = try await service.formAvailable(tabID: current.tabID, documentID: documentID)
                        guard self.pages[current.tabID]?.documentID == documentID else { return }
                        self.signInOffer(current.tabID, offer)
                    } else {
                        await service.documentChanged(tabID: current.tabID); self.signInOffer(current.tabID, nil)
                    }
                } else if let username = body["username"] as? String, let password = body["password"] as? String,
                          username.utf16.count <= 512, !password.isEmpty, password.utf16.count <= 512 {
                    if let offer = try await service.offerFromPage(tabID: current.tabID, documentID: documentID, username: username, password: password) {
                        self.passwordOffer(current.tabID, offer.login)
                    }
                }
            } catch is CancellationError { }
            catch { self.reportFailure("The saved-login form operation could not complete.") }
        }
    }
    static func signInHost(readVersionOutput: @escaping @Sendable (String) async throws -> String?) -> BackendBrowserSignIn {
        BackendBrowserSignIn(openExternal: { url in
            try await MainActor.run {
                guard NSWorkspace.shared.open(url) else { throw NativeRPCError(code: "signin-open-failed", message: "macOS could not open the sign-in page in the system browser.") }
            }
        }, readVersionOutput: readVersionOutput)
    }
    private static let formScript = #"""
    (() => {
      if (window.top !== window || globalThis.__terminalDeckPasswords) return;
      const bytes = new Uint8Array(16); crypto.getRandomValues(bytes);
      const nonce = Array.from(bytes, x => x.toString(16).padStart(2, '0')).join('');
      const post = value => window.webkit.messageHandlers.terminalDeckPasswordForm.postMessage({ ...value, nonce });
      const shown = node => {
        if (!(node instanceof HTMLInputElement) || node.disabled || node.readOnly) return false;
        const rect = node.getClientRects()[0];
        if (!rect || rect.width < 8 || rect.height < 8) return false;
        const style = getComputedStyle(node);
        return style.visibility !== 'hidden' && style.display !== 'none' && Number(style.opacity || 1) > 0.05;
      };
      const passwordField = () => Array.from(document.querySelectorAll('input[type="password"]')).find(shown);
      const usernameField = password => {
        let best, rank = 0;
        for (const node of document.querySelectorAll('input')) {
          if (node === password) break;
          if (!shown(node) || !['text', 'email', 'tel'].includes(node.type)) continue;
          const auto = (node.autocomplete || '').toLowerCase();
          const score = auto.includes('username') || auto === 'email' ? 3 : node.type === 'email' ? 2 : 1;
          if (score >= rank) { best = node; rank = score; }
        }
        return best;
      };
      const set = (node, value) => {
        if (!node) return;
        node.focus();
        const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
        setter.call(node, value);
        node.dispatchEvent(new Event('input', { bubbles: true }));
        node.dispatchEvent(new Event('change', { bubbles: true }));
        node.blur();
      };
      const fill = (username, password, replace, expectedNonce, expectedOrigin) => {
        if (expectedNonce !== nonce || location.origin !== expectedOrigin || typeof password !== 'string' || !password) return false;
        const pw = passwordField();
        if (!pw || (!replace && pw.value)) return false;
        const user = usernameField(pw);
        if (user && (!user.value || replace) && username) set(user, username);
        set(pw, password);
        return pw.value === password;
      };
      Object.defineProperty(globalThis, '__terminalDeckPasswords', { value: Object.freeze({ nonce, fill }), writable: false, configurable: false });
      let remembered = null, offered = '', announced = null, scheduled = false;
      const announce = () => {
        scheduled = false;
        const present = !!passwordField();
        if (announced === present) return;
        announced = present; post({ kind: 'form', present });
      };
      const schedule = () => { if (!scheduled) { scheduled = true; queueMicrotask(announce); } };
      const remember = () => {
        const pw = passwordField();
        if (!pw || !pw.value) return;
        const user = usernameField(pw);
        remembered = { username: (user?.value || '').slice(0, 512), password: pw.value.slice(0, 512) };
      };
      const offer = () => {
        remember();
        if (!remembered) return;
        const key = remembered.username + '\u0000' + remembered.password;
        if (key === offered) return;
        offered = key; post({ kind: 'offer', ...remembered });
      };
      document.addEventListener('input', event => {
        if (event.isTrusted && event.target instanceof HTMLInputElement && ['text', 'email', 'password'].includes(event.target.type)) remember();
      }, true);
      document.addEventListener('submit', offer, true);
      document.addEventListener('keydown', event => { if (event.isTrusted && event.key === 'Enter') offer(); }, true);
      document.addEventListener('click', event => {
        if (!event.isTrusted) return;
        const button = event.target instanceof Element ? event.target.closest('button,input[type="submit"],[role="button"]') : null;
        if (button) offer();
      }, true);
      document.addEventListener('DOMContentLoaded', schedule, { once: true });
      new MutationObserver(schedule).observe(document, { subtree: true, childList: true, attributes: true,
        attributeFilter: ['type', 'style', 'class', 'hidden', 'disabled', 'readonly'] });
      schedule();
    })();
    """#
}
