import Foundation

/// Session updates (the provider hooks), the native screen's pure half — the
/// Swift reading of `components/HooksPanel.tsx` and `components/HooksOffer.tsx`,
/// worded exactly as the page words them. Channels: `hooks:status`,
/// `hooks:install`, `hooks:remove`, `hooks:server`, and for the one-time ask in
/// the sidebar `hooks:offer`, `hooks:offer-accept`, `hooks:offer-decline`.

public enum HookInstallState: String, Sendable, Equatable {
    case none, partial, complete, stale, error
}

public struct HookProviderStatus: Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var file: String
    public var fileExists: Bool
    public var state: HookInstallState
    public var installedEvents: [String]
    public var staleEvents: [String]
    public var missingEvents: [String]
    public var foreignHooks: Int
    public var foreignOwners: [String]
    public var backupPath: String?
    public var message: String

    public init(id: String, label: String, file: String, fileExists: Bool = true, state: HookInstallState,
                installedEvents: [String] = [], staleEvents: [String] = [], missingEvents: [String] = [],
                foreignHooks: Int = 0, foreignOwners: [String] = [], backupPath: String? = nil, message: String = "") {
        self.id = id
        self.label = label
        self.file = file
        self.fileExists = fileExists
        self.state = state
        self.installedEvents = installedEvents
        self.staleEvents = staleEvents
        self.missingEvents = missingEvents
        self.foreignHooks = foreignHooks
        self.foreignOwners = foreignOwners
        self.backupPath = backupPath
        self.message = message
    }

    public init?(json: Any?) {
        guard let row = json as? [String: Any], let id = row["id"] as? String, !id.isEmpty else { return nil }
        self.init(id: id, label: row["label"] as? String ?? id, file: row["file"] as? String ?? "",
                  fileExists: row["fileExists"] as? Bool ?? false,
                  state: HookInstallState(rawValue: row["state"] as? String ?? "") ?? .none,
                  installedEvents: DeviceJSON.strings(row["installedEvents"]), staleEvents: DeviceJSON.strings(row["staleEvents"]),
                  missingEvents: DeviceJSON.strings(row["missingEvents"]), foreignHooks: Int(DeviceJSON.number(row["foreignHooks"])),
                  foreignOwners: DeviceJSON.strings(row["foreignOwners"]),
                  backupPath: (row["backupPath"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                  message: row["message"] as? String ?? "")
    }

    public static func list(_ json: Any?) -> [HookProviderStatus] {
        (json as? [Any] ?? []).compactMap(HookProviderStatus.init(json:))
    }
}

public struct HookWriteResult: Equatable, Sendable {
    public var ok: Bool
    public var message: String

    public init(ok: Bool, message: String) {
        self.ok = ok
        self.message = message
    }

    public init(json: Any?) {
        let row = json as? [String: Any] ?? [:]
        self.init(ok: row["ok"] as? Bool ?? false, message: row["message"] as? String ?? "")
    }
}

public struct HookServerInfo: Equatable, Sendable {
    public var address: String?
    public var running: Bool
    public var error: String?

    public init(address: String? = nil, running: Bool, error: String? = nil) {
        self.address = address
        self.running = running
        self.error = error
    }

    public init(json: Any?) {
        let row = json as? [String: Any] ?? [:]
        self.init(address: row["address"] as? String, running: row["running"] as? Bool ?? false,
                  error: (row["error"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }
}

public enum HooksRules {
    /// The heading the page gives itself (read by assistive tech; not drawn).
    public static let heading = "Session updates"

    /// The line under the heading. `section` is Settings' name for the assistants page.
    public static func subtitle(section: String = "Coding AI") -> String {
        "One switch per assistant. Which assistants you have, and who each is signed in as, is in Settings → \(section)."
    }

    public static func stateLabel(_ state: HookInstallState) -> String {
        switch state {
        case .complete: "Reporting"
        case .stale: "Out of date"
        case .partial: "Half set up"
        case .none: "Not reporting"
        case .error: "Cannot read its settings"
        }
    }

    public static func consequence(_ state: HookInstallState) -> String {
        switch state {
        case .complete: "Its tabs show working, waiting for you, or done."
        case .stale: "It is reporting to an address this app no longer listens on."
        case .partial: "Some steps report and some do not, so a tab can go quiet mid-run."
        case .none: "Its tabs cannot tell whether it is working or waiting for you."
        case .error: "Its settings file could not be read, so nothing here will write to it."
        }
    }

    /// The row's main button: a repair for a stale or half setup, never a write against a file it could not read.
    public static func primaryAction(_ state: HookInstallState) -> (label: String, enabled: Bool) {
        switch state {
        case .complete: ("Set up again", true)
        case .stale, .partial: ("Fix it", true)
        case .error: ("Turn on", false)
        case .none: ("Turn on", true)
        }
    }

    /// Turn off only when something of ours is actually there.
    public static func canRemove(_ status: HookProviderStatus) -> Bool {
        status.state == .complete || status.state == .stale || status.state == .partial
    }

    /// `3 hooks here belong to another tool. They are never modified or removed.`
    public static func foreignNote(_ status: HookProviderStatus) -> String? {
        guard status.foreignHooks > 0 else { return nil }
        let named = status.foreignOwners.filter { !$0.isEmpty }
        let owner = named.isEmpty ? "another tool" : named.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " and ")
        let count = status.foreignHooks
        return "\(count) hook\(count == 1 ? "" : "s") here belong\(count == 1 ? "s" : "") to \(owner). \(count == 1 ? "It is" : "They are") never modified or removed."
    }

    /// Shown only while the endpoint is not running: what that costs, and why when it is known.
    public static func endpointLine(_ server: HookServerInfo?) -> String {
        if let server, server.running { return "Listening on \(server.address ?? "")." }
        if let why = server?.error {
            return "The local endpoint is not running, so hooks have nowhere to report to: \(why)"
        }
        return "The local endpoint is not running, so hooks have nowhere to report to."
    }

    /// The promise at the confirm step of Turn off, and the backup when there is one.
    public static func removalPromise(file: String, backupPath: String?) -> String {
        let promise = "Only our own entries are removed from \(file). Everything else stays."
        return backupPath.map { "\(promise) The original is still at \($0)." } ?? promise
    }

    /// The button's hover: which file it writes.
    public static func writesFile(_ file: String) -> String { "Writes \(file)" }

    public static let emptyTitle = "Nothing to report on yet"

    public static func emptyMessage(section: String = "Coding AI") -> String {
        "This is a setting for the coding assistants you have installed, and there are none on this machine yet. Install one from Settings → \(section), then press Refresh."
    }
}

// MARK: - The one-time ask in the sidebar (HooksOffer)

public struct HooksOfferProvider: Equatable, Sendable, Identifiable {
    public var id: String
    public var label: String
    public var file: String
}

public struct HooksOfferState: Equatable, Sendable {
    public var providers: [HooksOfferProvider]
    /// Steps still the person's own after a clean accept, shown verbatim.
    public var followUps: [String]

    public static let none = HooksOfferState(providers: [], followUps: [])

    /// `hooks:offer`'s verdict. Anything unreadable, or `show: false`, is nothing to draw.
    public init(json: Any?) {
        guard let row = json as? [String: Any], row["show"] as? Bool == true, let eligible = row["eligible"] as? [Any] else {
            self = .none
            return
        }
        providers = eligible.compactMap { entry in
            guard let item = entry as? [String: Any],
                  let id = item["id"] as? String, !id.isEmpty,
                  let label = item["label"] as? String, !label.isEmpty,
                  let file = item["file"] as? String, !file.isEmpty else { return nil }
            return HooksOfferProvider(id: id, label: label, file: file)
        }
        followUps = (row["followUps"] as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
    }

    public init(providers: [HooksOfferProvider], followUps: [String]) {
        self.providers = providers
        self.followUps = followUps
    }
}

public enum HooksOffer {
    public static let notNowTitle = "Never asks again. The Session updates page in the sidebar can turn this on later."
    public static let followUpTitle = "Turned on — one step is still yours"

    public static func headline(_ count: Int) -> String {
        count == 1 ? "Let tabs say what your assistant is doing" : "Let tabs say what your assistants are doing"
    }

    public static func detail(_ count: Int, appName: String = "Terminal Deck") -> String {
        let place = count == 1 ? "your assistant's own settings file" : "each installed assistant's own settings file"
        let files = count == 1 ? "the file" : "those files"
        return "One press adds \(appName)'s session hooks to \(place), so a tab can show working, waiting for you, or done — nothing else in \(files) is touched."
    }

    public static func writesTitle(_ providers: [HooksOfferProvider]) -> String {
        "Writes \(providers.map(\.file).joined(separator: " and "))"
    }

    /// The refusals in `hooks:offer-accept`'s answer, each in the main process's own words.
    public static func failures(_ json: Any?) -> [String] {
        guard let list = json as? [Any] else {
            return ["The answer could not be read — the Session updates page in the sidebar shows what actually happened."]
        }
        return list.compactMap { entry -> String? in
            guard let row = entry as? [String: Any] else { return nil }
            if row["ok"] as? Bool == true { return nil }
            let message = (row["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return message.isEmpty ? "One install did not go through — the Session updates page in the sidebar has the state." : message
        }
    }
}
