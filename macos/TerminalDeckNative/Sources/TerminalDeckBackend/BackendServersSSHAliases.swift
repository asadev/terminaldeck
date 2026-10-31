import Foundation
import TerminalDeckNativeCore

/// The servers named in the person's own SSH settings (~/.ssh/config and the
/// files it includes). Only the config text is read, to find Host names; the
/// effective address, user, port and key-file paths come from `ssh -G`. Key
/// files are checked for existence only. Nothing is copied or connected to.
public struct BackendServersSSHAliases: Sendable {
    public struct Alias: Sendable, Equatable {
        public let alias: String
        public let hostname: String?, user: String?, port: Int?
        public let keyNames: [String]
        public let problem: String?
        public var ready: Bool { problem == nil }
    }
    public static let maximumAliases = 64
    /// Code hosting, not servers: listing these as servers would only confuse.
    static let codeHosts: Set<String> = ["github.com", "ssh.github.com", "gitlab.com", "bitbucket.org", "ssh.dev.azure.com", "vs-ssh.visualstudio.com"]
    private let home: URL
    private let reader: BackendServersKeyFolderReader
    private let resolver: BackendDockerMCPServerSSHConfig
    private let exists: @Sendable (String) -> Bool
    public init(home: URL, reader: BackendServersKeyFolderReader = .filesystem, resolver: BackendDockerMCPServerSSHConfig = .init(),
                exists: @escaping @Sendable (String) -> Bool = { FileManager.default.isReadableFile(atPath: $0) }) {
        self.home = home; self.reader = reader; self.resolver = resolver; self.exists = exists
    }

    public func list() async -> [Alias] {
        var output: [Alias] = []
        for name in hostNames() {
            try? Task.checkCancellation()
            if Task.isCancelled { break }
            do {
                let resolved = try await resolver.resolve(alias: name, home: home)
                if Self.codeHosts.contains(resolved.hostname.lowercased()) { continue }
                let found = resolved.identityFiles.filter(exists)
                output.append(.init(alias: name, hostname: resolved.hostname, user: resolved.user, port: resolved.port,
                    keyNames: found.map { URL(fileURLWithPath: $0).lastPathComponent },
                    problem: found.isEmpty ? "No key file named in these settings is on this Mac." : nil))
            } catch {
                output.append(.init(alias: name, hostname: nil, user: nil, port: nil, keyNames: [],
                    problem: "Terminal Deck could not read these SSH settings."))
            }
        }
        return output
    }

    /// Host names from `Host` lines, in file order, following `Include`. Patterns
    /// (`*`, `?`, `!`) and `Match` blocks are not servers and are skipped.
    public func hostNames() -> [String] {
        var names: [String] = [], seen: Set<String> = [], files = 0
        func visit(_ path: String, depth: Int) {
            guard depth <= 4, files < 32 else { return }
            files += 1
            guard let size = try? reader.size(path), size > 0, size <= BackendServersKeyfiles.maximumBytes,
                  let text = try? reader.read(path) else { return }
            for line in text.split(whereSeparator: \.isNewline) {
                let words = Self.words(String(line))
                guard let first = words.first?.lowercased(), words.count > 1 else { continue }
                if first == "include" {
                    for pattern in words.dropFirst() { for file in includes(pattern) { visit(file, depth: depth + 1) } }
                } else if first == "host" {
                    for name in words.dropFirst() where !name.contains(where: { "*?!".contains($0) }) {
                        guard BackendDockerMCPServerSSHConfig.validAlias(name), names.count < Self.maximumAliases,
                              seen.insert(name).inserted else { continue }
                        names.append(name)
                    }
                }
            }
        }
        visit(home.appendingPathComponent(".ssh/config").path, depth: 0)
        return names
    }

    /// OpenSSH reads relative Include paths from ~/.ssh. Wildcards are allowed
    /// in the file name only, which covers the common `config.d/*` layout.
    private func includes(_ raw: String) -> [String] {
        var path = raw
        if path.hasPrefix("~/") { path = home.path + String(path.dropFirst()) }
        if !path.hasPrefix("/") { path = home.appendingPathComponent(".ssh").appendingPathComponent(path).path }
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent, folder = url.deletingLastPathComponent().path
        guard !folder.contains(where: { "*?[".contains($0) }) else { return [] }
        guard name.contains(where: { "*?[".contains($0) }) else { return [path] }
        guard let entries = try? reader.entries(folder) else { return [] }
        return entries.filter { fnmatch(name, $0, 0) == 0 && !$0.hasPrefix(".") }.sorted().map { folder + "/" + $0 }
    }

    /// Whitespace or '=' separated words; quotes group, '#' starts a comment.
    static func words(_ line: String) -> [String] {
        var words: [String] = [], word = "", quote: Character?
        for char in line {
            if let q = quote { if char == q { quote = nil } else { word.append(char) }; continue }
            if char == "\"" { quote = char; continue }
            if char == "#" && word.isEmpty { break }
            if char.isWhitespace || (char == "=" && words.isEmpty) {
                if !word.isEmpty { words.append(word); word = "" }
            } else { word.append(char) }
        }
        if !word.isEmpty { words.append(word) }
        return quote == nil ? words : []
    }

    public static func wire(_ rows: [Alias], added: [String: String]) -> NativeRPCValue {
        .object([.init("ok", .bool(true)), .init("aliases", .array(rows.map { row in
            .object([.init("alias", .string(row.alias)), .init("hostname", row.hostname.map(NativeRPCValue.string) ?? .null),
                .init("user", row.user.map(NativeRPCValue.string) ?? .null), .init("port", row.port.map { .number(Double($0)) } ?? .null),
                .init("keyNames", .array(row.keyNames.map(NativeRPCValue.string))), .init("ready", .bool(row.ready)),
                .init("problem", row.problem.map(NativeRPCValue.string) ?? .null),
                .init("serverId", added[row.alias].map(NativeRPCValue.string) ?? .null)])
        }))])
    }
}
