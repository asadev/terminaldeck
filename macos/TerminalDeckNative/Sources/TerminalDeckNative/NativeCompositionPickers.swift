import AppKit
import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Free-standing choosers for the production graph (Hoot's folder picker, the
/// task popup's files/folder, the SSH key file). Each is its own window, so
/// nothing has to step aside; a cancelled panel answers nil / [].
@MainActor
enum NativeCompositionFolderPicker {
    static func pick(_ start: String?) async throws -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if let start, start.hasPrefix("/") { panel.directoryURL = URL(fileURLWithPath: start, isDirectory: true) }
        return await panel.run().first
    }
    static func files() async throws -> [String] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
        return await panel.run()
    }
    static func file() async throws -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        return await panel.run().first
    }
}

private extension NSOpenPanel {
    @MainActor func run() async -> [String] {
        // Forward only for the person's own click; a picker asked for from the
        // background opens without taking another app's front (NativeFront).
        if NativeFront.personActing { NSApp.activate(ignoringOtherApps: true) }
        let response = await withCheckedContinuation { continuation in begin { continuation.resume(returning: $0) } }
        return response == .OK ? urls.map(\.path) : []
    }
}

/// TS index.ts revealInFileManager: a file is shown in Finder, a folder is opened.
struct NativeCompositionReveal: BackendCopilotInspectRevealing {
    func reveal(path: String, kind: String) async throws -> (opened: Bool, message: String) {
        await MainActor.run {
            let url = URL(fileURLWithPath: path)
            if kind == "file" {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                return (true, "Shown in your file manager.")
            }
            return NSWorkspace.shared.open(url) ? (true, "Opened.") : (false, "macOS could not open " + path + ".")
        }
    }
}
