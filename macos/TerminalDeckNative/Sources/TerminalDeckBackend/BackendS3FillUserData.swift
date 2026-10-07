import Foundation
import TerminalDeckNativeCore

/// Source src/main/user-data.ts `pinUserData`: the data folder is named by the product's slug, not
/// its display name; `state.json` is carried over once, on the first run after a rename; an explicit
/// `--user-data-dir` is never touched. Takes the folder the platform would have chosen and returns
/// the folder to use (nil means leave it alone). The caller applies the result.
public enum BackendS3FillUserData {
    public static let brandID = "terminaldeck"
    static let stateFile = "state.json"

    public static func pin(current: URL, arguments: [String], fileManager: FileManager = .default) -> URL? {
        if NativePlatformPaths.userDataFlag(arguments) != nil { return nil }
        let pinned = current.deletingLastPathComponent().appendingPathComponent(brandID, isDirectory: true)
        if current.standardizedFileURL.path == pinned.standardizedFileURL.path { return nil }
        do {
            try fileManager.createDirectory(at: pinned, withIntermediateDirectories: true)
            let target = pinned.appendingPathComponent(stateFile), source = current.appendingPathComponent(stateFile)
            // Only ever a first-run copy: once the pinned folder has state of its own it is the truth.
            if !fileManager.fileExists(atPath: target.path), fileManager.fileExists(atPath: source.path) {
                try fileManager.copyItem(at: source, to: target)
            }
            return pinned
        } catch {
            // A failure here must not stop the app booting: keep the default location.
            return nil
        }
    }
}
