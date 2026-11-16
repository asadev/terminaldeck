import Foundation
import TerminalDeckNativeCore

/// The phones' three asks of 14 Nov (team/phone-apps/notes/2026-11-14-mac-asks.md), the Mac side.
///
/// The wire is the phones' own (td-phones-next: iOS `HostLink` `.error` / `.created`, `WireCodec` session row; Android
/// `HostLink.applyError`), no frame of its own:
/// - `start.text`: a phone that claims it, and hears it back, may send an optional `text` on `create` and
///   `chats.new`. A Chat takes it as its first message; a Terminal gets it typed (as the session's own paste setting
///   takes a paste, then Return on its own) only when the AI's own empty prompt is on screen (`NativeLandingTerminal`,
///   the Mac's own New session rule). Sent: nothing more is said. Not sent (two minutes without the prompt, the session
///   gone, a chat that refused it, a multi-line text a program without bracketed paste would run line by line): one
///   `error` frame `{code: "unavailable", message, rid: <the start's rid>}`; the phone puts ITS OWN kept copy of the
///   text back in its box (it is never sent back).
/// - `start.rid`: a phone that claims it, and hears it back, finds the `rid` of its own `create` / `chats.new` as
///   `rid` on the session row of the `created` answer and of every later `sessions` list, so a phone that lost its
///   connection mid-start finds ITS session exactly. Only the device that started it is shown it.
///
/// Older phones claim neither, so they are sent none of these fields or frames: their answers are as before.
/// Older Macs drop an unknown `text` silently (each frame is rebuilt from its known fields), so a new phone sends
/// `text` only to a Mac that advertised `start.text`.
public enum BackendPhoneStartText {
    public static let textCapability = "start.text"
    public static let ridCapability = "start.rid"

    /// One first message to deliver into a session a phone just started.
    public struct Job: Sendable, Equatable {
        public let sessionID: String
        public let provider: String
        public let chat: Bool
        public let text: String
        public init(sessionID: String, provider: String, chat: Bool, text: String) {
            self.sessionID = sessionID; self.provider = provider; self.chat = chat; self.text = text
        }
    }
    /// The app's delivery: true once the text went in (Chat said / Terminal typed and Return pressed).
    public typealias Deliver = @Sendable (Job) async -> Bool

    public static let notSent = "Your first message was not sent: the AI did not get ready. It is back in the box."

    /// What the phone is told after one delivery: nothing when sent; when not sent, the `error` its start page reads
    /// by the start's rid (without a rid the phone could not tell which start it was: nothing).
    public static func answer(rid: String?, sent: Bool) throws -> BackendRemoteServerMessage? {
        guard !sent, let rid else { return nil }
        return try .init(.error, fields: [.init("code", .string("unavailable")), .init("message", .string(notSent)), .init("rid", .string(rid))])
    }

    /// Which rids this Mac keeps for the sessions phones started (by session id; newest 256, this run only).
    struct Rids: Sendable {
        private(set) var bySession: [String: (device: String, rid: String)] = [:]
        private var order: [String] = []
        static let kept = 256
        mutating func note(session: String, device: String, rid: String) {
            if bySession[session] == nil { order.append(session) }
            bySession[session] = (device, rid)
            while order.count > Self.kept { bySession[order.removeFirst()] = nil }
        }
        func rid(session: String, device: String) -> String? {
            guard let row = bySession[session], row.device == device else { return nil }
            return row.rid
        }
    }
}

extension BackendRemoteCreateRequest {
    /// The same request from outside this module (the app's tests); the memberwise one stays as it was.
    public static func make(deviceID: String, cwd: String, provider: String?, cols: Int = 80, rows: Int = 24,
                            choices: BackendRemoteStartChoices = .init()) -> Self {
        var request = Self(deviceID: deviceID, cwd: cwd, provider: provider, cols: cols, rows: rows)
        request.choices = choices
        return request
    }
}

extension BackendRemoteHost {
    /// The app's first-message delivery. Without one, `start.text` is never advertised.
    public func setStartTextDelivery(_ deliver: BackendPhoneStartText.Deliver?) { startTextDelivery = deliver }
    /// The Mac's own New session default folder (`~/Terminal Deck/Independent`): listed among the folders the
    /// person's OWN devices may start in. A guest's folders are its grants alone (`BackendRemoteTrustStore.reach`),
    /// so this opens nothing to a guest; the owner's device may start anywhere already (`unrestricted`).
    public func setDefaultStartFolder(_ folder: (@Sendable () -> String?)?) { defaultStartFolder = folder }

    func claims(_ connection: UUID, _ capability: String) -> Bool { live[connection]?.capabilities.contains(capability) == true }

    /// The `created` answer for a phone's start: the session row's `rid` only to a phone that claimed `start.rid`;
    /// otherwise exactly the frame as before.
    func createdFrame(_ meta: BackendSessionMeta, rid: String?, connection: UUID) throws -> BackendRemoteServerMessage {
        let plain = try BackendRemoteServeSessionCreate.Outcome.created(meta).message()
        guard let rid, claims(connection, BackendPhoneStartText.ridCapability) else { return plain }
        return try BackendRemoteServeSessionCreate.Outcome.created(meta).message(rid: rid)
    }

    /// A phone's start went through (`create` or `chats.new`, every check already made): keep its rid on the session,
    /// and deliver its first message; when it was not sent, the device's live connections that claimed `start.text`
    /// are told by an `error` with the start's rid.
    /// True when the rid was kept (the session's row changed for that device).
    @discardableResult
    public func phoneStarted(connection: UUID, deviceID: String, meta: BackendSessionMeta, rid: String?, text: String?) -> Bool {
        var kept = false
        if let rid, claims(connection, BackendPhoneStartText.ridCapability) {
            startRids.note(session: meta.id, device: deviceID, rid: rid); kept = true
        }
        guard let text, !text.isEmpty, claims(connection, BackendPhoneStartText.textCapability), let deliver = startTextDelivery else { return kept }
        let job = BackendPhoneStartText.Job(sessionID: meta.id, provider: meta.provider, chat: meta.chat == true, text: text)
        // Held until the `created` answer has gone out (`startDeliveries`): a "not sent" never overtakes it.
        startDeliveriesWaiting[connection, default: []].append(job.sessionID)
        startDeliveryJobs[job.sessionID] = (job, rid, deviceID, deliver)
        return kept
    }

    /// After the answer to a start was sent on this connection (or it failed): the first messages it held begin.
    /// Returns how many began (tests).
    @discardableResult
    func startDeliveries(_ connection: UUID) -> Int {
        let waiting = startDeliveriesWaiting.removeValue(forKey: connection) ?? []
        var begun = 0
        for session in waiting {
            guard let held = startDeliveryJobs.removeValue(forKey: session) else { continue }
            begun += 1
            Task { [weak self] in
                let sent = await held.deliver(held.job)
                await self?.answerStartText(held.job, rid: held.rid, deviceID: held.deviceID, sent: sent)
            }
        }
        return begun
    }

    /// A "not sent" goes to every live connection of that device that claimed `start.text` (the one that started it
    /// may have dropped and come back). Returns how many were told (tests).
    @discardableResult
    func answerStartText(_ job: BackendPhoneStartText.Job, rid: String?, deviceID: String, sent: Bool) async -> Int {
        guard let frame = try? BackendPhoneStartText.answer(rid: rid, sent: sent) else { return 0 }
        var told = 0
        for (connection, row) in live where row.device?.id == deviceID && row.capabilities.contains(BackendPhoneStartText.textCapability) {
            if (try? await sendToConnection(connection, message: frame)) != nil { told += 1 }
        }
        return told
    }

    /// The rid a session row carries for this device (`start.rid` claimed), else nil.
    func startRid(_ session: String, context: BackendRemoteHostContext) -> String? {
        guard context.claimedCapabilities.contains(BackendPhoneStartText.ridCapability) else { return nil }
        return startRids.rid(session: session, device: context.deviceID)
    }
}
