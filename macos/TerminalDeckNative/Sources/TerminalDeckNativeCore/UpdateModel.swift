import Foundation

/// updates/UpdateBanner.tsx's model, one to one: the state the engine pushes on
/// `update:state`, how it is read, and every sentence the banner says about it.
public enum UpdateState: Equatable, Sendable {
    case idle(checkedAt: Double?)
    case checking
    case available(version: String?, notes: String?, sizeBytes: Double?)
    case downloading(version: String?, percent: Double?, bytesPerSecond: Double?)
    case ready(version: String?)
    case error(message: String)
    case unsupported(reason: String)

    public static let none = UpdateState.idle(checkedAt: nil)

    public var phase: String {
        switch self {
        case .idle: return "idle"
        case .checking: return "checking"
        case .available: return "available"
        case .downloading: return "downloading"
        case .ready: return "ready"
        case .error: return "error"
        case .unsupported: return "unsupported"
        }
    }

    /// toUpdateState: anything unreadable is "no update"; an error or a reason
    /// without words is "no update" too, never an empty red strip.
    public init(raw: Any?) {
        guard let record = raw as? [String: Any] else { self = .none; return }
        switch record["phase"] as? String {
        case "checking":
            self = .checking
        case "available":
            self = .available(version: Self.text(record["version"]), notes: Self.text(record["notes"]),
                              sizeBytes: Self.number(record["sizeBytes"]))
        case "downloading":
            self = .downloading(version: Self.text(record["version"]), percent: Self.number(record["percent"]),
                                bytesPerSecond: Self.number(record["bytesPerSecond"]))
        case "ready":
            self = .ready(version: Self.text(record["version"]))
        case "error":
            if let message = Self.text(record["message"]) { self = .error(message: message) } else { self = .none }
        case "unsupported":
            if let reason = Self.text(record["reason"]) { self = .unsupported(reason: reason) } else { self = .none }
        default:
            self = .idle(checkedAt: Self.number(record["checkedAt"]))
        }
    }

    static func text(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    /// Hidden for idle and checking: a strip that appears for two seconds on
    /// every launch is worse than silence.
    public var shown: Bool {
        switch self {
        case .idle, .checking: return false
        default: return true
        }
    }

    public var headline: String {
        switch self {
        case .available(let version, _, _):
            return version.map { "Version \($0) is available" } ?? "A new version is available"
        case .downloading(let version, _, _):
            return version.map { "Downloading version \($0)" } ?? "Downloading the update"
        case .ready(let version):
            return version.map { "Version \($0) is downloaded" } ?? "The update is downloaded"
        case .error: return "That update did not go through"
        case .unsupported: return "This build cannot update itself"
        case .idle, .checking: return ""
        }
    }

    public var detail: String? {
        switch self {
        case .available(_, _, let size):
            return Update.formatBytes(size).map { "\($0) download" }
        case .downloading(_, let percent, let rate):
            let parts = [Update.percentText(percent), Update.formatRate(rate)].compactMap { $0 }
            return parts.isEmpty ? "Started — the feed is not reporting progress." : parts.joined(separator: " · ")
        case .ready:
            return "Restart to finish. Every session running in this window is closed when it does."
        case .error(let message): return message
        case .unsupported(let reason): return reason
        case .idle, .checking: return nil
        }
    }

    /// The download's progress, 0–100, or nil for an indeterminate bar.
    public var progress: Double? {
        if case .downloading(_, let percent, _) = self { return Update.percentOf(percent) }
        return nil
    }

    public var notes: String? {
        if case .available(_, let notes, _) = self { return notes }
        return nil
    }

    /// One dismissal per offer: a newer version, a different error, or the next
    /// launch brings the strip back.
    public var dismissKey: String? {
        switch self {
        case .available(let version, _, _), .downloading(let version, _, _):
            return "offer:\(version ?? "unknown")"
        case .ready(let version): return "ready:\(version ?? "unknown")"
        case .error(let message): return "error:\(message)"
        case .unsupported: return "unsupported"
        case .idle, .checking: return nil
        }
    }

    public func isDismissed(by dismissed: String?) -> Bool {
        guard let dismissed, let key = dismissKey else { return false }
        return key == dismissed
    }
}

public enum UpdateBusy: String, Sendable {
    case update, restart, retry

    /// The engine channel each button calls (preload: downloadUpdate,
    /// installUpdate, checkForUpdate). "Update" downloads only.
    public var channel: String {
        switch self {
        case .update: return "update:download"
        case .restart: return "update:install"
        case .retry: return "update:check"
        }
    }
}

public enum Update {
    public static let dismissStorageKey = "terminaldeck.updates.dismissed"
    public static let dismissHelp = "Hides this until the app is started again."
    public static let releasesLink = "Download it from the releases page"
    public static let notesTitle = "What changed"
    public static let failed = "That did not go through."

    public static func percentOf(_ percent: Double?) -> Double? {
        guard let percent, percent.isFinite else { return nil }
        return min(100, max(0, percent))
    }

    public static func percentText(_ percent: Double?) -> String? {
        percentOf(percent).map { "\(Int($0.rounded(.down)))%" }
    }

    private static let units = ["B", "KB", "MB", "GB"]

    public static func formatBytes(_ value: Double?) -> String? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        var size = value
        var unit = 0
        while size >= 1024 && unit < units.count - 1 {
            size /= 1024
            unit += 1
        }
        let figure = unit > 0 && size < 10 ? String(format: "%.1f", size) : String(Int(jsRound(size)))
        return "\(figure) \(units[unit])"
    }

    public static func formatRate(_ bytesPerSecond: Double?) -> String? {
        guard let bytesPerSecond, bytesPerSecond > 0 else { return nil }
        return formatBytes(bytesPerSecond).map { "\($0)/s" }
    }

    /// Only a github.com repository gets a releases link.
    public static func releasesUrl(for repository: String?) -> String? {
        guard let repository = UpdateState.text(repository),
              let url = URL(string: repository), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(), host == "github.com" || host == "www.github.com" else { return nil }
        var trimmed = repository
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        return "\(trimmed)/releases"
    }

    public static func missingNote(_ missing: [String]) -> String? {
        guard !missing.isEmpty else { return nil }
        return "This build is missing \(missing.count) of the update channels (\(missing.joined(separator: ", "))). Anything that needs one will say so rather than appear to have worked."
    }

    /// Math.round: halves go up, also for the figures the page shows.
    static func jsRound(_ value: Double) -> Double { (value + 0.5).rounded(.down) }
}
