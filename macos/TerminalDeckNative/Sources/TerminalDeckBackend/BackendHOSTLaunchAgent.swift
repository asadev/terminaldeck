import Foundation
import Darwin
import CryptoKit
import TerminalDeckNativeCore

/// Installation is explicit. Constructing a plan touches no launchd service,
/// installed app, account, Keychain or session.
///
/// One name (9 Nov, Asad: "everything on one name … so i can allow only one time"): the keeper's launchd job is one of
/// Terminal Deck.app's own background items (SMAppService, plist inside the app, see `BackendHOSTService`). launchd starts
/// the app's own program, which hands over (`execv`) to the stable copied-out keeper. macOS fixes "responsible" when it
/// starts a process, so permissions, prompts and notices belong to Terminal Deck while app updates still never touch the
/// running keeper. The copy is named "Terminal Deck" too (Activity Monitor, keychain and crash notices name the file).
public struct BackendHOSTLaunchAgent: Sendable {
    public static let productionLabel = "dev.terminaldeck.session-host"
    /// The copied-out keeper's file name. Versions up to 0.21.3 used `legacyKeeperFileName`; their folders still work.
    public static let keeperFileName = "Terminal Deck"
    public static let legacyKeeperFileName = "TerminalDeckNativeHelper"
    /// Folder generation of the full graph's keepers (`<marketing>-host3-<hash>`).
    public static let hostGeneration = "-host3"
    public let paths: BackendHOSTPaths
    public let version: String
    public let label: String
    public let helper: URL
    public let plist: URL
    public let associatedBundleIdentifier: String
    private let appBundleIdentifier: String?
    private let childOnly: Bool

    /// The keeper inside one version folder: the new name, or an older build's legacy name when only that exists.
    public static func keeperExecutable(in folder: URL) -> URL {
        let current = folder.appendingPathComponent(keeperFileName), legacy = folder.appendingPathComponent(legacyKeeperFileName)
        var info = stat()
        if lstat(current.path, &info) != 0, lstat(legacy.path, &info) == 0 { return legacy }
        return current
    }

    public init(paths: BackendHOSTPaths, version: String, launchAgentsDirectory: URL,
                label: String? = nil, appBundleIdentifier: String? = Bundle.main.bundleIdentifier) throws {
        let dataRoot = paths.dataDirectory.path
        let productionRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/terminaldeck").standardizedFileURL.resolvingSymlinksInPath().path
        // Every isolated copy is temporary. It must never register a background item, even if its launcher
        // forgot the explicit test switch. Refuse a child-only launch against the real data folder.
        let requestedChild = ProcessInfo.processInfo.environment[NativeLaunchSwitches.hostChild] == "1"
        guard dataRoot != productionRoot || !requestedChild else {
            throw BackendHOSTFailure.invalid("A child keeper needs a separate test data folder.")
        }
        childOnly = dataRoot != productionRoot
        let hash = SHA256.hash(data: Data(dataRoot.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16)
        let baseLabel = dataRoot == productionRoot ? Self.productionLabel : Self.productionLabel + ".scratch-" + hash
        let expectedLabel = baseLabel + (paths.namespace.map { "." + $0 } ?? "")
        let resolvedLabel = label ?? expectedLabel
        guard version.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil,
              resolvedLabel == expectedLabel, !dataRoot.contains("\n"), !dataRoot.contains("\r"),
              launchAgentsDirectory.isFileURL, launchAgentsDirectory.path.hasPrefix("/") else {
            throw BackendHOSTFailure.invalid("Invalid session host installation identity.")
        }
        // A scratch keeper belongs to its own app, never the installed app's privacy identity.
        associatedBundleIdentifier = dataRoot == productionRoot ? "dev.terminaldeck.app" :
            (appBundleIdentifier == "dev.terminaldeck.app" ? nil : appBundleIdentifier) ?? "dev.terminaldeck.app.scratch"
        self.paths = paths; self.version = version; self.label = resolvedLabel; self.appBundleIdentifier = appBundleIdentifier
        helper = Self.keeperExecutable(in: paths.directory.appendingPathComponent(version, isDirectory: true))
        // Only an older version's per-user launch file lives here now; it is removed once its keeper is idle.
        plist = launchAgentsDirectory.appendingPathComponent(resolvedLabel + ".plist")
    }
    /// One install directory per helper BUILD (QUIT, 9 Oct): the marketing version plus a short
    /// hash of the helper's own bytes. Two local builds of one marketing version used to share
    /// "0.20.2-host3/", the second was refused ("already contains a different helper") and new
    /// sessions fell back in-app. A running compatible old host is still adopted (its version
    /// simply differs, so its replacement waits until it is empty).
    public static func buildVersion(marketing: String, helper: URL) throws -> String {
        let bytes = try Data(contentsOf: helper, options: .mappedIfSafe)
        let digest = SHA256.hash(data: bytes).prefix(6).map { String(format: "%02x", $0) }.joined()
        var base = String(marketing.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "-", options: .regularExpression).prefix(48))
        if base.first.map({ !$0.isLetter && !$0.isNumber }) ?? true { base = "v" + base }
        return base + "-" + digest
    }

    /// Only while this namespace's owner lock is held (no live host): remove other build
    /// directories that hold nothing but a helper. Never a namespace folder, a socket, a secret
    /// or anything else.
    static func pruneOtherHelpers(in directory: URL, keeping version: String) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var removed: [String] = []
        for name in names where name != version && !name.hasPrefix(".") {
            let folder = directory.appendingPathComponent(name, isDirectory: true)
            var info = stat()
            // Exactly one keeper (new or legacy name) and nothing else but this copy's own library links.
            guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(),
                  let inside = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
                  let keeper = [keeperFileName, legacyKeeperFileName].first(where: { inside.contains($0) }),
                  inside.filter({ $0 != keeper }).allSatisfy({ name in
                      let link = folder.appendingPathComponent(name)
                      var entry = stat()
                      return ["framework", "dylib"].contains(link.pathExtension)
                          && lstat(link.path, &entry) == 0 && entry.st_mode & S_IFMT == S_IFLNK && entry.st_uid == geteuid()
                          && ((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))?.hasSuffix("/Contents/MacOS/" + name) == true)
                  }),
                  lstat(folder.appendingPathComponent(keeper).path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
            if (try? FileManager.default.removeItem(at: folder)) != nil { removed.append(name) }
        }
        return removed
    }

    /// The per-user launch description older versions (up to 0.21.3) installed in ~/Library/LaunchAgents. Nothing loads
    /// it any more: production uses Terminal Deck's own background item (`BackendHOSTService.properties`), and isolated
    /// copies run a child keeper. Kept as the plan's description for the isolation checks.
    public func propertyList() throws -> Data {
        var value: [String: Any] = [
            "Label": label,
            "ProgramArguments": programArguments,
            "RunAtLoad": false,
            "KeepAlive": ["PathState": [paths.activeFile.path: true]],
            // PERF (9 Oct): the host owns the PTYs of the person's live terminals; "Background" clamped its
            // CPU and I/O, so under load it starved while Terminal.app's shells kept running. No Nice, no LowPriorityIO.
            "ProcessType": "Interactive",
            "AbandonProcessGroup": false,
            "ThrottleInterval": 10,
            "Umask": 0o077,
        ]
        // launchd starts the keeper outside the GUI process tree. Without this association,
        // privacy decisions belong to its versioned executable path, rather than to the app.
        // Never lend the installed app's grants to a scratch host.
        value["AssociatedBundleIdentifiers"] = [associatedBundleIdentifier]
        if label.contains(".scratch-") {
            // launchd does not inherit the dev app's isolation switches. The
            // helper's hook owner must refuse the same global-config writes.
            value["EnvironmentVariables"] = [NativeLaunchSwitches.agentConfigReadOnly: "1",
                NativeLaunchSwitches.dataFolder: paths.dataDirectory.path]
            value["StandardOutPath"] = paths.directory.appendingPathComponent("scratch-helper-out.log").path
            value["StandardErrorPath"] = paths.directory.appendingPathComponent("scratch-helper-error.log").path
        }
        return try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    }
    private var programArguments: [String] {
        [helper.path, "--session-host", paths.dataDirectory.path, version] + (paths.namespace.map { [$0] } ?? [])
    }

    public enum Result: Sendable { case attached(BackendHOSTClient, updateDeferred: Bool), started(BackendHOSTClient) }
    /// A compatible old host always wins. A failed/incompatible handshake
    /// never bootouts a service or overwrites its running version.
    public func connectOrStart(sourceHelper: URL, pruneStaleHelpers: Bool = true) async throws -> Result {
        if let client = try? BackendHOSTClient(paths: paths) {
            return .attached(client, updateDeferred: client.hello.hostVersion != version)
        }
        try paths.prepare()
        let installationLock = try BackendHOSTFileLock(paths.directory.appendingPathComponent("install.lock"))
        defer { withExtendedLifetime(installationLock) {} }
        // Check again inside the install lock, preserving incompatible errors.
        if access(paths.socket, F_OK) == 0 {
            do {
                let client = try BackendHOSTClient(paths: paths)
                return .attached(client, updateDeferred: client.hello.hostVersion != version)
            } catch let failure as BackendHOSTFailure {
                switch failure {
                case .io(let code) where code == ECONNREFUSED || code == ENOENT: break
                default: throw failure
                }
            }
        }
        // Never replace a host while its kernel owner lock is held, including
        // startup before the socket or a temporarily unavailable endpoint.
        do {
            let idleLock: BackendHOSTFileLock
            switch try await ownerLockAfterIdleExit() {
            case .locked(let lock): idleLock = lock
            case .attached(let client): return .attached(client, updateDeferred: client.hello.hostVersion != version)
            }
            defer { withExtendedLifetime(idleLock) {} }
            try installHelper(from: sourceHelper)
            if childOnly { try linkScratchLibraries(from: sourceHelper) }
            _ = try paths.secret(create: true)
            if childOnly {
                if pruneStaleHelpers { _ = Self.pruneOtherHelpers(in: paths.directory, keeping: version) }
            } else {
                // Only the installed release app owns the production background item; a renamed copy never claims it.
                guard appBundleIdentifier == BackendHOSTService.releaseBundleIdentifier else {
                    throw BackendHOSTFailure.invalid("Only the installed Terminal Deck app can start the session keeper for this data folder.")
                }
                // The owner lock proves no conforming live host: an older version's idle launch file can go now.
                // Terminal Deck's own item takes its label after the lock is released (startAfterInstall).
                try await retireLegacyRegistration()
                // Still under the owner lock and after the old registration was booted out: older
                // builds' helpers are no longer referenced (77 MB each).
                if pruneStaleHelpers { _ = Self.pruneOtherHelpers(in: paths.directory, keeping: version) }
            }
        }
        // The owner lock is now released before the helper starts.
        return try await startAfterInstall(sourceHelper: sourceHelper)
    }

    /// The production start, run only after the owner lock is released (review-one-name-0609 #1): the request first,
    /// then the item (registering makes launchd run the app program once at once, and that run must already find the
    /// request), then kickstart. A job already running from that load-time run is fine; the socket wait is the proof.
    struct ServiceStart: Sendable {
        var writeRequest: @Sendable () throws -> Void
        var register: @Sendable () throws -> Void
        var kickstart: @Sendable () async throws -> Int32
        var loaded: @Sendable () async throws -> Bool
    }
    static func startServiceItem(_ steps: ServiceStart) async throws {
        try steps.writeRequest()
        try steps.register()
        let status = try await steps.kickstart()
        if status != 0 {
            guard try await steps.loaded() else {
                throw BackendHOSTFailure.remote("Terminal Deck's background item could not start the session keeper (status \(status)).")
            }
        }
    }

    private enum OwnerLock { case locked(BackendHOSTFileLock), attached(BackendHOSTClient) }
    /// QUIT (9 Oct): a host that just went idle removes its socket a moment before it releases its
    /// owner lock and exits. Relaunching in that moment used to read as "still owns processes but
    /// cannot be reached" and sent new sessions in-app. Startup only, bounded to five seconds, no
    /// resident polling: wait for that exit; a host that answers again is adopted; a lock still held
    /// at the bound stays occupied (never replaced, never killed).
    private func ownerLockAfterIdleExit() async throws -> OwnerLock {
        let lockFile = paths.directory.appendingPathComponent("owner.lock")
        for attempt in 0..<50 {
            do { return .locked(try BackendHOSTFileLock(lockFile)) }
            catch BackendHOSTFailure.unavailable {
                if access(paths.socket, F_OK) == 0, let client = try? BackendHOSTClient(paths: paths) { return .attached(client) }
                guard attempt < 49 else { throw BackendHOSTFailure.occupiedHost }
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        throw BackendHOSTFailure.occupiedHost
    }

    private func startAfterInstall(sourceHelper: URL) async throws -> Result {
        // No '-k': kickstart must never kill an occupied service. A kickstart
        // failure is accepted only if this exact label is loaded.
        let domain = "gui/" + String(geteuid())
        let service = domain + "/" + label
        if childOnly {
            // A dev helper can use libraries beside its executable. Keep it in its own app bundle.
            try BackendHOSTChildKeeper.start(helper: sourceHelper, arguments: Array(programArguments.dropFirst()), data: paths.dataDirectory)
        } else {
            let request = paths.directory.appendingPathComponent(BackendHOSTService.launchRequestFile)
            let namespace = paths.namespace, version = version
            try await Self.startServiceItem(.init(
                writeRequest: { try BackendHOSTFiles.atomicWrite(Data(version.utf8), to: request) },
                register: { try BackendHOSTService.ensureRegistered(namespace: namespace) },
                kickstart: { try await Self.launchctl(["kickstart", service]) },
                loaded: { try await Self.launchctl(["print", service]) == 0 }))
        }
        // Startup-only retry, bounded to fifteen seconds. No resident polling.
        for _ in 0..<150 {
            do { return .started(try BackendHOSTClient(paths: paths)) }
            catch let failure as BackendHOSTFailure {
                switch failure {
                case .io(let code) where code == ECONNREFUSED || code == ENOENT: break
                default: throw failure
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        // A startup timeout is not proof that an acquired owner is empty.
        // Preserve it and prevent saved-session restore beside its processes.
        do {
            let idleLock = try BackendHOSTFileLock(paths.directory.appendingPathComponent("owner.lock"))
            withExtendedLifetime(idleLock) {}
        } catch BackendHOSTFailure.unavailable { throw BackendHOSTFailure.occupiedHost }
        throw BackendHOSTFailure.remote("The session helper did not open its authenticated endpoint within fifteen seconds.")
    }

    /// Explicit one-time upgrade: stage this build, then let the app's existing recovery restart saved conversations.
    /// This ends the old helper once. It never retries bootout or stops another helper.
    public func restartUsingSavedConversations(sourceHelper: URL) async throws {
        guard !childOnly else { throw BackendHOSTFailure.invalid("Restart the test copy to update its child keeper.") }
        let client = try BackendHOSTClient(paths: paths)
        guard client.hello.hostVersion != version else { throw BackendHOSTFailure.invalid("This helper build is already running.") }
        let installationLock = try BackendHOSTFileLock(paths.directory.appendingPathComponent("install.lock"))
        defer { withExtendedLifetime(installationLock) {} }
        try installHelper(from: sourceHelper)
        let service = "gui/\(geteuid())/" + label
        if let job = try await Self.registeredJob(service), Self.isAppItem(job) {
            // Terminal Deck's own background item: end the old keeper once. The item stays registered; launchd or the
            // app's reconnect starts this build through the request below.
            try BackendHOSTFiles.atomicWrite(Data(version.utf8), to: paths.directory.appendingPathComponent(BackendHOSTService.launchRequestFile))
            guard try await Self.launchctl(["kill", "SIGTERM", service]) == 0 else { throw BackendHOSTFailure.remote("The one helper stop was requested but launchd did not confirm it. Do not retry.") }
        } else {
            // An older version's own launch file: end it once and remove the file; the reconnect registers the item.
            guard try await Self.launchctl(["bootout", service]) == 0 else { throw BackendHOSTFailure.remote("The one helper stop was requested but launchd did not confirm it. Do not retry.") }
            try removeLegacyPlist()
        }
    }
    /// Versions up to 0.21.3 registered each keeper from ~/Library/LaunchAgents: a Login Items row and privacy identity
    /// of its own, named after the copied file. Only under the owner lock (no conforming live host): end that idle
    /// registration and remove its file. A registration of Terminal Deck's own background item is left alone.
    private func retireLegacyRegistration() async throws {
        let service = "gui/" + String(geteuid()) + "/" + label
        if let job = try await Self.registeredJob(service), !Self.isAppItem(job) {
            let registered = job.arguments ?? []
            guard registered.count == (paths.namespace == nil ? 4 : 5), registered[1] == "--session-host", registered[2] == paths.dataDirectory.path,
                  registered.count == 4 || registered[4] == paths.namespace,
                  registered[0].hasPrefix(paths.directory.path + "/") else {
                throw BackendHOSTFailure.invalid("This launchd label belongs to another data folder. It was left untouched.")
            }
            guard try await Self.launchctl(["bootout", service]) == 0 else { throw BackendHOSTFailure.unavailable }
        }
        try removeLegacyPlist()
    }
    /// Removes the old per-user launch file only when it is ours: this label, and a keeper inside this data folder.
    private func removeLegacyPlist() throws {
        var info = stat()
        guard lstat(plist.path, &info) == 0 else {
            guard errno == ENOENT else { throw BackendHOSTFailure.io(errno) }
            return
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
              let raw = try? PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String: Any],
              raw["Label"] as? String == label,
              let program = (raw["ProgramArguments"] as? [String])?.first, program.hasPrefix(paths.directory.path + "/") else {
            throw BackendHOSTFailure.invalid("A launch file named like the session keeper belongs to something else. It was left untouched.")
        }
        guard unlink(plist.path) == 0 else { throw BackendHOSTFailure.io(errno) }
    }
    /// Account handling pins a private helper too. Its library links stay beside that helper,
    /// pointing to this test copy's libraries, so no library bytes or registration need duplicating.
    private func linkScratchLibraries(from source: URL) throws {
        let directory = source.deletingLastPathComponent()
        let libraries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for library in libraries where ["framework", "dylib"].contains(library.pathExtension) {
            let destination = helper.deletingLastPathComponent().appendingPathComponent(library.lastPathComponent)
            var info = stat()
            if lstat(destination.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFLNK, info.st_uid == geteuid(),
                      try FileManager.default.destinationOfSymbolicLink(atPath: destination.path) == library.path else {
                    throw BackendHOSTFailure.invalid("A test helper library belongs to another copy. It was left untouched.")
                }
            } else {
                guard errno == ENOENT else { throw BackendHOSTFailure.io(errno) }
                try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: library)
            }
        }
    }

    private func installHelper(from source: URL) throws { try Self.installKeeper(from: source, to: helper) }
    /// Copies the bundled keeper to its version folder (private, 0700). Idempotent and race-safe: an existing copy must
    /// hold the same bytes; a new one appears by rename, never by writing over a running keeper.
    static func installKeeper(from source: URL, to helper: URL) throws {
        var info = stat()
        guard source.isFileURL, lstat(source.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              access(source.path, X_OK) == 0 else { throw BackendHOSTFailure.invalid("The bundled session helper is missing.") }
        let directory = helper.deletingLastPathComponent()
        try BackendHOSTFiles.privateDirectory(directory)
        let original = try Data(contentsOf: source, options: .mappedIfSafe)
        if lstat(helper.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700,
                  SHA256.hash(data: original) == SHA256.hash(data: try Data(contentsOf: helper, options: .mappedIfSafe)) else {
                throw BackendHOSTFailure.invalid("This host version already contains a different helper. Use a new version directory.")
            }
            return
        }
        guard errno == ENOENT else { throw BackendHOSTFailure.io(errno) }
        let temporary = directory.appendingPathComponent(".helper-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        // copyItem preserves the signed Mach-O; never mutate a running helper.
        try FileManager.default.copyItem(at: source, to: temporary)
        guard chmod(temporary.path, 0o700) == 0, rename(temporary.path, helper.path) == 0 else { throw BackendHOSTFailure.io(errno) }
    }

    /// launchctl through the standard runner. A bootout waits while launchd stops the job (its own
    /// exit timeout is 20 s), so a minute is never cut short; a launchctl stuck past it counts as failed.
    private static func launchctl(_ arguments: [String]) async throws -> Int32 {
        try await NativeChild.run(.init("/bin/launchctl", arguments, output: .discard, errors: .discard), timeoutMilliseconds: 60_000, outputLimit: 1).code
    }
    /// A loaded job as `launchctl print` shows it, or nil when the label is not loaded. A job the app registered through
    /// SMAppService prints `managed_by = com.apple.xpc.ServiceManagement` and `program identifier`, not `program =`
    /// (seen on macOS 27.3); an older version's own launch file prints its `program` and `arguments`.
    typealias Job = (program: String?, arguments: [String]?, managedBy: String?)
    static func registeredJob(_ service: String) async throws -> Job? {
        let run = try await NativeChild.run(.init("/bin/launchctl", ["print", service], errors: .discard), timeoutMilliseconds: 15_000, outputLimit: 256 * 1024)
        guard !run.outputLimited, !run.timedOut else { throw BackendHOSTFailure.invalid("The registered session service could not be verified.") }
        guard run.code == 0 else { return nil }
        let lines = String(decoding: run.output, as: UTF8.self).components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        func value(_ key: String) -> String? { lines.first { $0.hasPrefix(key + " = ") }.map { String($0.dropFirst(key.count + 3)) } }
        let program = value("program"), managedBy = value("managed_by")
        guard let start = lines.firstIndex(of: "arguments = {"), let end = lines[(start + 1)...].firstIndex(of: "}") else { return (program, nil, managedBy) }
        return (program, Array(lines[(start + 1)..<end]), managedBy)
    }
    /// Terminal Deck's own background item (registered through SMAppService), never an older version's launch file.
    static func isAppItem(_ job: Job) -> Bool {
        if job.managedBy == "com.apple.xpc.ServiceManagement" { return true }
        if let arguments = job.arguments, arguments.count >= 2 { return arguments[1] == BackendHOSTService.launchArgument }
        return job.program?.hasSuffix("/" + BackendHOSTService.bundleProgram) == true
    }
}
