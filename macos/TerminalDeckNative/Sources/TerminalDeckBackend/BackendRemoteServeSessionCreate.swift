import Foundation
import TerminalDeckNativeCore

/// The Mac policy from session-create.ts. Lifecycle, account/profile resolution,
/// guest Git and Seatbelt stay in the supplied native launch path.
public struct BackendRemoteServeSessionCreate: Sendable {
    public struct Request: Sendable {
        public let deviceID: String
        public let cwd: String?, provider: String?
        public let cols: Int?, rows: Int?
        public init(deviceID: String, cwd: String? = nil, provider: String? = nil, cols: Int? = nil, rows: Int? = nil) {
            self.deviceID = deviceID; self.cwd = cwd; self.provider = provider; self.cols = cols; self.rows = rows
        }
        public init(message: BackendRemoteClientMessage, deviceID: String) {
            self.init(deviceID: deviceID, cwd: message["cwd"].string, provider: message["provider"].string,
                cols: message["cols"].number.map(Int.init), rows: message["rows"].number.map(Int.init))
        }
    }
    public struct Refusal: Error, Equatable, Sendable {
        public let code: String, message: String
        public init(code: String, message: String) { self.code = code; self.message = message }
    }
    /// The session/provider owner must wrap its typed failures at their source;
    /// raw CLI paths or Seatbelt stderr are never guessed from string matching.
    public enum SpawnFailure: Error, Sendable { case confinement(detail: String), agent(message: String) }
    public enum Outcome: Sendable {
        case created(BackendSessionMeta), refused(Refusal)
        public var session: BackendSessionMeta? { if case .created(let meta) = self { return meta }; return nil }
        public func message() throws -> BackendRemoteServerMessage {
            switch self {
            case .refused(let failure): return try .error(code: failure.code, message: failure.message)
            case .created(let meta):
                return try .init(.created, fields: [.init("session", .object([.init("id", .string(meta.id)), .init("title", .string(meta.title)),
                    .init("cwd", .string(meta.cwd)), .init("provider", .string(meta.provider)), .init("status", .string("idle")),
                    .init("exitCode", meta.exitCode.map { .number(Double($0)) } ?? .null)]))])
            }
        }
    }
    public typealias Spawn = @Sendable (BackendRemoteCreateRequest) async throws -> BackendSessionMeta
    private let offer: @Sendable (String) async throws -> [String]
    private let unrestricted: (@Sendable (String) async throws -> Bool)?
    private let spawn: Spawn?
    private let noteStarted: (@Sendable (String, String) async throws -> Void)?
    private let report: @Sendable (String) -> Void
    public init(folders: @escaping @Sendable (String) async throws -> [String],
                unrestricted: (@Sendable (String) async throws -> Bool)? = nil, spawn: Spawn? = nil,
                noteStarted: (@Sendable (String, String) async throws -> Void)? = nil,
                report: @escaping @Sendable (String) -> Void = { _ in }) {
        offer = folders; self.unrestricted = unrestricted; self.spawn = spawn; self.noteStarted = noteStarted; self.report = report
    }
    public var available: Bool { spawn != nil }
    public func folders(_ deviceID: String) async throws -> [String] { try await offer(deviceID) }
    public static let providers = ["claude", "codex", "gemini", "shell"]
    public static func knownProvider(_ value: String) -> String? { providers.first { $0 == value } }
    public static func plan(_ request: Request, offered: [String], unrestricted: Bool = false) -> Result<BackendRemoteCreateRequest, Refusal> {
        let cwd: String
        if let named = request.cwd {
            guard named.hasPrefix("/"), unrestricted || offered.contains(where: { BackendRemoteServeSessionPolicy.sameFolder($0, named) }) else {
                return .failure(.init(code: "unauthorized", message: "This Mac is not offering that folder to this device. Pick one from the list it sent."))
            }
            cwd = named
        } else {
            guard let first = offered.first else {
                return .failure(.init(code: "unauthorized", message: "This Mac has no folders chosen for this device. Choose one in its remote access settings."))
            }
            cwd = first
        }
        if let provider = request.provider, knownProvider(provider) == nil {
            return .failure(.init(code: "unauthorized", message: "This Mac does not have an agent by that name. It can start: \(providers.joined(separator: ", "))."))
        }
        return .success(.init(deviceID: request.deviceID, cwd: cwd, provider: request.provider, cols: request.cols ?? 80, rows: request.rows ?? 24))
    }
    public static func refusal(_ error: any Error) -> Refusal {
        switch error {
        case SpawnFailure.confinement:
            return .init(code: "unavailable", message: "This Mac could not keep a session inside that folder, so it did not start one. Settings → Remote on that Mac says what it can hold.")
        case SpawnFailure.agent(let message):
            return .init(code: "unauthorized", message: message + " Install it on that Mac, or choose a different one in its settings.")
        default: return .init(code: "unavailable", message: "This Mac could not start a session there. The folder may have moved.")
        }
    }
    public func create(_ request: Request) async -> Outcome {
        guard let spawn else { return .refused(.init(code: "unavailable", message: "This host cannot start a session.")) }
        let planned: BackendRemoteCreateRequest
        do {
            let offered = try await offer(request.deviceID), anywhere = try await unrestricted?(request.deviceID) ?? false
            switch Self.plan(request, offered: offered, unrestricted: anywhere) {
            case .failure(let refusal): return .refused(refusal)
            case .success(let input): planned = input
            }
        } catch { report("[remote] could not read the session folder rule: " + error.localizedDescription); return .refused(Self.refusal(error)) }
        do {
            let meta = try await spawn(planned)
            // A failed include must never turn an already-spawned live session
            // into a failed create. Source logs it and retains the true result.
            do { try await noteStarted?(request.deviceID, meta.id) }
            catch { report("[remote] could not record the session this device started: " + error.localizedDescription) }
            return .created(meta)
        } catch {
            if case SpawnFailure.confinement(let detail) = error { report("[remote] refusing to start an unconfined session: " + detail) }
            else { report("[remote] could not start a session: " + error.localizedDescription) }
            return .refused(Self.refusal(error))
        }
    }
}
