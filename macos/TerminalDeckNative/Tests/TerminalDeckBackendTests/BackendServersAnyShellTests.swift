import Foundation
import Testing
@testable import TerminalDeckBackend

/// U37: server scripts must not assume one shell or one OS. Each script runs for real here,
/// with stand-in tools on PATH where the server's own tool matters.
@Suite("Server scripts on any shell and any OS")
struct BackendServersAnyShellTests {
    private func run(_ shell: String, _ arguments: [String], path: String? = nil) throws -> (code: Int32, out: String, err: String) {
        let process = Process(), out = Pipe(), err = Pipe()
        process.executableURL = URL(fileURLWithPath: shell); process.arguments = arguments
        process.standardOutput = out; process.standardError = err
        if let path { var env = ProcessInfo.processInfo.environment; env["PATH"] = path; process.environment = env }
        try process.run(); process.waitUntilExit()
        return (process.terminationStatus, String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }
    private func folder(_ tools: [String: String] = [:]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("td-anyshell-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, body) in tools {
            let file = dir.appendingPathComponent(name)
            try ("#!/bin/sh\n" + body + "\n").write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        }
        return dir
    }

    @Test("#59: a degraded systemd user manager still counts as one") func degradedSystemd() throws {
        let line = try #require(BackendServersHostScripts.probe.components(separatedBy: "\n").first { $0.contains("is-system-running") })
        for (state, code, expected) in [("degraded", 1, true), ("running", 0, true), ("offline", 1, false)] {
            let tools = try folder(["systemctl": "echo \(state); exit \(code)"]); defer { try? FileManager.default.removeItem(at: tools) }
            let result = try run("/bin/sh", ["-c", #"p() { printf "%s\t%s\n" "$1" "$2"; }"# + "\n" + line], path: tools.path + ":/usr/bin:/bin")
            #expect(result.out.contains("systemd_user\tyes") == expected, "\(state)")
        }
    }

    @Test("#100: the gallery scan lists files on a Mac (BSD stat), not an empty finished scan") func bsdScan() throws {
        let home = try folder(); defer { try? FileManager.default.removeItem(at: home) }
        try Data(repeating: 1, count: 2048).write(to: home.appendingPathComponent("a b.jpg"))
        try Data().write(to: home.appendingPathComponent("notes.txt"))
        let script = BackendServersFilesLive.scanScript(skip: ["node_modules"], extensions: ["jpg"], limit: 10)
        let result = try run("/bin/sh", ["-c", script, "sh", home.path])
        let entries = result.out.split(separator: "\n").compactMap(BackendServersFilesLive.parseScanLine)
        #expect(result.out.hasSuffix("##td-scan-end\n"))
        #expect(entries.count == 1 && entries.first?.name == "a b.jpg" && entries.first?.size == 2048 && (entries.first?.modified ?? 0) > 1_600_000_000)
    }

    @Test("#101: install and sign-out lines run inside sh, so fish or csh login shells still report the result") func anyLoginShell() throws {
        let line = BackendServersSetupRules.marked(#"printf '%s\n' "it's here" && false"#)
        #expect(line.hasPrefix("sh -c '"))
        for shell in ["/bin/sh", "/bin/zsh", "/bin/tcsh"] where FileManager.default.isExecutableFile(atPath: shell) {
            let result = try run(shell, ["-c", line])
            #expect(result.out.contains("it's here") && result.out.contains(BackendServersSetupRules.done + " 1"), "\(shell)")
        }
    }

    @Test("#126: an older MariaDB with only mysqldump still backs up") func mysqldumpFallback() throws {
        let dump = try #require(BackendServersActions.dumpCommand(.mariadb, managedBy: .container(runtime: .docker, name: "db", compose: nil))?.dump.last)
        let tools = try folder(["mysqldump": #"echo "dumped by mysqldump $*""#]); defer { try? FileManager.default.removeItem(at: tools) }
        let result = try run("/bin/sh", ["-c", dump], path: tools.path + ":/usr/bin:/bin")
        #expect(result.code == 0 && result.out.contains("dumped by mysqldump -u root --all-databases"))
    }
}
