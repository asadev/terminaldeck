import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

/// L8 (11 Oct, Asad: "AI model difference should not choose who gets what kind of authority"): one description
/// of a session's app tools and allowance, translated per CLI; the same lease, token and grant for every AI.
final class L8SessionAppToolsTests: XCTestCase {
    private let entry = NativeRPCValue.object([.init("type", .string("http")), .init("url", .string("http://127.0.0.1:58764/mcp")),
        .init("headers", .object([.init("Authorization", .string("Bearer secret-token"))]))])

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("L8CLI-" + UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testTheLeaseFileIsReadAndOnlyALocalBearerEndpointIsAccepted() throws {
        let dir = try folder(), config = dir.appendingPathComponent("deck-control.json")
        try NativeRPCValue.object([.init("mcpServers", .object([.init("deck-control", entry)]))]).encodedJSON(pretty: true).write(to: config)
        XCTAssertEqual(BackendSessionAppTools.endpoint(leaseArguments: ["--mcp-config", config.path]), .init(url: "http://127.0.0.1:58764/mcp", token: "secret-token"))
        XCTAssertNil(BackendSessionAppTools.endpoint(entry.setting("url", .string("https://example.com/mcp"))))
        XCTAssertNil(BackendSessionAppTools.endpoint(entry.setting("headers", .object([]))))
        XCTAssertNil(BackendSessionAppTools.endpoint(leaseArguments: ["--mcp-config", dir.appendingPathComponent("missing.json").path]))
    }

    func testCodexGetsCommandLineOverridesAndTheTokenOnlyInItsEnvironment() throws {
        let endpoint = try XCTUnwrap(BackendSessionAppTools.endpoint(entry))
        let plain = BackendSessionAppTools.codex(.init(endpoint: endpoint, allowance: []))
        XCTAssertEqual(plain.arguments, ["-c", #"mcp_servers.deck-control.url="http://127.0.0.1:58764/mcp""#,
                                         "-c", #"mcp_servers.deck-control.bearer_token_env_var="TERMINALDECK_DECK_CONTROL_TOKEN""#,
                                         "-c", "mcp_servers.deck-control.tool_timeout_sec=900"])
        XCTAssertEqual(plain.environment, ["TERMINALDECK_DECK_CONTROL_TOKEN": "secret-token"])
        XCTAssertFalse(plain.arguments.joined().contains("secret-token"), "the token never goes on a command line")
        // A task session is spared Codex's own question for exactly Claude's task-session list.
        let task = BackendSessionAppTools.codex(.init(endpoint: endpoint, allowance: BackendSessionAppTools.taskAllowance())).arguments
        let approved = task.filter { $0.hasSuffix(#".approval_mode="approve""#) }
        XCTAssertEqual(approved.count, BackendSessionAppTools.taskAllowance().count)
        XCTAssertTrue(approved.contains(#"mcp_servers.deck-control.tools.tools_run.approval_mode="approve""#))
        XCTAssertTrue(approved.contains(#"mcp_servers.deck-control.tools.tasks_comment.approval_mode="approve""#))
        XCTAssertEqual(BackendSessionAppTools.claudeAllowance(BackendSessionAppTools.taskAllowance()), DeckMemorySessionHook.taskToolRules())
    }

    func testGeminiGetsAPrivateDefaultsFileOnTopOfTheOneTheLaunchAlreadyNames() throws {
        let dir = try folder(), existing = dir.appendingPathComponent("project-defaults.json")
        try Data(#"{"mcpServers":{"staysfixed":{"command":"/bin/true"}},"ui":{"theme":"x"}}"#.utf8).write(to: existing)
        let endpoint = try XCTUnwrap(BackendSessionAppTools.endpoint(entry))
        let made = try XCTUnwrap(BackendSessionAppTools.gemini(.init(endpoint: endpoint, allowance: BackendSessionAppTools.taskAllowance()), directory: dir,
                                                              environment: ["GEMINI_CLI_SYSTEM_DEFAULTS_PATH": existing.path]))
        XCTAssertEqual(made.environment, ["GEMINI_CLI_SYSTEM_DEFAULTS_PATH": made.file.path])
        let value = try NativeRPCValue.parseJSON(Data(contentsOf: made.file))
        XCTAssertEqual(value["ui"]["theme"].string, "x")
        XCTAssertEqual(value["mcpServers"]["staysfixed"]["command"].string, "/bin/true")
        let server = value["mcpServers"]["deck-control"]
        XCTAssertEqual(server["httpUrl"].string, "http://127.0.0.1:58764/mcp")
        XCTAssertNil(server["url"].string, "url alone would mean SSE to Gemini")
        XCTAssertEqual(server["headers"]["Authorization"].string, "Bearer secret-token")
        XCTAssertEqual(server["trust"].bool, true)
        let mode = try FileManager.default.attributesOfItem(atPath: made.file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((mode?.intValue ?? 0o777) & 0o077, 0, "owner-only")
        XCTAssertEqual(BackendSessionAppTools.geminiForm(entry, taskSession: false)["trust"].bool, false)
        // An existing defaults file that cannot be read: nothing is handed over (never a half-merged file).
        try Data("not json".utf8).write(to: existing)
        XCTAssertNil(BackendSessionAppTools.gemini(.init(endpoint: endpoint, allowance: []), directory: dir, environment: ["GEMINI_CLI_SYSTEM_DEFAULTS_PATH": existing.path]))
    }

    /// The same lease gives every AI the same server and the same allowance; only the form differs.
    func testEveryAdapterHandsOverTheSameLeaseAndOnlyTheTaskSessionGetsTheAllowance() throws {
        let dir = try folder(), config = dir.appendingPathComponent("deck-control.json")
        try NativeRPCValue.object([.init("mcpServers", .object([.init("deck-control", entry)]))]).encodedJSON(pretty: true).write(to: config)
        let lease = ["--mcp-config", config.path]
        XCTAssertEqual(BackendSessionAppTools.adapters, ["claude", "codex", "gemini"])
        for provider in BackendSessionAppTools.adapters.sorted() { XCTAssertTrue(BackendSessionAppTools.handedTo(provider: provider)) }
        XCTAssertFalse(BackendSessionAppTools.handedTo(provider: "shell"))
        XCTAssertEqual(BackendSessionAppTools.handover(provider: "claude", leaseArguments: lease, leaseFiles: [config.path], taskSession: true, environment: [:], inAgentSettings: false).arguments, lease)
        let codex = BackendSessionAppTools.handover(provider: "codex", leaseArguments: lease, leaseFiles: [config.path], taskSession: true, environment: [:], inAgentSettings: false)
        XCTAssertNil(codex.problem); XCTAssertEqual(codex.environment["TERMINALDECK_DECK_CONTROL_TOKEN"], "secret-token")
        let gemini = BackendSessionAppTools.handover(provider: "gemini", leaseArguments: lease, leaseFiles: [config.path], taskSession: false,
                                                    environment: ["GEMINI_CLI_SYSTEM_DEFAULTS_PATH": dir.appendingPathComponent("none.json").path], inAgentSettings: false)
        XCTAssertNil(gemini.problem); XCTAssertEqual(gemini.readableFiles.count, 1)
        XCTAssertEqual(try NativeRPCValue.parseJSON(Data(contentsOf: URL(fileURLWithPath: gemini.readableFiles[0])))["mcpServers"]["deck-control"]["trust"].bool, false)
        XCTAssertNotNil(BackendSessionAppTools.handover(provider: "aider", leaseArguments: lease, leaseFiles: [], taskSession: true, environment: [:], inAgentSettings: false).problem)
        // The agent-seat rule for "this AI can report through the task tools" is the same table.
        for provider in ["claude", "codex", "gemini"] { XCTAssertTrue(BackendAGTLeadSeats.hasTaskTools(provider: provider)) }
        XCTAssertTrue(BackendTaskBriefComposition.hasTaskTools(.object([.init("provider", .string("codex"))])))
        XCTAssertTrue(BackendTaskBriefComposition.hasTaskTools(.object([.init("provider", .string("gemini"))])))
    }
}
