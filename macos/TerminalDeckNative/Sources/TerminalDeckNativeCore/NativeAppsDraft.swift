import Foundation

/// The editable New app form. The caller maps this draft onto the Apps contract
/// and uses the existing server approval and GitHub access paths.
public struct NativeAppsDraft: Equatable, Sendable {
    public enum Source: String, CaseIterable, Equatable, Hashable, Sendable {
        case github, template, database
    }

    /// Reuses the GitHub integration's repository reference, without carrying
    /// sign-in details into the form or a deployment request.
    public enum SourceInfo: Equatable, Sendable {
        case github(repository: GitHubRepoRef, branch: String, port: Int)
        case template(id: String)
        case database(engine: String)
    }

    public var name: String
    public var appID: String
    public var source: Source
    /// `owner/repository` or a GitHub HTTPS repository address.
    public var repository: String
    public var branch: String
    public var templateID: String
    /// Apps contract spelling: postgres, mysql, redis or mongodb.
    public var databaseEngine: String
    /// The app's listening port; database ports are decided by their engine.
    public var port: Int

    public init(name: String = "", appID: String = "", source: Source = .github,
                repository: String = "", branch: String = "main", templateID: String = "",
                databaseEngine: String = "postgres", port: Int = 3000) {
        self.name = name
        self.appID = appID
        self.source = source
        self.repository = repository
        self.branch = branch
        self.templateID = templateID
        self.databaseEngine = databaseEngine
        self.port = port
    }

    /// A readable default for the contract's stable app ID. A person may edit
    /// it independently of the display name, including when a name is in use.
    public var suggestedAppID: String {
        let raw = trimmed(name).lowercased()
        guard !raw.isEmpty else { return "" }
        var slug = ""
        var separator = false
        for scalar in raw.unicodeScalars {
            if Self.isASCIILetter(scalar) || Self.isASCIIDigit(scalar) {
                if separator && !slug.isEmpty { slug.append("-") }
                slug.unicodeScalars.append(scalar)
                separator = false
            } else {
                separator = true
            }
        }
        if slug.isEmpty { slug = "app" }
        if let first = slug.unicodeScalars.first, !Self.isASCIILetter(first) { slug = "app-" + slug }
        return String(slug.prefix(48)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    public var resolvedAppID: String {
        let explicit = trimmed(appID)
        return explicit.isEmpty ? suggestedAppID : explicit
    }

    /// Canonical owner/name for `apps:create`, plus its safe HTTPS address.
    /// The current Apps contract carries owner/name only and deploys from
    /// github.com. Other hosts need an explicit contract field first.
    public var githubRepository: GitHubRepoRef? {
        let raw = trimmed(repository)
        guard !raw.isEmpty else { return nil }
        if raw.contains("://") {
            guard let url = URLComponents(string: raw), url.scheme?.lowercased() == "https",
                  let host = url.host, host.lowercased() == "github.com",
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
                  url.port == nil || url.port == 443 else { return nil }
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard let name = Self.repositoryName(path) else { return nil }
            return GitHubRepoRef(nameWithOwner: name, url: "https://\(host.lowercased())/\(name)")
        }
        guard let name = Self.repositoryName(raw) else { return nil }
        return GitHubRepoRef(nameWithOwner: name, url: "")
    }

    public var resolvedBranch: String {
        let value = trimmed(branch)
        return value.isEmpty ? "main" : value
    }

    /// The Apps contract accepts owner/name rather than a web address.
    /// Callers check validationMessage before submitting this value.
    public var normalizedRepository: String { githubRepository?.nameWithOwner ?? "" }

    public var validationMessage: String? {
        let cleanName = trimmed(name)
        if cleanName.isEmpty { return "Give your app a name." }
        // APE's GitHub path counts characters. APD's database and template
        // paths limit the submitted name to 120 UTF-8 bytes.
        switch source {
        case .github:
            if cleanName.count > 120 { return "Use a shorter app name." }
        case .database:
            if cleanName.utf8.count > 120 { return "Use a shorter database name." }
        case .template:
            if cleanName.utf8.count > 120 { return "Use a shorter app name for this template." }
        }
        if name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            return "Keep the app name on one line."
        }
        let id = resolvedAppID
        guard id.count <= 48, let first = id.unicodeScalars.first, Self.isASCIILetter(first),
              id.unicodeScalars.allSatisfy({ Self.isASCIILetter($0) || Self.isASCIIDigit($0) || $0 == "-" }) else {
            return "The address name must start with a lowercase letter and use up to 48 lowercase letters, numbers or hyphens."
        }
        if id.hasSuffix("-") { return "End the address name with a letter or number so its web address works." }
        switch source {
        case .github:
            guard githubRepository != nil else {
                return "Choose a repository, or enter owner/repository or its HTTPS GitHub address."
            }
            guard Self.validBranch(resolvedBranch) else { return "Enter a branch name such as main or release/next." }
            guard (1...65_535).contains(port) else { return "Enter an app port from 1 to 65535." }
        case .template:
            guard !trimmed(templateID).isEmpty else { return "Choose a template for your app." }
        case .database:
            guard ["postgres", "mysql", "redis", "mongodb"].contains(databaseEngine) else {
                return "Choose Postgres, MySQL, Redis or MongoDB."
            }
        }
        return nil
    }

    /// Nil until the form is valid. Only the active source is returned, so an
    /// edited repository cannot accidentally accompany a database request.
    public var sourceInfo: SourceInfo? {
        guard validationMessage == nil else { return nil }
        switch source {
        case .github:
            guard let ref = githubRepository else { return nil }
            return .github(repository: ref, branch: resolvedBranch, port: port)
        case .template: return .template(id: trimmed(templateID))
        case .database: return .database(engine: databaseEngine)
        }
    }

    public var normalized: NativeAppsDraft {
        var value = self
        value.name = trimmed(name)
        value.appID = resolvedAppID
        value.repository = trimmed(repository)
        value.branch = resolvedBranch
        value.templateID = trimmed(templateID)
        return value
    }

    private func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func repositoryName(_ raw: String) -> String? {
        var name = raw
        if name.hasSuffix(".git") { name.removeLast(4) }
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        // Mirrors BackendAppsDeploySource. The core target cannot import the
        // backend; keeping its bounds here prevents avoidable server failures.
        guard name.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}$"#,
                         options: .regularExpression) != nil else { return nil }
        return name
    }

    private static func validBranch(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 255, value != "@", !value.hasPrefix("-"), !value.hasPrefix("/"),
              !value.hasSuffix("/"), !value.hasSuffix("."), !value.contains(".."),
              !value.contains("@{"), !value.contains("//") else { return false }
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
            .union(CharacterSet(charactersIn: "~^:?*[\\"))
        guard !value.unicodeScalars.contains(where: { forbidden.contains($0) }) else { return false }
        return value.split(separator: "/").allSatisfy { !$0.hasPrefix(".") && !$0.hasSuffix(".lock") }
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool { (97...122).contains(scalar.value) }
    private static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool { (48...57).contains(scalar.value) }
}
