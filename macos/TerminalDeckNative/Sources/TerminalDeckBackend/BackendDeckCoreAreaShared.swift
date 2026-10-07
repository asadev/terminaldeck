import Foundation
import TerminalDeckNativeCore

public enum BackendDeckCoreArguments {
    public static func str(_ args: NativeRPCValue, _ key: String) throws -> String {
        guard let value = args[key].string, !BackendDeckCoreCatalogueRules.trim(value).isEmpty else {
            throw NativeRPCError.invalidArguments("\(key) is required and must be a non-empty string")
        }
        return value
    }
    public static func optStr(_ args: NativeRPCValue, _ key: String) throws -> String? {
        if args[key].isNullish || args[key].string == "" { return nil }
        guard let value = args[key].string else { throw NativeRPCError.invalidArguments("\(key) must be a string") }
        return value
    }
    public static func bool(_ args: NativeRPCValue, _ key: String) throws -> Bool {
        guard let value = args[key].bool else { throw NativeRPCError.invalidArguments("\(key) is required and must be true or false") }
        return value
    }
    public static func optBool(_ args: NativeRPCValue, _ key: String, fallback: Bool) throws -> Bool {
        if args[key].isNullish { return fallback }
        guard let value = args[key].bool else { throw NativeRPCError.invalidArguments("\(key) must be true or false") }
        return value
    }
    public static func int(_ args: NativeRPCValue, _ key: String, min: Int, max: Int) throws -> Int {
        guard let value = args[key].number, value.rounded(.towardZero) == value else {
            throw NativeRPCError.invalidArguments("\(key) is required and must be a whole number")
        }
        guard value >= Double(min), value <= Double(max) else { throw NativeRPCError.invalidArguments("\(key) must be between \(min) and \(max)") }
        return Int(value)
    }
    public static func strList(_ args: NativeRPCValue, _ key: String) throws -> [String] {
        guard let list = args[key].elements, list.allSatisfy({ $0.string != nil }) else {
            throw NativeRPCError.invalidArguments("\(key) is required and must be a list of strings")
        }
        return list.compactMap(\.string)
    }
    public static func oneOf(_ args: NativeRPCValue, _ key: String, allowed: [String]) throws -> String {
        let value = try str(args, key)
        guard allowed.contains(value) else { throw NativeRPCError.invalidArguments("\(key) must be one of: \(allowed.joined(separator: ", "))") }
        return value
    }
    public static func verbOf(_ args: NativeRPCValue) -> String { args["do"].string ?? "" }
    public static func hereOnly(_ caller: BackendDeckCoreSecurityCaller, what: String) throws {
        guard caller.actsAsOwner else {
            throw BackendDeckCoreSecurityRefusal(.notGranted,
                "\(what) only works for the person at this computer, Hoot (the assistant they talk to here), and AI apps they gave an access key to. A paired device cannot do it from here. Say what you would have done and let them do it.")
        }
    }
    public static func sendableFile(_ path: String, alsoRefuse: [String] = [], home: String = FileManager.default.homeDirectoryForCurrentUser.path) throws -> String {
        guard path.hasPrefix("/") else { throw NativeRPCError.invalidArguments("path must be an absolute path to a file on this computer") }
        let clean = URL(fileURLWithPath: path).standardizedFileURL.path
        let refused = [".ssh", ".aws", ".gnupg", ".kube", ".docker", ".config/gh", "Library/Keychains"].map { home + "/" + $0 } + alsoRefuse
        for folder in refused where clean == folder || clean.hasPrefix(folder + "/") {
            throw BackendDeckCoreSecurityRefusal(.notPermitted,
                "\(clean) is inside \(folder), where sign-in keys and credentials are kept. Files there are never sent from this computer by a tool.")
        }
        return clean
    }
    public static func shown(_ text: String, most: Int = 160) -> String {
        text.utf16.count > most ? String(decoding: text.utf16.prefix(max(0, most)), as: UTF16.self) + "… (\(text.utf16.count) characters)" : text
    }
}
