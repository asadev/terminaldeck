import Foundation

// What goes INTO a session from the native terminal: typed paths, dropped text,
// pastes, and the few chords the terminal answers itself. Each rule is the web
// terminal's own (terminal-drop.ts, terminal-clipboard.ts, chat/attach/mentions.ts,
// xterm's Clipboard.ts), restated here so it can be tested without a window.

public enum TerminalText {
    /// `normalise` from mentions.ts: trimmed, trailing separators dropped
    /// (a drive root keeps its one), never reduced to nothing.
    public static func normalisePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 1 else { return trimmed }
        if trimmed.range(of: #"^[A-Za-z]:[\\/]+$"#, options: .regularExpression) != nil {
            return String(trimmed.prefix(3))
        }
        let stripped = trimmed.replacingOccurrences(of: #"[\\/]+$"#, with: "", options: .regularExpression)
        return stripped.isEmpty ? trimmed : stripped
    }

    /// `shellQuote`: single quotes for a POSIX path (with `'` written `'\''`),
    /// double quotes for a Windows one — chosen from the path's shape, not this machine.
    public static func shellQuote(_ path: String) -> String {
        let target = normalisePath(path)
        if target.range(of: #"^[A-Za-z]:"#, options: .regularExpression) != nil || target.hasPrefix("\\\\") {
            return "\"\(target)\""
        }
        return "'" + target.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `promptWord`: a path as it should appear at a prompt — quoted, then one space,
    /// so four dropped files are four arguments. No Return is ever added.
    public static func promptWord(_ path: String) -> String {
        shellQuote(path) + " "
    }

    /// `droppedText`: `\r\n` and lone `\r` become `\n`, so a dropped snippet
    /// cannot run its first line before the second is read.
    public static func droppedText(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        // Swift treats "\r\n" as one Character, so walk the scalars.
        var out = String.UnicodeScalarView()
        var previousWasCR = false
        for scalar in raw.unicodeScalars {
            if scalar == "\r" {
                out.append("\n")
                previousWasCR = true
                continue
            }
            if scalar == "\n" && previousWasCR {
                previousWasCR = false
                continue
            }
            previousWasCR = false
            out.append(scalar)
        }
        return String(out)
    }

    public static let bracketedPasteStart = "\u{1b}[200~"
    public static let bracketedPasteEnd = "\u{1b}[201~"

    /// xterm's `paste()`: line endings become a Return each (`\r?\n` → `\r`), and
    /// the whole is wrapped in `ESC[200~ … ESC[201~` when the program asked for
    /// bracketed paste — what every ⌘V, drop and typed path goes through.
    public static func pasteData(_ text: String, bracketed: Bool) -> String {
        var out = String.UnicodeScalarView()
        var pendingCR = false
        for scalar in text.unicodeScalars {
            if pendingCR {
                pendingCR = false
                if scalar == "\n" { out.append("\r"); continue }
                out.append("\r")
            }
            if scalar == "\r" { pendingCR = true; continue }
            if scalar == "\n" { out.append("\r"); continue }
            out.append(scalar)
        }
        if pendingCR { out.append("\r") }
        let body = String(out)
        return bracketed ? bracketedPasteStart + body + bracketedPasteEnd : body
    }
}

/// What a ⌘V carries, once the pasteboard has been read.
public enum TerminalPastePlan: Equatable, Sendable {
    /// Files copied in Finder: each path typed at the prompt, quoted, with a space.
    case paths([String])
    /// An image with no file behind it (a screenshot): its bytes become a file on
    /// this Mac first (`transfer:stage`), then that path is typed.
    case stageImage(name: String)
    /// Ordinary text, pasted as xterm pastes it.
    case text(String)
    /// Nothing usable.
    case nothing

    /// `pastedFiles` + the plain-text path, decided from what is on the pasteboard.
    ///
    /// Files win, because a Finder copy also carries the file's name as text and
    /// its icon as an image. Then, as the page's paste handler: any image on the
    /// clipboard is a file item there (`pastedFiles` reads `items`), so an image
    /// wins over text that came with it — a spreadsheet copy pastes its picture.
    /// Only a paste with no file and no image is a text paste.
    public static func decide(filePaths: [String], hasImage: Bool, imageType: String?, text: String?, now: Date) -> TerminalPastePlan {
        let paths = filePaths.filter { !$0.isEmpty }
        if !paths.isEmpty { return .paths(paths) }
        if hasImage { return .stageImage(name: pastedName(type: imageType, now: now)) }
        if let text, !text.isEmpty { return .text(text) }
        return .nothing
    }

    /// `pastedName`: a clipboard image's file name, `pasted-YYYYMMDD-HHMMSS.<ext>` in local time.
    public static func pastedName(type: String?, now: Date, calendar: Calendar = .current) -> String {
        let extensions = [
            "image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp",
            "image/svg+xml": "svg", "image/tiff": "tiff", "image/bmp": "bmp",
        ]
        let ext = extensions[(type ?? "").lowercased()] ?? "bin"
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        func two(_ n: Int?) -> String { String(format: "%02d", n ?? 0) }
        return "pasted-\(c.year ?? 0)\(two(c.month))\(two(c.day))-\(two(c.hour))\(two(c.minute))\(two(c.second)).\(ext)"
    }
}

/// `readHandover`: what `transfer:stage` (and the other transfer channels) answer.
public enum TerminalHandover: Equatable, Sendable {
    case path(String)
    case refused(String)

    public static func read(_ response: Any?) -> TerminalHandover {
        guard let body = response as? [String: Any] else {
            return .refused("Sending files is not available in this build.")
        }
        if TerminalJSON.bool(body["ok"]) == true, let path = TerminalJSON.text(body["path"]) {
            return .path(path)
        }
        return .refused(TerminalJSON.text(body["message"]) ?? "That file did not send.")
    }
}

/// A program in the session putting something on the clipboard (OSC 52).
/// Sets are allowed up to a megabyte; reads are never answered.
public enum TerminalClipboard {
    /// `MAX_OSC_CLIPBOARD_BYTES`.
    public static let maxBytes = 1024 * 1024
    public static let tooLarge = "That copy was too large to put on the clipboard."
    public static let didNotReach = "That copy did not reach the clipboard."

    public enum Decision: Equatable, Sendable {
        case copy(String)
        case refuse(String)
        case ignore
    }

    public static func decide(_ content: Data) -> Decision {
        if content.count > maxBytes { return .refuse(tooLarge) }
        let text = String(decoding: content, as: UTF8.self)
        return text.isEmpty ? .ignore : .copy(text)
    }
}

/// Which links a click in a session may open: web addresses only, as the web
/// terminal (WebLinksAddon + OSC 8 without `allowNonHttpProtocols`). They go to
/// `link:open` with the session's id, which routes them like the page does.
public enum TerminalLinks {
    public static func openable(_ link: String) -> String? {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host?.isEmpty == false else { return nil }
        return text
    }
}

/// The session's own chords (`TERMINAL_COMMANDS`): find, clear, copy.
/// As the page's `terminalChord`: ⌘ or ⌃ for those three (⌘F / ⌃F, ⌘⇧K / ⌃⇧K,
/// ⌘⇧C / ⌃⇧C), never with ⌥. The Mac's own edit chords (find next, copy, paste,
/// select all) stay ⌘ only, as the page's menu has them.
public enum TerminalChord: Equatable, Sendable {
    case find, findNext, findPrevious, clear, copy, paste, selectAll

    public static func from(key: String, command: Bool, shift: Bool, option: Bool, control: Bool) -> TerminalChord? {
        guard !option, command || control else { return nil }
        let key = key.lowercased()
        switch (key, shift) {
        case ("f", false): return .find
        case ("k", true): return .clear
        case ("c", true): return .copy
        default: break
        }
        guard command, !control else { return nil }
        switch (key, shift) {
        case ("g", false): return .findNext
        case ("g", true): return .findPrevious
        case ("c", false): return .copy
        case ("v", false): return .paste
        case ("a", false): return .selectAll
        default: return nil
        }
    }
}

public enum TerminalSessionID {
    /// A session on this Mac: the engine's pty ids are UUIDs. Held rows (`held:…`),
    /// sessions on another machine (`machine …`), server shells (`server …`) and
    /// browser tabs (`browser:…`) are not, and stay the page.
    public static func isLocal(_ id: String) -> Bool {
        UUID(uuidString: id) != nil
    }
}
