import Foundation
import TerminalDeckNativeCore

/// WhatsApp agents (Asad, 15 Nov 2026, DESIGN-WHATSAPP.md second version): the person adds his WhatsApp agents as
/// PROFILES (a name and a key each, as many as he has, from one or several WhatsApp accounts) and chooses, whenever he likes, WHERE each one is received: Hoot, one of
/// his agents, one session, or nowhere. This file is the PUBLIC SHAPE the screens build against (Settings > AI apps group,
/// the "WhatsApp" submenu, the heading chip). Nothing here touches the network, a key or a screen.
/// Windows ports this file as it is.

/// Where one WhatsApp agent's messages are received.
public enum WhatsAppReceiver: Codable, Equatable, Hashable, Sendable {
    /// Kept, not received (no computer polls it).
    case nowhere
    /// Hoot: one lasting Hoot conversation named after the WhatsApp agent.
    case hoot
    /// One of his agents (seat or saved agent) by id: one lasting chat of that agent named after the WhatsApp agent.
    case agent(id: String, name: String)
    /// One session (chat or terminal) by its session id, on the computer it runs on.
    case session(id: String, name: String)

    /// What the pop-up and the tools show: "Hoot", the agent's or session's name, or "Nowhere".
    public var title: String {
        switch self {
        case .nowhere: return "Nowhere"
        case .hoot: return "Hoot"
        case .agent(_, let name), .session(_, let name): return name.isEmpty ? "Unnamed" : name
        }
    }
    /// The same receiver, compared by what it points at (a renamed session is still the same session).
    public func sameTarget(_ other: WhatsAppReceiver) -> Bool {
        switch (self, other) {
        case (.nowhere, .nowhere), (.hoot, .hoot): return true
        case (.agent(let a, _), .agent(let b, _)), (.session(let a, _), .session(let b, _)): return a == b
        default: return false
        }
    }
    /// Hoot and agents may be taken over by another computer after 10 minutes; a session never moves.
    public var canMoveComputer: Bool {
        switch self { case .hoot, .agent: return true; case .nowhere, .session: return false }
    }
}

/// The one state a row shows (design section 2).
public enum WhatsAppAgentState: String, Codable, Equatable, Sendable {
    /// Green dot: the key is accepted and he has written to the agent at least once.
    case connected
    /// No dot: the key is accepted but he has not written yet (the agent cannot write first).
    case waiting
    /// Orange: the key was refused (wrong or replaced). "Replace key" fixes it.
    case refused

    /// The secondary words beside the row, nil when the row shows none (connected).
    public var words: String? {
        switch self {
        case .connected: return nil
        case .waiting: return "Waiting for your first message"
        case .refused: return "The key was refused"
        }
    }
}

/// One WhatsApp agent, as every screen and tool sees it. Never holds the key.
public struct WhatsAppAgentProfile: Identifiable, Codable, Equatable, Sendable {
    /// Stable id made by the app when the agent is added (never derived from the key).
    public var id: String
    /// His own name for it ("WhatsApp agent", "WhatsApp agent 2", or what he typed).
    public var name: String
    public var state: WhatsAppAgentState
    public var receiver: WhatsAppReceiver
    /// The computer that polls this agent now (nil while it is received nowhere or no computer has taken it yet).
    public var answeringComputerName: String?
    /// True when the answering computer is this one.
    public var answeredHere: Bool
    /// True when this computer took it over by itself because the other one was off for more than 10 minutes.
    public var takenOver: Bool
    /// When his last message arrived (nil before the first).
    public var lastMessageAt: Date?
    /// The switch (Asad, 15 Nov): ON = the receiver's final answers and approval questions go to WhatsApp; OFF = nothing is
    /// sent to WhatsApp, the agent stays attached and is still read. Attaching turns it on; a message he writes from
    /// WhatsApp turns it on by itself; only he turns it off. Synced like the receiver.
    public var sending: Bool
    public init(id: String, name: String, state: WhatsAppAgentState, receiver: WhatsAppReceiver, answeringComputerName: String? = nil,
                answeredHere: Bool = false, takenOver: Bool = false, lastMessageAt: Date? = nil, sending: Bool = true) {
        self.id = id; self.name = name; self.state = state; self.receiver = receiver
        self.answeringComputerName = answeringComputerName; self.answeredHere = answeredHere; self.takenOver = takenOver
        self.lastMessageAt = lastMessageAt; self.sending = sending
    }
    /// "Answered by MacBook Pro" when another computer answers; nil when this one does or nobody does.
    public var answeredElsewhereWords: String? {
        guard !answeredHere, receiver != .nowhere, let name = answeringComputerName, !name.isEmpty else { return nil }
        return "Answered by " + name
    }
}

/// A refusal in one plain sentence (a refused key, a sixth agent, an empty name). Never carries the key.
public struct WhatsAppProblem: Error, LocalizedError, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
    public static let keyRefused = WhatsAppProblem("WhatsApp refused this key. Copy it again from the agent's Chat info > API key.")
    public static let notFound = WhatsAppProblem("That WhatsApp agent is not in the list any more.")
    public static let notReady = WhatsAppProblem("WhatsApp agents are not ready on this computer yet. Try again in a moment.")
    public static let unreachable = WhatsAppProblem("WhatsApp could not be reached. Check the internet connection and try again.")
}

public enum WhatsAppAgentsLimits {
    /// No limit on the number of agents on our side (Asad, 15 Nov: "If they have more API, they can connect").
    public static let maximumNameLength = 60
    /// "WhatsApp agent", then "WhatsApp agent 2", ...: the first free default name.
    public static func defaultName(taken: [String]) -> String {
        let base = "WhatsApp agent"
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains(base + " " + String(n)) { n += 1 }
        return base + " " + String(n)
    }
}

/// What the screens and the tools call. The engine (`BackendWhatsAppAgents`) implements it; the screens' store
/// (`NativeWhatsAppAgents`) and the picture tests use any implementation (a fixture in tests).
public protocol WhatsAppAgentsControlling: Sendable {
    /// The profiles, in the order he added them.
    func agents() async -> [WhatsAppAgentProfile]
    /// Called on every change of the list (state, receiver, answering computer, last message). Replaces the one before.
    func observe(_ changed: (@Sendable ([WhatsAppAgentProfile]) -> Void)?) async
    /// Checks the key with WhatsApp first; a refused key throws `WhatsAppProblem.keyRefused` and adds nothing.
    /// An empty name takes the next default name. The FIRST agent he adds is received by Hoot; later ones nowhere.
    @discardableResult func add(name: String, key: String) async throws -> WhatsAppAgentProfile
    func rename(_ id: String, to name: String) async throws
    /// Checks the new key with WhatsApp first; a refused key throws and keeps the old one.
    func replaceKey(_ id: String, key: String) async throws
    func remove(_ id: String) async throws
    /// Moves the agent to this receiver at once (taking it from wherever it was). `.nowhere` = kept, not received.
    /// A receiver that already has another WhatsApp agent keeps it too (one place can hold more than one).
    func setReceiver(_ id: String, _ receiver: WhatsAppReceiver) async throws
    /// "Off" in the submenu or the chip: every WhatsApp agent attached to this receiver goes to `.nowhere`.
    func off(_ receiver: WhatsAppReceiver) async throws
    /// The switch on an attached agent: on = answers and approvals go to WhatsApp; off = nothing is sent there.
    func setSending(_ on: Bool, for agentID: String) async throws
}

public extension WhatsAppAgentsControlling {
    /// "WhatsApp > <agent>" on a page or a session row: attaches it HERE (= setReceiver).
    func attach(_ id: String, to receiver: WhatsAppReceiver) async throws { try await setReceiver(id, receiver) }
}

/// An in-memory list for picture tests and previews: no network, no key kept (a key equal to `refusedKey` is refused).
public actor WhatsAppAgentsFixture: WhatsAppAgentsControlling {
    private var list: [WhatsAppAgentProfile]
    private var changed: (@Sendable ([WhatsAppAgentProfile]) -> Void)?
    private let refusedKey: String
    public init(_ list: [WhatsAppAgentProfile] = [], refusedKey: String = "refused-test-key") { self.list = list; self.refusedKey = refusedKey }
    public func agents() -> [WhatsAppAgentProfile] { list }
    public func observe(_ changed: (@Sendable ([WhatsAppAgentProfile]) -> Void)?) { self.changed = changed }
    private func tell() { changed?(list) }
    @discardableResult public func add(name: String, key: String) throws -> WhatsAppAgentProfile {
        guard key != refusedKey, !key.isEmpty else { throw WhatsAppProblem.keyRefused }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = WhatsAppAgentProfile(id: "wa-" + String(list.count + 1), name: trimmed.isEmpty ? WhatsAppAgentsLimits.defaultName(taken: list.map(\.name)) : trimmed,
                                           state: .waiting, receiver: list.isEmpty ? .hoot : .nowhere, answeringComputerName: "This Mac", answeredHere: true)
        list.append(profile); tell(); return profile
    }
    public func rename(_ id: String, to name: String) throws {
        guard let i = list.firstIndex(where: { $0.id == id }) else { throw WhatsAppProblem.notFound }
        list[i].name = name; tell()
    }
    public func replaceKey(_ id: String, key: String) throws {
        guard let i = list.firstIndex(where: { $0.id == id }) else { throw WhatsAppProblem.notFound }
        guard key != refusedKey, !key.isEmpty else { throw WhatsAppProblem.keyRefused }
        list[i].state = .waiting; tell()
    }
    public func remove(_ id: String) throws { list.removeAll { $0.id == id }; tell() }
    public func setReceiver(_ id: String, _ receiver: WhatsAppReceiver) throws {
        guard let i = list.firstIndex(where: { $0.id == id }) else { throw WhatsAppProblem.notFound }
        list[i].receiver = receiver; list[i].sending = true; tell()
    }
    public func setSending(_ on: Bool, for agentID: String) throws {
        guard let i = list.firstIndex(where: { $0.id == agentID }) else { throw WhatsAppProblem.notFound }
        list[i].sending = on; tell()
    }
    public func off(_ receiver: WhatsAppReceiver) {
        for i in list.indices where list[i].receiver.sameTarget(receiver) { list[i].receiver = .nowhere }
        tell()
    }
}

public extension Array where Element == WhatsAppAgentProfile {
    /// The WhatsApp agents attached to a page or session (the chip shows the first; the submenu checks each).
    func attached(to receiver: WhatsAppReceiver) -> [WhatsAppAgentProfile] { filter { $0.receiver.sameTarget(receiver) } }
    /// Whether "+ Add WhatsApp agent" shows: always (no limit on our side).
    var canAdd: Bool { true }
}
