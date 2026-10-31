import Foundation

// A tour Hoot plays through the app: copilot/driving/tour.ts (stops, records,
// readers, words), the focus targets of driving/focus-target.ts, the degrade
// sentences of tour-player.ts and the recap helpers of TourRecap.tsx — ported one
// for one. A record keeps every field it was sent, so a report sends it back whole.

/// What a stop points at (`DriveAnchor`), as the `data-drive-anchor` ids the page uses.
public enum DriveAnchor: Equatable, Sendable, Hashable {
    case message(messageId: String)
    case sessionRow(sessionId: String)
    case alert(alertId: String)
    case gitFile(cwd: String, path: String)
    case usage(sessionId: String)

    /// `anchorId`: the id a native view registers with `.driveAnchor(_:)`.
    public var id: String {
        switch self {
        case .message(let m): return "message:\(m)"
        case .sessionRow(let s): return "session-row:\(s)"
        case .alert(let a): return "alert:\(a)"
        case .gitFile(let cwd, let path): return "git-file:\(cwd):\(path)"
        case .usage(let s): return "usage:\(s)"
        }
    }
}

/// `FocusTarget`: a quote in a terminal, an anchor, or the browser page.
public enum FocusTarget: Equatable, Sendable, Hashable {
    case terminal(sessionId: String, quote: String)
    case anchor(DriveAnchor)
    case page
}

/// Why a stop could not be boxed (`FocusFailure`).
public enum FocusFailure: String, Equatable, Sendable {
    case notRegistered = "not-registered", notRendered = "not-rendered", alternateBuffer = "alternate-buffer"
    case quoteNotFound = "quote-not-found", offScreen = "off-screen", anchorMissing = "anchor-missing", noPage = "no-page"
}

public struct TourStop: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case message(messageId: String, quote: String)
        case screen(quote: String)
        case anchor(at: String, path: String?)
    }
    public var sessionId: String
    public var note: String
    public var why: String
    public var kind: Kind

    public var quote: String {
        switch kind {
        case .message(_, let q), .screen(let q): return q
        case .anchor: return ""
        }
    }
}

public struct TourStopRecord: Equatable, Sendable {
    public var index: Int
    public var sessionId: String
    public var sessionTitle: String
    public var kind: String
    public var cwd: String
    public var messageId: String?
    public var at: String?
    public var path: String?
    public var why: String
    public var quote: String
    public var note: String
    public var shownAt: Double?
    public var dwellMs: Double?
    public var degraded: Bool
    public var degradedWhy: String?
}

public struct DroppedStop: Equatable, Sendable {
    public var title: String
    public var why: String
    public var detail: String
}

/// A tour record, as the engine wrote it. Typed fields for the page's use; `raw`
/// carries every field, and `wire` writes the typed ones back over it.
public struct TourRecord: Equatable, @unchecked Sendable {
    public var id: String
    public var startedAt: Double
    public var endedAt: Double?
    public var question: String
    public var headline: String
    public var background: Bool
    public var stops: [TourStopRecord]
    public var stoppedAfter: Int?
    public var dropped: [DroppedStop]
    let raw: [String: Any]
    let rawStops: [[String: Any]]

    public static func == (a: TourRecord, b: TourRecord) -> Bool {
        a.id == b.id && a.startedAt == b.startedAt && a.endedAt == b.endedAt && a.question == b.question && a.headline == b.headline
            && a.background == b.background && a.stops == b.stops && a.stoppedAfter == b.stoppedAfter && a.dropped == b.dropped
    }

    /// The record to send back on `deck-control:tour-report`.
    public var wire: [String: Any] {
        var out = raw
        out["endedAt"] = endedAt.map { $0 as Any } ?? NSNull()
        out["stoppedAfter"] = stoppedAfter.map { $0 as Any } ?? NSNull()
        out["stops"] = stops.enumerated().map { i, stop -> [String: Any] in
            var row = i < rawStops.count ? rawStops[i] : [:]
            row["shownAt"] = stop.shownAt.map { $0 as Any } ?? NSNull()
            row["dwellMs"] = stop.dwellMs.map { $0 as Any } ?? NSNull()
            row["degraded"] = stop.degraded
            row["degradedWhy"] = stop.degradedWhy.map { $0 as Any } ?? NSNull()
            return row
        }
        return out
    }
}

public struct TourMessage: Equatable, Sendable {
    public var record: TourRecord
    public var stops: [TourStop]
}

private func text(_ v: Any?) -> String? {
    guard let s = v as? String, !s.isEmpty else { return nil }
    return s
}
private func number(_ v: Any?) -> Double? {
    guard let n = v as? NSNumber, !(v is Bool), n.doubleValue.isFinite else { return nil }
    return n.doubleValue
}

public enum DriveTour {
    public static let channel = "deck-control:tour"
    public static let reportChannel = "deck-control:tour-report"
    public static let toursChannel = "deck-control:tours"
    /// A `copilot:action` row with this tool means a scan just finished.
    public static let scanTool = "tour.play"

    public static func record(_ value: Any?) -> TourRecord? {
        guard let r = value as? [String: Any], (r["v"] as? NSNumber)?.intValue == 1, let id = r["id"] as? String,
              let rawStops = r["stops"] as? [Any] else { return nil }
        let stopDicts = rawStops.compactMap { $0 as? [String: Any] }
        return TourRecord(
            id: id, startedAt: number(r["startedAt"]) ?? 0, endedAt: number(r["endedAt"]),
            question: r["question"] as? String ?? "", headline: r["headline"] as? String ?? "",
            background: (r["shown"] as? String) == "background",
            stops: stopDicts.map(stopRecord),
            stoppedAfter: number(r["stoppedAfter"]).map { Int($0) },
            dropped: ((r["dropped"] as? [Any]) ?? []).compactMap { $0 as? [String: Any] }.map {
                DroppedStop(title: $0["title"] as? String ?? "", why: $0["why"] as? String ?? "", detail: $0["detail"] as? String ?? "")
            },
            raw: r, rawStops: stopDicts)
    }

    static func stopRecord(_ s: [String: Any]) -> TourStopRecord {
        TourStopRecord(index: Int(number(s["index"]) ?? 0), sessionId: s["sessionId"] as? String ?? "",
                       sessionTitle: s["sessionTitle"] as? String ?? "", kind: s["kind"] as? String ?? "",
                       cwd: s["cwd"] as? String ?? "", messageId: s["messageId"] as? String, at: s["at"] as? String,
                       path: s["path"] as? String, why: s["why"] as? String ?? "", quote: s["quote"] as? String ?? "",
                       note: s["note"] as? String ?? "", shownAt: number(s["shownAt"]), dwellMs: number(s["dwellMs"]),
                       degraded: (s["degraded"] as? Bool) == true, degradedWhy: s["degradedWhy"] as? String)
    }

    /// `readTour`: a played tour, or nil when it is not one this build can play.
    public static func read(_ value: Any?) -> TourMessage? {
        guard let raw = value as? [String: Any], let record = record(raw["record"]), let stops = raw["stops"] as? [Any] else { return nil }
        let parsed = stops.compactMap(stop)
        return parsed.isEmpty ? nil : TourMessage(record: record, stops: parsed)
    }

    static func stop(_ value: Any?) -> TourStop? {
        guard let r = value as? [String: Any], let sessionId = text(r["sessionId"]), let note = text(r["note"]),
              let why = text(r["why"]) else { return nil }
        switch r["kind"] as? String {
        case "message":
            guard let messageId = text(r["messageId"]), let quote = text(r["quote"]) else { return nil }
            return TourStop(sessionId: sessionId, note: note, why: why, kind: .message(messageId: messageId, quote: quote))
        case "screen":
            guard let quote = text(r["quote"]) else { return nil }
            return TourStop(sessionId: sessionId, note: note, why: why, kind: .screen(quote: quote))
        case "anchor":
            guard let at = text(r["at"]) else { return nil }
            return TourStop(sessionId: sessionId, note: note, why: why, kind: .anchor(at: at, path: text(r["path"])))
        default:
            return nil
        }
    }

    /// `focusOf`: where a stop points, with the session's folder for a git file.
    public static func focus(_ stop: TourStop, cwd: String?) -> FocusTarget? {
        switch stop.kind {
        case .screen(let quote): return .terminal(sessionId: stop.sessionId, quote: quote)
        case .message(let messageId, _): return .anchor(.message(messageId: messageId))
        case .anchor(let at, let path):
            if at == "usage" { return .anchor(.usage(sessionId: stop.sessionId)) }
            if at == "git-file", let path, let cwd { return .anchor(.gitFile(cwd: cwd, path: path)) }
            return nil
        }
    }

    /// `focusOfRecord`: where a recorded stop points, for "Take me there".
    public static func focus(_ stop: TourStopRecord) -> FocusTarget? {
        switch stop.kind {
        case "screen": return stop.quote.isEmpty ? nil : .terminal(sessionId: stop.sessionId, quote: stop.quote)
        case "message": return stop.messageId.map { .anchor(.message(messageId: $0)) }
        case "anchor":
            if stop.at == "usage" { return .anchor(.usage(sessionId: stop.sessionId)) }
            if stop.at == "git-file", let path = stop.path, !stop.cwd.isEmpty { return .anchor(.gitFile(cwd: stop.cwd, path: path)) }
            return nil
        default: return nil
        }
    }

    /// Whether a stop's travel goes through the Git view first.
    public static func goesToGit(_ stop: TourStop) -> Bool {
        if case .anchor(let at, _) = stop.kind { return at == "git-file" }
        return false
    }

    public static func reasonLabel(_ why: String) -> String {
        ["blocked-on-you": "Waiting on you", "failed": "Failed", "finished": "Finished", "looping": "Looping",
         "tool-failing": "Tool failing", "compacted": "Compacted", "expensive": "Expensive", "files-changed": "Files changed",
         "question-asked": "Asked a question", "decision": "Decision"][why] ?? why
    }

    public static func droppedSentence(_ dropped: [DroppedStop]) -> String {
        if dropped.isEmpty { return "" }
        let count = "\(dropped.count) stop\(dropped.count == 1 ? "" : "s")"
        let reasons = Set(dropped.map(\.why))
        if reasons.count == 1, let only = reasons.first { return "\(count) dropped — \(dropReason(only))." }
        return "\(count) dropped — the checks did not hold."
    }

    static func dropReason(_ why: String) -> String {
        ["quote-not-found": "the quoted text was not there", "session-gone": "the session had gone",
         "over-budget": "they were over what a tour may carry",
         "reason-unsupported": "this app’s own data did not support the reason given"][why] ?? "the checks did not hold"
    }

    public static func stoppedSentence(_ record: TourRecord) -> String {
        guard let after = record.stoppedAfter else { return "" }
        let shown = after + 1
        if shown >= record.stops.count { return "" }
        return "Stopped after \(shown) of \(record.stops.count)."
    }

    /// `degradeSentence`: why there is no box, said in the stop's own row.
    public static func degradeSentence(_ why: FocusFailure) -> String {
        switch why {
        case .notRegistered: return "That session is not open in this window, so there is nothing to box. The text is here."
        case .notRendered: return "That session is not on screen, so there is nothing to box. The text is here."
        case .alternateBuffer: return "That session is in a full-screen program, which has no scrollback to box. The text is here."
        case .quoteNotFound: return "That text has scrolled out of what this window still holds. It is here."
        case .offScreen: return "The text is outside the visible part of that pane."
        case .anchorMissing: return "The thing this points at is not on screen right now."
        case .noPage: return "There is no browser page open to point at."
        }
    }

    // MARK: TourRecap

    /// `readRecords`: finished tours, newest first as the engine lists them.
    public static func records(_ value: Any?) -> [TourRecord] {
        ((value as? [Any]) ?? []).compactMap(record).filter { $0.endedAt != nil }
    }

    /// `nthStopOf`: the recorded stop behind one line of the grouped answer.
    public static func nthStop(_ record: TourRecord, sessionId: String, position: Int) -> TourStopRecord? {
        var seen = 0
        for stop in record.stops where stop.sessionId == sessionId {
            if seen == position { return stop }
            seen += 1
        }
        return nil
    }

    /// Whether a `copilot:action` row says a scan just finished.
    public static func isScanRow(_ raw: Any?) -> Bool { ((raw as? [String: Any])?["tool"] as? String) == scanTool }

    /// The keys that drive the panel instead of interrupting it.
    public static let transportKeys = [" ", "ArrowLeft", "ArrowRight", "Escape"]
}

// MARK: - The browser the agent drives (browser-trace.ts)

public struct DriveNow: Equatable, Sendable {
    public enum State: String, Sendable { case idle, agent, human }
    public var state: State
    public var tabId: String
    public var step: String
    public var url: String

    public static func of(_ raw: Any?) -> DriveNow? {
        guard let s = raw as? [String: Any], let state = (s["state"] as? String).flatMap(State.init(rawValue:)) else { return nil }
        return DriveNow(state: state, tabId: s["tabId"] as? String ?? "", step: s["step"] as? String ?? "", url: s["url"] as? String ?? "")
    }

    /// "example.com/path" — host without www, and the path when there is one.
    public static func shortUrl(_ url: String) -> String {
        if url.isEmpty { return "" }
        guard let parts = URLComponents(string: url), let host = parts.host, parts.scheme != nil else { return url }
        let trimmed = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        let port = parts.port.map { ":\($0)" } ?? ""
        let path = parts.path == "/" ? "" : parts.path
        return "\(trimmed)\(port)\(path)"
    }
}
