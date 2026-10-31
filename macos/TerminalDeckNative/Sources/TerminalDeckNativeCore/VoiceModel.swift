import Foundation

/// Settings → Tools' voice key, as data: a port of the pure parts of
/// `settings/sections/VoiceKeyRow.tsx` and `ToolsSection.tsx`. Same narrowing, same words.

public struct VoiceProvider: Equatable, Sendable, Identifiable {
    public let id: String
    public let label: String
    public let model: String
    public let note: String
    public let keysUrl: String

    /// `asProviders`: rows with an id and a label, the rest as text or "".
    public static func list(_ raw: CodingAIJSON) -> [VoiceProvider] {
        (raw.array ?? []).compactMap { entry in
            guard entry.object != nil, let id = entry["id"].string, let label = entry["label"].string else { return nil }
            return VoiceProvider(id: id, label: label, model: entry["model"].string ?? "", note: entry["note"].string ?? "",
                                 keysUrl: entry["keysUrl"].string ?? "")
        }
    }

    /// The picker's option: "Groq · whisper-large-v3".
    public var optionLabel: String { "\(label) · \(model)" }
    /// "Get a Groq key", only when there is somewhere to get one.
    public var getKeyLabel: String? { keysUrl.isEmpty ? nil : "Get a \(label) key" }
}

public struct VoiceStatus: Equatable, Sendable {
    public let provider: String?
    public let hasKey: Bool
    public let canStore: Bool
    public let reason: String?

    /// `asStatus`: anything unreadable is "no key, can store".
    public static func from(_ raw: CodingAIJSON) -> VoiceStatus {
        guard raw.object != nil else { return VoiceStatus(provider: nil, hasKey: false, canStore: true, reason: nil) }
        return VoiceStatus(provider: raw["provider"].string, hasKey: raw["hasKey"].isTrue,
                           canStore: raw["canStore"].bool != false, reason: raw["reason"].string)
    }
}

public enum VoiceWords {
    public static let groupTitle = "Voice dictation"
    public static let serviceLabel = "Transcription service"
    public static let serviceHelp = "Speech is transcribed by the service you choose, using the key you paste below."
    public static let keyLabel = "API key"
    public static let keyMore = "The key is encrypted by your operating system's own secure store — Keychain on macOS, DPAPI on Windows — and never leaves this machine except in the request that transcribes your audio."
    public static let keyPlaceholder = "Paste the key"
    public static let storedLabel = "Transcription"
    public static let storedMore = "Recording happens only while the microphone button is live. The audio goes to the provider you chose and nowhere else, and this app keeps no copy of it."
    public static let remove = "Remove key"
    public static let whyTitle = "Why a key, and not a model in the app"
    public static let whyMore = "Speech recognition inside this window does not work: Chromium's own recogniser starts and then stays silent forever, because the service behind it ships only with Google's own builds. Running Whisper locally instead is allowed — its code is MIT, the large-v3 weights are Apache-2.0, and the GGML conversions are MIT, so a download would be legal — but this app has no local inference runtime to run them with yet, and a three-gigabyte download that cannot be used is worse than none. The hosted route uses the same model: Groq serves whisper-large-v3 itself."
    public static let whyText = "Recording happens here; the words come back from the service you pick."

    /// The stored key's help line.
    public static func storedHelp(_ provider: VoiceProvider?) -> String {
        guard let provider else { return "A key is stored. The microphone is in the chat box." }
        return "Connected to \(provider.label), transcribing with \(provider.model). The microphone is in the chat box."
    }

    /// Check and save: its label and its help.
    public static func saveLabel(working: Bool) -> String { working ? "Checking…" : "Check and save" }
    public static func saveHelp(key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Paste a key first."
            : "Sends a fraction of a second of silence to check the key before saving it."
    }

    /// What `voice:save` answered: whether it took, and its sentence.
    public static func saveResult(_ raw: CodingAIJSON) -> (ok: Bool, text: String) {
        (raw.object != nil && raw["ok"].isTrue, raw["message"].string ?? "")
    }
}
