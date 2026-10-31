import Foundation

/// A separate feed prevents the native app from installing the Electron release
/// that still lives at latest-mac.yml.
public struct NativeUpdateRelease: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let channel: String
    public let version: String
    public let bundleIdentifier: String
    public let architecture: String
    public let url: URL
    public let sha512: String
    public let size: Int64
    public let releaseDate: String
    public let releaseNotes: String?
}

public enum NativeUpdateFeed {
    public static let filename = "latest-native-mac.yml"
    public static let maximumFeedBytes = 1_048_576
    public static let maximumArchiveBytes: Int64 = 2_147_483_648

    public struct Failure: Error, LocalizedError, Sendable {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    /// The publisher emits a deliberately small YAML subset: flat keys whose
    /// values are JSON strings or numbers. No YAML tags, aliases or constructors.
    public static func decode(_ data: Data, feedURL: URL, bundleIdentifier: String,
                              architecture: String) throws -> NativeUpdateRelease {
        try validateFeedURL(feedURL)
        guard data.count <= maximumFeedBytes, let text = String(data: data, encoding: .utf8) else {
            throw Failure("The native update feed is too large or is not UTF-8.")
        }
        let allowed: Set<String> = ["schemaVersion", "channel", "version", "bundleIdentifier", "architecture",
                                    "url", "sha512", "size", "releaseDate", "releaseNotes"]
        var fields: [String: Any] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard !line.hasPrefix(" "), !line.hasPrefix("\t"), let colon = line.firstIndex(of: ":") else {
                throw Failure("The native update feed has an unsupported layout.")
            }
            let key = String(line[..<colon])
            let scalar = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard allowed.contains(key), fields[key] == nil, let bytes = scalar.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: bytes, options: .fragmentsAllowed),
                  value is String || value is NSNumber || value is NSNull else {
                throw Failure("The native update feed contains an invalid field: \(key).")
            }
            fields[key] = value
        }
        // updater.ts:364-386 readNotes: trimmed, empty is none, and never more than MAX_NOTES_LENGTH (4000) UTF-16 units.
        if let notes = fields["releaseNotes"] as? String {
            let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            fields["releaseNotes"] = trimmed.isEmpty ? NSNull() : String(decoding: Array(trimmed.utf16.prefix(4000)), as: UTF16.self)
        }
        let release: NativeUpdateRelease
        do { release = try JSONDecoder().decode(NativeUpdateRelease.self, from: JSONSerialization.data(withJSONObject: fields)) }
        catch { throw Failure("The native update feed is missing required fields.") }
        try validate(release, feedURL: feedURL, bundleIdentifier: bundleIdentifier, architecture: architecture)
        return release
    }

    public static func validate(_ release: NativeUpdateRelease, feedURL: URL, bundleIdentifier: String,
                                architecture: String) throws {
        try validateFeedURL(feedURL)
        guard release.schemaVersion == 1, release.channel == "native-mac", release.bundleIdentifier == bundleIdentifier,
              release.architecture == architecture, ["arm64", "x64"].contains(architecture) else {
            throw Failure("This release belongs to a different app or Mac architecture. It was not downloaded.")
        }
        guard release.version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil,
              release.size > 0, release.size <= maximumArchiveBytes,
              let checksum = Data(base64Encoded: release.sha512), checksum.count == 64,
              checksum.base64EncodedString() == release.sha512 else {
            throw Failure("The native update feed has an invalid version, size or SHA512 checksum.")
        }
        let prefix = repositoryPrefix(of: feedURL)
        guard release.url.scheme == "https", release.url.host == "github.com", release.url.user == nil,
              release.url.password == nil, release.url.port == nil, release.url.query == nil, release.url.fragment == nil,
              let prefix, release.url.path.hasPrefix(prefix + "/releases/download/"),
              release.url.pathComponents.count == 7, release.url.lastPathComponent.hasSuffix(".zip"),
              release.url.lastPathComponent.contains("native"), !release.url.lastPathComponent.contains("..") else {
            throw Failure("The native update archive must be a native ZIP asset in this GitHub repository.")
        }
    }

    public static func validateFeedURL(_ url: URL) throws {
        guard url.scheme == "https", url.host == "github.com", url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil, url.lastPathComponent == filename,
              repositoryPrefix(of: url) != nil,
              url.path.contains("/releases/latest/download/") || url.path.contains("/releases/download/") else {
            throw Failure("This app needs its own latest-native-mac.yml feed on GitHub.")
        }
    }

    public static func allowedNetworkURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil else { return false }
        return ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(url.host?.lowercased() ?? "")
    }

    private static func repositoryPrefix(of url: URL) -> String? {
        let parts = url.pathComponents
        guard parts.count >= 4, parts[0] == "/", parts[3] == "releases",
              parts[1].range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil,
              parts[2].range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil else { return nil }
        return "/\(parts[1])/\(parts[2])"
    }
}
