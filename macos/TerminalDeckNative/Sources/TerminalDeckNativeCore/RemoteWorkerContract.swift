import Foundation

/// Terminal Deck's own small, versioned contract for a remote worker that runs an
/// explicit request on another machine. Nothing here claims an arbitrary URL (or any
/// other product's endpoint) speaks it: a server is compatible only when its
/// capability answer declares this protocol version and the required operations.
///
///   GET  /v1/capabilities            -> RemoteWorkerCapabilities (no run is created)
///   POST /v1/runs                    -> start; Deck's request ID doubles as the idempotency key
///   GET  /v1/runs/{id}               -> status snapshot (monotonic revision)
///   GET  /v1/requests/{requestId}    -> the run started for a Deck request ID (or 404 = never started)
///   POST /v1/runs/{id}/stop          -> idempotent stop request
///   POST /v1/runs/{id}/resume        -> continue with a new message (capability "resume")
public enum RemoteWorkerContract {
    public static let protocolVersion = 1
    public static let maxIDLength = 128
    public static let maxPromptBytes = 32 * 1024
    public static let maxResultBytes = 64 * 1024
    public static let maxModels = 32
    public static let maxTokenCount = 1_000_000_000_000
    public static let maxLabel = 80

    /// Opaque remote identities are data, not paths: a small safe alphabet only.
    public static func validID(_ id: String) -> Bool {
        guard !id.isEmpty, id.utf8.count <= maxIDLength, id != ".", id != ".." else { return false }
        return id.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || $0 == 45 || $0 == 95 || $0 == 46 || $0 == 58 }
    }

    public static func isLoopback(_ host: String) -> Bool {
        let host = host.lowercased()
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]" || host.hasSuffix(".localhost")
    }

    /// HTTPS with no credentials, query or fragment; plain HTTP only for this computer.
    public static func normalizedBase(_ raw: String) throws -> URL {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count <= 512, var parts = URLComponents(string: text), let scheme = parts.scheme?.lowercased(), let host = parts.host, !host.isEmpty else {
            throw RemoteWorkerFailure("Enter the worker's web address, for example https://worker.example.com")
        }
        guard parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw RemoteWorkerFailure("The worker address cannot hold a password, query or fragment. Save the access token separately.")
        }
        guard scheme == "https" || (scheme == "http" && isLoopback(host)) else {
            throw RemoteWorkerFailure("Remote workers need a secure https:// address (plain http:// is only allowed for this computer).")
        }
        parts.scheme = scheme; parts.host = host.lowercased()
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        guard !parts.path.contains(".."), let url = parts.url else { throw RemoteWorkerFailure("That worker address is not valid.") }
        return url
    }

    public static func boundedText(_ text: String, bytes: Int) -> (text: String, truncated: Bool) {
        guard text.utf8.count > bytes else { return (text, false) }
        var out = ""; var used = 0
        for character in text { let n = String(character).utf8.count; if used + n > bytes { break }; out.append(character); used += n }
        return (out, true)
    }
}

public struct RemoteWorkerFailure: Error, LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct RemoteWorkerCapabilities: Codable, Equatable, Sendable {
    public var service: String
    public var start: Bool, status: Bool, stop: Bool, resume: Bool, tokens: Bool
    public var models: [String]

    public init(service: String, start: Bool, status: Bool, stop: Bool, resume: Bool, tokens: Bool, models: [String] = []) {
        self.service = service; self.start = start; self.status = status; self.stop = stop; self.resume = resume; self.tokens = tokens; self.models = models
    }

    /// Strict decode: wrong protocol version or a missing required operation is a refusal, not "connected".
    public static func decode(_ json: [String: Any]) throws -> RemoteWorkerCapabilities {
        guard let version = json["protocol"] as? Int, version == RemoteWorkerContract.protocolVersion else {
            throw RemoteWorkerFailure("This server does not speak Terminal Deck's remote worker protocol version \(RemoteWorkerContract.protocolVersion).")
        }
        guard let service = json["service"] as? String, !service.isEmpty, service.utf8.count <= 80 else {
            throw RemoteWorkerFailure("The server did not name itself.")
        }
        guard let list = json["capabilities"] as? [String], list.count <= 16 else { throw RemoteWorkerFailure("The server did not list what it can do.") }
        let set = Set(list)
        guard set.contains("start"), set.contains("status") else {
            throw RemoteWorkerFailure("The server must at least support starting a run and reading its status.")
        }
        var models: [String] = []
        if let raw = json["models"] {
            guard let names = raw as? [String], names.count <= RemoteWorkerContract.maxModels, names.allSatisfy(RemoteWorkerContract.validID) else {
                throw RemoteWorkerFailure("The server's model list is not valid.")
            }
            models = names
        }
        return .init(service: service, start: true, status: true, stop: set.contains("stop"), resume: set.contains("resume"), tokens: set.contains("tokens"), models: models)
    }
}

public enum RemoteWorkerState: String, Codable, Equatable, Sendable {
    case prepared, starting, running, completed, failed
    case stopRequested = "stop_requested", stopped, unknown

    public var isTerminal: Bool { self == .completed || self == .failed || self == .stopped }
    public var isActive: Bool { !isTerminal }

    /// Remote reports only move a run forward. A confirmed end never changes again.
    public func accepts(_ next: RemoteWorkerState) -> Bool {
        if self == next { return true }
        if isTerminal { return false }
        switch self {
        case .prepared, .starting, .unknown: return next != .prepared
        case .running: return next != .prepared && next != .starting
        case .stopRequested: return next == .stopped || next == .completed || next == .failed
        default: return false
        }
    }

    /// States a worker may report in a snapshot.
    public static func reported(_ text: String) -> RemoteWorkerState? {
        switch text { case "running": .running; case "completed": .completed; case "failed": .failed; case "stop_requested": .stopRequested; case "stopped": .stopped; default: nil }
    }
}

/// Tokens exactly as the worker reported them. Missing is "not reported", never zero.
public struct RemoteWorkerUsage: Codable, Equatable, Sendable {
    public var input: Int?, output: Int?, total: Int?
    public var revision: Int
    public init(input: Int? = nil, output: Int? = nil, total: Int? = nil, revision: Int) { self.input = input; self.output = output; self.total = total; self.revision = revision }

    public static func decode(_ json: Any?, revision: Int) throws -> RemoteWorkerUsage? {
        guard let json else { return nil }
        guard let object = json as? [String: Any] else { throw RemoteWorkerFailure("The worker's usage report is not valid.") }
        func count(_ key: String) throws -> Int? {
            guard let raw = object[key], !(raw is NSNull) else { return nil }
            guard let number = raw as? Int, number >= 0, number <= RemoteWorkerContract.maxTokenCount else { throw RemoteWorkerFailure("The worker reported an impossible token count.") }
            return number
        }
        let usage = RemoteWorkerUsage(input: try count("input"), output: try count("output"), total: try count("total"), revision: revision)
        return usage.input == nil && usage.output == nil && usage.total == nil ? nil : usage
    }
    public var shownTotal: Int? { total ?? ((input != nil || output != nil) ? (input ?? 0) + (output ?? 0) : nil) }
}

public struct RemoteWorkerCheck: Codable, Equatable, Sendable {
    public var at: Date
    public var ok: Bool
    public var capabilities: RemoteWorkerCapabilities?
    public var error: String?
    public init(at: Date, ok: Bool, capabilities: RemoteWorkerCapabilities?, error: String?) { self.at = at; self.ok = ok; self.capabilities = capabilities; self.error = error }
}

public struct RemoteWorkerConnection: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var baseURL: String
    public var profile: String?
    /// Raised whenever the address changes, so a run started against an older address is never steered to the new one.
    public var revision: Int
    public var lastCheck: RemoteWorkerCheck?
    public init(id: String, label: String, baseURL: String, profile: String?, revision: Int, lastCheck: RemoteWorkerCheck? = nil) {
        self.id = id; self.label = label; self.baseURL = baseURL; self.profile = profile; self.revision = revision; self.lastCheck = lastCheck
    }
}

/// A named remote run. It is never a terminal session: it has no PTY, session ID or conversation ID.
public struct RemoteWorkerRun: Codable, Equatable, Sendable {
    public var id: String
    public var connectionID: String
    public var endpoint: String
    public var configRevision: Int
    public var requestID: String
    public var remoteID: String?
    public var title: String
    public var model: String?
    public var state: RemoteWorkerState
    public var revision: Int
    public var result: String?
    public var resultTruncated: Bool
    public var error: String?
    public var note: String?
    public var usage: RemoteWorkerUsage?
    public var attempt: Int
    public var previous: String?
    public var stopRequestID: String?
    public var stopConfirmed: Bool
    public var created: Date
    public var updated: Date
    /// Consecutive "no record of this request" answers while it is not known whether the run started.
    public var notFound: Int?
    public var executionKind: String { "remote_http" }
    private enum CodingKeys: String, CodingKey {
        case id, connectionID, endpoint, configRevision, requestID, remoteID, title, model, state, revision, result, resultTruncated, error, note, usage, attempt, previous, stopRequestID, stopConfirmed, created, updated, notFound
    }
    public init(id: String, connectionID: String, endpoint: String, configRevision: Int, requestID: String, title: String, model: String?, now: Date, attempt: Int = 1, previous: String? = nil) {
        self.id = id; self.connectionID = connectionID; self.endpoint = endpoint; self.configRevision = configRevision; self.requestID = requestID
        self.title = title; self.model = model; state = .prepared; revision = 0; resultTruncated = false; stopConfirmed = false
        created = now; updated = now; self.attempt = attempt; self.previous = previous
    }
}
