import Foundation
import WebKit
import TerminalDeckNativeCore
import TerminalDeckBackend

/// Actual website-store retirement supplied to BackendBrowserProfiles.delete.
/// No profile jar or credentials are read in init. Existing tab stores remain
/// the sole owners, and the root decides whether held tabs may be closed.
@MainActor
final class NativeSafariProfiles {
    let tabs: NativeBrowserTabs
    let bindings: BackendBrowserBindings
    private let authorizeRetirement: @MainActor (String, [String]) async throws -> Void
    private let stopProfileWork: @MainActor (String) async throws -> Void
    private let requireKnownProfile: @MainActor (String) async throws -> Void
    private let authorizeRead: @MainActor (String) async throws -> Void
    init(tabs: NativeBrowserTabs, bindings: BackendBrowserBindings,
         authorizeRetirement: @escaping @MainActor (String, [String]) async throws -> Void,
         stopProfileWork: @escaping @MainActor (String) async throws -> Void,
         requireKnownProfile: @escaping @MainActor (String) async throws -> Void,
         authorizeRead: @escaping @MainActor (String) async throws -> Void) {
        self.tabs = tabs; self.bindings = bindings; self.authorizeRetirement = authorizeRetirement
        self.stopProfileWork = stopProfileWork
        self.requireKnownProfile = requireKnownProfile; self.authorizeRead = authorizeRead
    }
    /// Metadata is removed only after this succeeds. No private filesystem
    /// paths are guessed or deleted, and isolated jars are never selected.
    func deleteWebsiteData(_ profileID: String) async throws {
        guard BackendBrowserProfiles.validID(profileID), BackendBrowserProfiles.normalizedID(profileID) != "default" else {
            throw NativeRPCError.invalidArguments("Only a known non-default browser profile can be retired.")
        }
        try await requireKnownProfile(profileID)
        let selected = tabs.tabs.filter { !$0.isolated && BackendBrowserProfiles.normalizedID($0.profile) == BackendBrowserProfiles.normalizedID(profileID) }
        let ids = selected.map(\.id)
        try await authorizeRetirement(profileID, ids)
        try Task.checkCancellation()
        // Includes bound downloads, explicit authenticated HTTP fetches,
        // asset/capture work and lift/queued-seed writers for this profile.
        // Clearing must not race an old authorized writer that refills the jar.
        try await stopProfileWork(profileID)
        // A WebKit clear concurrent with a live request can repopulate the jar.
        // Every actual page holding it is stopped and closed first.
        for id in ids { tabs.close(id); bindings.closed(id) }
        let store = tabs.store(for: profileID)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { continuation.resume() }
        }
        try Task.checkCancellation()
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in store.httpCookieStore.getAllCookies { continuation.resume(returning: $0) } }
        let records: [WKWebsiteDataRecord] = await withCheckedContinuation { continuation in
            store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { continuation.resume(returning: $0) }
        }
        guard cookies.isEmpty, records.isEmpty else {
            throw NativeRPCError(code: "profile-clear-incomplete", message: "WebKit still reports data in this profile. Its metadata was preserved; retry clearing it.")
        }
    }
    func websiteRecords(_ profileID: String) async throws -> NativeRPCValue {
        guard BackendBrowserProfiles.validID(profileID) else { throw NativeRPCError.invalidArguments("Invalid profile id.") }
        try await requireKnownProfile(profileID); try await authorizeRead(profileID)
        let store = tabs.store(for: profileID)
        let records: [WKWebsiteDataRecord] = await withCheckedContinuation { continuation in
            store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { continuation.resume(returning: $0) }
        }
        // These are displayed-site records. They must never be relabelled as
        // exact origins, byte counts or private storage paths.
        return .array(records.sorted { $0.displayName < $1.displayName }.map { record in
            .object([.init("displayName", .string(record.displayName)), .init("dataTypes", .array(record.dataTypes.sorted().map(NativeRPCValue.string))),
                .init("exactOrigin", .null), .init("bytes", .null), .init("path", .null)])
        })
    }
}
