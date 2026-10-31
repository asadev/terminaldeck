import Foundation
import CryptoKit
import TerminalDeckNativeCore

/// Only non-secret account settings are serializable. Credential values never enter this type.
public struct BackendAPIAccountRecord: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable, Hashable {
        case anthropic, anthropicToken, openai, compatible, compatibleLocal, gemini
        public var provider: String {
            switch self { case .anthropic, .anthropicToken: "claude"; case .openai, .compatible, .compatibleLocal: "codex"; case .gemini: "gemini" }
        }
        public var defaultBaseURL: String {
            switch self {
            case .anthropic, .anthropicToken: "https://api.anthropic.com"
            case .openai: "https://api.openai.com/v1"
            case .gemini: "https://generativelanguage.googleapis.com/v1beta"
            case .compatible, .compatibleLocal: ""
            }
        }
    }
    public var version = 1
    public let accountID: String
    public let provider: String
    public let configDirectory: String
    public let appName: String
    public var kind: Kind
    public var baseURL: String
    public var model: String?
    /// Anthropic keys not scoped to one workspace must name it on every request (anthropic-workspace-id).
    public var workspaceID: String?
    public var checkState: String?
    /// The provider's own reason when the check did not pass (#169).
    public var checkDetail: String?
    public var checkedAt: Double?
    public var credentialRevision = 0
    public var requiresKey: Bool { kind != .compatibleLocal }
    public static let fileName = "api-account.json"
    public static let referenceVariable = "TERMINALDECK_API_ACCOUNT_REFERENCE"
    public static let customKeyVariable = "TERMINALDECK_PROVIDER_API_KEY"
    public static func isAPIAccountID(_ id: String) -> Bool { id.range(of: #"^api-key-[a-f0-9]{24}$"#, options: .regularExpression) != nil }

    /// Bootstrap metadata may precede the API settings file. Only reserved IDs in this
    /// app's own canonical account folders can use the API-only multi-account route.
    public static func isOwnedAPIProfile(_ profile: BackendAccountProfile, configuration: BackendAccountConfiguration) -> Bool {
        isAPIAccountID(profile.id) && ["claude", "codex", "gemini"].contains(profile.provider)
            && BackendAccountSignInStorage.ownsFolder(profile, configuration: configuration)
    }

    public init(profile: BackendAccountProfile, appName: String, kind: Kind, baseURL: String?, model: String?, workspaceID: String? = nil) throws {
        guard !profile.system, profile.provider == kind.provider else { throw BackendAccountFailure("Choose the matching AI for this API account.") }
        accountID = profile.id; provider = profile.provider; configDirectory = profile.configDir; self.appName = appName; self.kind = kind
        self.baseURL = (baseURL?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? kind.defaultBaseURL
        self.model = model.flatMap { let value = $0.trimmingCharacters(in: .whitespacesAndNewlines); return value.isEmpty ? nil : value }
        self.workspaceID = workspaceID.flatMap { let value = $0.trimmingCharacters(in: .whitespacesAndNewlines); return value.isEmpty ? nil : value }
        if let id = self.workspaceID {
            guard [.anthropic, .anthropicToken].contains(kind), id.hasPrefix("wrkspc_"), id.utf8.count <= 128,
                  id.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
                throw BackendAccountFailure("Enter a Claude workspace ID that starts with wrkspc_, or leave it empty.")
            }
        }
        _ = try endpoint()
        if kind == .openai {
            let endpoint = try endpoint()
            guard endpoint.scheme == "https", endpoint.host?.lowercased() == "api.openai.com", endpoint.path == "/v1", endpoint.port == nil || endpoint.port == 443 else {
                throw BackendAccountFailure("Choose OpenAI-compatible provider for a custom Codex endpoint.")
            }
        }
        if kind == .gemini, try endpoint().lastPathComponent != "v1beta" { self.baseURL = try endpoint().appendingPathComponent("v1beta").absoluteString }
        guard (self.model?.utf8.count ?? 0) <= 512, self.model?.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) != true,
              ![.compatible, .compatibleLocal].contains(kind) || self.model != nil else { throw BackendAccountFailure("Enter the compatible provider's model ID.") }
        if kind == .compatibleLocal, let host = try endpoint().host, !["localhost", "127.0.0.1", "::1"].contains(host) {
            throw BackendAccountFailure("Keyless connections are restricted to a local server.")
        }
    }
    public func endpoint() throws -> URL {
        guard let parts = URLComponents(string: baseURL), let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)),
              let url = parts.url else { throw BackendAccountFailure("Use an HTTPS base URL, or a local HTTP server, without credentials or query parameters.") }
        return url
    }
    public var home: URL { URL(fileURLWithPath: configDirectory).standardizedFileURL }
    public var dataRoot: URL { home.deletingLastPathComponent().deletingLastPathComponent() }
    public var keychainService: String { appName + " API Accounts" }
    public var credentialScope: Data { Data(SHA256.hash(data: Data((provider + "\0" + kind.rawValue + "\0" + baseURL).utf8))) }
    public var keychainAccount: String { SHA256.hash(data: Data((dataRoot.path + "\0" + configDirectory).utf8)).map { String(format: "%02x", $0) }.joined() + ":" + accountID }
    public var reference: String { home.appendingPathComponent(Self.fileName).path }
    public func save() throws {
        try Self.validateHome(home)
        let data = try JSONEncoder().encode(self)
        try BackendAccountFiles.writeAtomic(data, to: home.appendingPathComponent(Self.fileName))
    }
    private static func validateHome(_ folder: URL) throws {
        guard folder.path.hasPrefix("/"), folder.deletingLastPathComponent().lastPathComponent == "account-logins",
              folder.resolvingSymlinksInPath().path == folder.path else { throw BackendAccountFailure("API credentials require this app's own account folder.") }
    }
    public static func read(_ profile: BackendAccountProfile) throws -> Self? {
        guard !profile.system else { return nil }
        let folder = URL(fileURLWithPath: profile.configDir).standardizedFileURL
        guard folder.deletingLastPathComponent().lastPathComponent == "account-logins" else { return nil }
        let file = folder.appendingPathComponent(fileName)
        guard let bytes = try BackendAccountFiles.boundedRead(file, maximum: 16_384) else { return nil }
        try validateHome(folder)
        let record = try JSONDecoder().decode(Self.self, from: bytes)
        guard record.version == 1, record.credentialRevision >= 0, record.credentialRevision < Int.max,
              record.accountID == profile.id, record.provider == profile.provider,
              record.kind.provider == record.provider, record.home.path == folder.path, !record.appName.isEmpty else {
            throw BackendAccountFailure("The API account settings do not match the selected account.")
        }
        _ = try record.endpoint()
        return record
    }
    public static func fromReference(_ path: String) throws -> Self {
        let file = URL(fileURLWithPath: path).standardizedFileURL
        guard file.lastPathComponent == fileName, let bytes = try BackendAccountFiles.boundedRead(file, maximum: 16_384) else {
            throw BackendAccountFailure("The selected API account is unavailable.")
        }
        let record = try JSONDecoder().decode(Self.self, from: bytes)
        let profile = BackendAccountProfile(id: record.accountID, name: "API account", provider: record.provider,
            configDir: file.deletingLastPathComponent().path, system: false, color: "--accent", createdAt: 0)
        guard let checked = try read(profile), checked.reference == file.path else { throw BackendAccountFailure("The API account reference is invalid.") }
        return checked
    }
    public var wire: NativeRPCValue {
        .object([.init("authentication", .string("api-key")), .init("apiKind", .string(kind.rawValue)),
            .init("apiBaseURL", .string(baseURL)), .init("apiModel", model.map(NativeRPCValue.string) ?? .null),
            .init("apiWorkspaceID", workspaceID.map(NativeRPCValue.string) ?? .null),
            .init("apiCheckState", checkState.map(NativeRPCValue.string) ?? .null),
            .init("apiCheckDetail", checkDetail.map(NativeRPCValue.string) ?? .null),
            .init("apiCheckedAt", checkedAt.map(NativeRPCValue.number) ?? .null),
            .init("apiConfigured", .bool(!requiresKey || BackendAPIAccountKeychain.contains(self)))]
            + (shellNote.map { [.init("note", .string($0))] } ?? []))
    }
    public var shellNote: String? { kind == .gemini ? Self.geminiShellNote : nil }
    /// Review sessions-security #2: Claude gets CLAUDE_CODE_SUBPROCESS_ENV_SCRUB (checked in the installed CLI 2.1.299);
    /// no Gemini CLI equivalent is proven, so the limit is stated instead of guessed.
    public static let geminiShellNote = "Gemini may pass this API key to commands it runs, so a command it runs could show the key."
    public static func decorate(_ snapshot: NativeRPCValue) -> NativeRPCValue {
        guard let profiles = snapshot["profiles"].elements else { return snapshot }
        var vault = snapshot["vault"]
        let rows = profiles.map { value -> NativeRPCValue in
            guard let profile = try? JSONDecoder().decode(BackendAccountProfile.self, from: value.encodedJSON()) else { return value }
            let record: Self
            do {
                guard let found = try read(profile) else {
                    return value.setting("authentication", .string(isAPIAccountID(profile.id) ? "api-key" : "subscription"))
                }
                record = found
            } catch { return value.setting("authentication", .string("api-key")).setting("apiCheckState", .string("unavailable")) }
            var row = value
            for field in record.wire.fields ?? [] { row = row.setting(field.key, field.value) }
            vault = vault.setting(profile.id, .object([.init("keptBy", .string("app")),
                .init("signedIn", .bool(!record.requiresKey || BackendAPIAccountKeychain.contains(record)))]))
            return row
        }
        return snapshot.setting("profiles", .array(rows)).setting("vault", vault)
    }
}
