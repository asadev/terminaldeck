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
