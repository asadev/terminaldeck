import Foundation

/// Internal app/helper wire only. Never a renderer channel or public MCP surface.
public enum BackendHOSTProtocol {
    public static let version = 2
    public static let maximumFrameBytes = 128 * 1024 * 1024
    public static let maximumRequestBytes = 8 * 1024 * 1024
    public static let maximumInputBytes = 4 * 1024 * 1024
    public static let maximumConnections = 16
    // 22 Oct (Asad, "remove this 128 limit"): there is no session-count limit. A lead's team starts many small
    // sessions; a fixed count refused every new chat once the list (mostly finished chats) held 128.

    public struct Hello: Codable, Equatable, Sendable {
        public var protocolVersion: Int
        public var hostVersion: String
        public var hostPID: Int32
        public var instance: UUID
        /// Optional so an old helper decodes and remains untouched.
        public var chatService: Int? = nil
        public var pcDecisionValidation: Int? = nil
        public var chatSteering: Int? = nil
        public var chatFeatures: Int? = nil
        public var chatOwnedTerminals: Int? = nil
        /// File checkpoints, background tasks, fork and location (separate from chatFeatures, which stays 1).
        public var chatSessionFeatures: Int? = nil
        /// 18 Oct (#107): 1 = an account question this host does not know is answered with the typed
        /// `unknown-channel` code (BackendHOSTUnknownChannel). Nil: an older host, which says so only in words.
        public var accountUnknownChannel: Int? = nil
    }

    /// The app resolves policy first, including its own inherited environment
    /// and shim. The helper must not substitute launchd's environment.
    public struct Launch: Codable, Sendable {
        /// A backend-composed task launch whose records fence is already compiled into the command.
        public var pcDecision: BackendPCDecisionHostValidation.Envelope? = nil
        public var preparedChat: Bool?
        public var chatSetup: BackendHootChatSetup?

        public var id: String
        public var input: BackendCreateSessionInput
        public var command: String
        public var arguments: [String]
        public var environment: [String: String]
        public var cwd: String
        public var metadata: BackendSessionMeta
        public var scope: Scope?
        public var accountHandle: String? = nil
        public var mcpLeaseIDs: [UUID]? = nil
        /// The same backend-authored machine identity used by the ordinary or
        /// project lease transaction, never inferred from argv or MCP arguments.
        public var machineID: String? = nil
        public var ownerIndependent: Bool? = nil
        public init(id: String, input: BackendCreateSessionInput, spawn: BackendSpawnSpec,
                    inheritedEnvironment: [String: String], openShim: (directory: String, browser: String)? = nil,
                    context: BackendLaunchContext? = nil, machineID: String? = nil) throws {
            guard UUID(uuidString: id) != nil else { throw BackendHOSTFailure.invalid("Invalid host session identity.") }
            guard machineID.map({ !$0.contains("\0") && $0.utf8.count <= 1_024 }) ?? true else {
                throw BackendHOSTFailure.invalid("Invalid host lease machine identity.")
            }
            self.machineID = machineID
            self.id = id; self.input = input; command = spawn.command; arguments = spawn.args
            environment = try BackendSessionEnvironment.forSession(id: id, inherited: inheritedEnvironment, spawn: spawn)
            if let openShim {
                environment["PATH"] = BackendMacAppHandoffOpenShim.prepend(path: environment["PATH"] ?? "", shim: openShim.directory)
                environment["BROWSER"] = openShim.browser
            }
            cwd = spawn.hostCwd ?? input.cwd
            metadata = BackendSessionMeta(id: id, input: input, spawn: spawn)
            scope = context.map(Scope.init)
        }
    }

    /// Immutable, backend-authored ledger/confinement facts; no callback or
    /// environment is projected back to the UI with a replay snapshot.
    public struct Scope: Codable, Sendable {
        public var deviceBoundary: BackendDeviceBoundary?
        public var appFenceID: String?
        public var hostedTask: Bool? = nil
        public var rememberTab: Bool
        public var isAppComposed: Bool
        public init(_ context: BackendLaunchContext) {
            deviceBoundary = context.deviceBoundary; appFenceID = context.appFenceID
            rememberTab = context.rememberTab; isAppComposed = context.isAppComposed
        }
    }

    public struct Snapshot: Codable, Sendable {
        public var sequence: UInt64
        public var session: BackendSessionMeta
        public var pid: Int32?
        public var replay: String
        public var screen: String?
        public var scrollbackText: String?
        public var status: BackendSessionStatus
        public var input: BackendCreateSessionInput? = nil
        public var scope: Scope? = nil
        /// 27 Oct: the bytes that draw the terminal as it is now (`BackendTerminalRemount`), when the request
        /// asked for them. An older helper never sends it; the app then uses `replay`, as before.
        public var remount: String? = nil
    }

    public struct Event: Codable, Sendable {
        public enum Kind: String, Codable, Sendable { case data, exit, status, removed }
        public var sequence: UInt64
        public var id: String
        public var kind: Kind
        public var text: String?
        public var exitCode: Int?
        public var status: BackendSessionStatus?
        public var reason: BackendRemovalReason?
        public init(sequence: UInt64, event: BackendSessionEvent) {
            self.sequence = sequence
            switch event {
            case let .data(id, text): self.id = id; kind = .data; self.text = text
            case let .exit(id, code): self.id = id; kind = .exit; exitCode = code
            case let .status(id, status): self.id = id; kind = .status; self.status = status
            case let .removed(id, reason): self.id = id; kind = .removed; self.reason = reason
            }
        }
        public func sessionEvent() throws -> BackendSessionEvent {
            switch kind {
            case .data: guard let text else { throw BackendHOSTFailure.invalid("Missing output.") }; return .data(id: id, text: text)
            case .exit: guard let exitCode else { throw BackendHOSTFailure.invalid("Missing exit status.") }; return .exit(id: id, exitCode: exitCode)
            case .status: guard let status else { throw BackendHOSTFailure.invalid("Missing session status.") }; return .status(id: id, status: status)
            case .removed: guard let reason else { throw BackendHOSTFailure.invalid("Missing removal reason.") }; return .removed(id: id, reason: reason)
            }
        }
    }

    public struct Request: Codable, Sendable {
        public enum Operation: String, Codable, Sendable {
            case chatWatch, hello, list, snapshot, create, write, resize, rename, account, conversation, remove, stopAll, watch, drain, resource, setWatched
        }
        public var protocolVersion = BackendHOSTProtocol.version
        public var secret: String
        public var operation: Operation
        public var instance: UUID?
        public var id: String?
        public var launch: Launch?
        public var bytes: Data?
        public var expectedCreatedAt: Double?
        public var drainTimeoutMilliseconds: Int?
        var drainTimeout: Int { min(60_000, max(0, drainTimeoutMilliseconds ?? 2_000)) }
        public var watched: Bool?
        /// SCROLL (9 Oct): a snapshot of the visible screen only — no replay, no scrollback.
        /// Older helpers ignore it and answer the full snapshot.
        public var viewportOnly: Bool?
        /// 27 Oct: an attach also wants `Snapshot.remount`. Older helpers ignore it.
        public var remount: Bool?
        public var cols: Int?
        public var rows: Int?
        public var title: String?
        public var account: BackendAccountIdentity?
        public var home: String?
        public var conversation: String?
        public var reason: BackendRemovalReason?
        public var pcDecision: BackendPCDecisionHostValidation.Envelope? = nil
        public var resourceMethod: String?
        public var resourcePayload: Data?
        public init(secret: String, operation: Operation, id: String? = nil) {
            self.secret = secret; self.operation = operation; self.id = id
        }
    }

    public struct Response: Codable, Sendable {
        public var hello: Hello?
        public var sessions: [BackendSessionMeta]?
        public var snapshot: Snapshot?
        public var event: Event?
        public var session: BackendSessionMeta?
        public var success: Bool?
        public var ready: Bool?
        public var error: String?
        /// 18 Oct (#107): what kind of refusal `error` is, where it matters (`unknown-channel`). Optional so an old
        /// app or host decodes it and remains untouched.
        public var errorCode: String? = nil
        public var resourcePayload: Data?
        public init(hello: Hello? = nil, sessions: [BackendSessionMeta]? = nil, snapshot: Snapshot? = nil,
                    event: Event? = nil, session: BackendSessionMeta? = nil, success: Bool? = nil,
                    ready: Bool? = nil, error: String? = nil, errorCode: String? = nil, resourcePayload: Data? = nil) {
            self.hello = hello; self.sessions = sessions; self.snapshot = snapshot; self.event = event
            self.session = session; self.success = success; self.ready = ready; self.error = error
            self.errorCode = errorCode; self.resourcePayload = resourcePayload
        }
    }
}

/// 18 Oct (#107): the session host does not know an account question (it is older than the app). Typed, so a
/// real refusal (a failed authentication, a refused account) is never mistaken for it.
public struct BackendHOSTUnknownChannel: Error, LocalizedError, Sendable {
    public static let code = "unknown-channel"
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum BackendHOSTFailure: Error, LocalizedError, Sendable {
    case invalid(String), unavailable, occupiedHost, incompatible(Int), authentication, io(Int32), remote(String), uncertainLaunch(String)
    public var errorDescription: String? {
        switch self {
        case .invalid(let detail), .remote(let detail): detail
        case .unavailable: "The session host is unavailable. Sessions won't survive updates right now."
        case .occupiedHost: "The session host still owns processes but cannot be reached yet. Retry before restoring saved sessions."
        case .incompatible(let version): "The running session host uses protocol \(version). Its sessions were left running."
        case .authentication: "The private session host could not be authenticated."
        case .io(let code): "The private session host connection failed (POSIX status \(code))."
        case .uncertainLaunch(let id): "The host launch reply was lost. Reattach session \(id) before retrying; no replacement process was started."
        }
    }
}
