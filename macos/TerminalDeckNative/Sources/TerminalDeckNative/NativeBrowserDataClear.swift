import Foundation
import WebKit
import TerminalDeckBackend
import TerminalDeckNativeCore

/// HOOTFIX sweep (2026-10-09): Settings → Browser → "Clear browsing data" always answered
/// "…unavailable until the app-owned Safari data service is connected" because production never
/// supplied one. This IS that service: the browser tab's own persistent stores (the default
/// profile and every saved profile, the same `NativeBrowserTabs.store(for:)` instances the tabs
/// use), every website data type, all time. The app's own engine pages use no profile store.
struct NativeBrowserDataClear: BackendAppSettingsBrowserData {
    func clearStorageCacheAndAuthentication() async throws { await Self.clear() }

    @MainActor private static func clear() async {
        let tabs = NativeBrowserTabs.shared
        var seen = Set<ObjectIdentifier>()
        let stores = ([""] + tabs.profiles.map(\.id)).map { tabs.store(for: $0) }.filter { seen.insert(ObjectIdentifier($0)).inserted }
        for store in stores {
            await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        }
    }
}
