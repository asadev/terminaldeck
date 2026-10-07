import Foundation
import Security
import WebKit
import TerminalDeckNativeCore

/// Run before restoring/navigating browser tabs. Only the signed parent app
/// reads its original key; there is no helper process, key creation, external
/// browser discovery, permission dialog, or plaintext cookie file.
@MainActor
final class NativeBrowserCookieMigration {
    static let shared = NativeBrowserCookieMigration()

    struct ProfileResult: Sendable {
        enum State: String, Sendable { case completed, alreadyCompleted, noSource, incomplete }
        let profileID: String
        var state: State
        var imported = 0
        var keptExisting = 0
        var expired = 0
        var failed = 0
        /// Safe descriptions and counts only, never cookie names or values.
        var errors: [String] = []
    }

    struct Report: Sendable {
        var profiles: [ProfileResult] = []
        var errors: [String] = []
        var imported: Int { profiles.reduce(0) { $0 + $1.imported } }
        var failed: Int { profiles.reduce(0) { $0 + $1.failed } }
        var complete: Bool { errors.isEmpty && profiles.allSatisfy { $0.state != .incomplete } }

        var summary: String {
            if complete {
                return "Browser sign-ins carried over: \(imported) cookies. Existing Safari sign-ins were kept."
            }
            let detail = errors.first ?? profiles.first(where: { !$0.errors.isEmpty })?.errors.first ?? "Cookie migration is incomplete."
            return "Some browser sign-ins could not be carried over. \(detail)"
        }
    }

    private var runs: [String: Task<Report, Never>] = [:]
    private var finishedRoots: Set<String> = []
    private(set) var lastReport: Report?

    /// A failed migration is retryable explicitly; a completed profile is
    /// skipped durably. Share one run per data root to avoid concurrent writes.
    func run(dataRoot: URL, retry: Bool = false) async -> Report {
        let key = dataRoot.standardizedFileURL.path
        if retry && finishedRoots.contains(key) {
            runs[key] = nil
            finishedRoots.remove(key)
        }
        if let task = runs[key] { return await task.value }
        let task = Task { await self.migrate(dataRoot: dataRoot) }
        runs[key] = task
        let report = await task.value
        finishedRoots.insert(key)
        lastReport = report
        return report
    }

    private func migrate(dataRoot: URL) async -> Report {
        var report = Report()
        let sources: [TerminalDeckCookieMigration.Source]
        do {
            sources = try await Task.detached(priority: .utility) {
                try TerminalDeckCookieMigration.sources(dataRoot: dataRoot)
            }.value
        } catch {
            report.errors.append(Self.safeError(error))
            return report
        }

        // Read lazily, only when a supported encrypted source row needs it.
        // A denial is reused across profiles for this run, never repeated.
        var password: Data?
        var keyAttempted = false
        var keyFailure: String?
        defer {
            if let count = password?.count { password?.resetBytes(in: 0..<count) }
        }

        for source in sources {
            if Task.isCancelled {
                report.errors.append("Cookie migration was interrupted. Original browser data was kept and unfinished profiles can be retried.")
                break
            }
            if source.alreadyCompleted {
                report.profiles.append(ProfileResult(profileID: source.profileID, state: .alreadyCompleted))
                continue
            }
            guard source.hasDatabase else {
                // No marker: an older install may supply this profile later.
                report.profiles.append(ProfileResult(profileID: source.profileID, state: .noSource))
                continue
            }
            var result = ProfileResult(profileID: source.profileID, state: .incomplete)
            let snapshot: TerminalDeckCookieMigration.Snapshot
            do {
                snapshot = try await Task.detached(priority: .utility) {
                    try TerminalDeckCookieMigration.snapshot(source, dataRoot: dataRoot)
                }.value
            } catch {
                result.errors.append(Self.safeError(error))
                report.profiles.append(result)
                continue
            }
            if snapshot.needsKey && !keyAttempted {
                keyAttempted = true
                do { password = try Self.originalStoragePassword() }
                catch { keyFailure = Self.safeError(error) }
            }
            let originalPassword = password
            let plan = await Task.detached(priority: .utility) {
                TerminalDeckCookieMigration.plan(snapshot, password: originalPassword)
            }.value
            result.expired = plan.expired
            result.failed = plan.failed
            for reason in TerminalDeckCookieMigration.Rejection.allCases {
                if let count = plan.rejected[reason] { result.errors.append("\(reason.message) (\(count) cookies.)") }
            }
            if plan.rejected[.keyUnavailable] != nil, let keyFailure { result.errors.insert(keyFailure, at: 0) }

            let store = NativeBrowserTabs.shared.store(for: source.profileID == "default" ? "" : source.profileID)
            var existing = Set(await allCookies(in: store).map(identity))
            var written: [HTTPCookie] = []
            var attributeFailures = 0
            for row in plan.cookies {
                if Task.isCancelled { break }
                do {
                    let cookie = try makeCookie(row)
                    let key = identity(cookie)
                    if existing.contains(key) {
                        result.keptExisting += 1
                        continue
                    }
                    await set(cookie, in: store)
                    // Count only cookies confirmed by the final read below.
                    written.append(cookie)
                    existing.insert(key)
                } catch {
                    attributeFailures += 1
                }
            }
            if attributeFailures > 0 {
                result.failed += attributeFailures
                result.errors.append("Safari could not preserve all attributes of \(attributeFailures) source cookies; those cookies were not written.")
            }
            if Task.isCancelled {
                result.errors.append("Cookie migration was interrupted before this profile finished. It can be retried.")
                report.profiles.append(result)
                break
            }
            let retained = await allCookies(in: store)
            let retainedByIdentity = Dictionary(grouping: retained, by: identity)
            for cookie in written {
                if retainedByIdentity[identity(cookie)]?.contains(where: { sameAttributes($0, cookie) }) == true {
                    result.imported += 1
                } else {
                    result.failed += 1
                }
            }
            let refused = written.count - result.imported
            if refused > 0 { result.errors.append("Safari did not retain \(refused) cookies with their original attributes. This profile can be retried.") }
            if result.failed == 0 && result.errors.isEmpty {
                let completion = TerminalDeckCookieMigration.Completion(imported: result.imported,
                    keptExisting: result.keptExisting, expired: result.expired)
                do {
                    try await Task.detached(priority: .utility) {
                        try TerminalDeckCookieMigration.recordCompletion(dataRoot: dataRoot,
                            profileID: source.profileID, completion: completion)
                    }.value
                    result.state = .completed
                } catch { result.errors.append(Self.safeError(error)) }
            }
            report.profiles.append(result)
        }
        return report
    }

    private func allCookies(in store: WKWebsiteDataStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    private func set(_ cookie: HTTPCookie, in store: WKWebsiteDataStore) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.httpCookieStore.setCookie(cookie) { continuation.resume() }
        }
    }

    private struct CookieIdentity: Hashable {
        let domain: String
        let name: String
        let path: String
    }

    private func identity(_ cookie: HTTPCookie) -> CookieIdentity {
        // A signed-in destination wins even if its host/domain-only choice
        // differs from the old cookie with the same effective domain/name/path.
        let domain = cookie.domain.lowercased().drop(while: { $0 == "." })
        return CookieIdentity(domain: String(domain), name: cookie.name, path: cookie.path)
    }

    private struct AttributeFailure: Error {}

    private func makeCookie(_ row: TerminalDeckCookieMigration.Cookie) throws -> HTTPCookie {
        guard let origin = URL(string: "\(row.secure ? "https" : "http")://\(row.host)/") else { throw AttributeFailure() }
        var properties: [HTTPCookiePropertyKey: Any] = [
            .originURL: origin, .name: row.name, .value: row.value, .path: row.path,
        ]
        // Omitting Domain is required for host-only and __Host- cookies.
        if row.domainCookie { properties[.domain] = "." + row.host }
        if row.secure { properties[.secure] = "TRUE" }
        if row.httpOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let expiry = row.expires { properties[.expires] = expiry }
        else { properties[.discard] = "TRUE" }
        if row.sameSite != .unspecified { properties[.sameSitePolicy] = row.sameSite.rawValue }
        guard let cookie = HTTPCookie(properties: properties),
              cookie.domain.lowercased() == (row.domainCookie ? "." : "") + row.host.lowercased(),
              cookie.name == row.name, cookie.value == row.value, cookie.path == row.path,
              cookie.isSecure == row.secure, cookie.isHTTPOnly == row.httpOnly,
              cookie.isSessionOnly == (row.expires == nil),
              expirationMatches(cookie.expiresDate, row.expires),
              site(cookie) == (row.sameSite == .unspecified ? nil : row.sameSite.rawValue) else { throw AttributeFailure() }
        return cookie
    }

    private func sameAttributes(_ saved: HTTPCookie, _ wanted: HTTPCookie) -> Bool {
        saved.domain.lowercased() == wanted.domain.lowercased() && saved.name == wanted.name &&
        saved.path == wanted.path && saved.value == wanted.value && saved.isSecure == wanted.isSecure &&
        saved.isHTTPOnly == wanted.isHTTPOnly && saved.isSessionOnly == wanted.isSessionOnly &&
        site(saved) == site(wanted) && expirationMatches(saved.expiresDate, wanted.expiresDate)
    }

    private func expirationMatches(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): abs(a.timeIntervalSince(b)) < 1
        default: false
        }
    }

    private func site(_ cookie: HTTPCookie) -> String? {
        let policy = cookie.sameSitePolicy?.rawValue.lowercased()
        return policy?.isEmpty == true ? nil : policy
    }

    private struct KeychainFailure: Error, LocalizedError {
        let status: OSStatus
        let operation: String

        var errorDescription: String? {
            let detail: String
            switch status {
            case errSecItemNotFound: detail = "The original Terminal Deck Safe Storage key was not found. Restore that original key to carry over encrypted browser sign-ins."
            case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
                detail = "macOS denied the signed native app access to Terminal Deck's original Safe Storage key. Authorize this app for that existing item in Keychain Access, then retry cookie migration."
            case errSecNotAvailable: detail = "The login Keychain is unavailable. Unlock it, then retry cookie migration."
            default: detail = "macOS could not read Terminal Deck's original Safe Storage key."
            }
            return "\(detail) (\(operation), Keychain status \(status).)"
        }
    }

    /// This is Terminal Deck's original Electron name from src/shared/brand.ts,
    /// not the new shell's display name. Never create or replace this item.
    private static func originalStoragePassword() throws -> Data {
        var wasAllowed: DarwinBoolean = false
        let settingsStatus = SecKeychainGetUserInteractionAllowed(&wasAllowed)
        guard settingsStatus == errSecSuccess else { throw KeychainFailure(status: settingsStatus, operation: "read interaction setting") }
        let disableStatus = SecKeychainSetUserInteractionAllowed(false)
        guard disableStatus == errSecSuccess else { throw KeychainFailure(status: disableStatus, operation: "disable interaction") }
        defer { SecKeychainSetUserInteractionAllowed(wasAllowed.boolValue) }
        let appName = "Terminal Deck"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: appName + " Safe Storage",
            kSecAttrAccount as String: appName,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { throw KeychainFailure(status: status, operation: "read original key") }
        guard let data = item as? Data, !data.isEmpty else {
            throw KeychainFailure(status: errSecDecode, operation: "read empty original key")
        }
        return data
    }

    private static func safeError(_ error: Error) -> String {
        // Only our own typed errors are surfaced. File/database/library errors
        // may contain paths or data and are deliberately reduced to a category.
        if let error = error as? TerminalDeckCookieMigration.Failure { return error.localizedDescription }
        if let error = error as? KeychainFailure { return error.localizedDescription }
        return "Terminal Deck's own browser cookies could not be carried over. Original data was kept."
    }
}
