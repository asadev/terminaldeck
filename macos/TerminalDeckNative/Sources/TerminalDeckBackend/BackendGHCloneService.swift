import Darwin
import Foundation
import TerminalDeckNativeCore

/// Local git execution through the existing process owner. Authentication is
/// an ephemeral process environment value, never a remote URL, argument or file.
public struct BackendGHCloneService: Sendable {
    private let auth: BackendGitHubAuthenticator
    private let tools: any BackendGitHubToolRunning
    private let environment: [String: String]
    private let addProject: (@Sendable (String) async throws -> NativeRPCValue)?
    public init(auth: BackendGitHubAuthenticator, tools: any BackendGitHubToolRunning,
                environment: [String: String],
                addProject: (@Sendable (String) async throws -> NativeRPCValue)? = nil) {
        self.auth = auth; self.tools = tools; self.environment = environment
        self.addProject = addProject
    }

    public func clone(_ request: BackendGHCloneRequest) async throws -> NativeRPCValue {
        try Task.checkCancellation()
        _ = try BackendGHAPIValidation.host(request.host)
        _ = try BackendGHAPIValidation.repo(.object([.init("repo", .string(request.repo))]))
        guard request.host == auth.host,
              request.parentPath.hasPrefix("/"), !request.parentPath.contains("\0"),
              !request.parentPath.split(separator: "/").contains(".."),
              request.directoryName.utf8.count <= 255,
              BackendGHAPIValidation.matches(request.directoryName, #"[A-Za-z0-9][A-Za-z0-9_. -]{0,254}"#),
              !request.directoryName.hasSuffix(" "), !request.directoryName.hasSuffix(".") else {
            throw NativeRPCError.invalidArguments("Choose a GitHub repository, an existing project folder and a simple folder name.")
        }
        if let branch = request.branch {
            _ = try BackendGHAPIValidation.ref(branch)
        }
        let parent = URL(fileURLWithPath: request.parentPath).standardizedFileURL.resolvingSymlinksInPath()
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &directory), directory.boolValue else {
            throw NativeRPCError(code: "no-such-folder", message: "The destination folder no longer exists. Choose another folder.")
        }
        let destination = parent.appendingPathComponent(request.directoryName, isDirectory: true)
        guard destination.deletingLastPathComponent() == parent else {
            throw NativeRPCError.invalidArguments("The new repository must stay inside the chosen folder.")
        }
        let token: String
        if let credential = await auth.gitCredential() { token = credential.password }
        else {
            let outcome = try await tools.run(tool: "gh", arguments: ["auth", "token", "--hostname", request.host], cwd: nil,
                environment: BackendGitHubAuthenticator.probeEnvironment(environment), timeoutMilliseconds: 5_000, maximumBytes: 16_384)
            let found = outcome.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard outcome.ok, !found.isEmpty else {
                throw NativeRPCError(code: "not-authenticated", message: "Your GitHub sign-in is unavailable. Check your connection in the GitHub page and try again.")
            }
            token = found
        }
        guard !token.isEmpty, token.utf8.count <= 4096,
              !token.contains(where: { $0.isWhitespace || $0.isNewline || $0.asciiValue.map { $0 < 32 || $0 == 127 } == true }) else {
            throw NativeRPCError(code: "not-authenticated", message: "GitHub returned an invalid sign-in. Reconnect and try again.")
        }
        try Task.checkCancellation()
        // Exclusive reservation prevents an existing folder being changed.
        guard destination.path.withCString({ Darwin.mkdir($0, 0o700) }) == 0 else {
            throw NativeRPCError(code: "destination-unavailable", message: "That folder already exists or cannot be created. Choose another folder name.")
        }
        var processEnvironment = environment.filter { ["HOME", "TMPDIR", "LANG", "LC_ALL", "PATH", "DEVELOPER_DIR", "SDKROOT"].contains($0.key) }
        processEnvironment["GIT_CONFIG_NOSYSTEM"] = "1"
        processEnvironment["GIT_CONFIG_SYSTEM"] = "/dev/null"
        processEnvironment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        processEnvironment["GIT_TERMINAL_PROMPT"] = "0"
        processEnvironment["GIT_ASKPASS"] = "/usr/bin/false"
        let encoded = Data(("x-access-token:" + token).utf8).base64EncodedString()
        let settings = [
            ("credential.helper", ""), ("core.askPass", "/usr/bin/false"),
            ("core.hooksPath", "/dev/null"), ("init.templateDir", ""),
            ("http.followRedirects", "false"), ("http.https://\(request.host)/.extraHeader", "Authorization: Basic \(encoded)"),
            ("protocol.allow", "never"), ("protocol.https.allow", "always"), ("submodule.recurse", "false")
        ]
        processEnvironment["GIT_CONFIG_COUNT"] = String(settings.count)
        for (index, setting) in settings.enumerated() {
            processEnvironment["GIT_CONFIG_KEY_\(index)"] = setting.0
            processEnvironment["GIT_CONFIG_VALUE_\(index)"] = setting.1
        }
        var arguments = ["clone", "--no-recurse-submodules"]
        if let branch = request.branch { arguments += ["--branch", branch] }
        arguments += ["--", "https://\(request.host)/\(request.repo).git", destination.path]
        let outcome: BackendGitOutcome
        do {
            outcome = try await tools.run(tool: "git", arguments: arguments, cwd: parent.path,
                environment: processEnvironment, timeoutMilliseconds: 300_000, maximumBytes: 2 * 1024 * 1024)
        } catch is CancellationError { throw CancellationError() }
        catch {
            throw NativeRPCError(code: "clone-failed", message: "Cloning stopped. A partial folder may remain at \(destination.path). Choose a new folder name to try again.")
        }
        try Task.checkCancellation()
        guard outcome.ok else {
            let safe = BackendGitHubSecretRedaction.redact(outcome.stderr.replacingOccurrences(of: token, with: "[redacted]").replacingOccurrences(of: encoded, with: "[redacted]"))
            throw NativeRPCError(code: "clone-failed", message: "Cloning did not finish. \(String(safe.prefix(2_000))) A partial folder may remain; choose a new folder name to try again.")
        }
        var result = NativeRPCValue.object([.init("ok", .bool(true)), .init("repo", .string(request.repo)),
            .init("path", .string(destination.path)), .init("projectAdded", .bool(false))])
        if let addProject {
            do {
                try Task.checkCancellation()
                _ = try await addProject(destination.path)
                result = result.setting("projectAdded", .bool(true))
            } catch is CancellationError { throw CancellationError() }
            catch {
                result = result.setting("warning", .string("The repository was cloned, but could not be added to Terminal Deck. Add the folder at \(destination.path) from Projects."))
            }
        }
        return result
    }
}
