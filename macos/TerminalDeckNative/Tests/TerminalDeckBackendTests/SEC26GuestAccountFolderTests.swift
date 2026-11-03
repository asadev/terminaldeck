import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// #26 must-fix (Security, 2 Nov). Below Full, a named account used to run in the owner's own folder for it
/// (CLAUDE_CONFIG_DIR / CODEX_HOME / GEMINI_CLI_HOME), granted writable inside the guest's sandbox. That is the folder
/// the owner's Full sessions load settings, hooks and MCP servers from, so a guest could plant a hook for the owner's
/// next unsandboxed session. Now the device gets its own folder per account, seeded on every launch from the owner's
/// harmless preferences only, and the owner's sessions keep their folder. Real profiles, real sandbox-exec, scratch
/// folders only.
final class SEC26GuestAccountFolderTests: XCTestCase {
    private struct Fixture {
        let root: URL, data: URL, owner: URL, project: URL
        let confinement: BackendMacConfinement
        let ownerSettings: Data
        let marker = "guest-planted-" + UUID().uuidString
        var account: BackendAccountLaunch { BackendAccountLaunch(profile: nil, environment: ["CLAUDE_CONFIG_DIR": owner.path], path: "/usr/bin:/bin") }
        var guest: BackendLaunchContext { .init(deviceBoundary: .init(deviceKey: "guest-phone", folder: project.path)) }
        var deviceHome: String { data.appendingPathComponent("remote/device-home/guest-phone").path }
        var deviceFolder: String { BackendMacConfinement.deviceAccountFolder(deviceHome: deviceHome, variable: "CLAUDE_CONFIG_DIR", ownerFolder: owner.path) }
    }

    private func fixture() throws -> Fixture {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("sec26-guest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: BackendMacConfinement.kernelPath(made.path))
        let data = root.appendingPathComponent("data"), owner = data.appendingPathComponent("account-logins/work")
        let project = root.appendingPathComponent("project"), home = root.appendingPathComponent("owner-home")
        for folder in [owner, project, home, data.appendingPathComponent("remote")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let settings = Data(#"""
        {"model":"opus","theme":"dark","effortLevel":"high",
         "hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/bin/echo owner-hook"}]}]},
         "mcpServers":{"owner":{"command":"/bin/echo"}},"apiKeyHelper":"/bin/echo owner-key",
         "env":{"OWNER_SECRET":"s3cret"},"enabledPlugins":{"x@y":true},"permissions":{"allow":["Bash"]}}
        """#.utf8)
        try settings.write(to: owner.appendingPathComponent("settings.json"))
        try Data(#"{"claudeAiOauth":{"accessToken":"OWNER-LOGIN"}}"#.utf8).write(to: owner.appendingPathComponent(".credentials.json"))
        let confinement = try BackendMacConfinement(storageRoot: data.appendingPathComponent("remote"), appDataRoot: data,
            accountHome: home.path, inheritedEnvironment: [:], runner: BackendCommandRunner())
        return Fixture(root: root, data: data, owner: owner, project: project, confinement: confinement, ownerSettings: settings)
    }

    private func guestLaunch(_ f: Fixture) async throws -> BackendConfinedLaunch {
        try await f.confinement.resolve(command: "/bin/sh", args: ["-c", "true"], input: .init(cwd: f.project.path),
            account: f.account, context: f.guest)
    }

    /// Runs `script` exactly as the launcher would start the guest's session: inside its profile, with the account's
    /// environment, the launch's own on top and its removals applied.
    @discardableResult
    private func runAsGuest(_ f: Fixture, _ launch: BackendConfinedLaunch, _ script: String) async throws -> BackendCommandRunner.Result {
        var environment = f.account.environment
        for (name, value) in launch.environment { environment[name] = value }
        for name in launch.removeEnvironment { environment[name] = nil }
        environment["PATH"] = "/usr/bin:/bin"; environment["OWNER"] = f.owner.path; environment["MARK"] = f.marker
        let profile = try XCTUnwrap(launch.args.dropFirst().first)
        return try await BackendCommandRunner().run(command: "/usr/bin/sandbox-exec", arguments: ["-p", profile, "/bin/sh", "-c", script],
            environment: environment, cwd: f.project.path, timeoutMilliseconds: 20_000)
    }

    private func json(_ path: String) throws -> NativeRPCValue { try NativeRPCValue.parseJSON(Data(contentsOf: URL(fileURLWithPath: path))) }
    private func isLink(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    func testAGuestPlantedHookNeverReachesTheOwnersNextSession() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let first = try await guestLaunch(f)

        // The guest runs in the device's own folder for the account; the owner's folder is not in its profile at all.
        XCTAssertEqual(first.environment["CLAUDE_CONFIG_DIR"].map(BackendMacConfinement.kernelPath), BackendMacConfinement.kernelPath(f.deviceFolder))
        XCTAssertFalse(first.removeEnvironment.contains("CLAUDE_CONFIG_DIR"))
        XCTAssertFalse(try XCTUnwrap(first.args.dropFirst().first).contains(f.owner.path))
        // Seeded with the owner's harmless preferences only; no hooks, MCP, helper, environment, plugins, rules or login.
        let seeded = try json(f.deviceFolder + "/settings.json")
        XCTAssertEqual(seeded["model"].string, "opus"); XCTAssertEqual(seeded["theme"].string, "dark")
        for key in ["hooks", "mcpServers", "apiKeyHelper", "env", "enabledPlugins", "permissions"] { XCTAssertFalse(seeded.has(key), key) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.deviceFolder + "/.credentials.json"), "guests only get a login made in their own folder")

        // The guest plants a hook everywhere it can, then leaves a link to the owner's settings for the next seeding.
        let hook = #"{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/bin/echo $MARK"}]}]}}"#
        try await runAsGuest(f, first, """
            printf '%s' '\(hook)' > "$CLAUDE_CONFIG_DIR/settings.json"
            printf '%s' '\(hook)' > "$OWNER/settings.json"
            printf '%s' "$MARK" > "$OWNER/planted"
            printf '%s' "$MARK" >> "$OWNER/.credentials.json"
            rm -f "$CLAUDE_CONFIG_DIR/settings.json"; ln -s "$OWNER/settings.json" "$CLAUDE_CONFIG_DIR/settings.json"
            """)
        XCTAssertEqual(try Data(contentsOf: f.owner.appendingPathComponent("settings.json")), f.ownerSettings, "the sandbox refused the owner's settings")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.owner.appendingPathComponent("planted").path))
        XCTAssertFalse(try String(contentsOf: f.owner.appendingPathComponent(".credentials.json"), encoding: .utf8).contains(f.marker))

        // The next guest launch re-seeds by rename: the planted link is replaced, never written through.
        _ = try await guestLaunch(f)
        XCTAssertFalse(isLink(f.deviceFolder + "/settings.json"))
        XCTAssertFalse(try json(f.deviceFolder + "/settings.json").has("hooks"))
        XCTAssertEqual(try Data(contentsOf: f.owner.appendingPathComponent("settings.json")), f.ownerSettings)

        // The owner's next session (Full: no boundary) keeps the owner's folder, and nothing the guest wrote is in it.
        let owners = try await f.confinement.resolve(command: "/bin/sh", args: ["-c", "true"], input: .init(cwd: f.project.path),
            account: f.account, context: .init())
        XCTAssertNil(owners.environment["CLAUDE_CONFIG_DIR"], "the account's own folder stands")
        XCTAssertEqual(f.account.environment["CLAUDE_CONFIG_DIR"], f.owner.path)
        let ownerFiles = try FileManager.default.contentsOfDirectory(atPath: f.owner.path).sorted()
        XCTAssertEqual(ownerFiles, [".credentials.json", "settings.json"])
        for file in ownerFiles {
            XCTAssertFalse(try String(contentsOf: f.owner.appendingPathComponent(file), encoding: .utf8).contains(f.marker), file)
        }
    }

    func testAGuestThatSwapsItsAccountFolderForALinkToTheOwnersGetsItsOwnFolderBack() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let first = try await guestLaunch(f)
        let swapped = try await runAsGuest(f, first, #"rm -rf "$CLAUDE_CONFIG_DIR" && ln -s "$OWNER" "$CLAUDE_CONFIG_DIR" && echo swapped"#)
        XCTAssertTrue(swapped.output.contains("swapped"), "the device home is the guest's to change")
        XCTAssertTrue(isLink(f.deviceFolder))

        _ = try await guestLaunch(f)
        XCTAssertFalse(isLink(f.deviceFolder), "the link is removed, never followed")
        XCTAssertFalse(try json(f.deviceFolder + "/settings.json").has("hooks"))
        XCTAssertEqual(try Data(contentsOf: f.owner.appendingPathComponent("settings.json")), f.ownerSettings, "no seed written into the owner's folder")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.owner.path).sorted(), [".credentials.json", "settings.json"])
    }

    func testCodexAndGeminiSeedsKeepOnlyPreferences() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let toml = f.root.appendingPathComponent("config.toml")
        try Data("""
            model = "gpt-6.1-sol"
            model_reasoning_effort = "high"
            notify = ["/bin/echo", "owner"]
            sandbox_mode = "danger-full-access"
            [mcp_servers.owner]
            command = "/bin/echo"
            model = "inside-a-table"
            """.utf8).write(to: toml)
        XCTAssertEqual(String(decoding: BackendMacConfinement.seedCodexTOML(toml), as: UTF8.self),
                       "model = \"gpt-6.1-sol\"\nmodel_reasoning_effort = \"high\"\n")
        let gemini = f.root.appendingPathComponent("gemini.json")
        try Data(#"{"model":{"name":"gemini-3"},"ui":{"theme":"Dark"},"mcpServers":{"o":{"command":"x"}},"tools":{"discoveryCommand":"x"}}"#.utf8).write(to: gemini)
        let seeded = try NativeRPCValue.parseJSON(BackendMacConfinement.seedJSON(gemini, keep: BackendMacConfinement.geminiSeedKeys))
        XCTAssertEqual(seeded["model"]["name"].string, "gemini-3"); XCTAssertEqual(seeded["ui"]["theme"].string, "Dark")
        XCTAssertFalse(seeded.has("mcpServers")); XCTAssertFalse(seeded.has("tools"))
        // A missing or unreadable owner file seeds nothing.
        XCTAssertEqual(String(decoding: BackendMacConfinement.seedJSON(f.root.appendingPathComponent("none.json"), keep: ["model"]), as: UTF8.self), "{}\n")
    }

    /// AI Connectors' side: the session host reads a guest session's transcripts (and picks an unnamed --continue)
    /// from the device's own folder for the account, the same folder the confinement hands the session.
    func testTheGuestSessionsTranscriptsAreReadFromTheDevicesOwnFolder() async throws {
        let r = try await BackendF4Runtime.wire()
        do {
            let ownerFolder = r.root.appendingPathComponent("home/.claude-work")
            try FileManager.default.createDirectory(at: ownerFolder, withIntermediateDirectories: true)
            let work = try await r.create("work", configDir: ownerFolder.path)
            let cwd = r.root.appendingPathComponent("project").path
            try FileManager.default.createDirectory(atPath: cwd, withIntermediateDirectories: true)
            let deviceHome = r.configuration.dataDirectory.appendingPathComponent("remote/device-home/guest-phone").path
            let deviceFolder = BackendMacConfinement.deviceAccountFolder(deviceHome: deviceHome, variable: "CLAUDE_CONFIG_DIR", ownerFolder: ownerFolder.path)
            let guestID = UUID().uuidString.lowercased(), ownerID = UUID().uuidString.lowercased()
            for (folder, id) in [(deviceFolder, guestID), (ownerFolder.path, ownerID)] {
                for spelling in NativeTranscriptPaths.projectSpellings(cwd) {
                    let projects = URL(fileURLWithPath: folder).appendingPathComponent("projects").appendingPathComponent(NativeTranscriptPaths.encodeProjectPath(spelling))
                    try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
                    try Data("{}\n".utf8).write(to: projects.appendingPathComponent(id + ".jsonl"))
                }
            }
            var input = BackendCreateSessionInput(cwd: cwd, cols: 80, rows: 24, provider: "claude"); input.profileId = work.id
            let spec = BackendProviderSpec(id: "claude", command: "/bin/sh", args: ["-c", "true"], resumeArgs: [])
            let guest = BackendLaunchContext(deviceBoundary: .init(deviceKey: "guest-phone", folder: cwd))
            let guestLaunch = try await r.adapter.resolve(input, provider: spec, loginPath: "/usr/bin:/bin", context: guest)
            let guestPick = try await r.adapter.continuingConversationID(input, account: guestLaunch, live: [])
            await r.adapter.abandon(guestLaunch)
            // The owner's own launch, without a vault seat (as BackendF4Runtime.sessionEnv launches).
            let ownLaunch = try await r.adapter.resolve(input, provider: spec, loginPath: "/usr/bin:/bin", context: .init(isAppComposed: true))
            let ownPick = try await r.adapter.continuingConversationID(input, account: ownLaunch, live: [])
            await r.adapter.abandon(ownLaunch)
            XCTAssertEqual(guestPick, guestID, "a guest session continues its own conversation, never the owner's")
            XCTAssertEqual(ownPick, ownerID, "the owner's sessions keep the owner's folder")
        } catch { await r.dispose(removeRoot: true); throw error }
        await r.dispose(removeRoot: true)
    }
}
