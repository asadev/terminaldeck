import Foundation
import Darwin

/// Native macOS port of confine/plan.ts, seatbelt.ts and records.ts. Readiness
/// means the full implementation exists; each requested boundary must still
/// pass its own positive/negative runtime canary before a session is launched.
/// Nothing is probed, created, or written during initialization.
public struct BackendMacConfinement: BackendConfinementLaunchResolver, Sendable {
    public static let recordsFenceID = "terminaldeck-records"
    public let readiness: BackendLaunchReadiness = .ready
    private let storageRoot: URL
    private let appDataRoot: URL
    private let accountHome: String
    private let inherited: [String: String]
    private let runner: BackendCommandRunner

    public init(storageRoot: URL, appDataRoot: URL, accountHome: String,
                inheritedEnvironment: [String: String], runner: BackendCommandRunner) throws {
        guard storageRoot.isFileURL, storageRoot.path.hasPrefix("/"), appDataRoot.isFileURL,
              appDataRoot.path.hasPrefix("/"), accountHome.hasPrefix("/"), accountHome != "/" else {
            throw BackendSessionFailure.invalidInput("Mac confinement needs the app's own storage roots and the absolute account home.")
        }
        self.storageRoot = storageRoot.standardizedFileURL; self.appDataRoot = appDataRoot.standardizedFileURL
        self.accountHome = accountHome; inherited = BackendSessionEnvironment.stripInherited(inheritedEnvironment)
        self.runner = runner
    }

    public func resolve(command: String, args: [String], input: BackendCreateSessionInput,
                        account: BackendAccountLaunch, context: BackendLaunchContext) async throws -> BackendConfinedLaunch {
        if context.deviceBoundary != nil && context.appFenceID != nil {
            throw BackendSessionFailure.unsupported("Mac confinement cannot nest a device boundary and an app records fence.")
        }
        guard context.deviceBoundary != nil || context.appFenceID != nil else {
            return BackendConfinedLaunch(command: command, args: args, environment: context.environmentOverrides,
                removeEnvironment: context.removeEnvironment)
        }
        guard access("/usr/bin/sandbox-exec", X_OK) == 0 else { throw BackendSessionFailure.missingCapability("the macOS Seatbelt launcher") }
        var proofEnvironment = inherited
        proofEnvironment["PATH"] = account.path
        if let boundary = context.deviceBoundary {
            guard Self.validDeviceKey(boundary.deviceKey), input.cwd.hasPrefix("/"), boundary.folder.hasPrefix("/"),
                  Self.real(input.cwd) == Self.real(boundary.folder) else {
                throw BackendSessionFailure.invalidInput("A device session must start in its validated granted folder.")
            }
            let home = try prepareDeviceHome(boundary.deviceKey)
            let namedConfig = ["CLAUDE_CONFIG_DIR", "CODEX_HOME", "GEMINI_CLI_HOME"].compactMap { account.environment[$0] }
            let plan = try Self.plan(folder: boundary.folder, home: home.path, accountHome: accountHome,
                path: account.path, writable: boundary.writableDirectories + namedConfig,
                files: boundary.readableFiles, projects: boundary.readOnlyProjects)
            let profile = Self.profile(plan)
            try await proveBoundary(plan: plan, profile: profile, environment: proofEnvironment)
            var environment = context.environmentOverrides
            environment["HOME"] = home.path
            environment["TMPDIR"] = home.appendingPathComponent("tmp").path
            environment["CLAUDE_CODE_TMPDIR"] = home.appendingPathComponent("tmp").path
            var removals = context.removeEnvironment.union(BackendSessionEnvironment.vaultVariables)
            // Named config folders are deliberate and appear in the plan's
            // writable roots. A system account uses this device's own HOME.
            for name in ["CLAUDE_CONFIG_DIR", "CODEX_HOME", "GEMINI_CLI_HOME"] where account.environment[name] == nil {
                removals.insert(name)
            }
            return BackendConfinedLaunch(command: "/usr/bin/sandbox-exec", args: ["-p", profile, command] + args,
                environment: environment, removeEnvironment: removals,
                deviceKey: boundary.deviceKey, enforcedBoundary: true)
        }
        guard context.appFenceID == Self.recordsFenceID else { throw BackendSessionFailure.missingCapability("the requested app records fence") }
        let paths = Self.recordsPaths(appDataRoot)
        let profile = Self.recordsProfile(paths)
        try await proveRecords(paths: paths, profile: profile, environment: proofEnvironment)
        return BackendConfinedLaunch(command: "/usr/bin/sandbox-exec", args: ["-p", profile, command] + args,
            environment: context.environmentOverrides, removeEnvironment: context.removeEnvironment, enforcedBoundary: true)
    }

    public struct Plan: Sendable {
        public let folder: String
        public let home: String
        public let writable: [String]
        public let readable: [String]
        public let readableFiles: [String]
        public let readOnlyProjects: [String]
    }

    public static let systemReadRoots = ["/System", "/usr", "/bin", "/sbin", "/Library", "/Applications", "/opt", "/private/etc", "/private/var/db", "/private/var/select"]

    public static func plan(folder: String, home: String, accountHome: String, path: String,
                            writable: [String], files: [String], projects: [String]) throws -> Plan {
        let paths = [folder, home, accountHome] + writable + files + projects
        guard paths.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") && !$0.contains(where: { $0.isNewline }) }) else {
            throw BackendSessionFailure.invalidInput("A confinement path is not a valid absolute path.")
        }
        let folder = real(folder), home = real(home), owner = real(accountHome)
        let writable = collapse(([folder, home] + writable).map(real))
        // A grant must never silently widen to the whole owner home/root.
        guard writable.allSatisfy({ $0 != "/" && $0 != owner }) else {
            throw BackendSessionFailure.invalidInput("A confined session cannot be granted the filesystem root or the owner's entire home.")
        }
        let protected = [owner] + writable
        let projects = collapse(projects.filter(isDirectory).map(real).filter { candidate in
            candidate != "/" && !protected.contains(where: { within($0, candidate) })
        })
        let protectedTools = protected + projects
        var tools: [String] = []
        for raw in path.components(separatedBy: ":") {
            let entry = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard entry.hasPrefix("/"), isDirectory(entry) else { continue }
            let directory = real(entry)
            let covered = systemReadRoots.contains { within(directory, $0) }
            if !covered && !protectedTools.contains(where: { within($0, directory) }) { tools.append(directory) }
            if URL(fileURLWithPath: directory).lastPathComponent == "bin" {
                let prefix = URL(fileURLWithPath: directory).deletingLastPathComponent().path
                if prefix != "/", prefix != owner, !systemReadRoots.contains(where: { within(prefix, $0) }),
                   !protectedTools.contains(where: { within($0, prefix) }) { tools.append(prefix) }
            }
        }
        let readable = collapse(systemReadRoots + tools + projects)
        let readableFiles = Array(Set(files.map(real).filter { file in
            !readable.contains(where: { within(file, $0) }) && !writable.contains(where: { within(file, $0) })
        })).sorted()
        return Plan(folder: folder, home: home, writable: writable, readable: readable,
            readableFiles: readableFiles, readOnlyProjects: projects)
    }

    public static func profile(_ plan: Plan) -> String {
        var lines = ["(version 1)", "(deny default)", "(allow process-exec)", "(allow process-fork)",
            "(allow sysctl-read)", "(allow ipc-posix-shm)", "(allow process-info* (target self))", "(allow signal (target self))",
            "(allow network*)", "(allow system-socket)", "(allow mach-lookup)",
            "(deny mach-lookup (global-name \"com.apple.coreservices.appleevents\") (global-name \"com.apple.coreservices.launchservicesd\") (global-name \"com.apple.lsd.open\") (global-name \"com.apple.lsd.modifydb\") (global-name \"com.apple.SecurityServer\") (global-name \"com.apple.securityd.xpc\") (global-name \"com.apple.security.agent\"))",
            "(allow file-read-metadata)", "(allow file-read* (literal \"/\"))", "(allow file-read* (subpath \"/dev\"))",
            "(allow file-write* (subpath \"/dev\"))", "(allow file-ioctl (subpath \"/dev\"))",
            #"(allow file-read* file-write* (regex #"^/private/var/folders/[^/]+/[^/]+/T/xcrun_db(-[A-Za-z0-9]+)?$"))"#]
        for path in plan.readable { lines.append("(allow file-read* (subpath \(seatbeltString(path))))") }
        for path in plan.readableFiles { lines.append("(allow file-read* (literal \(seatbeltString(path))))") }
        for path in plan.writable { lines.append("(allow file-read* file-write* (subpath \(seatbeltString(path))))") }
        // As in secrets.ts, every deny precedes every exception; emit all after
        // the grants because Seatbelt's last matching rule wins.
        for fragment in secretShapes {
            for root in plan.readOnlyProjects { lines.append("(deny file-read* (regex #\"^\(pathRegex(root))(/.*)?/\(fragment)\"))") }
        }
        for fragment in secretExceptions {
            for root in plan.readOnlyProjects { lines.append("(allow file-read* (regex #\"^\(pathRegex(root))(/.*)?/\(fragment)\"))") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private func prepareDeviceHome(_ key: String) throws -> URL {
        let root = storageRoot.resolvingSymlinksInPath().appendingPathComponent("device-home", isDirectory: true)
        let home = root.appendingPathComponent(key, isDirectory: true)
        guard home.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else {
            throw BackendSessionFailure.invalidInput("A device home must remain in the app's own device-home directory.")
        }
        for directory in [home, home.appendingPathComponent("tmp"), home.appendingPathComponent(".claude/projects")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let hush = home.appendingPathComponent(".hushlogin")
        if !FileManager.default.fileExists(atPath: hush.path) {
            guard FileManager.default.createFile(atPath: hush.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
                throw BackendSessionFailure.invalidInput("The device home could not be prepared.")
            }
        }
        return home.resolvingSymlinksInPath()
    }

    private func proveBoundary(plan: Plan, profile: String, environment: [String: String]) async throws {
        let scratch = URL(fileURLWithPath: Self.kernelPath(FileManager.default.temporaryDirectory.path), isDirectory: true)
            .appendingPathComponent("td-native-confine-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let canary = scratch.appendingPathComponent("canary")
        guard !(plan.writable + plan.readable).contains(where: { Self.within(canary.path, $0) }) else {
            throw BackendSessionFailure.unsupported("The boundary proof's temporary file is inside the granted paths, so this boundary cannot be proven.")
        }
        let token = UUID().uuidString, secret = UUID().uuidString + UUID().uuidString
        guard FileManager.default.createFile(atPath: canary.path, contents: Data(secret.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw BackendSessionFailure.unsupported("The boundary proof's temporary file could not be prepared.")
        }
        let positive = try await runner.run(command: "/usr/bin/sandbox-exec", arguments: ["-p", profile, "/bin/echo", token],
            environment: environment, cwd: plan.folder)
        guard positive.succeeded, positive.output.contains(token) else { throw BackendSessionFailure.unsupported("macOS refused to run this session's Seatbelt profile.") }
        let negative = try await runner.run(command: "/usr/bin/sandbox-exec", arguments: ["-p", profile, "/bin/cat", canary.path],
            environment: environment, cwd: plan.folder)
        guard !negative.timedOut, !negative.outputLimited, !negative.output.contains(secret) else {
            throw BackendSessionFailure.unsupported("macOS could not prove that this session's Seatbelt profile holds files outside its grant.")
        }
    }

    /// records.ts `recordsFencePaths`: realpath the parent first, then the names
    /// (confine/records.ts:257-296). Kernel paths, so a Seatbelt rule matches.
    private static func recordsPaths(_ root: URL) -> [String] {
        let root = URL(fileURLWithPath: kernelPath(root.path))
        let remote = URL(fileURLWithPath: kernelPath(root.appendingPathComponent("remote").path))
        return [root.appendingPathComponent("routines"), root.appendingPathComponent("routine-state.json"),
            root.appendingPathComponent("copilot-log"), remote.appendingPathComponent("remote-device-kinds.json"),
            remote.appendingPathComponent("remote-auth.json"), remote.appendingPathComponent("access-keys.json"),
            root.appendingPathComponent("plugin-grants.json")].map { kernelPath($0.path) }
    }

    /// realpath(3), the path the kernel (and so Seatbelt) sees. Foundation's
    /// `resolvingSymlinksInPath` strips a leading `/private` (`/var`, `/tmp`),
    /// and a Seatbelt rule naming that form never matches: the fence would hold
    /// nothing. A not-yet-existing tail stays lexical under the deepest existing,
    /// resolved ancestor (records.ts resolves the parent for the same reason).
    public static func kernelPath(_ path: String) -> String {
        var head = URL(fileURLWithPath: path).standardizedFileURL
        var tail: [String] = []
        while head.path != "/" {
            if let resolved = realpath(head.path, nil) {
                defer { free(resolved) }
                var url = URL(fileURLWithPath: String(cString: resolved))
                for part in tail.reversed() { url.appendPathComponent(part) }
                return url.path
            }
            tail.append(head.lastPathComponent)
            head.deleteLastPathComponent()
        }
        var url = URL(fileURLWithPath: "/")
        for part in tail.reversed() { url.appendPathComponent(part) }
        return url.path
    }

    /// Read-only contract inspection. Uses the same resolved paths as launch
    /// confinement; no process probe, directory creation or policy mutation.
    public static func recordsFencePaths(_ root: URL) -> [String] { recordsPaths(root) }

    /// The actual launch profile, for contract/parity inspection without
    /// starting a process or weakening the positive/negative launch canaries.
    public static func recordsFenceProfile(_ root: URL) -> String { recordsProfile(recordsPaths(root)) }

    private static func recordsProfile(_ paths: [String]) -> String {
        var lines = ["(version 1)", "(allow default)"]
        for (index, path) in paths.enumerated() {
            let operations = index == 2 ? "file-read* file-write*" : "file-write*"
            let selector = index == 0 || index == 2 ? "subpath" : "literal"
            lines.append("(deny \(operations) (\(selector) \(seatbeltString(path))))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// One measured proof of the app records fence (copilot-session.ts
    /// `fence()`), with the same canaries a fenced launch uses. Starts no
    /// session. Hoot measures per start and fails open visibly on a throw.
    public func measureRecordsFence(path: String) async throws -> BackendCopilotSessionFence {
        guard access("/usr/bin/sandbox-exec", X_OK) == 0 else { throw BackendSessionFailure.missingCapability("the macOS Seatbelt launcher") }
        var environment = inherited
        environment["PATH"] = path
        let paths = Self.recordsPaths(appDataRoot)
        try await proveRecords(paths: paths, profile: Self.recordsProfile(paths), environment: environment)
        return BackendCopilotSessionFence(id: Self.recordsFenceID, kind: "seatbelt")
    }

    private func proveRecords(paths: [String], profile: String, environment: [String: String]) async throws {
        let log = URL(fileURLWithPath: paths[2], isDirectory: true)
        try FileManager.default.createDirectory(at: log, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let scratch = URL(fileURLWithPath: Self.kernelPath(FileManager.default.temporaryDirectory.path), isDirectory: true)
            .appendingPathComponent("td-native-records-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let token = UUID().uuidString
        let outside = scratch.appendingPathComponent("writable")
        let canary = log.appendingPathComponent(".fence-probe-" + token)
        defer { try? FileManager.default.removeItem(at: canary) }
        guard !Self.within(outside.path, log.path), !Self.within(outside.path, paths[0]) else {
            throw BackendSessionFailure.unsupported("The records fence cannot be proven with this temporary directory.")
        }
        let runs = try await runner.run(command: "/usr/bin/sandbox-exec", arguments: ["-p", profile, "/bin/echo", token],
            environment: environment, cwd: accountHome)
        guard runs.succeeded, runs.output.contains(token) else { throw BackendSessionFailure.unsupported("macOS refused to run the app records fence.") }
        let positive = try await runner.run(command: "/usr/bin/sandbox-exec",
            arguments: ["-p", profile, "/bin/sh", "-c", #"printf %s "$1" > "$2""#, "td-fence-proof", token, outside.path],
            environment: environment, cwd: accountHome)
        guard positive.succeeded, (try? Data(contentsOf: outside)) == Data(token.utf8) else {
            throw BackendSessionFailure.unsupported("The app records fence refused an ordinary write outside its protected records.")
        }
        let negative = try await runner.run(command: "/usr/bin/sandbox-exec",
            arguments: ["-p", profile, "/bin/sh", "-c", #"printf %s "$1" >> "$2""#, "td-fence-proof", token, canary.path],
            environment: environment, cwd: accountHome)
        guard !negative.timedOut, !negative.outputLimited, (try? Data(contentsOf: canary)) != Data(token.utf8) else {
            throw BackendSessionFailure.unsupported("The app records fence did not hold writes to its protected log.")
        }
    }

    public static func seatbeltString(_ path: String) -> String {
        "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    private static func pathRegex(_ path: String) -> String {
        var value = ""
        for character in path {
            if character == "\"" { value += "." }
            else if ".^$*+?()[]{}|\\".contains(character) { value += "\\" + String(character) }
            else { value.append(character) }
        }
        return value
    }
    private static func real(_ path: String) -> String { kernelPath(path) }
    private static func within(_ inner: String, _ outer: String) -> Bool { inner == outer || inner.hasPrefix(outer == "/" ? "/" : outer + "/") }
    private static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
    private static func collapse(_ paths: [String]) -> [String] {
        var kept: [String] = []
        for path in paths.sorted(by: { $0.count < $1.count }) where !kept.contains(where: { within(path, $0) }) { kept.append(path) }
        return kept
    }
    private static func validDeviceKey(_ key: String) -> Bool {
        !key.isEmpty && key != "." && key != ".." && !key.contains("/") && !key.contains("\\") &&
        key.utf8.count <= 256 && key.rangeOfCharacter(from: .controlCharacters) == nil
    }
    private static let secretShapes = [#"\.env(\.[^/]*)?$"#, #"\.envrc$"#, #"(\.npmrc|\.yarnrc\.yml|\.pypirc)$"#,
        #"(\.netrc|_netrc|\.pgpass|\.htpasswd)$"#, #"(\.git-credentials|\.credentials\.json|\.vault-token)$"#,
        #"id_(rsa|dsa|ecdsa|ed25519)(_sk)?$"#, #"[^/]*\.(pem|key|p8|p12|pfx|jks|keystore|asc|ppk)$"#,
        #"[^/]*\.(tfvars(\.json)?|tfstate(\.backup)?)$"#, #"(\.ssh|\.aws|\.gnupg|\.kube|\.azure|\.docker)(/.*)?$"#,
        #"(secrets?\.(json|ya?ml|toml|env)|[^/]*\.secrets?\.(json|ya?ml|toml))$"#, #"service-account[^/]*\.json$"#]
    private static let secretExceptions = [#"\.env\.(example|sample|template|defaults|dist)$"#, #"\.env\.d\.ts$"#]
}
