import Foundation
import WebKit
import TerminalDeckNativeCore

@MainActor
final class NativeCloudBrowserCookies: NSObject, CloudBrowserCookiePort, WKHTTPCookieStoreObserver {
    private let bridge: NativeBrowserDataBridge
    private let beforeFirstNavigation: @MainActor @Sendable (String) -> Bool
    private let changed: @MainActor @Sendable (String) -> Void
    private var stores: [String: WKHTTPCookieStore] = [:]
    init(bridge: NativeBrowserDataBridge, beforeFirstNavigation: @escaping @MainActor @Sendable (String) -> Bool,
         changed: @escaping @MainActor @Sendable (String) -> Void) {
        self.bridge = bridge; self.beforeFirstNavigation = beforeFirstNavigation; self.changed = changed
    }
    func observe(profileId: String) throws {
        guard stores[profileId] == nil else { return }
        let store = try bridge.cloudCookieStore(profileID: profileId)
        stores[profileId] = store; store.add(self)
    }
    func close() { for store in stores.values { store.remove(self) }; stores.removeAll() }
    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        for (id, store) in stores where store === cookieStore { changed(id) }
    }
    func cookies(profileId: String) async throws -> [CloudBrowserCookie] { try await bridge.cloudCookies(profileID: profileId) }
    func insertKeepingLocal(_ cookie: CloudBrowserCookie) async throws -> CloudApplyStatus {
        try await bridge.cloudInsertKeepingLocal(cookie, beforeFirstNavigation: { self.beforeFirstNavigation(cookie.profileId) })
    }
    func needsSignInSites(profileId: String) async throws -> Set<String> { try await bridge.cloudNeedsSignIn(profileID: profileId) }
}
