import Foundation
import TerminalDeckNativeCore

public enum BackendDeckCoreTyping {
    public struct Key: Sendable { public let name: String, label: String, bytes: String }
    public static let gapMs = 50.0, escapeGapMs = 150.0, maxKeys = 24
    public static let namedKeys: [Key] = [
        Key(name: "enter", label: "Enter", bytes: "\r"), Key(name: "escape", label: "Escape", bytes: "\u{1b}"),
        Key(name: "tab", label: "Tab", bytes: "\t"), Key(name: "shift-tab", label: "Shift-Tab", bytes: "\u{1b}[Z"),
        Key(name: "backspace", label: "Backspace", bytes: "\u{7f}"), Key(name: "delete", label: "Delete", bytes: "\u{1b}[3~"),
        Key(name: "space", label: "Space", bytes: " "), Key(name: "up", label: "Up", bytes: "\u{1b}[A"),
        Key(name: "down", label: "Down", bytes: "\u{1b}[B"), Key(name: "right", label: "Right", bytes: "\u{1b}[C"),
        Key(name: "left", label: "Left", bytes: "\u{1b}[D"), Key(name: "home", label: "Home", bytes: "\u{1b}[H"),
        Key(name: "end", label: "End", bytes: "\u{1b}[F"), Key(name: "page-up", label: "Page Up", bytes: "\u{1b}[5~"),
        Key(name: "page-down", label: "Page Down", bytes: "\u{1b}[6~"), Key(name: "ctrl-c", label: "Ctrl-C", bytes: "\u{03}"),
        Key(name: "ctrl-d", label: "Ctrl-D", bytes: "\u{04}"), Key(name: "ctrl-l", label: "Ctrl-L", bytes: "\u{0c}"),
        Key(name: "ctrl-u", label: "Ctrl-U", bytes: "\u{15}"), Key(name: "ctrl-r", label: "Ctrl-R", bytes: "\u{12}"),
        Key(name: "ctrl-o", label: "Ctrl-O", bytes: "\u{0f}"), Key(name: "ctrl-t", label: "Ctrl-T", bytes: "\u{14}"),
        Key(name: "ctrl-a", label: "Ctrl-A", bytes: "\u{01}"), Key(name: "ctrl-e", label: "Ctrl-E", bytes: "\u{05}")
    ]
    private static let aliases = ["return": "enter", "esc": "escape", "arrow-up": "up", "arrow-down": "down",
        "arrow-left": "left", "arrow-right": "right", "pageup": "page-up", "pagedown": "page-down", "shifttab": "shift-tab", "shift+tab": "shift-tab"]
    public static func resolveKey(_ value: NativeRPCValue) throws -> Key {
        guard let raw = value.string, !raw.isEmpty else { throw NativeRPCError.invalidArguments("each key must be a non-empty string") }
        if raw.unicodeScalars.count == 1, let scalar = raw.unicodeScalars.first {
            guard scalar.value >= 0x20, scalar.value != 0x7f, !(0x80...0x9f).contains(scalar.value) else {
                throw NativeRPCError.invalidArguments("a single-character key must be printable; name control keys instead, e.g. \"ctrl-c\"")
            }
            return Key(name: "char:" + raw, label: raw == " " ? "Space" : "“\(raw)”", bytes: raw)
        }
        let folded = BackendDeckCoreCatalogueRules.trim(raw).lowercased().unicodeScalars.map { scalar -> String in
            if scalar == "+" || scalar == "_" || BackendDeckCoreCatalogueRules.trim(String(scalar)).isEmpty { return "-" }
            return String(scalar)
        }.joined()
        let name = aliases[folded] ?? folded
        guard let key = namedKeys.first(where: { $0.name == name }) else {
            throw NativeRPCError.invalidArguments("there is no key called \"\(raw)\". Name one of: \(namedKeys.map(\.name).joined(separator: ", ")) — or give a single printable character such as \"y\" or \"2\".")
        }
        return key
    }
    public static func resolveKeys(_ value: NativeRPCValue) throws -> [Key] {
        guard let list = value.elements, !list.isEmpty else { throw NativeRPCError.invalidArguments("keys must be a non-empty list") }
        guard list.count <= maxKeys else { throw NativeRPCError.invalidArguments("at most \(maxKeys) keys in one call; got \(list.count)") }
        return try list.map(resolveKey)
    }
    public static func pressKeys(write: @Sendable (String) async throws -> Void, keys: [Key], clock: BackendDeckCoreBriefClock = .real) async throws {
        for (index, key) in keys.enumerated() {
            try Task.checkCancellation(); try await write(key.bytes)
            if index < keys.count - 1 { try await clock.sleep(key.bytes == "\u{1b}" ? escapeGapMs : gapMs) }
        }
    }
    public static func typeLine(write: @Sendable (String) async throws -> Void, text: String, submit: Bool, clock: BackendDeckCoreBriefClock = .real) async throws {
        try Task.checkCancellation(); try await write(submit && text.contains("@") ? text + " " : text)
        if submit { try await clock.sleep(gapMs); try Task.checkCancellation(); try await write("\r") }
    }
}

extension BackendDeckCoreArguments {
    public static var keyNames: [String] { BackendDeckCoreTyping.namedKeys.map(\.name) }
    public static func keysFrom(_ value: NativeRPCValue) throws -> [BackendDeckCoreTyping.Key] { try BackendDeckCoreTyping.resolveKeys(value) }
}
