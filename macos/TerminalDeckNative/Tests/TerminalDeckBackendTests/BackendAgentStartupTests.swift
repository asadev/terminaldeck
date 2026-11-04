import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendAgentStartupTests: XCTestCase, @unchecked Sendable {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("td-agent-startup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testCodexTerminalStartsAndResumesDisableOnlyInvocationUpdateCheck() async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("codex")
        try Data("#!/bin/sh\nprintf 'codex-cli 0.159.3\\n'\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let resolver = try BackendNativeProviders(store: NativeStateStore(), dataRoot: root,
            inheritedEnvironment: ["HOME": root.path], home: root.path, runner: BackendCommandRunner())
        let provider = try await resolver.resolve(.init(cwd: root.path, provider: "codex"), loginPath: root.path)
        XCTAssertEqual(provider.args, ["-c", "check_for_update_on_startup=false"])
        XCTAssertEqual(provider.resumeArgs, provider.args + ["resume", "--last"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".codex/config.toml").path))
    }

    func testStructuredLaunchDisablesCodexUpdateCheckAndClaudeInteractiveScreens() throws {
        let codex = try BackendHootChatLaunchPlan(provider: .codex, cwd: "/scratch", sessionID: nil,
            extra: ["-c", "check_for_update_on_startup=true"])
        XCTAssertEqual(Array(codex.arguments.prefix(2)), ["app-server", "--stdio"])
        XCTAssertEqual(Array(codex.arguments.suffix(2)), ["-c", "check_for_update_on_startup=false"])
        let claude = try BackendHootChatLaunchPlan(provider: .claude, cwd: "/scratch", sessionID: nil, extra: [])
        XCTAssertTrue(claude.arguments.contains("--print"))
        XCTAssertTrue(claude.arguments.contains("--input-format"))
        XCTAssertTrue(claude.arguments.contains("stream-json"))
        XCTAssertTrue(claude.arguments.contains("--permission-prompt-tool"))
        XCTAssertFalse(claude.arguments.contains("--dangerously-skip-permissions"))
        let gemini = try BackendHootChatLaunchPlan(provider: .gemini, cwd: "/scratch", sessionID: nil, extra: [])
        XCTAssertEqual(gemini.arguments, ["--acp"])
    }

    private func waitForFile(_ file: URL) async throws {
        for _ in 0..<150 {
            if FileManager.default.fileExists(atPath: file.path) { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NativeRPCError(code: "test-timeout", message: "Scratch AI did not receive its expected input.")
    }

    private func exerciseStructuredReadiness(_ provider: HootChatProvider) async throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        // The gate makes ordering observable: no AI account, model request or real session is used.
        let script = #"""
        import json,sys,time,os
        provider=sys.argv[1]
        for line in sys.stdin:
            row=json.loads(line)
            with open('inputs.jsonl','a') as log: log.write(line)
            method=row.get('method')
            if method=='initialize' or row.get('request',{}).get('subtype')=='initialize':
                open('initializing','w').close()
                while not os.path.exists('ready-gate'): time.sleep(0.01)
                if provider=='claude':
                    reply={'type':'control_response','response':{'subtype':'success','request_id':row['request_id'],'response':{}}}
                else: reply={'id':row['id'],'result':{}}
                print(json.dumps(reply),flush=True)
            elif method=='thread/start':
                print(json.dumps({'id':row['id'],'result':{'thread':{'id':'scratch-thread'}}}),flush=True)
            elif method=='turn/start' or row.get('type')=='user':
                open('brief-received','w').close()
        """#
        let store = try BackendHootChatStore(file: root.appendingPathComponent("chat.json"), provider: provider)
        try await store.attach(.init(command: "/usr/bin/python3", arguments: ["-u", "-c", script, provider.rawValue],
            cwd: root.path, environment: ["HOME": root.path], setup: .init(cwd: root.path)))
        let starting = Task { try await store.initialize() }
        do {
            try await waitForFile(root.appendingPathComponent("initializing"))
            do {
                _ = try await store.say("must not be delivered to setup")
                XCTFail("A brief was sent before the structured handshake completed")
            } catch let error as NativeRPCError { XCTAssertEqual(error.code, "starting") }
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("brief-received").path))
            try Data().write(to: root.appendingPathComponent("ready-gate"))
            try await starting.value
            let receipt = try await store.say("the exact startup brief", clientMessageID: "startup-brief")
            XCTAssertEqual(receipt["startup"]["ready"].bool, true)
            XCTAssertEqual(receipt["delivery"]["state"].string, "written")
            XCTAssertEqual(receipt["delivery"]["evidence"].string, "stdin-write-completed")
            XCTAssertEqual(receipt["delivery"]["afterReady"].bool, true)
            XCTAssertNotNil(receipt["delivery"]["turnId"].string)
            try await waitForFile(root.appendingPathComponent("brief-received"))
            let inputs = try String(contentsOf: root.appendingPathComponent("inputs.jsonl"), encoding: .utf8)
            XCTAssertEqual(inputs.components(separatedBy: "the exact startup brief").count - 1, 1)
            XCTAssertFalse(inputs.contains("must not be delivered to setup"))
        } catch {
            starting.cancel()
            await store.stop()
            throw error
        }
        await store.stop()
        let stopped = await store.snapshot()
        XCTAssertTrue(stopped["startup"].isNullish)
    }

    func testCodexBriefWaitsForStructuredSessionAndReturnsWriteEvidence() async throws {
        try await exerciseStructuredReadiness(.codex)
    }

    func testClaudeBriefWaitsForStructuredHandshakeAndReturnsWriteEvidence() async throws {
        try await exerciseStructuredReadiness(.claude)
    }

    private final class SetupSurface: BackendDeckCoreBriefSurface, @unchecked Sendable {
        let screen: String
        private let lock = NSLock()
        private var writes: [String] = []
        init(_ screen: String) { self.screen = screen }
        func listSessions() -> [NativeRPCValue] { [.object([.init("id", .string("scratch"))])] }
        func sessionScreen(id: String) async throws -> String? { screen }
        func writeToSession(id: String, data: String) async throws { lock.withLock { writes.append(data) } }
        func inputCount() -> Int { lock.withLock { writes.count } }
    }

    func testCodexUpdateAndClaudeFirstRunScreensReceiveNoBriefOrReturn() async throws {
        let screens = [
            "Update available! 0.159.3 → 0.166.0\n› 1. Update now\n  2. Skip\n  3. Skip until next version",
            "Choose the text style that looks best with your terminal\n❯ Dark mode\n  Light mode"
        ]
        for screen in screens {
            let surface = SetupSurface(screen)
            let result = try await BackendDeckCoreBrief.deliver(surface: surface, sessionID: "scratch", line: "the brief")
            XCTAssertEqual(result["setup"].bool, true)
            XCTAssertEqual(result["sent"].bool, false)
            XCTAssertEqual(surface.inputCount(), 0)
            XCTAssertTrue(result["reason"].string?.contains("Open") == true)
        }
    }
}
