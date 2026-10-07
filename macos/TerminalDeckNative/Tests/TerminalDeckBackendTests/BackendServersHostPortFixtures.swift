import Foundation
@testable import TerminalDeckBackend

enum BackendServersHostPortFixtures {
    static let machine = "P5PCNBABHBBVFDBZZ2ECELNAZ7", ours = "A3PL-DGAB-3N6W-RK3Y-V4VS-MMHP", other = "ZZZZ-DGAB-3N6W-RK3Y-V4VS-MMHP"
    static let bare = ["os\tLinux", "arch\tx86_64", "libc\tgnu", "node\tv18.19.1", "npm\t", "tools\t make gcc g++", "fetch\tcurl", "hash\tsha256sum", "tar\tyes", "home_free_kb\t33209852", "state_dir\t/root/.local/share/terminaldeck", "systemd_user\tyes", "command\t", ""].joined(separator: "\n")
    static let stopped = ["os\tLinux", "arch\tx86_64", "libc\tgnu", "node\tv18.19.1", "npm\t/home/td-scratch/.terminaldeck/runtime/bin/npm", "tools\t", "fetch\tcurl", "hash\tsha256sum", "tar\tyes", "home_free_kb\t32439968", "state_dir\t/home/td-scratch/.local/share/terminaldeck", "command\t/home/td-scratch/.local/bin/terminaldeck", "version\t0.9.1", "--- status ---", "Terminal Deck host: not running.", "", "  state  /home/td-scratch/.local/share/terminaldeck", "", "Start it with \"terminaldeck-host\", or run \"terminaldeck pair\", which starts it for you.", ""].joined(separator: "\n")
    static let running = ["os\tLinux", "arch\tx86_64", "libc\tgnu", "node\tv18.19.1", "npm\t/home/td-scratch/.terminaldeck/runtime/bin/npm", "tools\t", "fetch\tcurl", "hash\tsha256sum", "tar\tyes", "home_free_kb\t32439968", "state_dir\t/home/td-scratch/.local/share/terminaldeck", "state\tyes", "systemd_user\tyes", "unit\tactive", "linger\tyes", "command\t/home/td-scratch/.local/bin/terminaldeck", "version\t0.9.1", "--- status ---", "Terminal Deck host 0.9.1 — running, idle", "  pid 139188, up 5s", "  state  /home/td-scratch/.local/share/terminaldeck", "", "Relay", "  connected      wss://relay.terminaldeck.dev", "  host id        P5PCNBABHBBVFDBZZ2ECELNAZ7", "  fingerprint    A3PL-DGAB-3N6W-RK3Y-V4VS-MMHP", ""].joined(separator: "\n")
    static let offRelay = running.replacingOccurrences(of: "  connected      wss://relay.terminaldeck.dev", with: "  not connected  dialling").replacingOccurrences(of: "  host id        P5PCNBABHBBVFDBZZ2ECELNAZ7\n", with: "")
    static var good: BackendServersHostRoom { var r = BackendServersHostRules.readHostProbe(running).room; r.node = "v22.23.2"; r.npm = "/usr/bin/npm"; return r }
    static var goodLook: BackendServersHostLook { .init(host: BackendServersHostRules.readHostProbe(running).host, room: good) }
}

struct BackendServersHostPortOptions: Sendable {
    var after = BackendServersHostPortFixtures.running, carriesPackage = true, installExit = 0, canLink = true, approves = true, hostShows = BackendServersHostPortFixtures.ours
    var codes = ["904021"], answers: [BackendServersHostLinkOutcome] = [.linked(machineId: BackendServersHostPortFixtures.machine, machineName: "office-pc", deviceFingerprint: BackendServersHostPortFixtures.ours)]
    var reaches: Bool?, holdInstall = false, holdCode = false
    var beforeProbe: (@Sendable (Int) async -> Void)?, whileRedeeming: (@Sendable () async -> Void)?
}
final class BackendServersHostPortCursor: @unchecked Sendable {
    private let lock = NSLock(); private var values: [String: Int] = [:]
    func next(_ name: String) -> Int { lock.withLock { let value = values[name, default: 0]; values[name] = value + 1; return value } }
}
final class BackendServersHostPortStates: @unchecked Sendable {
    private let lock = NSLock(); private var recorded: [BackendServersHostState] = []
    func add(_ state: BackendServersHostState) { lock.withLock { recorded.append(state) } }
    var values: [BackendServersHostState] { lock.withLock { recorded } }
}
struct BackendServersHostPortBox: Sendable {
    let scripts = BackendServersSetupPortLog(), puts = BackendServersSetupPortLog(), states = BackendServersHostPortStates(), redeemed = BackendServersSetupPortLog(), waited = BackendServersSetupPortLog()
    let cursor = BackendServersHostPortCursor(), options: BackendServersHostPortOptions
    let shell: BackendServersSetupPortShell
    init(_ options: BackendServersHostPortOptions = .init()) {
        self.options = options
        let cursor = cursor
        shell = BackendServersSetupPortShell { line, shell in
            if line.contains("install.sh"), !options.holdInstall { shell.emit("__terminaldeck_host \(options.installExit)\n") }
            else if line.contains("pair --kind mine"), !options.holdCode {
                let at = cursor.next("mint"), code = options.codes[min(at, options.codes.count - 1)]
                shell.emit("\n  Pairing code   \(code)\n  Valid for      60 seconds\n")
            } else if line.trimmingCharacters(in: .whitespacesAndNewlines) == "y" {
                shell.emit(options.approves ? "\n  Approved as your own device. This Mac can reach this host now.\n" : "\n  This Mac was NOT approved.\n")
            }
        }
    }
    var dependencies: BackendServersHostDependencies {
        let scripts = scripts, puts = puts, states = states, redeemed = redeemed, waited = waited, cursor = cursor, options = options, shell = shell
        let link: (@Sendable (String) async -> BackendServersHostLinkOutcome)? = options.canLink ? { @Sendable code in
            redeemed.add(code); if let callback = options.whileRedeeming { await callback() }
            let at = cursor.next("redeem"), answer = options.answers[min(at, options.answers.count - 1)]
            if case .linked = answer { shell.emit("\n  New device     This Mac\n  Fingerprint    \(options.hostShows)\n\n  Check that fingerprint against the one the device is showing.\n\n  Approve it? [y/N] ") }
            return answer
        } : nil
        let reaching: (@Sendable (String, Int) async -> Bool)? = options.reaches.map { result -> (@Sendable (String, Int) async -> Bool) in { id, _ in waited.add(id); return result } }
        return .init(runScript: { _, script in
            scripts.add(script)
            if script == BackendServersHostScripts.probe { let at = cursor.next("probe"); if let callback = options.beforeProbe { await callback(at) }; return .init(code: 0, stdout: options.after) }
            if script.contains("enable --now") { return .init(code: 0, stdout: "linger yes\n") }
            return .init(code: 0, stdout: "")
        }, linkThisComputer: link, whenReaching: reaching, relayWaitMilliseconds: 0,
                     putFile: { _, local, name in puts.add(local + "|" + name); return "/home/me/Terminal Deck/" + name },
                     hostPackage: { options.carriesPackage ? .init(tarball: "/here/terminaldeck-host.tgz", installer: "/here/install.sh", version: "0.9.1") : nil }, broadcast: { states.add($0) })
    }
    func install(_ hosts: BackendServersHosts, look: BackendServersHostLook = BackendServersHostPortFixtures.goodLook) async -> BackendServersHostState { await hosts.install("s1", shell: shell, look: look, serverName: "box") }
}
