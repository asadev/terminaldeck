import Foundation
import Darwin
import Security
import ServiceManagement
import TerminalDeckNativeCore

/// One app to macOS (9 Nov, Asad: "everything on one name … so i can allow only one time not seprate for each").
///
/// Each keeper's launchd job is a background item of Terminal Deck.app itself, the way ordinary Mac apps ship helpers:
/// its plist lives in `Contents/Library/LaunchAgents/` and is registered once with SMAppService, so Login Items lists
/// Terminal Deck alone and later updates keep the same item. launchd starts the app's own program with
/// `--session-host-launch`; before any app code runs it hands over (`execv`, same process) to the stable copied-out
/// keeper in the data folder. macOS fixes a process's "responsible" code when launchd starts it, so every privacy
/// prompt, grant and notice for the sessions belongs to Terminal Deck, while an app update (which renames the old bundle
/// away) never touches the running keeper. Verified on macOS 27.3: a launchd job started from an app's main program that
/// then execs a binary outside the bundle is attributed by tccd to that app (`responsible_path` = the main program).
public enum BackendHOSTService {
    public static let releaseBundleIdentifier = "dev.terminaldeck.app"
    public static let launchArgument = "--session-host-launch"
    /// Written by the app before it starts the job: the exact keeper build to run. Consumed by the hand-over.
    public static let launchRequestFile = "launch-requested"
    /// The app's main program, relative to the bundle (SMAppService `BundleProgram`).
    public static let bundleProgram = "Contents/MacOS/TerminalDeckNative"

    public static func label(namespace: String?) -> String {
        BackendHOSTLaunchAgent.productionLabel + (namespace.map { "." + $0 } ?? "")
    }
    public static func plistName(namespace: String?) -> String { label(namespace: namespace) + ".plist" }

    /// The shipped `Contents/Library/LaunchAgents/<label>.plist` (OneNameTests compares the files with this).
    /// No user path and no version: the same item serves every update. `SuccessfulExit = false` restarts the job only
    /// after a crash; the hand-over then starts a keeper only while sessions were active (the old PathState rule).
    public static func properties(namespace: String?, appBundleIdentifier: String = releaseBundleIdentifier) -> [String: Any] {
        [
            "Label": label(namespace: namespace),
            "BundleProgram": bundleProgram,
            "ProgramArguments": ["TerminalDeckNative", launchArgument] + (namespace.map { [$0] } ?? []),
            "AssociatedBundleIdentifiers": [appBundleIdentifier],
            "KeepAlive": ["SuccessfulExit": false],
            // PERF (9 Oct): the host owns the PTYs of the person's live terminals: never launchd's clamped Background type.
            "ProcessType": "Interactive",
            "AbandonProcessGroup": false,
            "ThrottleInterval": 10,
            "Umask": 0o077,
        ]
    }

    /// Registers the item once. Agents need no approval; macOS shows its one "Terminal Deck added items" notice the
    /// first time only. A person who switched Terminal Deck off in Login Items gets an honest failure (sessions then
    /// run in the app) and never a second prompt from us.
    static func ensureRegistered(namespace: String?) throws {
        let service = SMAppService.agent(plistName: plistName(namespace: namespace))
        switch service.status {
        case .enabled: return
        case .requiresApproval:
            throw BackendHOSTFailure.remote("Terminal Deck is switched off in System Settings › General › Login Items & Extensions. Switch it on so sessions survive updates.")
        default:
            // macOS 27.3 reports an agent that was never registered as `.notFound`, not `.notRegistered` (seen in the
            // live proof), so both register; a plist that is really missing makes register() fail instead.
            do { try service.register() } catch {
                throw BackendHOSTFailure.remote("Terminal Deck could not add its session keeper to Login Items (\(error.localizedDescription)).")
            }
        }
    }

    public enum Launch: Equatable, Sendable {
        /// `environment`: settings added for the keeper. A test copy's keeper refuses global agent-config writes and
        /// names its data folder, as the old scratch launch files did; the release keeper gets nothing extra.
        case exec(path: String, arguments: [String], environment: [String: String])
        case stay(String)
    }

    /// The hand-over decision, made in the app's own program before any app code. `.stay` exits 0 (launchd then leaves
    /// the job stopped): nothing was requested and no sessions were active, or something is unsafe.
    /// The installed release app always serves the real data folder. Any other bundle (a scratch proof) must name its
    /// own separate data folder and can never reach the real one.
    /// `signingTeam`: the running app's own Developer ID team (nil for an ad-hoc dev or test copy).
    public static func launch(arguments: [String], bundle: Bundle = .main,
                              environment: [String: String] = ProcessInfo.processInfo.environment,
                              signingTeam: String? = ownSigningTeam()) -> Launch {
        // [program, --session-host-launch, (agents)] as shipped; a test copy may add [--data-folder, <its folder>]
        // because launchd passes no environment to a transient test job. The release app refuses that pair.
        var rest = Array(arguments.dropFirst())
        guard rest.first == launchArgument else { return .stay("Unknown keeper launch arguments.") }
        rest.removeFirst()
        var namespace: String?
        if rest.first == "agents" { namespace = "agents"; rest.removeFirst() }
        var namedFolder = environment[NativeLaunchSwitches.dataFolder]
        if rest.count == 2, rest[0] == "--data-folder" { namedFolder = rest[1]; rest.removeAll() }
        guard rest.isEmpty else { return .stay("Unknown keeper launch arguments.") }
        let production = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/terminaldeck", isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let dataRoot: URL
        let release = bundle.bundleIdentifier == releaseBundleIdentifier
        if release {
            guard arguments.count <= 3 else { return .stay("The installed app always serves its own data folder.") }
            dataRoot = production
        } else {
            guard let named = namedFolder, named.hasPrefix("/") else {
                return .stay("A test copy must name its own data folder.")
            }
            dataRoot = URL(fileURLWithPath: named, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
            guard dataRoot.path != production.path else { return .stay("A test copy can never start the real session keeper.") }
        }
        do {
            let paths = try BackendHOSTPaths(dataDirectory: dataRoot, namespace: namespace)
            guard let program = bundle.executableURL else { return .stay("The app program is missing.") }
            let source = program.deletingLastPathComponent().appendingPathComponent("TerminalDeckSessionHostHelper")
            let request = paths.directory.appendingPathComponent(launchRequestFile)
            let requested = consumeRequest(request)
            let active = access(paths.activeFile.path, F_OK) == 0
            guard requested != nil || active else { return .stay("No keeper start was requested and no sessions were active.") }
            var version = requested.flatMap { value -> String? in
                // An app's request names a build it installed; it is used only while that copy is still there.
                let folder = paths.directory.appendingPathComponent(value, isDirectory: true)
                return access(BackendHOSTLaunchAgent.keeperExecutable(in: folder).path, X_OK) == 0 ? value : nil
            }
            if version == nil {
                // Crash recovery without the app: this bundle's own keeper build, copied out exactly as the app does.
                let marketing = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.20.2") + BackendHOSTLaunchAgent.hostGeneration
                let current = try BackendHOSTLaunchAgent.buildVersion(marketing: marketing, helper: source)
                let folder = paths.directory.appendingPathComponent(current, isDirectory: true)
                try paths.prepare()
                try BackendHOSTLaunchAgent.installKeeper(from: source, to: BackendHOSTLaunchAgent.keeperExecutable(in: folder))
                version = current
            }
            guard let version else { return .stay("No keeper build could be chosen.") }
            let keeper = BackendHOSTLaunchAgent.keeperExecutable(in: paths.directory.appendingPathComponent(version, isDirectory: true))
            var info = stat()
            guard lstat(keeper.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else {
                return .stay("The keeper copy is not a private file owned by this user.")
            }
            // review-one-name-0609 #2: only this developer's keeper runs under the app's grants. A copy someone else
            // dropped there (or a damaged one) is refused, like a missing keeper: the app then keeps sessions in-app.
            let requirement = keeperRequirement(team: signingTeam, appIdentifier: bundle.bundleIdentifier)
            guard keeperSignatureValid(keeper, requirement: requirement) else {
                return .stay("The keeper copy is not signed by Terminal Deck's developer.")
            }
            return .exec(path: keeper.path, arguments: [keeper.path, "--session-host", paths.dataDirectory.path, version] + (namespace.map { [$0] } ?? []),
                         environment: release ? [:] : [NativeLaunchSwitches.agentConfigReadOnly: "1", NativeLaunchSwitches.dataFolder: paths.dataDirectory.path])
        } catch {
            return .stay("The keeper could not be prepared.")
        }
    }

    /// The keeper's designated requirement, as release signing pins it (`scripts/mac-privacy-signing.sh`): this app's
    /// keeper identifier, the Developer ID chain and the app's own team. Nil when the app itself has no team (ad hoc).
    static func keeperRequirement(team: String?, appIdentifier: String?) -> String? {
        guard let team, let appIdentifier, team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil,
              appIdentifier.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]*$", options: .regularExpression) != nil else { return nil }
        return "identifier \"\(appIdentifier).session-host\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"\(team)\""
    }
    /// A valid signature meeting `requirement`. Without one (an ad-hoc dev or test app, which holds no real grants) the
    /// copy still needs an intact signature and a keeper identifier.
    static func keeperSignatureValid(_ keeper: URL, requirement: String?) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(keeper as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let strict = SecCSFlags(rawValue: kSecCSStrictValidate)
        if let requirement {
            var compiled: SecRequirement?
            guard SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess, let compiled else { return false }
            return SecStaticCodeCheckValidity(code, strict, compiled) == errSecSuccess
        }
        var info: CFDictionary?
        guard SecStaticCodeCheckValidity(code, strict, nil) == errSecSuccess,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let identifier = (info as? [String: Any])?[kSecCodeInfoIdentifier as String] as? String else { return false }
        return identifier.hasSuffix(".session-host")
    }
    /// The running program's own team identifier (the app, in the hand-over), or nil when it is ad-hoc signed.
    public static func ownSigningTeam() -> String? {
        var code: SecCode?, staticCode: SecStaticCode?, info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code, SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Reads and removes the request (at most one build name, never a path).
    private static func consumeRequest(_ file: URL) -> String? {
        var info = stat()
        guard lstat(file.path, &info) == 0 else { return nil }
        defer { _ = unlink(file.path) }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(), info.st_size <= 64,
              let data = FileManager.default.contents(atPath: file.path) else { return nil }
        let value = String(decoding: data, as: UTF8.self)
        return value.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil ? value : nil
    }

    /// Runs the hand-over in the current process. Returns only when nothing was started (the caller exits 0).
    public static func handOver(_ decision: Launch) -> Never {
        switch decision {
        case .stay(let reason):
            FileHandle.standardError.write(Data(("Terminal Deck session keeper: " + reason + "\n").utf8))
        case .exec(let path, let arguments, let environment):
            for (key, value) in environment { setenv(key, value, 1) }
            var pointers: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
            execv(path, &pointers)
            FileHandle.standardError.write(Data("Terminal Deck session keeper: the keeper copy could not start.\n".utf8))
        }
        exit(0)
    }
}
