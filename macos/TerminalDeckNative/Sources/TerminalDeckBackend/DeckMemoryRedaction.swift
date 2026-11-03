import Foundation

/// Keeps passwords, keys and tokens out of memory that travels (notes are plain files any AI app can open).
/// The diary itself stays word for word; this is applied to what is written into Markdown files, to what is
/// sent to the helper, and to diary text handed to a caller other than Hoot.
public enum DeckMemoryRedaction {
    public static let marker = "[secret removed]"
    public static let withheld = "[withheld: too large to check for secrets]"
    /// A field larger than this is withheld whole rather than passed through unchecked.
    public static let maxScanCharacters = 1_000_000

    /// The app's one rule (BackendSharedRedact, with its high-randomness sweep), written with this marker.
    /// Paths stay as they are: notes name real folders.
    private static let options = BackendSharedRedactOptions(keepIdentity: true, marker: marker)

    /// The text with anything that looks like a secret replaced by a visible marker. `removed` counts the replacements.
    public static func redact(_ text: String) -> (text: String, removed: Int) {
        guard text.count <= maxScanCharacters else { return (withheld, 1) }
        let result = BackendSharedRedact.redactWithCount(text, options: options)
        return (result.text, result.count)
    }
    public static func redacted(_ text: String) -> String { redact(text).text }

    nonisolated(unsafe) private static let privateBlock = try? NSRegularExpression(pattern: #"<private>[\s\S]*?</private>"#, options: [.caseInsensitive])
    public static let privateMarker = "[private]"
    /// Text the person wrapped in `<private>…</private>` stays in the diary but is never indexed and never sent to the helper.
    public static func withoutPrivate(_ text: String) -> String {
        guard let privateBlock, text.range(of: "<private>", options: .caseInsensitive) != nil else { return text }
        return privateBlock.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: privateMarker)
    }
    /// What may leave the diary for the helper or for a caller other than Hoot: private parts out, secrets out.
    public static func forSharing(_ text: String) -> String { redacted(withoutPrivate(text)) }
}
