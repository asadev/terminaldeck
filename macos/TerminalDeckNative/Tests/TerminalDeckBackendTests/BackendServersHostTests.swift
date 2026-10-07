import Foundation
import XCTest
@testable import TerminalDeckBackend

final class BackendServersHostTests: XCTestCase, @unchecked Sendable {
    func testProbeKeepsUnknownSeparateFromNotRunningAndNoUnit() {
        let unknown = BackendServersHostRules.readHostProbe("os\tLinux\ncommand\t/home/x/terminaldeck\nversion\t0.18.5\n")
        XCTAssertEqual(unknown.host.running, .unknown); XCTAssertEqual(unknown.host.unit, "")
        XCTAssertTrue(BackendServersHostRules.hostLine(unknown.host).contains("would not say"))
        let stopped = BackendServersHostRules.readHostProbe("command\t/home/x/terminaldeck\n--- status ---\nTerminal Deck host: not running\n")
        XCTAssertEqual(stopped.host.running, .no)
        XCTAssertEqual(BackendServersHostRules.readHostProbe("--- status ---\nhost connected\n").host.running, .unknown)
    }
    func testRelayAndAddressAreReadOnlyFromTheirOwnBlocks() {
        XCTAssertEqual(BackendServersHostRules.relayState("host connected\nRelay\n  not connected\n"), .notConnected)
        XCTAssertEqual(BackendServersHostRules.relayState("Relay\n  connected\n"), .connected)
        XCTAssertEqual(BackendServersHostRules.relayState("Relay\n  off\n"), .off)
        XCTAssertEqual(BackendServersHostRules.relayState("connected"), .unknown)
        XCTAssertEqual(BackendServersHostRules.hostIdOf(" host id ABCDE\n"), "ABCDE")
        XCTAssertEqual(BackendServersHostRules.channelsOf("  channels 0\n"), 0)
        XCTAssertNil(BackendServersHostRules.channelsOf("Relay\noff"))
        XCTAssertEqual(BackendServersHostRules.serverAddressOf("Server address\nsrv1.mangled"), "")
        XCTAssertEqual(BackendServersHostRules.serverAddressOf("srv1.mangled"), "")
    }
    func testRoomRefusalsUseRemoteFactsAndNeverOfferAWorseInstall() {
        var room = BackendServersHostRoom(os: "linux", node: "v22.1.0", npm: "/usr/bin/npm", homeFreeKb: 500 * 1024)
        XCTAssertNil(BackendServersHostRules.whyNotHost(room))
        room.npm = ""; XCTAssertFalse(BackendServersHostRules.usableNode(room))
        XCTAssertTrue(BackendServersHostRules.whyNotHost(room)?.contains("no curl or wget") == true)
        room.downloader = "curl"; room.canHash = true; room.canUnpack = true
        XCTAssertNil(BackendServersHostRules.whyNotHost(room))
        room.libc = "musl"; XCTAssertTrue(BackendServersHostRules.whyNotHost(room)?.contains("musl") == true)
        room.libc = "gnu"; room.missingTools = ["gcc", "g++"]
        XCTAssertTrue(BackendServersHostRules.whyNotHost(room)?.contains("sudo apt-get install -y gcc g++") == true)
        room.missingTools = []; room.os = "windows"
        XCTAssertTrue(BackendServersHostRules.whyNotHost(room)?.contains("desktop app") == true)
        for (host, mine, wanted) in [("0.9.1", "0.10.1", true), ("v0.18", "0.18.5", true), ("0.19", "0.18.5", false), ("0.18.5-beta", "0.19", false)] {
            XCTAssertEqual(BackendServersHostRules.hostUpdateAvailable(.init(command: "/x", version: host), mine: mine) != nil, wanted)
        }
    }
    func testHostPackageRequiresBothFilesAndPrefersPackagedResources() {
        let exists: (String) -> Bool = { $0.hasPrefix("/app/headless/") }
        let pack = BackendServersHostPackages.find(version: "0.18.5", resources: "/app", tree: "/tree", exists: exists)
        XCTAssertEqual(pack?.tarball, "/app/headless/terminaldeck-host.tgz")
        XCTAssertEqual(pack?.installer, "/app/headless/install.sh")
        XCTAssertNil(BackendServersHostPackages.find(version: "1", resources: "/app", tree: nil, exists: { $0.hasSuffix("install.sh") }))
    }
    func testServiceAndRemovalReceiptsGuardHomeAndPreserveDataByDefault() {
        let service = BackendServersHostScripts.service("/home/a b/.local/bin/terminaldeck")
        XCTAssertTrue(service.contains("ExecStart=$host")); XCTAssertTrue(service.contains("systemctl --user enable --now"))
        XCTAssertTrue(service.contains("loginctl enable-linger")); XCTAssertFalse(service.contains("sudo"))
        let keep = BackendServersHostScripts.remove("/home/a b/.local/bin/terminaldeck", dataDir: "/home/a b/.local/share/terminaldeck", alsoData: false)
        XCTAssertTrue(keep.contains("b='/home/a b/.local/bin/terminaldeck'")); XCTAssertTrue(keep.contains(#"case "$b" in "$HOME"/*)"#))
        XCTAssertFalse(keep.contains("dd="))
        let all = BackendServersHostScripts.remove("/home/a b/.local/bin/terminaldeck", dataDir: "/home/a b/.local/share/terminaldeck", alsoData: true)
        XCTAssertTrue(all.contains(#"case "$dd" in "$HOME"/*) rm -rf "$dd""#))
        XCTAssertEqual(BackendServersHostRules.shellQuote("/a'b"), "'/a'\\''b'")
    }
    func testAutomaticLinkChecksFingerprintKeepsCodeOffStateAndWaitsForChannel() async {
        let states = BackendServersSetupTestLog()
        let shell = BackendServersSetupTestShell { data, shell in
            if data.contains(" pair ") { shell.emit("Pairing code 123456\nFingerprint OUR-KEY\n") }
            if data == "y\n" { shell.emit("Approved as your own device\n") }
        }
        let hosts = BackendServersHosts(.init(runScript: { _, _ in .init(code: 0, stdout: "command\t/x\n--- status ---\nRelay\nconnected\n") },
                                             linkThisComputer: { _ in .linked(machineId: "machine", machineName: "Server", deviceFingerprint: "OUR-KEY") },
                                             whenReaching: { _, ceiling in XCTAssertEqual(ceiling, 20_000); return false },
                                             hostPackage: { nil }, broadcast: { states.add($0.code ?? "nil") }))
        let result = await hosts.link("server", shell: shell, command: "/x")
        XCTAssertEqual(result.step, .done); XCTAssertTrue(result.line.contains("has not reached it yet"))
        XCTAssertTrue(shell.writes.contains("y\n")); XCTAssertTrue(states.values.allSatisfy { $0 == "nil" })
    }
    func testFingerprintMismatchRefusesAndDoesNotSpendAnotherCode() async {
        let shell = BackendServersSetupTestShell { data, shell in if data.contains(" pair ") { shell.emit("Pairing code 123456\nFingerprint OTHER-KEY\n") } }
        let hosts = BackendServersHosts(.init(runScript: { _, _ in .init(code: 0, stdout: "") }, linkThisComputer: { _ in .linked(machineId: "m", machineName: "s", deviceFingerprint: "OUR-KEY") }, hostPackage: { nil }))
        let result = await hosts.link("s", shell: shell, command: "/x")
        XCTAssertEqual(result.step, .failed); XCTAssertTrue(shell.writes.contains("n\n")); XCTAssertFalse(shell.writes.contains("y\n"))
        XCTAssertEqual(shell.writes.filter { $0.contains(" pair ") }.count, 1)
    }
    func testThreeUnansweredCodesStopTheirRemoteCommandsAndNameRetryButton() async {
        let shell = BackendServersSetupTestShell { data, shell in if data.contains(" pair ") { shell.emit("Pairing code 123456\n") } }
        let hosts = BackendServersHosts(.init(runScript: { _, _ in .init(code: 0, stdout: "command\t/x\n--- status ---\nRelay\noff\n") }, linkThisComputer: { _ in .refused("No rendezvous.") }, relayWaitMilliseconds: 0, hostPackage: { nil }))
        let result = await hosts.link("s", shell: shell, command: "/x")
        XCTAssertEqual(result.step, .failed); XCTAssertTrue(result.detail.contains("off")); XCTAssertTrue(result.detail.contains("Link this computer"))
        XCTAssertEqual(shell.writes.filter { $0.contains(" pair ") }.count, 3)
        XCTAssertEqual(shell.writes.filter { $0 == "\u{03}" }.count, 3)
        XCTAssertNil(result.code)
    }
    func testPhoneCodeStaysAsPrintedAndNeverApprovesUnknownFingerprint() async {
        let shell = BackendServersSetupTestShell { data, shell in if data.contains(" pair ") { shell.emit("Pairing code CSPA-0ECH\nFingerprint OTHER-KEY\n") } }
        let hosts = BackendServersHosts(.init(runScript: { _, _ in .init(code: 0, stdout: "") }, hostPackage: { nil }))
        let result = await hosts.pairDevice("s", shell: shell, command: "/x")
        XCTAssertEqual(result.code, "CSPA-0ECH"); XCTAssertEqual(result.step, .done)
        XCTAssertFalse(shell.writes.contains("y\n")); XCTAssertFalse(shell.writes.contains("n\n"))
        await hosts.cancel("s"); XCTAssertTrue(shell.writes.contains("\u{03}"))
    }
    func testMissingPackageRefusesBeforeAnyFileUploadOrPTYWrite() async {
        let shell = BackendServersSetupTestShell(), uploads = BackendServersSetupTestLog()
        let hosts = BackendServersHosts(.init(runScript: { _, _ in .init(code: 0, stdout: "") }, putFile: { _, _, name in uploads.add(name); return "/x" }, hostPackage: { nil }))
        let result = await hosts.install("s", shell: shell, look: .init(host: .init(), room: .init(os: "linux", node: "22", npm: "/npm")), serverName: "server")
        XCTAssertEqual(result.step, .failed); XCTAssertTrue(uploads.values.isEmpty); XCTAssertTrue(shell.writes.isEmpty)
    }
    func testInstallUploadsInstallerFirstUsesCopiedReceiptAndEndsLinked() async {
        let log = BackendServersSetupTestLog()
        let shell = BackendServersSetupTestShell { data, shell in
            if data.contains("__terminaldeck_host") { shell.emit("__terminaldeck_host 0\n") }
            if data.contains(" pair ") { shell.emit("Pairing code 123456\nFingerprint OUR-KEY\n") }
            if data == "y\n" { shell.emit("Approved as your own device\n") }
        }
        let hosts = BackendServersHosts(.init(runScript: { _, script in
            if script == BackendServersHostScripts.probe { return .init(code: 0, stdout: "command\t/home/s/.local/bin/terminaldeck\nversion\t0.18.5\n--- status ---\nRelay\nconnected\n") }
            return .init(code: 0, stdout: "linger yes\n")
        }, linkThisComputer: { _ in .linked(machineId: "M", machineName: "server", deviceFingerprint: "OUR-KEY") },
                                             putFile: { _, _, name in log.add(name); return "/home/a b/.local/share/terminaldeck/uploads/" + name },
                                             hostPackage: { .init(tarball: "/bundle/host.tgz", installer: "/bundle/install.sh", version: "0.18.5") }))
        let result = await hosts.install("s", shell: shell, look: .init(host: .init(), room: .init(os: "linux", node: "22", npm: "/npm", systemdUser: true)), serverName: "server")
        XCTAssertEqual(log.values, ["install.sh", "terminaldeck-0.18.5.tgz"])
        XCTAssertTrue(shell.writes.contains { $0.contains("TERMINALDECK_PACKAGE='/home/a b/") })
        XCTAssertEqual(result.step, .done); XCTAssertNil(result.code); XCTAssertEqual(result.done.count, 5)
    }
}
