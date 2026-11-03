import Foundation
import TerminalDeckNativeCore

public struct BackendServersWindowScratchFile: Sendable, Equatable {
    public let path: String; public let body: String; public let executable: Bool
    public init(path: String, body: String, executable: Bool = false) { self.path = path; self.body = body; self.executable = executable }
}
public struct BackendServersWindowBelongInput: Sendable {
    public let dir: String, curl: String; public let port: Int; public let sessionId: String, token: String
    public let openers: [String: String]; public let pages: [String: String]?; public let hooks: Bool
    public init(dir: String, curl: String, port: Int, sessionId: String, token: String, openers: [String: String], pages: [String: String]?, hooks: Bool) {
        self.dir = dir; self.curl = curl; self.port = port; self.sessionId = sessionId; self.token = token; self.openers = openers; self.pages = pages; self.hooks = hooks
    }
}
public enum BackendServersWindowBelong {
    public static let settingsFlag = "--settings", settingsFileName = "settings.json", hookConfigFile = "hook.conf", posterFile = "bin/td-hook", contextSubdir = "context"
    public static let events = ["SessionStart", "UserPromptSubmit", "PostToolUse"]
    public static let openerNames = ["open", "xdg-open", "sensible-browser"]
    public static let hookTimeoutSeconds = 5
    public static var marker: String { "# \(BackendSharedBrand.id)-hook" }
    public static var tokenHeader: String { "x-\(BackendSharedBrand.id)-token" }
    public static var sessionHeader: String { "x-\(BackendSharedBrand.id)-session" }
    public static func honoursSettings(_ help: String) -> Bool { help.contains(settingsFlag) }
    public static func plainEnough(_ text: String) -> Bool { !text.isEmpty && text.range(of: #"^[A-Za-z0-9 _.,:@+=/-]+$"#, options: .regularExpression) != nil }
    public static func files(_ input: BackendServersWindowBelongInput) -> [BackendServersWindowScratchFile] {
        guard input.port > 0, plainEnough(input.dir), input.dir.hasPrefix("/"), plainEnough(input.curl), input.curl.hasPrefix("/"), plainEnough(input.sessionId), input.token.range(of: #"^[0-9a-f]+$"#, options: .regularExpression) != nil else { return [] }
        var files: [BackendServersWindowScratchFile] = [.init(path: hookConfigFile, body: hookConfig(input.token))]
        for name in openerNames {
            let candidate = input.openers[name] ?? "", real = plainEnough(candidate) && candidate.hasPrefix("/") ? candidate : ""
            files.append(.init(path: "bin/" + name, body: openerScript(name, real: real, input: input), executable: true))
        }
        if input.hooks {
            let settings = settingsFile(input.dir)
            guard !settings.isEmpty else { return [] }
            files.append(.init(path: posterFile, body: posterScript(input), executable: true))
            files.append(.init(path: settingsFileName, body: settings))
            for name in (input.pages ?? [:]).keys.sorted() { files.append(.init(path: contextSubdir + "/" + name, body: input.pages![name]!)) }
        }
        return files
    }
    public static func hookConfig(_ token: String) -> String {
        "# Written by \(BackendSharedBrand.name) for this terminal only, and removed when it closes.\nheader = \"\(tokenHeader): \(token)\"\n"
    }
    public static func settingsFile(_ dir: String) -> String {
        let hooks = events.map { event in NativeRPCValue.Field(event, .array([.object([
            .init("matcher", .string("")), .init("hooks", .array([.object([
                .init("type", .string("command")), .init("command", .string("\(dir)/\(posterFile) \(event) \(marker)")), .init("timeout", .number(Double(hookTimeoutSeconds)))
            ])]))
        ])])) }
        guard let bytes = try? NativeRPCValue.object([.init("hooks", .object(hooks))]).encodedJSON(pretty: true),
              let text = String(data: bytes, encoding: .utf8) else { return "" }
        return text + "\n"
    }
    public static func posterScript(_ input: BackendServersWindowBelongInput) -> String {
        #"""
        #!/bin/sh
        # Written by \#(BackendSharedBrand.name) for this terminal, and removed when it closes.
        \#(marker)
        CURL='\#(input.curl)'
        CONF='\#(input.dir)/\#(hookConfigFile)'
        SESSION='\#(input.sessionId)'
        BASE='http://127.0.0.1:\#(input.port)/hook/claude/'
        case "${1:-}" in
        \#(events.map { "  " + $0 + ") ;;" }.joined(separator: "\n"))
          *) exit 0 ;;
        esac
        "$CURL" -s \
          --connect-timeout 1 \
          --max-time 3 \
          -X POST \
          -H 'content-type: application/json' \
          -H "\#(sessionHeader): $SESSION" \
          -K "$CONF" \
          --data-binary @- \
          "$BASE$1" 2>/dev/null
        exit 0

        """#
    }
    public static func openerScript(_ name: String, real: String, input: BackendServersWindowBelongInput) -> String {
        #"""
        #!/bin/sh
        # Written by \#(BackendSharedBrand.name) for this terminal, and removed when it closes.
        REAL='\#(real)'
        CURL='\#(input.curl)'
        CONF='\#(input.dir)/\#(hookConfigFile)'
        SESSION='\#(input.sessionId)'
        ENDPOINT='http://127.0.0.1:\#(input.port)/open'
        open_for_real() {
          if [ -n "$REAL" ] && [ -x "$REAL" ]; then exec "$REAL" "$@"; fi
          printf '%s\n' "\#(name): not found" >&2
          exit 127
        }
        [ "$#" -eq 1 ] || open_for_real "$@"
        case "$1" in
          http://*|https://*|HTTP://*|HTTPS://*|Http://*|Https://*) ;;
          *) open_for_real "$@" ;;
        esac
        ANSWER=$(printf '%s' "$1" | "$CURL" -s \
          --connect-timeout 1 \
          --max-time 3 \
          -X POST \
          -H 'content-type: text/plain' \
          -H "\#(sessionHeader): $SESSION" \
          -K "$CONF" \
          --data-binary @- \
          "$ENDPOINT" 2>/dev/null)
        ROUTE=$(printf '%s\n' "$ANSWER" | head -n 1)
        LINE=$(printf '%s\n' "$ANSWER" | sed -n '2,$p')
        if [ "$ROUTE" = "tab" ]; then printf '%s\n' "$LINE"; exit 0; fi
        if [ -n "$LINE" ]; then printf '%s\n' "$LINE"
        else printf '%s\n' "\#(BackendSharedBrand.name) did not take this link — opening it on this server instead."; fi
        open_for_real "$@"

        """#
    }
}
