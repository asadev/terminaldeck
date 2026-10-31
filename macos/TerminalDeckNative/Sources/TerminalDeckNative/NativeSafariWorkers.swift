import Foundation
import WebKit
import TerminalDeckNativeCore
import TerminalDeckBackend

/// Concrete worker dependencies. Profiles are created by the one native
/// metadata owner; pages are enumerated from the actual app-owned WKWebViews,
/// not a second browser registry or guessed cookie partition.
@MainActor
final class NativeSafariWorkers {
    let tabs: NativeBrowserTabs
    let profiles: BackendBrowserProfiles
    private let authorize: BackendBrowserScrapingAuthorize
    private let changed: @MainActor (BackendBrowserProfileState) async throws -> Void
    init(tabs: NativeBrowserTabs, profiles: BackendBrowserProfiles,
         authorize: @escaping BackendBrowserScrapingAuthorize,
         profilesChanged: @escaping @MainActor (BackendBrowserProfileState) async throws -> Void) {
        self.tabs = tabs; self.profiles = profiles; self.authorize = authorize; changed = profilesChanged
    }
    func hooks() -> BackendBrowserWorkerHooks {
        .init(profiles: { [self] caller in try await profileList(caller) },
              createProfile: { [self] caller, name in try await create(caller, name: name) },
              pages: { [self] caller, profileID in try await pages(caller, profileID: profileID) },
              authorize: authorize)
    }
    private func profileList(_ caller: BackendBrowserScrapingCaller) async throws -> [BackendBrowserWorkerProfile] {
        let state = try await profiles.state()
        var result: [BackendBrowserWorkerProfile] = []
        for profile in state.profiles {
            do {
                try await profiles.requireProfile(profile.id)
                try await authorize(caller, "browser.workers", profile.id, nil, .object([]))
                result.append(.init(id: profile.id, name: profile.name, partition: profile.partition))
            } catch let failure as NativeRPCError where ["access-denied", "not-permitted", "profile-retiring"].contains(failure.code) { continue }
        }
        return result
    }
    private func create(_ caller: BackendBrowserScrapingCaller, name: String) async throws -> BackendBrowserWorkerProfile {
        try await authorize(caller, "browser.scraping.workers", nil, nil, .object([.init("name", .string(name))]))
        try Task.checkCancellation()
        let profile = try await profiles.create(name: name)
        let state = try await profiles.state()
        try await changed(state)
        return .init(id: profile.id, name: profile.name, partition: profile.partition)
    }
    private func pages(_ caller: BackendBrowserScrapingCaller, profileID: String) async throws -> NativeRPCValue {
        try await profiles.requireProfile(profileID)
        try await authorize(caller, "browser.workers.pages", profileID, nil, .object([]))
        let profile = try await profiles.state().resolve(profileID)
        let store = tabs.store(for: profile.id)
        var pages: [NativeRPCValue] = []
        for tab in tabs.tabs {
            guard !tab.isolated, tab.handoverPrompt == nil, let view = tab.webView,
                  view.configuration.websiteDataStore === store, let url = view.url,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
            try await authorize(caller, "browser.workers.pages", profile.id, url, .object([.init("tabId", .string(tab.id))]))
            // Authority awaited. The object/store/document may have changed.
            guard tabs.tab(tab.id)?.webView === view, view.configuration.websiteDataStore === store,
                  view.url == url, tab.handoverPrompt == nil else { continue }
            pages.append(.object([.init("url", .string(url.absoluteString)), .init("title", .string(view.title ?? ""))]))
        }
        return .array(pages)
    }
    /// The legacy browser:create profileId is a worker selector, not authority
    /// to choose another private jar. Native profile-picker changes use their
    /// own explicit profile operation and the direct native tab API.
    func creationProfile(_ context: NativeRPCContext, requestedID: String?, workers: BackendBrowserWorkers) async throws -> BackendBrowserWebsiteProfile {
        let caller = BackendBrowserScrapingCaller.native(context)
        let state = try await profiles.state()
        let selected: BackendBrowserProfile
        if let requestedID, !requestedID.isEmpty {
            let fleet = try await workers.view(caller)
            if fleet["workers"].elements?.contains(where: { $0["profileId"].string == requestedID }) == true {
                selected = try state.resolve(requestedID)
            } else { selected = try state.resolve(nil) }
        } else { selected = try state.resolve(nil) }
        try await profiles.requireProfile(selected.id)
        try await authorize(caller, "browser:create", selected.id, nil, .object([.init("profileId", requestedID.map(NativeRPCValue.string) ?? .null)]))
        return .init(id: selected.id, name: selected.name, partition: selected.partition)
    }
}
