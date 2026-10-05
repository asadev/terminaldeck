import Foundation

/// What a download is called on disk — a port of `src/main/browser-download-names.ts`,
/// so both browsers name files the same way.
///
/// The name comes from the website, so it is cleaned before it touches the
/// disk: no folder separators (a name cannot climb out of Downloads), no
/// characters Finder or Windows refuse, no leading dot (no hidden files), and
/// never a file that is already there — `report.pdf` becomes `report (2).pdf`.
public enum BrowserDownloadNaming {
    /// How many numbered names are tried before falling back to a timestamp.
    public static let maxVariants = 100

    /// The suggested name, made safe to write.
    public static func name(_ suggested: String) -> String {
        var flat = String(String.UnicodeScalarView(suggested.unicodeScalars.filter {
            !($0.value < 0x20 || $0.value == 0x7f)
        }))
        flat = flat.replacingOccurrences(of: #"[\\/]"#, with: " ", options: .regularExpression)
        flat = flat.replacingOccurrences(of: #"[:*?"<>|]"#, with: "", options: .regularExpression)
        flat = flat.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        flat = flat.trimmingCharacters(in: .whitespacesAndNewlines)
        flat = flat.replacingOccurrences(of: #"^[. ]+"#, with: "", options: .regularExpression)
        flat = flat.replacingOccurrences(of: #"[. ]+$"#, with: "", options: .regularExpression)
        if flat.isEmpty { return "download" }
        return flat.count > 120 ? String(flat.prefix(120)) : flat
    }

    /// A path in `directory` nothing is using yet: on disk (`exists`) or by
    /// another download still running (`taken`).
    public static func freePath(directory: String,
                                suggested: String,
                                exists: (String) -> Bool,
                                taken: Set<String> = [],
                                now: Date = Date()) -> String {
        let clean = name(suggested)
        let (stem, ext) = split(clean)
        let base = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
        for n in 1...maxVariants {
            let candidate = base + "/" + (n == 1 ? clean : "\(stem) (\(n))\(ext)")
            if !exists(candidate) && !taken.contains(candidate) { return candidate }
        }
        return base + "/" + "\(stem) (\(Int(now.timeIntervalSince1970 * 1000)))\(ext)"
    }

    /// `report.pdf` → (`report`, `.pdf`); a leading dot is not an extension.
    static func split(_ name: String) -> (stem: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        return (String(name[..<dot]), String(name[dot...]))
    }
}

/// One row of the downloads list, as kept across relaunch — the web browser's
/// ledger (`browser-downloads-store.ts`): at most 100 rows, newest first, and a
/// row that was still moving when the app closed comes back as failed, saying so.
public struct BrowserDownloadRow: Equatable, Sendable, Codable {
    /// "downloading", "done", "failed" or "cancelled" — the web ledger's words.
    public var id: String
    public var name: String
    public var path: String
    public var url: String
    public var state: String
    public var received: Int64
    public var bytes: Int64
    public var message: String
    public var startedAt: Double

    public init(id: String, name: String, path: String = "", url: String = "", state: String,
                received: Int64 = 0, bytes: Int64 = 0, message: String = "", startedAt: Double = 0) {
        self.id = id
        self.name = name
        self.path = path
        self.url = url
        self.state = state
        self.received = received
        self.bytes = bytes
        self.message = message
        self.startedAt = startedAt
    }
}

public enum BrowserDownloadLedger {
    public static let maxRows = 100
    static let states: Set<String> = ["downloading", "delivering", "done", "cancelled", "failed"]

    public static func encode(_ rows: [BrowserDownloadRow]) -> Data {
        (try? JSONEncoder().encode(["items": Array(rows.prefix(maxRows))])) ?? Data()
    }

    public static func decode(_ data: Data?) -> [BrowserDownloadRow] {
        guard let data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = object["items"] as? [Any] else { return [] }
        var out: [BrowserDownloadRow] = []
        for entry in list {
            guard let fields = entry as? [String: Any], let id = fields["id"] as? String, !id.isEmpty else { continue }
            let stored = (fields["state"] as? String).flatMap { states.contains($0) ? $0 : nil } ?? "failed"
            let wasMoving = stored == "downloading" || stored == "delivering"
            out.append(BrowserDownloadRow(
                id: id,
                name: (fields["name"] as? String) ?? "",
                path: (fields["path"] as? String) ?? "",
                url: (fields["url"] as? String) ?? "",
                state: wasMoving ? "failed" : stored,
                received: (fields["received"] as? NSNumber)?.int64Value ?? 0,
                bytes: (fields["bytes"] as? NSNumber)?.int64Value ?? 0,
                message: wasMoving ? "Terminal Deck closed while this was moving." : ((fields["message"] as? String) ?? ""),
                startedAt: (fields["startedAt"] as? NSNumber)?.doubleValue ?? 0))
            if out.count >= maxRows { break }
        }
        return out
    }

    /// What the toolbar's Downloads button says, or nil for no button at all —
    /// the web browser's `downloadsBadge`: absent until there is a download; the
    /// number still moving; "!" when the newest failed; else how many there are.
    public static func badge(_ rows: [BrowserDownloadRow]) -> (label: String, tone: String)? {
        let moving = rows.filter { $0.state == "downloading" || $0.state == "delivering" }.count
        if moving > 0 { return (String(moving), "busy") }
        guard let newest = rows.first else { return nil }
        if newest.state == "failed" { return ("!", "bad") }
        return (String(rows.count), "done")
    }
}
