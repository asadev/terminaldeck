import Foundation
import TerminalDeckNativeCore

public protocol BackendDeckCoreBriefSurface: Sendable {
    func listSessions() -> [NativeRPCValue]
    func sessionScreen(id: String) async throws -> String?
    func writeToSession(id: String, data: String) async throws
}
public struct BackendDeckCoreBriefClock: Sendable {
    public let now: @Sendable () -> Double
    public let sleep: @Sendable (Double) async throws -> Void
    public init(now: @escaping @Sendable () -> Double, sleep: @escaping @Sendable (Double) async throws -> Void) { self.now = now; self.sleep = sleep }
    public static let real = Self(now: { Date().timeIntervalSince1970 * 1000 }, sleep: { try await Task.sleep(for: .milliseconds(max(0, $0))) })
}

public enum BackendDeckCoreBrief {
    public static let maxBriefChars = 8000, minBriefChars = 40
    public static let deliveryTimeoutMs = 20_000.0, deliveryPollMs = 400.0, echoTimeoutMs = 2500.0
    public static func specsDirectory(copilotRoot: URL) -> URL { copilotRoot.appendingPathComponent("specs", isDirectory: true) }
    public static func slugifyTitle(_ title: String) -> String {
        let clean = title.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .replacingOccurrences(of: "^-+|-+$", with: "", options: .regularExpression)
        let slug = String(clean.prefix(48)).replacingOccurrences(of: "-+$", with: "", options: .regularExpression)
        return slug.isEmpty ? "brief" : slug
    }
    public static func stamp(at: Double, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = timeZone; formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.string(from: Date(timeIntervalSince1970: at / 1000))
    }
    public static func writeSpec(directory: URL, input: NativeRPCValue, ownership: NativeStateStore.Ownership = .readOnly) throws -> NativeRPCValue {
        guard directory.isFileURL else { throw NativeRPCError.invalidArguments("A spec directory must be a file URL.") }
        guard ownership == .exclusive else { throw NativeRPCError(code: "read-only", message: "Writing a brief requires exclusive native record ownership.") }
        let title = try input["title"].requireString("title"), brief = try input["brief"].requireString("brief")
        let at = input["at"].number ?? Date().timeIntervalSince1970 * 1000
        let slug = stamp(at: at) + "-" + slugifyTitle(title), path = directory.appendingPathComponent(slug + ".md")
        let date = ISO8601DateFormatter(); date.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let body = ["# " + BackendDeckCoreCatalogueRules.trim(title), "", "repo: " + (input["cwd"].string ?? ""),
            "agent: " + (input["provider"].string ?? "the default"), "written: " + date.string(from: Date(timeIntervalSince1970: at / 1000)),
            "from-turn: " + (input["callId"].string ?? ""), "", "---", "", BackendDeckCoreCatalogueRules.trim(brief), ""].joined(separator: "\n")
        // The existing native persistence helper creates 0600 bytes atomically.
        try BackendTaskPersistence(directory: directory, ownership: ownership).writeBytes(path.lastPathComponent, data: Data(body.utf8))
        return .object([.init("path", .string(path.path)), .init("slug", .string(slug))])
    }
    public static func deliveryLine(_ path: String) -> String {
        "Read \(path) and do exactly what it says. That file is your whole brief — nothing else has been said to you, and nobody is going to add to it. Read it before you start."
    }
    public static func refusal(_ composer: BackendTaskBriefDelivery.Composer) -> String? {
        switch composer {
        case .ready: return nil
        case .working: return "This session is mid-turn. A command typed now would land in whatever it asks next rather than on the command line, so nothing was sent — try again once it has finished."
        case .choosing(let asking): return "This session is waiting on a choice (“\(asking)”). Pressing return now would answer it instead of running a command, so nothing was sent."
        case .typing(let text): return "There is unsent text at this session’s prompt (“\(text)”). A command typed now would run into the middle of it, so nothing was sent — clear the prompt and pick again."
        case .unknown: return "This session’s prompt is not on screen, so there is nowhere to type that could be checked first."
        }
    }
    public static func deliver(surface: any BackendDeckCoreBriefSurface, sessionID: String, line: String,
                               timeoutMs: Double = deliveryTimeoutMs, pollMs: Double = deliveryPollMs,
                               clock: BackendDeckCoreBriefClock = .real) async throws -> NativeRPCValue {
        let started = clock.now(); var lastRefusal: String?
        func result(_ delivered: Bool, _ reason: String?) -> NativeRPCValue {
            .object([.init("delivered", .bool(delivered)), .init("reason", reason.map(NativeRPCValue.string) ?? .null), .init("waitedMs", .number(clock.now() - started))])
        }
        while true {
            try Task.checkCancellation()
            guard let alive = surface.listSessions().first(where: { $0["id"].string == sessionID }), alive["exitCode"].isNullish else {
                return result(false, "The session ended before it was ready to be typed into.")
            }
            if let screen = try await surface.sessionScreen(id: sessionID) {
                let composer = BackendTaskBriefDelivery.composer(screen), refused = refusal(composer)
                if refused == nil {
                    try await surface.writeToSession(id: sessionID, data: line)
                    let deadline = clock.now() + echoTimeoutMs
                    do {
                        while true {
                            try Task.checkCancellation()
                            if let echo = try await surface.sessionScreen(id: sessionID),
                               case .typing(let text) = BackendTaskBriefDelivery.composer(echo), !text.isEmpty, line.hasPrefix(text) {
                                try await surface.writeToSession(id: sessionID, data: "\r")
                                return result(true, nil)
                            }
                            if clock.now() >= deadline { break }
                            try await clock.sleep(pollMs)
                        }
                    } catch { try? await surface.writeToSession(id: sessionID, data: "\u{15}"); throw error }
                    try await surface.writeToSession(id: sessionID, data: "\u{15}")
                    return result(false, "The brief was typed but never appeared on the session command line, so the return was not sent and the line was cleared again. Nothing was delivered.")
                }
                lastRefusal = refused
            }
            if clock.now() - started >= timeoutMs {
                return result(false, lastRefusal ?? "The session never drew a prompt this app could recognise, so nothing was typed.")
            }
            try await clock.sleep(pollMs)
        }
    }
}
