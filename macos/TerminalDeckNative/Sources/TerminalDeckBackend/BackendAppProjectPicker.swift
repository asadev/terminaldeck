import Foundation
import TerminalDeckNativeCore

public enum BackendAppProjectPicker {
    public static func startDirectory(projects: [String], home: String, exists: (String) -> Bool = directoryExists) -> String {
        for path in projects where !path.isEmpty {
            // Node dirname of a bare name is '.', rather than Foundation's cwd.
            guard path.contains("/") else { continue }
            var trimmed = path
            while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
            let parent = (trimmed as NSString).deletingLastPathComponent
            if !parent.isEmpty && parent != "." && exists(parent) { return parent }
        }
        return home
    }
    public static func directoryExists(_ path: String) -> Bool {
        var directory: ObjCBool = false; return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
}
