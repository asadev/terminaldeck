import Foundation

// Settings → Browser: the readers and sentences of `BrowserSection.tsx`, with
// the parsers it uses from `settings-bridge.ts` and `browser/accounts-bridge.ts`.
// Tests: BrowserSettingsTests.swift mirrors BrowserSection.test.tsx's pure parts.

public struct BrowserSettingsDetected: Equatable, Sendable, Identifiable {
    public enum Access: String, Sendable { case ok, blocked, missing }
    public var id: String
    public var name: String
    public var access: Access
    public var note: String?
    public var profiles: [String]

    public init(id: String, name: String, access: Access = .ok, note: String? = nil, profiles: [String] = []) {
        self.id = id
        self.name = name
        self.access = access
        self.note = note
        self.profiles = profiles
    }
}

public struct BrowserSettingsDevUrl: Equatable, Sendable, Identifiable {
    public var url: String
    public var title: String?
    /// bookmark, history or session.
    public var source: String
    public var detail: String?
    public var approximate: Bool
    public var id: String { url }
}

public struct BrowserSettingsCookieSource: Equatable, Sendable, Identifiable {
    public var browserId: String
    public var browserName: String
    public var profileId: String
    public var profileName: String
    public var keychainItem: Bool
    public var id: String { "\(browserId)/\(profileId)" }
}

public struct BrowserSettingsImports: Equatable, Sendable {
    public var present: Int
    public var recorded: Int
    public var importedAt: Double?
    public var source: String
    public var supported: Bool
}

public struct BrowserSettingsStored: Equatable, Sendable {
    public var cookieCount: Int
    public var domainCount: Int
    public var cacheBytes: Int?
}

public struct BrowserSettingsProfile: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var isDefault: Bool
}

public struct BrowserSettingsProfiles: Equatable, Sendable {
    public var profiles: [BrowserSettingsProfile]
    public var activeId: String
    public var active: BrowserSettingsProfile? { profiles.first { $0.id == activeId } }
}

public struct BrowserSettingsLogin: Equatable, Sendable, Identifiable {
    public var profileId: String
    public var origin: String
    public var username: String
    public var updatedAt: Double
    public var id: String { "\(origin)|\(username)" }
}

public struct BrowserSettingsPasswordStore: Equatable, Sendable {
    public enum Fault: String, Sendable { case none, tampered, unreadable }
    public var available: Bool
    public var path: String
    public var exists: Bool
    public var fault: Fault
    public var message: String
}

public enum BrowserSettings {
    // MARK: Readers

    public static func browsers(_ raw: CodingAIJSON) -> [BrowserSettingsDetected] {
        (raw.array ?? []).compactMap { entry in
            guard let id = entry["id"].string else { return nil }
            return BrowserSettingsDetected(
                id: id, name: entry["name"].text ?? id,
                access: entry["access"].string.flatMap(BrowserSettingsDetected.Access.init(rawValue:)) ?? .missing,
                note: entry["note"].text,
                profiles: (entry["profiles"].array ?? []).compactMap { $0["id"].string })
        }
    }

    public static func scan(_ raw: CodingAIJSON) -> (urls: [BrowserSettingsDevUrl], problems: [String]) {
        var seen = Set<String>()
        let urls = (raw["urls"].array ?? []).compactMap { hit -> BrowserSettingsDevUrl? in
            guard let url = hit["url"].string, !seen.contains(url) else { return nil }
            seen.insert(url)
            let source = hit["source"].string ?? ""
            return BrowserSettingsDevUrl(url: url, title: hit["title"].string,
                                         source: ["bookmark", "history", "session"].contains(source) ? source : "history",
                                         detail: hit["detail"].string, approximate: hit["approximate"].isTrue)
        }
        var seenProblems = Set<String>()
        let problems = (raw["problems"].array ?? []).compactMap { problem -> String? in
            guard let message = problem["message"].string, !message.isEmpty, !seenProblems.contains(message) else { return nil }
            seenProblems.insert(message)
            return message
        }
        return (urls, problems)
    }

    public static func cookieSources(_ raw: CodingAIJSON) -> [BrowserSettingsCookieSource] {
        (raw.array ?? []).compactMap { source in
            guard let browserId = source["browserId"].string, let profileId = source["profileId"].string else { return nil }
            return BrowserSettingsCookieSource(browserId: browserId, browserName: source["browserName"].text ?? browserId,
                                               profileId: profileId, profileName: source["profileName"].text ?? profileId,
                                               keychainItem: source["keychainItem"].isTrue)
        }
    }

    public static func imports(_ raw: CodingAIJSON) -> BrowserSettingsImports {
        BrowserSettingsImports(present: Int(raw["present"].number ?? 0), recorded: Int(raw["recorded"].number ?? 0),
                               importedAt: raw["importedAt"].number, source: raw["source"].string ?? "",
                               supported: raw["supported"].isTrue)
    }

    /// `toCookieImportReport`: what the import says, and whether it worked.
    public static func importReport(_ raw: CodingAIJSON) -> (ok: Bool, message: String) {
        (raw["ok"].isTrue, raw["message"].text ?? "The import finished without saying what happened.")
    }

    public static func stored(_ raw: CodingAIJSON) -> BrowserSettingsStored {
        BrowserSettingsStored(cookieCount: Int(raw["cookieCount"].number ?? 0), domainCount: Int(raw["domainCount"].number ?? 0),
                              cacheBytes: raw["cacheBytes"].number.map { Int($0) })
    }

    public static func clearMessage(_ raw: CodingAIJSON) -> String { raw["message"].text ?? "Nothing to report." }

    /// `readProfileState`: nil when there is no profile at all.
    public static func profiles(_ raw: CodingAIJSON) -> BrowserSettingsProfiles? {
        guard let rows = raw["profiles"].array else { return nil }
        let profiles = rows.compactMap { row -> BrowserSettingsProfile? in
            guard let id = row["id"].string, let name = row["name"].string else { return nil }
            return BrowserSettingsProfile(id: id, name: name, isDefault: row["isDefault"].isTrue)
        }
        guard let first = profiles.first else { return nil }
        let active = raw["activeId"].string.flatMap { id in profiles.contains { $0.id == id } ? id : nil } ?? first.id
        return BrowserSettingsProfiles(profiles: profiles, activeId: active)
    }

    public static func logins(_ raw: CodingAIJSON) -> [BrowserSettingsLogin] {
        (raw.array ?? []).compactMap { row in
            guard let origin = row["origin"].string, !origin.isEmpty else { return nil }
            return BrowserSettingsLogin(profileId: row["profileId"].string ?? "", origin: origin,
                                        username: row["username"].string ?? "", updatedAt: row["updatedAt"].number ?? 0)
        }
    }

    public static func passwordStore(_ raw: CodingAIJSON) -> BrowserSettingsPasswordStore? {
        guard raw.isObject else { return nil }
        return BrowserSettingsPasswordStore(available: raw["available"].isTrue, path: raw["path"].string ?? "",
                                            exists: raw["exists"].isTrue,
                                            fault: raw["fault"].string.flatMap(BrowserSettingsPasswordStore.Fault.init(rawValue:)) ?? .none,
                                            message: raw["message"].string ?? "")
    }

    // MARK: Sentences

    public static func blockedNote(_ blocked: [BrowserSettingsDetected]) -> String? {
        if blocked.isEmpty { return nil }
        if blocked.count == 1 {
            let only = blocked[0]
            return only.note ?? "\(only.name)’s data is protected by the system. Grant Full Disk Access to read it."
        }
        let names = blocked.map(\.name)
        let list = "\(names.dropLast().joined(separator: ", ")) and \(names.last!)"
        return "macOS will not let this app read \(list) until it is given full disk access. Open Privacy & Security → Full Disk Access, add this app, then run the import again. One grant covers all of them."
    }

    public static func buttonLabel(_ browser: BrowserSettingsDetected) -> String {
        if browser.access == .blocked { return browser.name }
        return browser.profiles.count > 1 ? "\(browser.name) (\(browser.profiles.count) profiles)" : browser.name
    }

    public static func noteFor(_ hit: BrowserSettingsDevUrl) -> String {
        let labels = ["bookmark": "Bookmark", "history": "History", "session": "Open tab"]
        let source = labels[hit.source] ?? "History"
        var parts = [source]
        if let title = hit.title, !title.isEmpty { parts.append(title) }
        if let detail = hit.detail, !detail.isEmpty, detail != source { parts.append(detail) }
        if hit.approximate { parts.append("approximate") }
        return parts.joined(separator: " · ")
    }

    /// `groupSources`: one row per browser, its profiles in order.
    public static func groupSources(_ sources: [BrowserSettingsCookieSource]) -> [(browserId: String, browserName: String, profiles: [BrowserSettingsCookieSource])] {
        var order: [String] = []
        var groups: [String: (String, [BrowserSettingsCookieSource])] = [:]
        for source in sources {
            if groups[source.browserId] == nil {
                order.append(source.browserId)
                groups[source.browserId] = (source.browserName, [])
            }
            groups[source.browserId]?.1.append(source)
        }
        return order.map { ($0, groups[$0]!.0, groups[$0]!.1) }
    }

    public static func profileOptionLabel(_ source: BrowserSettingsCookieSource) -> String {
        source.profileName == source.profileId ? source.profileId : "\(source.profileName) (\(source.profileId))"
    }

    public static func whenImported(_ at: Double?, now: Double) -> String {
        guard let at, at.isFinite else { return "" }
        let minutes = Int(((now - at) / 60_000).rounded())
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) minute\(minutes == 1 ? "" : "s") ago" }
        let hours = Int((Double(minutes) / 60).rounded())
        if hours < 24 { return "\(hours) hour\(hours == 1 ? "" : "s") ago" }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
        return formatter.string(from: Date(timeIntervalSince1970: at / 1000))
    }

    public static func importedCount(_ status: BrowserSettingsImports) -> String {
        if status.recorded == 0 { return "No cookies have been imported." }
        let place = status.source.isEmpty ? "" : " from \(status.source)"
        if status.present == status.recorded {
            return "\(status.present) imported cookie\(status.present == 1 ? "" : "s")\(place)."
        }
        return "\(status.present) of \(status.recorded) imported cookies\(place) are still here — the rest have expired."
    }

    public static func importedSummary(_ status: BrowserSettingsImports, now: Double) -> String {
        let count = importedCount(status)
        guard status.recorded != 0, status.importedAt != nil else { return count }
        return "\(count) Last imported \(whenImported(status.importedAt, now: now))."
    }

    /// `formatBytes`.
    public static func bytes(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }

    public static func keptSummary(_ stored: BrowserSettingsStored) -> String {
        guard let cacheBytes = stored.cacheBytes else {
            let cookies = stored.cookieCount == 0 ? "No cookies" : "\(stored.cookieCount) cookies from \(stored.domainCount) sites"
            return "\(cookies). Cache size unavailable."
        }
        if stored.cookieCount == 0 && cacheBytes == 0 { return "Nothing kept yet." }
        if stored.cookieCount == 0 { return "No cookies, and \(bytes(cacheBytes)) of cached pages." }
        let sites = "\(stored.domainCount) site\(stored.domainCount == 1 ? "" : "s")"
        let cookies = "\(stored.cookieCount) cookie\(stored.cookieCount == 1 ? "" : "s") from \(sites)"
        return cacheBytes == 0 ? "\(cookies), and nothing cached." : "\(cookies), and \(bytes(cacheBytes)) of cached pages."
    }

    public static func profileCaption(_ profile: BrowserSettingsProfile, activeId: String) -> String {
        var parts: [String] = []
        if profile.id == activeId { parts.append("New tabs open in this one") }
        if profile.isDefault { parts.append("Cannot be deleted") }
        return parts.joined(separator: " · ")
    }

    public static func savedSummary(_ count: Int, profileName: String) -> String {
        if count == 0 { return "Nothing saved in \(profileName) yet. Signing in to a site in the browser offers to remember it." }
        return "\(count) saved login\(count == 1 ? "" : "s") in \(profileName)."
    }

    public static func forgetAllConfirm(_ total: Int, faulted: Bool = false) -> String {
        if faulted { return "Delete the saved-login file? Its contents did not verify, so what is in it is unknown, and this cannot be undone." }
        if total == 1 { return "Forget the one saved password? This is across every profile and cannot be undone." }
        return "Forget all \(total) saved passwords? This is across every profile and cannot be undone."
    }

    public static func forgetAllHelp(_ total: Int, faulted: Bool) -> String {
        if faulted { return "Deletes the file that did not verify, so passwords can be saved again." }
        return total == 0 ? "There are no saved passwords to forget." : "Removes every saved password, in every profile."
    }

    /// `loginLabel`.
    public static func loginLabel(_ entry: BrowserSettingsLogin) -> String {
        let site = entry.origin.hasPrefix("https://") ? String(entry.origin.dropFirst(8)) : entry.origin
        return entry.username.isEmpty ? site : "\(site) — \(entry.username)"
    }

    public static func removedImported(_ count: Int) -> String {
        "Removed \(count) imported cookie\(count == 1 ? "" : "s"). Sign-ins made inside the browser tab are untouched."
    }

    /// `errorText`: the engine's own sentence, without "Error:" prefixes.
    public static func errorText(_ message: String, fallback: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return fallback }
        let tail = trimmed.components(separatedBy: "Error:").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return tail.isEmpty ? trimmed : tail
    }
}
