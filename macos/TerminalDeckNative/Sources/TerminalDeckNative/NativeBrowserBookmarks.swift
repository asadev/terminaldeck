import AppKit
import Observation
import TerminalDeckNativeCore

/// The built-in browser's bookmarks (owner, 18 Nov 2026), per browser profile, in one file beside the browser's
/// history (`browser-bookmarks.json`; `BrowserBookmarks` in Core holds the rules). The smallest store that makes the
/// star and the bar work on this Mac. Its tools share this store. Cloud sync and other-platform screens remain open seams.
@MainActor
@Observable
final class NativeBrowserBookmarksStore {
    private static var instance: NativeBrowserBookmarksStore?
    static var shared: NativeBrowserBookmarksStore {
        if let instance { return instance }
        let made = NativeBrowserBookmarksStore(); instance = made; return made
    }

    private(set) var all: [BrowserBookmark]
    /// "Always show the bookmarks bar": off, the bar shows on the New Tab page only.
    var alwaysShowBar: Bool {
        didSet { UserDefaults.standard.set(alwaysShowBar, forKey: BrowserBookmarks.alwaysShowKey) }
    }
    @ObservationIgnored private let file: URL
    @ObservationIgnored private var writeTask: Task<Void, Never>?

    private init() {
        file = AppModel.shared.engine.configuration.dataRoot.appendingPathComponent("browser-bookmarks.json")
        all = BrowserBookmarks.decode(try? Data(contentsOf: file))
        alwaysShowBar = UserDefaults.standard.bool(forKey: BrowserBookmarks.alwaysShowKey)
    }

    func list(profile: String) -> [BrowserBookmark] {
        BrowserBookmarks.list(all, profileID: BrowserBookmarks.profileKey(profile))
    }

    func contains(profile: String, url: URL?) -> Bool {
        guard let url else { return false }
        return BrowserBookmarks.contains(all, profileID: BrowserBookmarks.profileKey(profile), url: url.absoluteString)
    }

    /// The star. true: added, false: removed, nil: not a web page (nothing changed).
    @discardableResult
    func toggle(profile: String, url: URL?, title: String, favicon: NSImage?) -> Bool? {
        guard let url else { return nil }
        let step = BrowserBookmarks.toggle(all, profileID: BrowserBookmarks.profileKey(profile), url: url.absoluteString,
                                           title: title, icon: Self.png(favicon), at: Date().timeIntervalSince1970 * 1000)
        guard step.added != nil else { return nil }
        all = step.list
        scheduleWrite()
        return step.added
    }

    func remove(_ mark: BrowserBookmark) {
        all = BrowserBookmarks.remove(all, profileID: mark.profileID, url: mark.url)
        scheduleWrite()
    }

    func dropProfile(_ id: String) {
        let next = BrowserBookmarks.dropProfile(all, profileID: BrowserBookmarks.profileKey(id))
        guard next != all else { return }
        all = next
        scheduleWrite()
    }

    /// The site's icon as small PNG bytes (the bar shows it before any page is loaded).
    static func png(_ image: NSImage?) -> Data? {
        guard let image, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private func scheduleWrite() {
        writeTask?.cancel()
        writeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            let data = BrowserBookmarks.encode(self.all)
            try? FileManager.default.createDirectory(at: self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: self.file, options: .atomic)
        }
    }
}
