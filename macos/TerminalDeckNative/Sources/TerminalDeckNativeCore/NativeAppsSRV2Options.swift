import Foundation

/// SRV2: the app definition's options, shared by the app page, the engine and
/// the AI tools. Saved inside the app's server record as `options`; secret
/// values never live here (variables stay in the protected settings file).
public struct NativeAppsOptions: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version: Int
    public var build: Build
    public var steps: Steps
    public var health: Health
    public var web: Web
    public var storage: [Mount]

    public init(version: Int = NativeAppsOptions.currentVersion, build: Build = .init(), steps: Steps = .init(), health: Health = .init(),
                web: Web = .init(), storage: [Mount] = []) {
        self.version = version; self.build = build; self.steps = steps; self.health = health; self.web = web; self.storage = storage
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        build = try c.decodeIfPresent(Build.self, forKey: .build) ?? .init()
        steps = try c.decodeIfPresent(Steps.self, forKey: .steps) ?? .init()
        health = try c.decodeIfPresent(Health.self, forKey: .health) ?? .init()
        web = try c.decodeIfPresent(Web.self, forKey: .web) ?? .init()
        storage = try c.decodeIfPresent([Mount].self, forKey: .storage) ?? []
    }

    public struct Build: Codable, Sendable, Equatable {
        /// Folder inside the repository that holds the app ("" = the top).
        public var baseDirectory: String
        /// Build file, relative to the base folder ("" = Dockerfile).
        public var dockerfile: String
        /// Build stage to stop at ("" = the last one).
        public var target: String
        public var noCache: Bool
        public init(baseDirectory: String = "", dockerfile: String = "", target: String = "", noCache: Bool = false) {
            self.baseDirectory = baseDirectory; self.dockerfile = dockerfile; self.target = target; self.noCache = noCache
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            baseDirectory = try c.decodeIfPresent(String.self, forKey: .baseDirectory) ?? ""
            dockerfile = try c.decodeIfPresent(String.self, forKey: .dockerfile) ?? ""
            target = try c.decodeIfPresent(String.self, forKey: .target) ?? ""
            noCache = try c.decodeIfPresent(Bool.self, forKey: .noCache) ?? false
        }
    }

    public struct Steps: Codable, Sendable, Equatable {
        /// Runs once in a copy of the new version before it starts (e.g. migrations).
        public var beforeDeploy: String
        /// Runs inside the new version right after it goes live.
        public var afterDeploy: String
        public var timeoutSeconds: Int
        public init(beforeDeploy: String = "", afterDeploy: String = "", timeoutSeconds: Int = 600) {
            self.beforeDeploy = beforeDeploy; self.afterDeploy = afterDeploy; self.timeoutSeconds = timeoutSeconds
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            beforeDeploy = try c.decodeIfPresent(String.self, forKey: .beforeDeploy) ?? ""
            afterDeploy = try c.decodeIfPresent(String.self, forKey: .afterDeploy) ?? ""
            timeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 600
        }
    }

    public struct Health: Codable, Sendable, Equatable {
        public var enabled: Bool
        public var path: String
        /// nil accepts any answer from 200 to 399.
        public var expectedStatus: Int?
        public var intervalSeconds: Int
        public var timeoutSeconds: Int
        public var retries: Int
        public var startPeriodSeconds: Int
        public init(enabled: Bool = true, path: String = "/", expectedStatus: Int? = nil, intervalSeconds: Int = 5,
                    timeoutSeconds: Int = 3, retries: Int = 3, startPeriodSeconds: Int = 10) {
            self.enabled = enabled; self.path = path; self.expectedStatus = expectedStatus; self.intervalSeconds = intervalSeconds
            self.timeoutSeconds = timeoutSeconds; self.retries = retries; self.startPeriodSeconds = startPeriodSeconds
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            path = try c.decodeIfPresent(String.self, forKey: .path) ?? "/"
            expectedStatus = try c.decodeIfPresent(Int.self, forKey: .expectedStatus)
            intervalSeconds = try c.decodeIfPresent(Int.self, forKey: .intervalSeconds) ?? 5
            timeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 3
            retries = try c.decodeIfPresent(Int.self, forKey: .retries) ?? 3
            startPeriodSeconds = try c.decodeIfPresent(Int.self, forKey: .startPeriodSeconds) ?? 10
        }
        /// The longest a deploy waits for a new version, in seconds.
        public var deadlineSeconds: Int { startPeriodSeconds + retries * (intervalSeconds + timeoutSeconds) + 5 }
    }

    public enum Redirect: String, Codable, Sendable, CaseIterable { case none, toApex = "to-apex", toWWW = "to-www" }

    public struct Web: Codable, Sendable, Equatable {
        public var redirect: Redirect
        public var forceHTTPS: Bool
        public var compression: Bool
        public var password: Password?
        public init(redirect: Redirect = .none, forceHTTPS: Bool = true, compression: Bool = true, password: Password? = nil) {
            self.redirect = redirect; self.forceHTTPS = forceHTTPS; self.compression = compression; self.password = password
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            redirect = try c.decodeIfPresent(Redirect.self, forKey: .redirect) ?? .none
            forceHTTPS = try c.decodeIfPresent(Bool.self, forKey: .forceHTTPS) ?? true
            compression = try c.decodeIfPresent(Bool.self, forKey: .compression) ?? true
            password = try c.decodeIfPresent(Password.self, forKey: .password)
        }
    }

    /// Password protection. The saved form keeps only a bcrypt hash; the
    /// public form drops it. A plain `password` is accepted only on apply.
    public struct Password: Codable, Sendable, Equatable {
        public var username: String
        public var hash: String?
        public var password: String?
        public init(username: String, hash: String? = nil, password: String? = nil) {
            self.username = username; self.hash = hash; self.password = password
        }
    }

    public enum MountKind: String, Codable, Sendable, CaseIterable { case volume, file, folder }

    public struct Mount: Codable, Sendable, Equatable, Identifiable {
        public var kind: MountKind
        /// Where it appears inside the app (absolute).
        public var path: String
        /// Volume name, server folder (absolute), or the saved file's id.
        public var source: String
        public var readOnly: Bool
        /// File mounts only: the file's text. Saved separately on the server.
        public var content: String?
        public var id: String { kind.rawValue + ":" + path }
        public init(kind: MountKind, path: String, source: String = "", readOnly: Bool = false, content: String? = nil) {
            self.kind = kind; self.path = path; self.source = source; self.readOnly = readOnly; self.content = content
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decode(MountKind.self, forKey: .kind)
            path = try c.decode(String.self, forKey: .path)
            source = try c.decodeIfPresent(String.self, forKey: .source) ?? ""
            readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
            content = try c.decodeIfPresent(String.self, forKey: .content)
        }
    }

    // MARK: conversion

    public static func from(_ value: NativeRPCValue) throws -> NativeAppsOptions {
        if value.isNullish { return .init() }
        guard value.fields != nil else { throw NativeRPCError.invalidArguments("App options must be an object.") }
        do { return try JSONDecoder().decode(NativeAppsOptions.self, from: value.encodedJSON()) }
        catch { throw NativeRPCError.invalidArguments("App options are not in the expected form.") }
    }
    public func value() throws -> NativeRPCValue {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try NativeRPCValue.parseJSON(encoder.encode(self))
    }
    /// The form shown to the app page and AI tools: no hash, no plain password.
    public var publicForm: NativeAppsOptions {
        var copy = self
        if let password = copy.web.password { copy.web.password = .init(username: password.username) }
        return copy
    }
    public var hasPassword: Bool { web.password?.username.isEmpty == false }

    // MARK: validation (plain words; the engine re-checks every save)

    public func validate() throws {
        guard version == Self.currentVersion else { throw NativeRPCError.invalidArguments("These app options come from a newer Terminal Deck. Update the app first.") }
        try Self.relativePath(build.baseDirectory, label: "The app folder", allowEmpty: true)
        try Self.relativePath(build.dockerfile, label: "The build file", allowEmpty: true)
        guard build.target.isEmpty || build.target.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$"#, options: .regularExpression) != nil else {
            throw NativeRPCError.invalidArguments("The build stage name can use letters, numbers, dots, dashes and underscores.")
        }
        for (label, command) in [("before deploy", steps.beforeDeploy), ("after deploy", steps.afterDeploy)] {
            guard command.utf8.count <= 8192, !command.contains("\0") else { throw NativeRPCError.invalidArguments("The \(label) command is too long or has invalid characters.") }
        }
        guard (10...3600).contains(steps.timeoutSeconds) else { throw NativeRPCError.invalidArguments("Choose a command time limit between 10 seconds and 1 hour.") }
        guard health.path.hasPrefix("/"), health.path.utf8.count <= 512,
              health.path.range(of: #"^/[A-Za-z0-9._~!$&()*+,;=:@%/?-]*$"#, options: .regularExpression) != nil else {
            throw NativeRPCError.invalidArguments("The health check path must start with / and contain no spaces or quotes.")
        }
        if let code = health.expectedStatus { guard (100...599).contains(code) else { throw NativeRPCError.invalidArguments("Choose an expected answer code between 100 and 599.") } }
        guard (1...300).contains(health.intervalSeconds), (1...120).contains(health.timeoutSeconds), (1...20).contains(health.retries),
              (0...900).contains(health.startPeriodSeconds) else {
            throw NativeRPCError.invalidArguments("Health check timings are out of range: every 1–300 s, wait 1–120 s, 1–20 tries, start time 0–900 s.")
        }
        if let password = web.password {
            guard password.username.range(of: #"^[A-Za-z0-9._@-]{1,64}$"#, options: .regularExpression) != nil else {
                throw NativeRPCError.invalidArguments("The user name can use letters, numbers, dots, dashes, underscores and @.")
            }
            if let hash = password.hash { guard Self.isBcrypt(hash) else { throw NativeRPCError.invalidArguments("The saved password is damaged. Set it again.") } }
            if let plain = password.password {
                guard (8...72).contains(plain.utf8.count), !plain.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
                    throw NativeRPCError.invalidArguments("Use a password of 8 to 72 characters without control characters.")
                }
            }
        }
        guard storage.count <= 16 else { throw NativeRPCError.invalidArguments("An app can have up to 16 storage items.") }
        var paths = Set<String>()
        for mount in storage {
            try Self.appPath(mount.path)
            guard paths.insert(mount.path).inserted else { throw NativeRPCError.invalidArguments("Each storage path inside the app can be used once.") }
            switch mount.kind {
            case .volume:
                guard mount.source.range(of: #"^[a-z0-9][a-z0-9_.-]{0,47}$"#, options: .regularExpression) != nil else {
                    throw NativeRPCError.invalidArguments("Name each saved volume with lowercase letters, numbers, dots, dashes or underscores.")
                }
            case .folder: try Self.serverFolder(mount.source)
            case .file:
                guard !mount.path.hasSuffix("/") else { throw NativeRPCError.invalidArguments("A file needs a file path inside the app, not a folder.") }
                if let content = mount.content {
                    guard content.utf8.count <= 65_536, !content.contains("\0") else { throw NativeRPCError.invalidArguments("Keep each file under 64 KB of text.") }
                }
                guard mount.source.isEmpty || mount.source.range(of: #"^f-[a-f0-9]{16}$"#, options: .regularExpression) != nil else {
                    throw NativeRPCError.invalidArguments("The saved file reference is damaged. Add the file again.")
                }
            }
        }
    }

    public static func isBcrypt(_ hash: String) -> Bool {
        hash.range(of: #"^\$2[aby]\$(0[4-9]|[12][0-9]|3[01])\$[./A-Za-z0-9]{53}$"#, options: .regularExpression) != nil
    }
    static func relativePath(_ text: String, label: String, allowEmpty: Bool) throws {
        if text.isEmpty, allowEmpty { return }
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard !text.isEmpty, text.utf8.count <= 255, !text.hasPrefix("/"), !text.contains("\\"), !text.contains(":"),
              !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              parts.allSatisfy({ !$0.isEmpty && $0 != ".." && $0 != "." }) else {
            throw NativeRPCError.invalidArguments("\(label) must be a path inside the repository, like web or docker/Dockerfile.")
        }
    }
    static func appPath(_ text: String) throws {
        let parts = text.split(separator: "/", omittingEmptySubsequences: true)
        guard text.hasPrefix("/"), text.utf8.count <= 255, !parts.isEmpty,
              text.range(of: #"^[A-Za-z0-9/_.@+-]+$"#, options: .regularExpression) != nil,
              parts.allSatisfy({ $0 != ".." && $0 != "." }),
              !["proc", "sys", "dev"].contains(String(parts[0])) else {
            throw NativeRPCError.invalidArguments("Storage paths inside the app must start with / and use plain letters, numbers, dots, dashes or underscores.")
        }
    }
    /// Server folders: absolute, plain characters, and never a system or Terminal Deck folder.
    public static func serverFolder(_ text: String) throws {
        let parts = text.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard text.hasPrefix("/"), text.utf8.count <= 255, parts.count >= 2,
              text.range(of: #"^[A-Za-z0-9/_.@+-]+$"#, options: .regularExpression) != nil,
              parts.allSatisfy({ $0 != ".." && $0 != "." }) else {
            throw NativeRPCError.invalidArguments("Choose a server folder such as /srv/myapp/uploads (at least two levels, plain characters).")
        }
        let normalized = "/" + parts.joined(separator: "/")
        let blocked = ["/etc", "/root", "/boot", "/proc", "/sys", "/dev", "/run", "/var/run", "/usr", "/bin", "/sbin", "/lib", "/lib32", "/lib64",
                       "/var/lib/docker", "/var/lib/containerd", "/var/lib/terminaldeck", "/var/lib/td-test-apps", "/var/lib/caddy",
                       "/opt/terminaldeck", "/data/coolify", "/var/log", "/snap"]
        guard !blocked.contains(where: { normalized == $0 || normalized.hasPrefix($0 + "/") }) else {
            throw NativeRPCError.invalidArguments("That server folder belongs to the system or another tool. Choose a folder of your own, such as /srv/myapp.")
        }
    }

    /// Short plain-word lines for the app page and approvals.
    public var summaryLines: [String] {
        var lines: [String] = []
        if !build.baseDirectory.isEmpty { lines.append("Builds from the \(build.baseDirectory) folder") }
        if !build.dockerfile.isEmpty { lines.append("Build file: \(build.dockerfile)") }
        if !build.target.isEmpty { lines.append("Build stage: \(build.target)") }
        if build.noCache { lines.append("Builds from scratch every time") }
        if !steps.beforeDeploy.isEmpty { lines.append("Runs a command before each deploy") }
        if !steps.afterDeploy.isEmpty { lines.append("Runs a command after each deploy") }
        lines.append(health.enabled ? "Checks \(health.path) before switching" : "Switches when the new version is running")
        if web.redirect == .toApex { lines.append("www addresses go to the main address") }
        if web.redirect == .toWWW { lines.append("Main addresses go to www") }
        if !web.forceHTTPS { lines.append("Plain http is allowed") }
        if hasPassword { lines.append("Password protected") }
        if !storage.isEmpty { lines.append("\(storage.count) storage item\(storage.count == 1 ? "" : "s")") }
        return lines
    }
}

/// One app variable as the page and AI tools see it. Locked values are masked.
public struct NativeAppsVariable: Codable, Sendable, Equatable, Identifiable {
    public static let mask = "••••••••"
    public var key: String
    public var value: String
    public var build: Bool
    public var run: Bool
    public var locked: Bool
    public var multiline: Bool
    public var id: String { key }
    public init(key: String, value: String, build: Bool = false, run: Bool = true, locked: Bool = true, multiline: Bool = false) {
        self.key = key; self.value = value; self.build = build; self.run = run; self.locked = locked; self.multiline = multiline
    }
    public static func rows(_ value: NativeRPCValue) throws -> [NativeAppsVariable] {
        guard value.elements != nil else { throw NativeRPCError.malformed("The server returned variables in an unexpected form.") }
        do { return try JSONDecoder().decode([NativeAppsVariable].self, from: value.encodedJSON()) }
        catch { throw NativeRPCError.malformed("The server returned variables in an unexpected form.") }
    }
    /// Names that steer the server's build tools; they can't be used during a build.
    public static func reservedForBuild(_ key: String) -> Bool {
        let upper = key.uppercased()
        if ["PATH", "HOME", "IFS", "ENV", "BASH_ENV", "SHELL", "TMPDIR", "USER", "PWD", "OLDPWD", "SHELLOPTS", "PS4", "CDPATH"].contains(upper) { return true }
        return ["LD_", "DYLD_", "DOCKER_", "BUILDKIT_", "BUILDX_", "SSL_CERT_", "TD_", "GIT_"].contains { upper.hasPrefix($0) }
    }
    public static func validKey(_ key: String) -> Bool { key.range(of: #"^[A-Za-z_][A-Za-z0-9_]{0,127}$"#, options: .regularExpression) != nil }
}

/// What answers on ports 80 and 443 of a server, in plain words.
public struct NativeAppsRouterInfo: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable { case ownCaddy = "own-caddy", caddy, traefik, other, free, unknown }
    public var mode: Mode
    public var owner: String
    public var canServeAddresses: Bool
    public var forceHTTPSOptional: Bool
    public var note: String
    public init(mode: Mode, owner: String, canServeAddresses: Bool, forceHTTPSOptional: Bool, note: String) {
        self.mode = mode; self.owner = owner; self.canServeAddresses = canServeAddresses; self.forceHTTPSOptional = forceHTTPSOptional; self.note = note
    }
    public static func from(_ value: NativeRPCValue) throws -> NativeAppsRouterInfo {
        do { return try JSONDecoder().decode(NativeAppsRouterInfo.self, from: value.encodedJSON()) }
        catch { throw NativeRPCError.malformed("The server returned its address manager in an unexpected form.") }
    }
}

/// Whether this server's Caddy keeps Terminal Deck's addresses after it
/// restarts, and the one line to approve when it needs one.
public struct NativeAppsRouterPersistence: Codable, Sendable, Equatable {
    /// "resume" (Caddy reloads its saved state), "caddyfile" (needs our import line),
    /// "other" (can't be kept automatically), "not-caddy" (Traefik or nothing to keep).
    public var mode: String
    public var ready: Bool
    public var line: String?
    public var file: String?
    public var note: String
    /// Present only when Terminal Deck itself added the line (its receipt on the
    /// server). Removing Terminal Deck can take exactly this back out; an import
    /// the owner added themselves never appears here.
    public var owned: OwnedImport?
    public struct OwnedImport: Codable, Sendable, Equatable {
        public var file: String
        public var line: String
        public var folder: String
        public init(file: String, line: String, folder: String) { self.file = file; self.line = line; self.folder = folder }
    }
    public init(mode: String, ready: Bool, line: String? = nil, file: String? = nil, note: String, owned: OwnedImport? = nil) {
        self.mode = mode; self.ready = ready; self.line = line; self.file = file; self.note = note; self.owned = owned
    }
    public static func from(_ value: NativeRPCValue) throws -> NativeAppsRouterPersistence {
        do { return try JSONDecoder().decode(NativeAppsRouterPersistence.self, from: value.encodedJSON()) }
        catch { throw NativeRPCError.malformed("The server returned its address settings in an unexpected form.") }
    }
}
