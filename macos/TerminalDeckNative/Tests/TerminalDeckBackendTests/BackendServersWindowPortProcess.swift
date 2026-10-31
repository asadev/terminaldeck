import Foundation
import Testing
@testable import TerminalDeckBackend

/// A fake process boundary for the small generated POSIX clients. It parses
/// their actual quoted assignments and exec argv; it never invokes a shell,
/// curl, file writer, browser, network listener or executable on this computer.
enum BackendServersWindowPortProcess {
    struct Reply: Equatable { var out = "", err = ""; var status = 0; var argv: [String] = []; var stdin = "" }
    enum Invalid: Error { case unbalancedQuote, unknownScript, missingAssignment(String) }
    static func words(_ line: String, variables: [String: String] = [:], arguments: [String] = []) throws -> [String] {
        var quoted: Character?, escaped = false, started = false, word = "", result: [String] = []
        func append() {
            guard started else { return }
            if word == "$@" { result += arguments }
            else {
                let pattern = #"\$([A-Za-z_][A-Za-z0-9_]*|[0-9]+)"#
                var expanded = word
                if let regex = try? NSRegularExpression(pattern: pattern) {
                    for match in regex.matches(in: word, range: NSRange(word.startIndex..., in: word)).reversed() {
                        if let all = Range(match.range, in: expanded), let name = Range(match.range(at: 1), in: word) { expanded.replaceSubrange(all, with: variables[String(word[name])] ?? "$" + String(word[name])) }
                    }
                }
                result.append(expanded)
            }
            word = ""; started = false
        }
        for character in line {
            if escaped { word.append(character); started = true; escaped = false; continue }
            if quoted == "'" { if character == "'" { quoted = nil } else { word.append(character) }; continue }
            if character == "\\" { escaped = true; started = true; continue }
            if quoted == "\"" { if character == "\"" { quoted = nil } else { word.append(character) }; continue }
            if character == "'" || character == "\"" { quoted = character; started = true; continue }
            if character.isWhitespace { append() } else { word.append(character); started = true }
        }
        guard quoted == nil, !escaped else { throw Invalid.unbalancedQuote }; append(); return result
    }
    static func assignment(_ name: String, _ script: String) throws -> String {
        let line = try #require(script.components(separatedBy: "\n").first { $0.hasPrefix(name + "=") })
        return try #require(words(String(line.dropFirst(name.count + 1))).first)
    }
    static func joined(_ script: String) -> String { script.replacingOccurrences(of: #"\\\n\s*"#, with: " ", options: .regularExpression) }
    static func wrapper(_ script: String, args: [String], files: Set<String> = []) throws -> [String] {
        let real = try assignment("REAL", script), config = try assignment("CONFIG", script)
        var variables = ["REAL": real, "CONFIG": config]
        let subcommands = BackendServersSetupPortFixtures.capture(#"(?m)^\s*([a-z][a-z0-9|\-]*)\) exec "\$REAL" "\$@" ;;"#, script)?.components(separatedBy: "|") ?? []
        if let first = args.first, subcommands.contains(first) {
            let command = try #require(BackendServersSetupPortFixtures.capture(#"(?m)^\s*[a-z][a-z0-9|\-]*\) (exec "\$REAL" "\$@") ;;"#, script))
            return Array(try words(command, variables: variables, arguments: args).dropFirst(2))
        }
        var commands = script.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("exec ") }
        if script.contains("SETTINGS=") {
            let settings = try assignment("SETTINGS", script); variables["SETTINGS"] = settings
            #expect(script.contains(#"if [ -f "$SETTINGS" ]; then"#))
            commands = commands.filter { files.contains(settings) ? $0.contains("--settings") : !$0.contains("--settings") }
        }
        let command = try #require(commands.first)
        let argv = try words(command, variables: variables, arguments: args)
        #expect(argv.first == "exec" && argv.dropFirst().first == real)
        return Array(argv.dropFirst(2))
    }
    static func curlArguments(_ script: String, variables: [String: String]) throws -> [String] {
        let compact = joined(script), start = try #require(compact.range(of: #""$CURL" -s"#)?.lowerBound)
        let tail = compact[start...], stop = try #require(tail.range(of: "2>/dev/null")?.lowerBound)
        let argv = try words(String(compact[start..<stop]), variables: variables)
        return Array(argv.dropFirst())
    }
    static func poster(_ script: String, event: String, body: String, curlReply: String, curlStatus: Int = 0) throws -> Reply {
        var variables: [String: String] = [:]
        for name in ["CURL", "CONF", "SESSION", "BASE"] { variables[name] = try assignment(name, script) }
        variables["1"] = event
        let cases = script.components(separatedBy: "\n").compactMap { BackendServersSetupPortFixtures.capture(#"^\s+([A-Za-z]+)\) ;;$"#, $0) }
        #expect(script.contains("*) exit 0 ;;")); #expect(script.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("exit 0"))
        guard cases.contains(event) else { return .init() }
        let argv = try curlArguments(script, variables: variables)
        return .init(out: curlStatus == 0 ? curlReply : "", status: 0, argv: argv, stdin: argv.contains("@-") ? body : "")
    }
    static func opener(_ script: String, name: String, args: [String], curlReply: String, curlStatus: Int = 0, realExists: Bool) throws -> Reply {
        var variables: [String: String] = [:]
        for key in ["REAL", "CURL", "CONF", "SESSION", "ENDPOINT"] { variables[key] = try assignment(key, script) }
        #expect(script.contains(#"[ "$#" -eq 1 ] || open_for_real "$@""#))
        #expect(script.contains(#"exec "$REAL" "$@""#)); #expect(script.contains("exit 127"))
        func fallback(_ prefix: String = "", argv: [String] = [], stdin: String = "") -> Reply {
            if realExists, variables["REAL"]?.isEmpty == false { return .init(out: prefix + "REAL\n" + args.map { $0 + "\n" }.joined(), status: 0, argv: argv, stdin: stdin) }
            return .init(out: prefix, err: name + ": not found\n", status: 127, argv: argv, stdin: stdin)
        }
        guard args.count == 1 else { return fallback() }
        let prefixes = try #require(BackendServersSetupPortFixtures.capture(#"(?m)^\s*(http[^\n]+)\) ;;"#, script)).components(separatedBy: "|").map { String($0.dropLast()) }
        guard prefixes.contains(where: { args[0].hasPrefix($0) }) else { return fallback() }
        variables["1"] = args[0]
        let argv = try curlArguments(script, variables: variables)
        let reply = curlStatus == 0 ? curlReply : "", lines = reply.components(separatedBy: "\n"), route = lines.first ?? ""
        let text = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .newlines)
        #expect(script.contains(#"if [ "$ROUTE" = "tab" ]"#)); #expect(script.contains("head -n 1")); #expect(script.contains("sed -n '2,$p'"))
        if route == "tab" { return .init(out: text + "\n", status: 0, argv: argv, stdin: args[0]) }
        let message = text.isEmpty ? BackendSharedBrand.name + " did not take this link — opening it on this server instead." : text
        #expect(script.contains("opening it on this server instead."))
        return fallback(message + "\n", argv: argv, stdin: args[0])
    }
    struct Written: Equatable { let body: String; var mode: Int }
    static func armFiles(_ script: String) throws -> [String: Written] {
        let dir = try assignment("d", script)
        #expect(script.contains(#"case "$d" in /tmp/td-drive-??????)"#)); #expect(script.contains("umask 077"))
        var files: [String: Written] = [:], lines = script.components(separatedBy: "\n"), index = 0
        while index < lines.count {
            let line = lines[index]
            if let relative = BackendServersSetupPortFixtures.capture(#"^cat > "\$d/([^"]+)" <<'TD_FILE_\d+'"#, line),
               let tag = BackendServersSetupPortFixtures.capture(#"<<'(TD_FILE_\d+)'"#, line) {
                index += 1; var body: [String] = []
                while index < lines.count && lines[index] != tag { body.append(lines[index]); index += 1 }
                guard index < lines.count else { throw Invalid.unbalancedQuote }
                files[dir + "/" + relative] = .init(body: body.joined(separator: "\n") + "\n", mode: 0o600)
            } else if let relative = BackendServersSetupPortFixtures.capture(#"^chmod 700 "\$d/([^"]+)""#, line) { files[dir + "/" + relative]?.mode = 0o700 }
            index += 1
        }
        return files
    }
}
