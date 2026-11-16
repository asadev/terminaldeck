import AppKit
import Foundation
import ImageIO
import TerminalDeckNativeCore

/// 15 Nov (Asad's recording, items 15, 21, 22): what the chat SHOWS for a message. What Hoot receives is never changed;
/// only the drawing leaves out the app's own wiring (picture markers, file paths, accessibility trees, CLI diagnostics).
enum HootMessageDisplay {
    /// `[browser screenshot of http://…: /Users/…/marked-….png (1640 x 896)]`, `[iOS Simulator screenshot of "TD iPhone": /… (1206 x 2622)]`,
    /// `[Annotate: 2 marked elements on …; picture with the numbered markers: /… (w x h)]`. The path follows ": " (a space), so
    /// the "http:" of a page address is never taken for it.
    static let markerPattern = #"\[[^\[\]]*?(?:screenshot|Annotate|picture)[^\[\]]*?:\s+(/[^\[\]]+?\.(?:png|jpe?g|gif|webp|heic|tiff?))\s*\(\d+\s*x\s*\d+\)\]"#
    /// A bare path into the app's own picture folders.
    static let ownPathPattern = #"(?:/Users/[^/\s]+|~)/(?:Library/Application Support/terminaldeck|Pictures/Terminal Deck)/[^\s\]\)]+"#

    /// The person's message as the chat draws it.
    static func shown(_ text: String) -> String {
        // A device screen sent from a device's menu: the picture card says which device; the element tree is for Hoot only.
        if text.hasPrefix("Screen from "), text.contains("\nAccessibility tree:") { return "" }
        var shown = text.replacingOccurrences(of: markerPattern, with: "", options: .regularExpression)
        shown = shown.replacingOccurrences(of: ownPathPattern, with: "", options: .regularExpression)
        shown = shown.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        return shown.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The saved picture a message points at: the capture's own path first, then the first marker's.
    static func picturePath(text: String, source: NativeRPCValue) -> String? {
        if let path = source["path"].string, !path.isEmpty { return path }
        guard let regex = try? NSRegularExpression(pattern: markerPattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    /// The line under the picture card's title: the page address for a browser picture, the kind of device for a device
    /// screen (its NAME is the title), never an id.
    static func cardDetail(text: String, source: NativeRPCValue) -> String? {
        if let url = source["url"].string, !url.isEmpty { return url }
        if let regex = try? NSRegularExpression(pattern: #"\[([^\[\]":]+?) screenshot of ""#),
           let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let range = Range(match.range(at: 1), in: text) {
            return String(text[range]).trimmingCharacters(in: .whitespaces)
        }
        if source["kind"].string == "device" || source["deviceId"].string != nil { return "Device screen" }
        return nil
    }

    /// The card's title: the page's or device's name; a bare id never shows.
    static func cardTitle(_ source: NativeRPCValue) -> String? {
        guard let title = source["title"].string?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { return nil }
        if title.range(of: #"^(?:ios:|android:)?[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-"#, options: .regularExpression) != nil { return nil }
        return title
    }
}

/// How a turn that did not finish ends in the chat (items 15 and 21): the person's Stop is one quiet word, a failure is
/// one plain sentence with Try again, and an internal diagnostic line is never shown (it is in the app's log).
enum HootTurnEnd: Equatable {
    case stopped
    case failed(String)

    static let failedSentence = "Hoot could not finish this answer."

    /// The Claude Code CLI's own end-of-turn diagnostics, e.g. `[ede_diagnostic] result_type=user last_content_type=n/a stop_reason=null`.
    static func isDiagnostic(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.range(of: #"^\[[a-z0-9_]*diagnostic[a-z0-9_]*\]"#, options: .regularExpression) != nil { return true }
        return trimmed.contains("result_type=") && trimmed.contains("stop_reason=")
    }

    /// `kind` is the row's kind; `text` its text; `stoppedByPerson` whether this turn holds the person's Stop.
    static func of(kind: HootChatKind, text: String, stoppedByPerson: Bool) -> HootTurnEnd {
        if kind == .interrupted || stoppedByPerson { return .stopped }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // No Stop of his was recorded for such a turn (the backend now writes a real stop as `interrupted`), so an old
        // diagnostic line reads as a failure he can try again, never as the raw line.
        if isDiagnostic(trimmed) { return .failed(failedSentence) }
        if trimmed.isEmpty || trimmed == "Stopped." || trimmed == "Stopped" { return trimmed.isEmpty ? .failed(failedSentence) : .stopped }
        let safe = NativeChatDisplayError.text(trimmed)
        return .failed(safe.isEmpty ? failedSentence : safe)
    }
}

/// The real picture of a message whose bytes are no longer in memory (after a restart): read from the app's own
/// picture folders only (the browser's and Hoot's screenshots, ~/Pictures/Terminal Deck), never any other file.
@MainActor enum HootSavedPicture {
    private static var cache: [String: NSImage] = [:]
    private static var missing: Set<String> = []

    static func allowedFolders(dataRoot: URL) -> [String] {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Terminal Deck", isDirectory: true)
        return ([dataRoot.appendingPathComponent("browser-screenshots", isDirectory: true),
                 RNMHootPaths(dataRoot: dataRoot).screenshots] + [pictures].compactMap { $0 })
            .map { $0.resolvingSymlinksInPath().standardizedFileURL.path + "/" }
    }

    static func isAllowed(_ path: String, folders: [String]) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/"), !expanded.contains("/../") else { return false }
        let real = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL.path
        let ext = (real as NSString).pathExtension.lowercased()
        guard ["png", "jpg", "jpeg", "gif", "webp", "heic", "tif", "tiff"].contains(ext) else { return false }
        return folders.contains { real.hasPrefix($0) }
    }

    static func thumbnail(for value: NativeRPCValue, dataRoot: URL? = nil) -> NSImage? {
        let source = value["context"]["source"]
        guard let path = HootMessageDisplay.picturePath(text: value["text"].string ?? "", source: source) else { return nil }
        if let image = cache[path] { return image }
        if missing.contains(path) { return nil }
        let root = dataRoot ?? AppModel.shared.engine.configuration.engineDataDirectory
        guard isAllowed(path, folders: allowedFolders(dataRoot: root)),
              let image = load((path as NSString).expandingTildeInPath) else { missing.insert(path); return nil }
        if cache.count > 40 { cache.removeAll() }
        cache[path] = image
        return image
    }

    private static func load(_ path: String) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 640,
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: thumbnail, size: .zero)
    }
}
