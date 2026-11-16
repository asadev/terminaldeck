import Foundation

/// The WhatsApp Agent Platform client's SHAPE (DESIGN-WHATSAPP.md section 1). Depends on Foundation only, so Windows
/// ports it file for file. The engine calls only `WhatsAppTransport`; the real one (`WhatsAppHTTPTransport`, URLSession,
/// limits, back-off, one send at a time per key) and the fake one for tests (`WhatsAppFakeTransport`) implement it.
/// No value here ever holds the key except the `key` argument itself, and no implementation may log, throw or return it.

/// One message from the agent's creator, as the engine needs it.
public struct WhatsAppInbound: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable { case text, image, audio, video, document, sticker, reaction, other }
    /// WhatsApp's message id (wamid): what "mark read" names.
    public let id: String
    /// "user:<id>": the creator. The ONLY value a send may ever be addressed to.
    public let from: String
    public let timestamp: Date
    public let kind: Kind
    /// The text of a text message (nil otherwise).
    public let text: String?
    /// A picture's or document's caption.
    public let caption: String?
    /// A picture's, voice note's, video's or document's media id (`GET /media/<id>`).
    public let mediaID: String?
    public let mimeType: String?
    public let fileName: String?
    public init(id: String, from: String, timestamp: Date, kind: Kind, text: String? = nil, caption: String? = nil,
                mediaID: String? = nil, mimeType: String? = nil, fileName: String? = nil) {
        self.id = id; self.from = from; self.timestamp = timestamp; self.kind = kind; self.text = text; self.caption = caption
        self.mediaID = mediaID; self.mimeType = mimeType; self.fileName = fileName
    }
}

/// What one long-poll gave.
public enum WhatsAppPoll: Equatable, Sendable {
    /// 200: the messages in order and the offset to ask from next.
    case messages([WhatsAppInbound], next: Int64)
    /// 204: nothing new; poll again with the same offset.
    case nothing
    /// 409 (code 1752041): a newer reader took this agent. Stop polling it and re-read the settings.
    case replaced
    /// 400 code 100 or 401 code 190: the key is wrong or was replaced.
    case keyRefused
    /// 429, 5xx or no connection: wait this long (already grown by the transport's own back-off), then try again.
    case backOff(seconds: Double)
}

/// What a send or a status call gave.
public enum WhatsAppSent: Equatable, Sendable {
    case sent
    case keyRefused
    /// 403 code 131005: not the creator. The engine never addresses anyone else; this is reported, never retried.
    case notCreator
    /// 429 or 5xx: the transport already waited and retried within its limits; this one was not sent.
    case backOff(seconds: Double)
    /// Anything else, in one plain sentence without the key.
    case failed(String)
}

/// Whether WhatsApp accepts a key (checked before a key is added or replaced).
public enum WhatsAppKeyCheck: Equatable, Sendable { case accepted, refused, unreachable }

/// A media item's bytes, fetched with the same key.
public struct WhatsAppMedia: Equatable, Sendable {
    public let data: Data
    public let mimeType: String
    public let fileName: String?
    public init(data: Data, mimeType: String, fileName: String? = nil) { self.data = data; self.mimeType = mimeType; self.fileName = fileName }
}

/// The calls of design section 1. Every call names the agent by its key (the key identifies the agent).
/// Limits per key are the implementation's job: 12 sends a minute, 12 status calls a minute, 15 polls a minute;
/// sends and status calls for one key strictly one after another, never two at once.
public protocol WhatsAppTransport: Sendable {
    /// One quick look that does not keep a reader (`GET /updates` with `timeout=0`, `limit=1`, no offset).
    func check(key: String) async -> WhatsAppKeyCheck
    /// `GET /updates?offset=&limit=50&timeout=`. `offset` nil = start at the head; 0 = the whole backlog.
    func poll(key: String, offset: Int64?, timeout: Int) async -> WhatsAppPoll
    /// `POST /statuses` read, with the typing indicator when `typing` is true (it lasts 25 s; call again to keep it).
    func markRead(key: String, messageID: String, typing: Bool) async -> WhatsAppSent
    /// `POST /messages` one text of at most 4096 characters to `to` ("user:<id>", copied from an inbound `from`).
    func send(key: String, to: String, text: String) async -> WhatsAppSent
    /// `GET /media/<id>` then its url with the same key; nil when it is larger than `limit` bytes or could not be fetched.
    func media(key: String, id: String, limit: Int) async -> WhatsAppMedia?
}

/// Text as WhatsApp reads it (design section 4): `*bold*`, `_italic_`, triple backticks for code, plain lists,
/// a table as lines, links as plain URLs; and the split at paragraph ends to 4096 characters.
public enum WhatsAppText {
    public static let limit = 4096
    /// Markdown (what the AIs write) -> WhatsApp's own marks (rules in WhatsAppTextRules.swift).
    public static func format(_ markdown: String) -> String { WhatsAppTextRules.format(markdown) }
    /// Pieces of at most `limit` UTF-16 units, cut at paragraph ends first, then line ends, sentence ends, word ends;
    /// a code block that fits one piece is never cut, a longer one is closed and reopened. In order; [] for blank text.
    public static func split(_ text: String, limit: Int = WhatsAppText.limit) -> [String] {
        WhatsAppTextRules.split(text, limit: limit)
    }
}
