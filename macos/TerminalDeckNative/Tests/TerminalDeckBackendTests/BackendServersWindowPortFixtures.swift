import Foundation
import TerminalDeckNativeCore
@testable import TerminalDeckBackend

enum BackendServersWindowPortFixtures {
    static let dir = "/tmp/td-drive-abcdef"
    static let help = """
    Usage: claude [options] [command] [prompt]

    Options:
      --mcp-config <configs...>            Load MCP servers from JSON files or
                                           strings (space-separated)
      -p, --print                          Print response and exit
      --settings <file-or-json>            Path to a settings JSON file or a JSON
                                           string to load additional settings from

    Commands:
      agents [options]                     Manage background agents
      doctor                               Check the health of your installation
      mcp                                  Configure and manage MCP servers
      plugin|plugins                       Manage plugins
      update                               Update to the latest version

    """
    static func scouted(dir: String = dir, shell: String = "/bin/bash", curl: String = "/usr/bin/curl") -> String {
        ["TD_SCOUTED", dir, shell, curl, "", "/usr/bin/xdg-open", ""].joined(separator: "\n")
    }
    static func wrapper(real: String = "/fake/claude", settings: String? = nil) -> String {
        BackendServersWindowDriveScripts.wrapperScript(real: real, subcommands: BackendServersWindowDriveScripts.subcommandsFrom(help), config: dir + "/deck-control.json", settings: settings)
    }
}
final class BackendServersWindowPortLease: BackendServersReverseForward, @unchecked Sendable {
    let port: Int; private let lock = NSLock(); private var target: String?, closed = 0
    init(port: Int) { self.port = port }
    var activation: String? { lock.withLock { target } }; var closeCount: Int { lock.withLock { closed } }
    func activate(target: BackendServersReverseTarget) async throws { lock.withLock { switch target { case .tcp(let host, let port): self.target = "tcp:\(host):\(port)"; case .unix(let path): self.target = "unix:" + path } } }
    func close() { lock.withLock { closed += 1 } }
}
struct BackendServersWindowPortDriveOptions: Sendable {
    var allowed = true, claude = true, help = BackendServersWindowPortFixtures.help, dir = BackendServersWindowPortFixtures.dir
    var shell = "/bin/bash", curl = "/usr/bin/curl", token: String? = "abc123", failWrite = false
    var controlRefusal: String?, hookRefusal: String?
}
struct BackendServersWindowPortDriveBox: Sendable {
    let bound = BackendServersSetupPortLog(), dropped = BackendServersSetupPortLog(), releases = BackendServersSetupPortLog(), written = BackendServersSetupPortLog(), order = BackendServersSetupPortLog(), asked = BackendServersSetupPortLog()
    let options: BackendServersWindowPortDriveOptions
    init(_ options: BackendServersWindowPortDriveOptions = .init()) { self.options = options }
    var drives: BackendServersWindowDrives {
        let options = options, bound = bound, dropped = dropped, releases = releases, written = written, order = order, asked = asked
        return BackendServersWindowDrives(.init(allowed: { _ in options.allowed }, claudeOn: { _ in asked.add("claude"); return options.claude ? .init(id: .claude, path: "/usr/bin/claude", version: "2.0.0", signedIn: .yes) : nil },
            run: { _, _ in .init(code: 0, stdout: options.help) }, runScript: { _, script in
                written.add(script)
                if script.contains("mktemp") { return .init(code: 0, stdout: BackendServersWindowPortFixtures.scouted(dir: options.dir, shell: options.shell, curl: options.curl)) }
                if script.contains("rm -rf") { order.add("removed"); return .init(code: 0, stdout: "") }
                if options.failWrite { throw BackendServersSetupFailure.unavailable("no space left on device") }
                return .init(code: 0, stdout: "")
            }, reach: { _, kind in
                if kind == .control, let why = options.controlRefusal { return .refused(why) }
                if kind == .hooks, let why = options.hookRefusal { return .refused(why) }
                let port = kind == .control ? 40404 : 40405
                return .opened(BackendServersWindowReach(port: port, lease: BackendServersWindowPortLease(port: port)))
            }, letGo: { server, kind in releases.add(server + "/" + kind.rawValue) }, mint: { _ in
                BackendDeckToolsSessionsPreparedElsewhere(configFor: { url in NativeRPCValue.object([.init("url", .string(url))]).compact }, started: { session, server in bound.add(server + "/" + session) }, drop: { order.add("dropped"); dropped.add("dropped") })
            }, hookEndpoint: { options.token }, remoteContext: { _, _ in .init(pages: ["INDEX.md": "# index"], mapFor: { "read " + $0 + "/INDEX.md" }) }))
    }
}
