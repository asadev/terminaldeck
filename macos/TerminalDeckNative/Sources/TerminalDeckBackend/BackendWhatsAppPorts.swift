import Foundation
import TerminalDeckNativeCore

/// The doors the WhatsApp engine reaches the rest of the app through (DESIGN-WHATSAPP.md sections 4 and 5). The engine
/// depends on nothing else, so tests run it with fakes and Windows ports it with its own five doors.

// MARK: - The synced record of one WhatsApp agent

/// One WhatsApp agent as every computer of his keeps it: a synced app setting `whatsapp.agent.<id>` (a JSON text,
/// newest change wins). Never the key (that travels in saved passwords).
public struct WhatsAppAgentRecord: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var receiver: WhatsAppReceiver
    /// The computer that polls this agent (its receiver's computer). nil = none (received nowhere).
    public var readerID: String?
    public var readerName: String?
    /// True when `readerID` took it over by itself (the other computer was off for more than 10 minutes).
    public var takenOver: Bool
    /// The agent's creator ("user:<id>"), learned from his first message; the only address ever written to.
    public var creator: String?
    /// Where the next poll starts (WhatsApp's `next_offset`). nil = never read: the first read only learns the head.
    public var offset: Int64?
    /// His last message (ms since 1970).
    public var lastMessageAt: Double?
    /// WhatsApp refused the key (orange row) until a new key is given.
    public var refused: Bool
    /// A session receiver ended: the next message is answered once with "That session has ended…", then the reader stops.
    public var endedSession: Bool
    /// Removed in the app (a mark, so the removal travels like any change; the key goes by the delete rule).
    public var removed: Bool
    /// When he added it (ms), for the list's order.
    public var addedAt: Double
    /// The switch: nil or true = the receiver's answers and approvals go to WhatsApp; false = nothing is sent there.
    public var sending: Bool?
    public var isSending: Bool { sending != false }
    /// Security review fault 1: which key this record belongs to, as a short non-secret fingerprint (the first 16 hex of
    /// the key's SHA-256). A computer reads the agent only while its own stored key has this fingerprint.
    public var keyID: String?
    /// The session receiver's Cloud id (the SAME on every computer, unlike its local id): how a session that moves to
    /// another computer ("Switch to this Mac") takes its WhatsApp agent with it. Kept while the agent is at that session
    /// (and after it went Nowhere because the session ended); nil for Hoot, an agent or Nowhere chosen by him.
    public var cloudSessionID: String?
    public init(id: String, name: String, receiver: WhatsAppReceiver, readerID: String? = nil, readerName: String? = nil, takenOver: Bool = false,
                creator: String? = nil, offset: Int64? = nil, lastMessageAt: Double? = nil, refused: Bool = false, endedSession: Bool = false,
                removed: Bool = false, addedAt: Double, sending: Bool? = true) {
        self.id = id; self.name = name; self.receiver = receiver; self.readerID = readerID; self.readerName = readerName; self.takenOver = takenOver
        self.creator = creator; self.offset = offset; self.lastMessageAt = lastMessageAt; self.refused = refused; self.endedSession = endedSession
        self.removed = removed; self.addedAt = addedAt; self.sending = sending
    }
    /// What the reader decision depends on: a change here restarts a reader that a 409 stopped.
    var readerKey: String { [readerID ?? "", receiver.title, String(refused), String(removed), String(endedSession)].joined(separator: "|") }
}

/// Where the records live (the synced settings).
public protocol WhatsAppSettingsPort: Sendable {
    func records() async -> [WhatsAppAgentRecord]
    func save(_ record: WhatsAppAgentRecord) async throws
    /// Called after any record changed (here or arriving from another computer).
    func observe(_ changed: @escaping @Sendable () -> Void) async
}

// MARK: - Keys and computers

/// This computer and the account's other computers (the Cloud account's device list).
public struct WhatsAppComputer: Equatable, Sendable {
    public let id: String, name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}
public protocol WhatsAppPresencePort: Sendable {
    func thisComputer() async -> WhatsAppComputer
    /// When the account last saw that computer; nil = unknown.
    func lastSeen(_ computerID: String) async -> Date?
    func name(_ computerID: String) async -> String?
}

// MARK: - The receivers

/// The session that takes a WhatsApp agent's messages: a chat session (Hoot's lasting conversation and an agent's
/// lasting chat are chat sessions too) or a terminal session.
public struct WhatsAppTarget: Equatable, Hashable, Sendable {
    public let sessionID: String
    public let isTerminal: Bool
    public init(sessionID: String, isTerminal: Bool) { self.sessionID = sessionID; self.isTerminal = isTerminal }
}
/// One approval the receiver waits for: what it wants in one line and the command or file exactly.
public struct WhatsAppApproval: Equatable, Sendable {
    public let id: String, summary: String, detail: String
    public init(id: String, summary: String, detail: String) { self.id = id; self.summary = summary; self.detail = detail }
}
public enum WhatsAppTurnState: Equatable, Sendable {
    case idle, working
    case needsApproval([WhatsAppApproval])
    case done(answer: String)
    case failed(reason: String)
}
public struct WhatsAppTurn: Equatable, Sendable {
    public let turnID: String?
    public let state: WhatsAppTurnState
    public init(turnID: String?, state: WhatsAppTurnState) { self.turnID = turnID; self.state = state }
}
/// A picture or a document he sent, as the chat takes it.
public struct WhatsAppAttachment: Equatable, Sendable {
    public let data: Data, mimeType: String, fileName: String?
    public init(data: Data, mimeType: String, fileName: String?) { self.data = data; self.mimeType = mimeType; self.fileName = fileName }
}

public protocol WhatsAppReceiverPort: Sendable {
    /// The session for this receiver now. For Hoot and an agent: their ONE lasting conversation named
    /// `conversationName`, made on first use and kept (keyed by `agentID`). For a session: itself; nil when it ended.
    func target(for receiver: WhatsAppReceiver, conversationName: String, agentID: String) async throws -> WhatsAppTarget?
    /// His message into the chat as if he had typed it there.
    func say(_ target: WhatsAppTarget, text: String, attachments: [WhatsAppAttachment]) async throws
    func turn(_ target: WhatsAppTarget) async -> WhatsAppTurn?
    func approve(_ target: WhatsAppTarget, approvalID: String, allow: Bool) async throws -> Bool
    /// A terminal: typed in, then Return.
    func type(_ target: WhatsAppTarget, text: String) async throws
    /// A terminal's screen text now (its last lines).
    func screen(_ target: WhatsAppTarget) async -> String?
    func isOpen(_ target: WhatsAppTarget) async -> Bool
    /// Whether a tool call carrying `sessionID` comes from this target (its own id, or for Hoot's lasting conversation
    /// the AI process behind it): how a tool knows "the turn came from that same WhatsApp agent".
    func isToolSession(_ target: WhatsAppTarget, _ sessionID: String) async -> Bool
    /// A local session's Cloud id (the same on every computer); nil when unknown.
    func cloudSessionID(_ sessionID: String) async -> String?
    /// True while the session with this Cloud id is being moved AWAY from this computer, or was handed over from it
    /// (the move's own journal says so): its WhatsApp agent is held for the computer that takes it, never sent Nowhere.
    func leaving(cloudSessionID: String) async -> Bool
}

public extension WhatsAppReceiverPort {
    func cloudSessionID(_ sessionID: String) async -> String? { nil }
    func leaving(cloudSessionID: String) async -> Bool { false }
}
