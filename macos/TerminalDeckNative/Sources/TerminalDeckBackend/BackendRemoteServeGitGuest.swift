import Foundation
import Darwin
import TerminalDeckNativeCore

/// Native Mac half of remote/git-guest.ts. This is launch configuration, not a
/// filesystem boundary; BackendMacConfinement still owns that boundary.
public enum BackendRemoteServeGitGuest {
    public static let credentialURLVariable = "TERMINALDECK_CREDENTIAL_URL"
    public static let credentialKeyVariable = "TERMINALDECK_CREDENTIAL_KEY"
    public static let helperFile = "askpass.sh"
    public static let configFile = "gitconfig"

    public struct Link: Sendable {
        public let url: String, key: String, helper: String
        public init(url: String, key: String, helper: String) { self.url = url; self.key = key; self.helper = helper }
    }
    public struct Request: Sendable {
        public let directory: URL
        public let link: Link?
        public init(directory: URL, link: Link? = nil) { self.directory = directory; self.link = link }
    }
    public struct Environment: Sendable {
        public let set: [String: String]
        public let remove: [String]
        public let paths: [String]
        public func applying(to inherited: [String: String]) -> [String: String] {
            var next = inherited
            for name in remove { next[name] = nil }
            for (name, value) in set { next[name] = value }
            return next
        }
    }

    public static func directory(root: URL, deviceKey: String) -> URL { root.appendingPathComponent(deviceKey, isDirectory: true) }
    public static func shellPath(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "\\", with: "/").replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    public static func entries(_ request: Request) -> [(String, String)] {
        var result = [("credential.helper", "")]
        if let link = request.link { result.append(("credential.helper", "!" + shellPath(link.helper))) }
        result += [("credential.useHttpPath", "true"),
            ("url.https://github.com/.insteadOf", "git@github.com:"),
            ("url.https://github.com/.insteadOf", "ssh://git@github.com/"),
            ("core.sshCommand", "ssh -o IdentityAgent=none -o IdentitiesOnly=yes -o IdentityFile=/dev/null"),
            ("user.useConfigOnly", "true")]
        return result
    }
    public static func environment(_ request: Request, configPath: String? = nil) -> Environment {
        let config = entries(request)
        var set = ["GIT_CONFIG_GLOBAL": configPath ?? request.directory.appendingPathComponent(configFile).path,
            "GIT_CONFIG_COUNT": String(config.count), "GIT_TERMINAL_PROMPT": "0",
            "GH_CONFIG_DIR": request.directory.appendingPathComponent("gh").path]
        for (index, entry) in config.enumerated() {
            set["GIT_CONFIG_KEY_\(index)"] = entry.0; set["GIT_CONFIG_VALUE_\(index)"] = entry.1
        }
        var paths = ["GIT_CONFIG_GLOBAL", "GH_CONFIG_DIR"]
        if let link = request.link {
            set[credentialURLVariable] = link.url; set[credentialKeyVariable] = link.key
            set["GIT_ASKPASS"] = link.helper; set["SSH_ASKPASS"] = link.helper
            paths += ["GIT_ASKPASS", "SSH_ASKPASS"]
        }
        let owned = ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN",
            "GIT_ASKPASS", "SSH_ASKPASS", "SSH_AUTH_SOCK", "GIT_CONFIG", "GIT_SSH", "GIT_SSH_COMMAND"]
        return Environment(set: set, remove: owned.filter { set[$0] == nil }, paths: paths)
    }
    public static func configText() -> String {
        ["# Written by Terminal Deck for a session started from another device.",
            "# It stands in for the global git config so that this session cannot read",
            "# the login of the account that owns this machine. Yours to edit.", "", "[user]", "\tuseConfigOnly = true", ""].joined(separator: "\n")
    }
    /// Contains no endpoint/key. Those are per-session environment values only.
    public static func askpassScript() -> String {
        #"""
        #!/bin/sh
        # terminaldeck-askpass — forwards a git credential request to the device that owns it.
        # Generated; edits are overwritten. Holds no secret: the address and the key for
        # this session both arrive in the environment.
        case "$1" in
          get) ;;
          store|erase)
            # Nothing about somebody else's login is written to this machine.
            exit 0 ;;
          *)
            # The askpass hat. A prompt names a host and never a repository, so there is
            # nothing here that could be asked of anybody. Silent on purpose: git only
            # gets here after the branch above has already printed the real reason.
            exit 1 ;;
        esac

        if [ -z "${TERMINALDECK_CREDENTIAL_URL}" ] || [ -z "${TERMINALDECK_CREDENTIAL_KEY}" ]; then
          echo "This session has no way to reach your device for a GitHub login." >&2
          exit 1
        fi

        CURL=/usr/bin/curl
        [ -x "$CURL" ] || CURL=curl

        # --max-time has to outlast the desk's own deadlines, or curl gives up first and
        # the person reads a timeout from the wrong layer. The desk answers every request
        # it is holding; this is only here so a lost reply cannot wedge a git forever.
        answer=$("$CURL" -s --max-time 180 \
          -H "x-terminaldeck-credential: ${TERMINALDECK_CREDENTIAL_KEY}" \
          -H "x-terminaldeck-pid: $$" \
          --data-binary @- "${TERMINALDECK_CREDENTIAL_URL}") || {
          echo "This session could not reach the app on this machine for a GitHub login." >&2
          exit 1
        }

        # A leading '!' marks a sentence for the person, not an answer for git. Git reads
        # stdout as credential fields, so the two cannot share it.
        case "$answer" in
          '!'*)
            printf '%s\n' "${answer#!}" >&2
            exit 1 ;;
        esac

        printf '%s\n' "$answer"
        """# + "\n"
    }
    /// Explicit launch-time operation only. The config remains the guest's once
    /// created; the generated helper is refreshed for each proxied launch.
    public static func prepare(_ request: Request) throws -> Environment {
        guard request.directory.isFileURL, request.directory.path.hasPrefix("/") else {
            throw NativeRPCError.invalidArguments("Guest Git needs an absolute device directory")
        }
        try FileManager.default.createDirectory(at: request.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let config = request.directory.appendingPathComponent(configFile)
        if !FileManager.default.fileExists(atPath: config.path) { try write(configText(), file: config, mode: 0o600, exclusive: true) }
        if let link = request.link { try write(askpassScript(), file: URL(fileURLWithPath: link.helper), mode: 0o700, exclusive: false) }
        return environment(request, configPath: config.path)
    }
    private static func write(_ text: String, file: URL, mode: mode_t, exclusive: Bool) throws {
        let fd = Darwin.open(file.path, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC | (exclusive ? O_EXCL : O_TRUNC), mode)
        if fd < 0, exclusive, errno == EEXIST { return }
        guard fd >= 0 else { throw BackendRemoteTrustStorage.filesystem("write guest Git configuration") }
        defer { Darwin.close(fd) }
        let data = Data(text.utf8)
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let amount = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { throw BackendRemoteTrustStorage.filesystem("write guest Git file") }
                offset += amount
            }
        }
        guard Darwin.fchmod(fd, mode) == 0 else { throw BackendRemoteTrustStorage.filesystem("protect guest Git file") }
    }
}
