import Foundation
import Darwin
import CryptoKit
import TerminalDeckNativeCore

/// Installation is explicit. Constructing a plan touches no launchd service,
/// installed app, account, Keychain or session.
public struct BackendHOSTLaunchAgent: Sendable {
    public static let productionLabel = "dev.terminaldeck.session-host"
    public let paths: BackendHOSTPaths
    public let version: String
    public let label: String
    public let helper: URL
    public let plist: URL
    public let associatedBundleIdentifier: String
    private let childOnly: Bool

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
        self.paths = paths; self.version = version; self.label = resolvedLabel
        helper = paths.directory.appendingPathComponent(version, isDirectory: true).appendingPathComponent("TerminalDeckNativeHelper")
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
            guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid(),
                  let inside = try? FileManager.default.contentsOfDirectory(atPath: folder.path), inside.contains("TerminalDeckNativeHelper"),
                  inside.filter({ $0 != "TerminalDeckNativeHelper" }).allSatisfy({ name in
                      let link = folder.appendingPathComponent(name)
                      var entry = stat()
                      return ["framework", "dylib"].contains(link.pathExtension)
                          && lstat(link.path, &entry) == 0 && entry.st_mode & S_IFMT == S_IFLNK && entry.st_uid == geteuid()
                          && ((try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))?.hasSuffix("/Contents/MacOS/" + name) == true)
                  }),
                  lstat(folder.appendingPathComponent("TerminalDeckNativeHelper").path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
            if (try? FileManager.default.removeItem(at: folder)) != nil { removed.append(name) }
        }
        return removed
    }

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
                try FileManager.default.createDirectory(at: plist.deletingLastPathComponent(), withIntermediateDirectories: true)
                // An old, idle launchd registration retains old ProgramArguments.
                // The owner lock proves it cannot own any conforming live host.
                let service = "gui/" + String(geteuid()) + "/" + label
                if let registered = try await Self.registeredArguments(service) {
                    guard registered.count == programArguments.count, registered[1] == "--session-host", registered[2] == paths.dataDirectory.path,
                          registered.count == 4 || registered[4] == paths.namespace,
                          registered[0].hasPrefix(paths.directory.path + "/") else {
                        throw BackendHOSTFailure.invalid("This launchd label belongs to another data folder. It was left untouched.")
                    }
                    guard try await Self.launchctl(["bootout", service]) == 0 else { throw BackendHOSTFailure.unavailable }
                }
                try BackendHOSTFiles.atomicWrite(try propertyList(), to: plist)
                // Still under the owner lock and after the old registration was booted out: older
                // builds' helpers are no longer referenced (77 MB each).
                if pruneStaleHelpers { _ = Self.pruneOtherHelpers(in: paths.directory, keeping: version) }
            }
        }
        // The owner lock is now released before the helper starts.
        return try await startAfterInstall(sourceHelper: sourceHelper)
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
        // No '-k': kickstart must never kill an occupied service. A bootstrap
        // failure is accepted only if this exact label is already registered.
        let domain = "gui/" + String(geteuid())
        let service = domain + "/" + label
        if childOnly {
            // A dev helper can use libraries beside its executable. Keep it in its own app bundle.
            try BackendHOSTChildKeeper.start(helper: sourceHelper, arguments: Array(programArguments.dropFirst()), data: paths.dataDirectory)
        } else {
            let bootstrap = try await Self.launchctl(["bootstrap", domain, plist.path])
            if bootstrap != 0 {
                guard try await Self.launchctl(["print", service]) == 0 else { throw BackendHOSTFailure.remote("Launchd could not register the session helper (status \(bootstrap)).") }
            }
            let kickstart = try await Self.launchctl(["kickstart", service])
            guard kickstart == 0 else { throw BackendHOSTFailure.remote("Launchd could not start the registered session helper (status \(kickstart)).") }
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
        try BackendHOSTFiles.atomicWrite(try propertyList(), to: plist)
        let service = "gui/\(geteuid())/" + label
        guard try await Self.launchctl(["bootout", service]) == 0 else { throw BackendHOSTFailure.remote("The one helper stop was requested but launchd did not confirm it. Do not retry.") }
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

    private func installHelper(from source: URL) throws {
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
    private static func registeredArguments(_ service: String) async throws -> [String]? {
        let run = try await NativeChild.run(.init("/bin/launchctl", ["print", service], errors: .discard), timeoutMilliseconds: 15_000, outputLimit: 256 * 1024)
        guard !run.outputLimited, !run.timedOut else { throw BackendHOSTFailure.invalid("The registered session service could not be verified.") }
        let data = run.output
        guard run.code == 0 else { return nil }
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let start = lines.firstIndex(of: "arguments = {"), let end = lines[(start + 1)...].firstIndex(of: "}") else {
            throw BackendHOSTFailure.invalid("The registered session service's arguments could not be verified.")
        }
        return Array(lines[(start + 1)..<end])
    }
}
