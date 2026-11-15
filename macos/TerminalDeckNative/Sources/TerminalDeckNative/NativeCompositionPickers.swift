import AppKit
import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// Free-standing choosers for the production graph (Hoot's folder picker, the
/// task popup's files/folder, the SSH key file). Each is its own window, so
/// nothing has to step aside; a cancelled panel answers nil / [].
@MainActor
enum NativeCompositionFolderPicker {
    /// `window` and `acting` are taken at the press itself (proof 3): the picker then opens as a sheet on the window
    /// that was clicked, even when that window was not the main one, instead of a free panel decided later.
    static func pick(_ start: String?, on window: NSWindow? = nil, acting: Bool? = nil) async throws -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if let start, start.hasPrefix("/") { panel.directoryURL = URL(fileURLWithPath: start, isDirectory: true) }
        return await panel.run(on: window, acting: acting).first
    }
    /// The window a press came from: the event's own window, else the key window.
    static func pressWindow(event: NSWindow?, key: NSWindow?) -> NSWindow? { event ?? key }
    nonisolated static func canHostSheet(visible: Bool, hasSheet: Bool) -> Bool { visible && !hasSheet }
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
    @MainActor func run(on window: NSWindow? = nil, acting: Bool? = nil) async -> [String] {
        // Forward only for the person's own click; a picker asked for from the
        // background opens without taking another app's front (NativeFront).
        let person = acting ?? NativeFront.personActing
        if person { NSApp.activate(ignoringOtherApps: true) } // front-ok: NativeFront.personActing, taken at the press
        let response: NSApplication.ModalResponse
        if person, let window, NativeCompositionFolderPicker.canHostSheet(visible: window.isVisible, hasSheet: window.attachedSheet != nil) {
            // The clicked window comes forward with its sheet, whichever window was main before.
            window.makeKeyAndOrderFront(nil) // front-ok: the person's own press (acting)
            response = await withCheckedContinuation { continuation in beginSheetModal(for: window) { continuation.resume(returning: $0) } }
        } else {
            response = await withCheckedContinuation { continuation in begin { continuation.resume(returning: $0) } }
        }
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
