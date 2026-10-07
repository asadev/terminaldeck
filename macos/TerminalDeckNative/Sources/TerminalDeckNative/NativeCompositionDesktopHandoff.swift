import AppKit
import Foundation
import TerminalDeckBackend
import TerminalDeckNativeCore

/// The AppKit half of links and outside attachments (D14): link-open.ts
/// openSystemUrl / showLinkMenu (Launch Services, a native menu at the pointer,
/// the pasteboard) and attach-outside.ts's open panel and clipboard read. The
/// rules stay in BackendMacAppHandoffLinks / BackendMacAppHandoffAttachments.
struct NativeCompositionDesktopHandoff: BackendMacAppHandoffLinkDesktop, BackendMacAppHandoffAttachPanels, BackendMacAppHandoffAttachClipboard {
    let authority: BackendCompositionAuthority
    let registry: NativeChannelRegistry

    // MARK: links

    /// The asking window is the app's own, and it is still the current one.
    func ownerAlive(_ ownerID: String) async -> Bool {
        ownerID == BackendCompositionRoot.appOwnerID && (try? authority.localContext()) != nil
    }
    func hasWindow(_ ownerID: String) async -> Bool {
        guard await ownerAlive(ownerID) else { return false }
        return await MainActor.run { NSApp.windows.contains { $0.isVisible && $0.canBecomeMain } }
    }
    func push(_ ownerID: String, channel: String, value: NativeRPCValue) async throws {
        try await registry.publish(channel, arguments: [value], ownerID: ownerID)
    }
    func openSystem(_ url: String) async throws {
        guard let target = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw NativeRPCError(code: "invalid-url", message: "That is not a link this Mac can open.")
        }
        let opened = await MainActor.run { NSWorkspace.shared.open(target) }
        guard opened else { throw NativeRPCError(code: "open-failed", message: "No app on this Mac opened that link.") }
    }
    func copyLink(_ text: String) async throws {
        await MainActor.run {
            NSPasteboard.general.clearContents()
            _ = NSPasteboard.general.setString(text, forType: .string)
        }
    }
    func menu(_ ownerID: String, items: [BackendMacAppHandoffLinkMenuItem]) async throws {
        await NativeCompositionLinkMenu.pop(items)
    }

    // MARK: attachment panel

    func windowAvailable(_ ownerID: String) async -> Bool { await hasWindow(ownerID) }
    func open(ownerID: String, options: NativeRPCValue) async throws -> (cancelled: Bool, paths: [String]) {
        let paths = await NativeCompositionAttachPanel.run(options)
        return (paths == nil, paths ?? [])
    }

    // MARK: clipboard

    /// Electron's clipboard.read(format) on macOS: the pasteboard's string for
    /// that type (NSFilenamesPboardType reads as its XML property list).
    func read(_ format: String) async throws -> String {
        await MainActor.run {
            let board = NSPasteboard.general, type = NSPasteboard.PasteboardType(format)
            if let text = board.string(forType: type) { return text }
            if let list = board.propertyList(forType: type), !(list is String),
               let data = try? PropertyListSerialization.data(fromPropertyList: list, format: .xml, options: 0),
               let text = String(data: data, encoding: .utf8) { return text }
            return ""
        }
    }
    /// clipboard.readImage().toPNG(): the pasteboard's picture as PNG, or nil for none.
    func imagePNG() async throws -> Data? {
        await MainActor.run {
            let board = NSPasteboard.general
            if let png = board.data(forType: .png) { return png }
            guard let tiff = board.data(forType: .tiff), let image = NSBitmapImageRep(data: tiff) else { return nil }
            return image.representation(using: .png, properties: [:])
        }
    }
}

/// showLinkMenu: Open in System Browser (when the scheme can leave) and Copy
/// Link, popped at the pointer as the platform's own menu.
@MainActor
enum NativeCompositionLinkMenu {
    static func pop(_ items: [BackendMacAppHandoffLinkMenuItem]) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let targets = items.map { NativeCompositionLinkMenuTarget(click: $0.click) }
        for (item, target) in zip(items, targets) {
            let row = NSMenuItem(title: item.label, action: #selector(NativeCompositionLinkMenuTarget.choose(_:)), keyEquivalent: "")
            row.target = target
            menu.addItem(row)
        }
        _ = menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        withExtendedLifetime(targets) {}
    }
}

@MainActor
final class NativeCompositionLinkMenuTarget: NSObject {
    private let click: @Sendable () async throws -> Void
    init(click: @escaping @Sendable () async throws -> Void) { self.click = click }
    @objc func choose(_ sender: NSMenuItem) {
        let click = self.click
        Task { try? await click() }
    }
}

/// attach-outside.ts browse: Electron's showOpenDialog options on NSOpenPanel.
/// The image mode's filter ships with an "All files" escape (L430-441); a bare
/// NSOpenPanel has no format switcher, so no filter is applied rather than one
/// with no way out. nil is a cancelled panel.
@MainActor
enum NativeCompositionAttachPanel {
    static func run(_ options: NativeRPCValue) async -> [String]? {
        let properties = Set(options["properties"].elements?.compactMap(\.string) ?? [])
        let panel = NSOpenPanel()
        panel.canChooseDirectories = properties.contains("openDirectory")
        panel.canChooseFiles = properties.contains("openFile")
        panel.allowsMultipleSelection = properties.contains("multiSelections")
        if let title = options["title"].string { panel.title = title; panel.message = title }
        if let label = options["buttonLabel"].string { panel.prompt = label }
        if let start = options["defaultPath"].string, start.hasPrefix("/") { panel.directoryURL = URL(fileURLWithPath: start, isDirectory: true) }
        let response = await withCheckedContinuation { (continuation: CheckedContinuation<NSApplication.ModalResponse, Never>) in
            panel.begin { continuation.resume(returning: $0) }
        }
        return response == .OK ? panel.urls.map(\.path) : nil
    }
}
