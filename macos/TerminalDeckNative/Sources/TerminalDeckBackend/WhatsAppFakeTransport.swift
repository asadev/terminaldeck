import Foundation

/// A scriptable stand-in for WhatsApp, for everyone's tests (engine, screens, tools). Foundation only.
///
/// - Messages: `deliver` puts new messages after the head (what an offset-less poll returns); `addBacklog` puts messages
///   before the head (only `offset: 0` or an older offset sees them). Each entry has a sequence number from 1;
///   a poll returns up to 50 entries at or after its offset and `next` = the last one's number + 1, as WhatsApp does.
/// - Outcomes: `scriptPolls` / `scriptSends` / `scriptReads` / `scriptChecks` queue answers that are used first, in order
///   (nothing, replaced, key refused, back off, failed ...). `refuse(key:)` refuses a key everywhere.
/// - Records: `polls`, `sent`, `reads`, `checks`, `mediaFetches`, each with the virtual time it happened.
/// - Virtual time: `now` starts at 0 and moves only by `advance(by:)` or a poll that finds nothing (by its timeout),
///   so tests never sleep.
public actor WhatsAppFakeTransport: WhatsAppTransport {
    public struct PollCall: Equatable, Sendable { public let key: String; public let offset: Int64?; public let timeout: Int; public let at: Double }
    public struct SentText: Equatable, Sendable { public let key: String; public let to: String; public let text: String; public let at: Double }
    public struct ReadMark: Equatable, Sendable { public let key: String; public let messageID: String; public let typing: Bool; public let at: Double }

    public private(set) var now: Double = 0
    public private(set) var polls: [PollCall] = []
    public private(set) var sent: [SentText] = []
    public private(set) var reads: [ReadMark] = []
    public private(set) var checks: [String] = []
    public private(set) var mediaFetches: [String] = []
    /// When set, a send to anyone else answers `.notCreator` (as WhatsApp's 403 131005).
    public private(set) var creator: String?
    /// When true, the manual's per-key limits answer `.backOff` (12 sends, 12 status calls, 15 polls a minute).
    public private(set) var limitsEnforced = false

    private var log: [(seq: Int64, message: WhatsAppInbound)] = []
    private var nextSeq: Int64 = 1
    private var head: Int64 = 1
    private var refused: Set<String> = []
    private var pollScript: [WhatsAppPoll] = []
    private var sendScript: [WhatsAppSent] = []
    private var readScript: [WhatsAppSent] = []
    private var checkScript: [WhatsAppKeyCheck] = []
    private var stored: [String: WhatsAppMedia] = [:]
    private var windows: [String: [Double]] = [:]

    public init(creator: String? = "user:1000") { self.creator = creator }

    // MARK: - Scripting

    public func deliver(_ messages: [WhatsAppInbound]) { for message in messages { append(message) } }
    public func deliver(_ messages: WhatsAppInbound...) { deliver(messages) }
    /// Messages already there before the agent was connected: behind the head.
    public func addBacklog(_ messages: [WhatsAppInbound]) {
        for message in messages { append(message) }
        head = nextSeq
    }
    public func scriptPolls(_ outcomes: [WhatsAppPoll]) { pollScript += outcomes }
    public func scriptSends(_ outcomes: [WhatsAppSent]) { sendScript += outcomes }
    public func scriptReads(_ outcomes: [WhatsAppSent]) { readScript += outcomes }
    public func scriptChecks(_ outcomes: [WhatsAppKeyCheck]) { checkScript += outcomes }
    /// The next poll answers `.replaced`, as when another computer started reading this agent.
    public func replaceNextPoll() { pollScript.append(.replaced) }
    public func refuse(key: String) { refused.insert(key) }
    public func accept(key: String) { refused.remove(key) }
    public func setCreator(_ creator: String?) { self.creator = creator }
    public func enforceLimits(_ on: Bool = true) { limitsEnforced = on }
    public func setMedia(id: String, _ media: WhatsAppMedia) { stored[id] = media }
    public func advance(by seconds: Double) { now += max(seconds, 0) }
    /// The texts sent, in order (any key).
    public var sentTexts: [String] { sent.map(\.text) }
    /// The sequence number the next delivered message gets (= the `next` a poll would give after it).
    public var nextOffset: Int64 { nextSeq }

    /// A text message from `from`, `seconds` after 1 Jan 2026, for quick scripts.
    public static func text(_ body: String, id: String, from: String = "user:1000", at seconds: Double = 0) -> WhatsAppInbound {
        WhatsAppInbound(id: id, from: from, timestamp: Date(timeIntervalSince1970: 1_767_225_600 + seconds), kind: .text, text: body)
    }

    // MARK: - The protocol

    public func check(key: String) async -> WhatsAppKeyCheck {
        checks.append(key)
        if refused.contains(key) { return .refused }
        if !checkScript.isEmpty { return checkScript.removeFirst() }
        return .accepted
    }

    public func poll(key: String, offset: Int64?, timeout: Int) async -> WhatsAppPoll {
        polls.append(PollCall(key: key, offset: offset, timeout: timeout, at: now))
        if refused.contains(key) { return .keyRefused }
        if let wait = overLimit(key + "#poll", 15) { return .backOff(seconds: wait) }
        if !pollScript.isEmpty { return pollScript.removeFirst() }
        let from = offset.map { max($0, 0) } ?? head
        let found = log.filter { $0.seq >= from }.prefix(50)
        guard let last = found.last else {
            now += Double(min(max(timeout, 0), 25))
            return .nothing
        }
        return .messages(found.map(\.message), next: last.seq + 1)
    }

    public func markRead(key: String, messageID: String, typing: Bool) async -> WhatsAppSent {
        if refused.contains(key) { return .keyRefused }
        if let wait = overLimit(key + "#status", 12) { return .backOff(seconds: wait) }
        if !readScript.isEmpty { return readScript.removeFirst() }
        reads.append(ReadMark(key: key, messageID: messageID, typing: typing, at: now))
        return .sent
    }

    public func send(key: String, to: String, text: String) async -> WhatsAppSent {
        if refused.contains(key) { return .keyRefused }
        if let creator, to != creator { return .notCreator }
        guard !text.isEmpty, text.utf16.count <= WhatsAppText.limit else {
            return .failed("The message is longer than WhatsApp allows (\(WhatsAppText.limit) characters).")
        }
        if let wait = overLimit(key + "#send", 12) { return .backOff(seconds: wait) }
        if !sendScript.isEmpty {
            let outcome = sendScript.removeFirst()
            if outcome != .sent { return outcome }
        }
        sent.append(SentText(key: key, to: to, text: text, at: now))
        return .sent
    }

    public func media(key: String, id: String, limit: Int) async -> WhatsAppMedia? {
        mediaFetches.append(id)
        guard !refused.contains(key), let media = stored[id], media.data.count <= limit else { return nil }
        return media
    }

    // MARK: - Private

    private func append(_ message: WhatsAppInbound) {
        log.append((nextSeq, message))
        nextSeq += 1
    }

    /// With limits on: records the call, or gives the seconds until the rolling minute has room.
    private func overLimit(_ window: String, _ most: Int) -> Double? {
        guard limitsEnforced else { return nil }
        let recent = (windows[window] ?? []).filter { now - $0 < 60 }
        if recent.count >= most {
            windows[window] = recent
            return max(60 - (now - recent[0]), 0.001)
        }
        windows[window] = recent + [now]
        return nil
    }
}
