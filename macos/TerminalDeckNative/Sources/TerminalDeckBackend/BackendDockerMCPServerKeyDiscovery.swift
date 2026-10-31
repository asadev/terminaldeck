import Foundation

/// Listing uses metadata only. Key bytes enter only the existing approved
/// credential-input path after an offered file is selected.
public enum BackendDockerMCPServerKeyDiscovery {
    public static func list(directory: URL, reader: BackendServersKeyFolderReader) -> [BackendServersKeyFileOffer] {
        let home = directory.deletingLastPathComponent()
        var candidates = (try? reader.entries(directory.path))?.filter { permittedName($0) }
            .map { directory.appendingPathComponent($0).path } ?? []
        let config = directory.appendingPathComponent("config").path
        if let count = try? reader.size(config), count > 0, count <= BackendServersKeyfiles.maximumBytes,
           let text = try? reader.read(config) {
            for line in text.split(separator: "\n") {
                let parts = words(String(line))
                guard parts.count == 2, parts[0].lowercased() == "identityfile",
                      let path = identityPath(parts[1], home: home.path) else { continue }
                candidates.append(path)
            }
        }
        var seen: Set<String> = []
        return candidates.compactMap { path in
            guard seen.insert(path).inserted, permittedName(URL(fileURLWithPath: path).lastPathComponent),
                  reader.isFile(path), let count = try? reader.size(path), count > 0,
                  count <= BackendServersKeyfiles.maximumBytes else { return nil }
            return BackendServersKeyFileOffer(path: path, name: URL(fileURLWithPath: path).lastPathComponent,
                what: "A private key file", locked: nil)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func identityPath(_ raw: String, home: String) -> String? {
        guard raw.lowercased() != "none", !raw.contains("\0") else { return nil }
        var path = raw.replacingOccurrences(of: "%d", with: home)
        if path.hasPrefix("~/") { path = home + String(path.dropFirst()) }
        guard path.hasPrefix("/"), !path.contains("%"), !path.hasSuffix(".pub") else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func permittedName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.hasSuffix(".pub") &&
        !["config", "authorized_keys", "authorized_keys2"].contains(name) &&
        !name.hasPrefix("known_hosts") && !name.contains("/")
    }

    /// OpenSSH permits quoted filenames and an optional '=' separator. This
    /// extracts IdentityFile values for display, never evaluates Host/Match.
    private static func words(_ line: String) -> [String] {
        var words: [String] = [], word = "", quote: Character?, escaped = false
        for char in line {
            if escaped { word.append(char); escaped = false; continue }
            if char == "\\" { escaped = true; continue }
            if let q = quote { if char == q { quote = nil } else { word.append(char) }; continue }
            if char == "\"" || char == "'" { quote = char; continue }
            if char == "#" { break }
            if char.isWhitespace || (char == "=" && (words.isEmpty || (words.count == 1 && word.isEmpty))) {
                if !word.isEmpty { words.append(word); word = "" }
            } else { word.append(char) }
        }
        guard quote == nil, !escaped else { return [] }
        if !word.isEmpty { words.append(word) }
        return words
    }
}
