import AppKit
import Foundation
import WebKit
import TerminalDeckBackend
import TerminalDeckNativeCore

/// One explicit app-owned page and content-rule store. No default rule store,
/// system Safari instance or website credential store is discovered here.
@MainActor
final class NativeSafariProfileArmingRules {
    private weak var webView: WKWebView?
    let tabID: String
    let profileID: String
    let dataRoot: URL
    private let store: WKContentRuleListStore
    private let authorize: BackendBrowserScrapingAuthorize
    private let report: @MainActor (String) -> Void
    private var installed: WKContentRuleList?
    private var installedID: String?
    private var epoch = 0
    init(webView: WKWebView, tabID: String, profileID: String, dataRoot: URL, ruleStore: WKContentRuleListStore,
         authorize: @escaping BackendBrowserScrapingAuthorize, report: @escaping @MainActor (String) -> Void) {
        self.webView = webView; self.tabID = tabID; self.profileID = profileID; self.dataRoot = dataRoot
        store = ruleStore; self.authorize = authorize; self.report = report
        // The runtime creates ruleStore from its authorized explicit root.
        // WKContentRuleListStore exposes no public URL getter to re-inspect it.
    }

    func apply(caller: BackendBrowserScrapingCaller, target: BackendBrowserCaptureTarget,
               plan: BackendWebKitProfileArmingRulePlan) async throws {
        guard target.tabID == tabID, target.profileID == profileID, let view = webView else {
            throw NativeRPCError(code: "profile-rule-target", message: "This policy does not name the adapter's live WebKit tab/profile.")
        }
        guard plan.origin == BackendBrowserOrigin.exact(target.pageURL.absoluteString) else {
            throw NativeRPCError(code: "profile-rule-origin", message: "This content rule plan belongs to a different top-page origin.")
        }
        try await authorize(caller, "browser.profile-arm.rules", profileID, target.pageURL, plan.wireValue)
        if !plan.needsInstallation { await remove(); return }
        epoch += 1; let current = epoch
        let identifier = "td-profile-" + UUID().uuidString.lowercased()
        let rule: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: plan.encodedRules) { list, error in
                if let error { continuation.resume(throwing: error) }
                else if let list { continuation.resume(returning: list) }
                else { continuation.resume(throwing: NativeRPCError(code: "profile-rule-compile", message: "WebKit returned no compiled content rules.")) }
            }
        }
        do {
            try Task.checkCancellation()
            try await authorize(caller, "browser.profile-arm.rules", profileID, target.pageURL, plan.wireValue)
            guard epoch == current, webView === view else {
                throw NativeRPCError(code: "profile-rule-stale", message: "This tab stopped arming while its content rules compiled.")
            }
            let old = installed, oldID = installedID
            view.configuration.userContentController.add(rule)
            if let old { view.configuration.userContentController.remove(old) }
            installed = rule; installedID = identifier
            if let oldID { await removeCompiled(oldID) }
        } catch { await removeCompiled(identifier); throw error }
    }

    /// Cleanup uses the already-owned rule object and never deletes other
    /// profiles' rule lists, default store state or unrelated content scripts.
    func remove() async {
        epoch += 1
        let old = installed, id = installedID
        installed = nil; installedID = nil
        if let old { webView?.configuration.userContentController.remove(old) }
        if let id { await removeCompiled(id) }
    }
    func detach() async { await remove(); webView = nil }
    private func removeCompiled(_ id: String) async {
        await withCheckedContinuation { continuation in
            store.removeContentRuleList(forIdentifier: id) { [weak self] error in
                if let error { self?.report("The inactive content-rule cache could not be removed: \(error.localizedDescription)") }
                continuation.resume()
            }
        }
    }
}

/// Delegate seam only: the existing navigation/UI delegates call these methods.
/// It never replaces a delegate, creates a WKWebView, reads a real profile or
/// discovers a user's application data. Explicit start is the only watch entry.
@MainActor
final class NativeSafariProfileArming {
    private weak var webView: WKWebView?
    private let manager: BackendWebKitProfileArming
    private let caller: BackendBrowserScrapingCaller
    private let tabID: String
    private let profileID: String
    private let report: @MainActor (String) -> Void
    private var token: BackendWebKitProfileArming.Token?
    private var starting = false
    private var closed = false
    init(webView: WKWebView, tabID: String, profileID: String, manager: BackendWebKitProfileArming,
         caller: BackendBrowserScrapingCaller, report: @escaping @MainActor (String) -> Void) {
        self.webView = webView; self.tabID = tabID; self.profileID = profileID
        self.manager = manager; self.caller = caller; self.report = report
    }
    func start() async throws {
        guard token == nil, !starting, !closed else { return }
        guard let view = webView else { throw NativeRPCError(code: "profile-tab-closed", message: "The WebKit tab is no longer live.") }
        starting = true; defer { starting = false }
        let watched = try await manager.watch(target: .init(tabID: tabID, profileID: profileID,
            pageURL: view.url ?? URL(string: "about:blank")!, title: view.title ?? ""), caller: caller)
        if closed { try await manager.close(watched); throw NativeRPCError(code: "profile-tab-closed", message: "This tab closed while profile arming was starting.") }
        token = watched
    }
    /// Await from the existing async navigation decision before returning allow.
    /// Compilation after didCommit can miss a page's first subresource requests.
    func prepareNavigation(_ url: URL, canvasHex: String?) async throws {
        guard let token, let view = webView else { throw NativeRPCError(code: "profile-not-started", message: "Start this tab's profile lifecycle before navigating.") }
        NativeSafariProfileArmingBackground.apply(to: view, url: url.absoluteString, canvasHex: canvasHex)
        _ = try await manager.navigationStarted(token, url: url)
    }
    func committed() async throws {
        guard let token, let view = webView, let url = view.url else { return }
        _ = try await manager.navigationCommitted(token, url: url, title: view.title ?? "")
    }
    func settled(requestedURL: URL, httpStatus: Int?, error: (any Error)? = nil) async {
        guard let token else { return }
        do {
            let failure = error.map { NativeRPCError.wrapping($0).wireValue } ?? .null
            _ = try await manager.navigationFinished(token, requestedURL: requestedURL, httpStatus: httpStatus, failure: failure)
        } catch { report(error.localizedDescription) }
    }
    func yieldToDrive() async throws { if let token { _ = try await manager.yieldToDrive(token) } }
    func freedByDrive() async throws { if let token { _ = try await manager.freedByDrive(token) } }
    /// Must be awaited while the runtime still resolves the real tab. The
    /// network capture owner's stop then drains before the WKWebView is removed.
    func close() async throws {
        closed = true
        if let token { try await manager.close(token); self.token = nil }
        webView = nil
    }
}

@MainActor
enum NativeSafariProfileArmingBackground {
    /// Port of browser-background.ts. Eight-digit canvas tokens discard alpha;
    /// no page can supply a malformed color to WebKit or make the shell drift.
    static func canvas(_ raw: String?) -> NSColor? {
        guard let raw else { return nil }
        let clean = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard clean.hasPrefix("#") else { return nil }
        let digits = String(clean.dropFirst())
        guard digits.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdef").contains($0) }) else { return nil }
        let expanded: String
        if digits.count == 3 { expanded = digits.map { String(repeating: String($0), count: 2) }.joined() }
        else if digits.count == 6 || digits.count == 8 { expanded = String(digits.prefix(6)) }
        else { return nil }
        guard let value = UInt64(expanded, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                       green: CGFloat((value >> 8) & 255) / 255, blue: CGFloat(value & 255) / 255, alpha: 1)
    }
    static func apply(to view: WKWebView, url: String, canvasHex: String?) {
        let address = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        view.underPageBackgroundColor = address.hasPrefix("http://") || address.hasPrefix("https://") ? .white : canvas(canvasHex) ?? .white
    }
}
