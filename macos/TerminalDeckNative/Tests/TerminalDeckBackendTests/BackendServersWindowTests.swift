import Foundation
import XCTest
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

final class BackendServersWindowTests: XCTestCase, @unchecked Sendable {
    func testHelpFlagsAndSubcommandsComeFromTheRemoteCLI() {
        XCTAssertTrue(BackendServersWindowDriveScripts.honoursMcpConfig("--mcp-config <file>"))
        XCTAssertFalse(BackendServersWindowBelong.honoursSettings("--setting-sources"))
        XCTAssertTrue(BackendServersWindowBelong.honoursSettings("--settings <file>"))
        let help = "Commands:\n  mcp  config\n  plugin|plugins  manage\n      wrapped description\n  [bad] x\nOptions:\n  other\n"
        XCTAssertEqual(BackendServersWindowDriveScripts.subcommandsFrom(help), ["mcp", "plugin", "plugins"])
        XCTAssertEqual(BackendServersWindowDriveScripts.subcommandsFrom("no commands"), [])
        for shell in ["/bin/sh", "/usr/bin/zsh", "/bin/ash", ""] { XCTAssertTrue(BackendServersWindowDriveScripts.takesAnExportLine(shell)) }
        for shell in ["/usr/bin/fish", "/bin/csh", "/bin/tcsh"] { XCTAssertFalse(BackendServersWindowDriveScripts.takesAnExportLine(shell)) }
    }
    func testPrivateFilesPutTokenOnlyInCurlConfigAndOnlyTheThreeContextHooks() throws {
        let input = BackendServersWindowBelongInput(dir: "/tmp/td-drive-abcdef", curl: "/usr/bin/curl", port: 34234, sessionId: "shell", token: "abcdef12", openers: ["xdg-open": "/usr/bin/xdg-open"], pages: ["INDEX.md": "remote map"], hooks: true)
        let files = BackendServersWindowBelong.files(input)
        XCTAssertEqual(files.filter { $0.body.contains(input.token) }.map(\.path), ["hook.conf"])
        let settings = try NativeRPCValue.parseJSON(Data(BackendServersWindowBelong.settingsFile(input.dir).utf8))
        XCTAssertEqual(Set(settings["hooks"].fields?.map(\.key) ?? []), Set(BackendServersWindowBelong.events))
        XCTAssertNil(settings["model"].string); XCTAssertNil(settings["permissions"].fields)
        XCTAssertTrue(files.contains { $0.path == "context/INDEX.md" })
        let poster = BackendServersWindowBelong.posterScript(input)
        XCTAssertTrue(poster.contains("--data-binary @-")); XCTAssertTrue(poster.contains("--max-time 3")); XCTAssertTrue(poster.contains("*) exit 0"))
        XCTAssertTrue(poster.hasSuffix("exit 0\n")); XCTAssertFalse(poster.contains(input.token))
    }
    func testBelongingRefusesUnsafeInterpolationAsAWhole() {
        for dir in ["/tmp/td-drive-'quote", "/tmp/td-drive-`command`", "/tmp/td-drive-$(command)", "relative"] {
            let input = BackendServersWindowBelongInput(dir: dir, curl: "/curl", port: 1, sessionId: "shell", token: "abc", openers: [:], pages: nil, hooks: true)
            XCTAssertEqual(BackendServersWindowBelong.files(input), [])
        }
        let invalid = BackendServersWindowBelongInput(dir: "/tmp/td-drive-abcdef", curl: "/curl", port: 0, sessionId: "shell", token: "abc", openers: [:], pages: nil, hooks: false)
        XCTAssertTrue(BackendServersWindowBelong.files(invalid).isEmpty)
        XCTAssertFalse(BackendServersWindowBelong.plainEnough("")); XCTAssertFalse(BackendServersWindowBelong.plainEnough("x\ny"))
    }
    func testOpenerUsesAbsoluteFallbackAndRefusesFalseSuccess() {
        let input = BackendServersWindowBelongInput(dir: "/tmp/td-drive-abcdef", curl: "/curl", port: 1, sessionId: "shell", token: "abc", openers: [:], pages: nil, hooks: false)
        let script = BackendServersWindowBelong.openerScript("open", real: "", input: input)
        XCTAssertTrue(script.contains("REAL=''")); XCTAssertFalse(script.contains("command -v"))
        XCTAssertTrue(script.contains(#"[ "$#" -eq 1 ] || open_for_real "$@""#))
        XCTAssertTrue(script.contains("exit 127")); XCTAssertTrue(script.contains("opening it on this server instead"))
        XCTAssertTrue(script.contains(#"if [ "$ROUTE" = "tab" ]"#)); XCTAssertTrue(script.contains("-K \"$CONF\""))
    }
    func testHeredocsAreQuotedAndDelimiterCollisionOrPathInjectionRefuses() throws {
        let script = try BackendServersWindowDriveScripts.armScript(dir: "/tmp/td-drive-abcdef", files: [.init(path: "context/INDEX.md", body: "`literal` $HOME \\ text\n"), .init(path: "bin/claude", body: "body", executable: true)])
        XCTAssertTrue(script.contains("<<'TD_FILE_0'")); XCTAssertTrue(script.contains("`literal` $HOME \\ text")); XCTAssertTrue(script.contains("umask 077"))
        XCTAssertTrue(script.contains(#"chmod 700 "$d/bin/claude""#))
        XCTAssertThrowsError(try BackendServersWindowDriveScripts.armScript(dir: "/tmp/td-drive-abcdef", files: [.init(path: "x", body: "before\nTD_FILE_0\nafter")]))
        XCTAssertThrowsError(try BackendServersWindowDriveScripts.armScript(dir: "/tmp/td-drive-abcdef", files: [.init(path: "x\";touch y", body: "body")]))
        XCTAssertTrue(BackendServersWindowDriveScripts.disarmScript("/home/person").contains("/tmp/td-drive-??????"))
    }
    func testWrapperBypassesSubcommandsAndChecksOptionalSettingsFile() {
        let wrapper = BackendServersWindowDriveScripts.wrapperScript(real: "/home/a b/claude", subcommands: ["mcp", "plugin", "x;evil"], config: "/tmp/td-drive-abcdef/deck-control.json", settings: "/tmp/td-drive-abcdef/settings.json")
        XCTAssertTrue(wrapper.contains("REAL='/home/a b/claude'")); XCTAssertFalse(wrapper.contains("command -v"))
        XCTAssertTrue(wrapper.contains(#"mcp|plugin) exec "$REAL" "$@""#)); XCTAssertFalse(wrapper.contains("x;evil"))
        XCTAssertTrue(wrapper.contains(#"if [ -f "$SETTINGS" ]; then"#)); XCTAssertTrue(wrapper.contains("--settings"))
        let bare = BackendServersWindowDriveScripts.wrapperScript(real: "/x", subcommands: [], config: "/config", settings: nil)
        XCTAssertFalse(bare.contains("--settings"))
    }
    func testScoutUsesLastMarkAndOriginalOpenersBeforePathChange() {
        let scout = BackendServersWindowDriveScripts.readScouted("TD_SCOUTED\nwrong\nTD_SCOUTED\n/tmp/td-drive-abcdef\n/bin/bash\n/usr/bin/curl\n\n/usr/bin/xdg-open\n\n")
        XCTAssertEqual(scout.dir, "/tmp/td-drive-abcdef"); XCTAssertEqual(scout.shell, "/bin/bash")
        XCTAssertEqual(scout.openers["open"], ""); XCTAssertEqual(scout.openers["xdg-open"], "/usr/bin/xdg-open")
    }
    func testReachProvesTheAssignedPortBeforeAnyActivation() async {
        let client = BackendServersWindowTestConnection(port: 34567)
        let result = await BackendServersWindowReachRules.open(connection: client, local: .socketPath("/tmp/hook.sock"), runScript: { script in
            XCTAssertTrue(script.contains("p=34567")); XCTAssertNil(client.lease.activation)
            return .init(code: 0, stdout: "profile noise\nloopback\n")
        })
        guard case .opened(let reach) = result else { return XCTFail("Expected proved reach") }
        XCTAssertEqual(reach.port, 34567); XCTAssertEqual(client.boundAddress, "127.0.0.1"); XCTAssertEqual(client.lease.activation, "unix:/tmp/hook.sock")
        reach.close(); XCTAssertEqual(client.lease.closeCount, 1); reach.close(); XCTAssertEqual(client.lease.closeCount, 1)
    }
    func testPublicUnknownAndMissingPortBindingsAreTakenDownWithoutActivation() async {
        for answer in ["public", "unknown", "profile output"] {
            let client = BackendServersWindowTestConnection(port: 34567)
            let result = await BackendServersWindowReachRules.open(connection: client, local: .port(1234), runScript: { _ in .init(code: 0, stdout: answer) })
            guard case .refused(let why) = result else { XCTFail("Unproved binding was used"); continue }
            XCTAssertFalse(why.isEmpty); XCTAssertNil(client.lease.activation); XCTAssertEqual(client.lease.closeCount, 1)
        }
        let zero = BackendServersWindowTestConnection(port: 0)
        let result = await BackendServersWindowReachRules.open(connection: zero, local: .port(1234), runScript: { _ in XCTFail("Invalid port must not be probed"); return .init(code: 0, stdout: "loopback") })
        guard case .refused = result else { return XCTFail("Zero port was used") }
        XCTAssertNil(zero.lease.activation)
    }
    func testWindowCallerIsBoundToThisServerAndDroppedBeforeFolderRemoval() async {
        let log = BackendServersSetupTestLog(), client = BackendServersWindowTestConnection(port: 34567)
        let reach = BackendServersWindowReach(port: 34567, lease: client.lease)
        let minted = BackendDeckToolsSessionsPreparedElsewhere(configFor: { url in "config " + url }, started: { shell, server in log.add("bound:" + server + ":" + shell) }, drop: { log.add("drop") })
        let drives = BackendServersWindowDrives(.init(allowed: { _ in true }, claudeOn: { _ in .init(id: .claude, path: "/claude", version: "2") },
                                                     run: { _, _ in .init(code: 0, stdout: "--mcp-config --settings") }, runScript: { _, script in
            if script.contains("mktemp -d") { return .init(code: 0, stdout: "TD_SCOUTED\n/tmp/td-drive-abcdef\n/bin/bash\n\n\n\n\n") }
            log.add(script.contains("rm -rf") ? "remove" : "write"); return .init(code: 0, stdout: "")
        }, reach: { _, _ in .opened(reach) }, letGo: { _, kind in log.add("letGo:" + kind.rawValue) }, mint: { _ in minted }))
        let outcome = await drives.arm("SERVER", shellId: "SHELL")
        guard case .armed(let line) = outcome else { return XCTFail("Expected armed shell") }
        XCTAssertTrue(line.contains("export PATH=")); XCTAssertTrue(log.values.contains("bound:SERVER:SHELL"))
        await drives.disarm("SHELL")
        guard let dropped = log.values.firstIndex(of: "drop"), let removed = log.values.firstIndex(of: "remove") else { return XCTFail("Missing cleanup") }
        XCTAssertLessThan(dropped, removed)
    }
    func testDisabledServerRefusesBeforeMintAndRemoteCommands() async {
        let drives = BackendServersWindowDrives(.init(allowed: { _ in false }, claudeOn: { _ in XCTFail("disabled"); return nil }, run: { _, _ in XCTFail("disabled"); return .init(code: 0, stdout: "") }, runScript: { _, _ in XCTFail("disabled"); return .init(code: 0, stdout: "") }, reach: { _, _ in XCTFail("disabled"); return .refused("disabled") }, letGo: { _, _ in }, mint: { _ in XCTFail("disabled"); return nil }))
        let outcome = await drives.arm("S", shellId: "T")
        XCTAssertEqual(outcome, .refused(why: BackendServersWindowDriveReasons.notAllowed))
    }
    func testControlReachRefusalKeepsTheServersExactReasonAndDropsTheToken() async {
        let log = BackendServersSetupTestLog()
        let minted = BackendDeckToolsSessionsPreparedElsewhere(configFor: { _ in "unused" }, started: { _, _ in XCTFail("unproved reach must not bind") }, drop: { log.add("drop") })
        let drives = BackendServersWindowDrives(.init(allowed: { _ in true }, claudeOn: { _ in .init(id: .claude, path: "/claude", version: "2") }, run: { _, _ in .init(code: 0, stdout: "--mcp-config") }, runScript: { _, _ in XCTFail("unproved reach must not write"); return .init(code: 0, stdout: "") }, reach: { _, _ in .refused(BackendServersWindowReachRules.boundTooWidely) }, letGo: { _, _ in }, mint: { _ in minted }))
        let result = await drives.arm("s", shellId: "t")
        XCTAssertEqual(result, .refused(why: BackendServersWindowReachRules.boundTooWidely)); XCTAssertEqual(log.values, ["drop"])
    }
}

final class BackendServersWindowTestLease: BackendServersReverseForward, @unchecked Sendable {
    let port: Int; private let lock = NSLock(); private var target: String?; private var closed = 0
    init(port: Int) { self.port = port }
    var activation: String? { lock.withLock { target } }; var closeCount: Int { lock.withLock { closed } }
    func activate(target: BackendServersReverseTarget) async throws { lock.withLock { switch target { case .tcp(let host, let port): self.target = "tcp:\(host):\(port)"; case .unix(let path): self.target = "unix:" + path } } }
    func close() { lock.withLock { closed += 1 } }
}
final class BackendServersWindowTestConnection: BackendServersConnection, @unchecked Sendable {
    let lease: BackendServersWindowTestLease; private let lock = NSLock(); private var bound: String?
    init(port: Int) { lease = .init(port: port) }; var boundAddress: String? { lock.withLock { bound } }
    func reverseForward(bindAddress: String, bindPort: Int) async throws -> any BackendServersReverseForward { lock.withLock { bound = bindAddress }; return lease }
    func exec(command: String, stdin: Data?, timeoutMilliseconds: Int, maximumOutputBytes: Int) async throws -> BackendServersRunResult { throw BackendServersSetupFailure.unavailable("Unused test operation") }
    func follow(command: String) async throws -> any BackendServersFollow { throw BackendServersSetupFailure.unavailable("Unused test operation") }
    func shell(size: BackendServersTerminalSize) async throws -> any BackendServersShell { throw BackendServersSetupFailure.unavailable("Unused test operation") }
    func openSFTP() async throws -> any BackendServersSFTP { throw BackendServersSetupFailure.unavailable("Unused test operation") }
    func forward(host: String, port: Int) async throws -> any BackendServersDuplex { throw BackendServersSetupFailure.unavailable("Unused test operation") }
    func onClose(_ callback: @escaping @Sendable () -> Void) -> BackendServersUnsubscribe { {} }; func close() {}
}
