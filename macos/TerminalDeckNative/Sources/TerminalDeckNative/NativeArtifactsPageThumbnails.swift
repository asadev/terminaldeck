import AppKit
import CryptoKit
import Darwin
import TerminalDeckNativeCore
import WebKit

/// A picture of the top of a local page, for its card on the Artifacts page (Asad 11 Oct: "html can
/// give better preview photo"; the card used to print the page's raw markup).
///
/// The page is loaded once in a web view nobody sees, photographed at the card's proportions, and
/// the picture is kept by path and modification time, so each version of a page is drawn once.
/// What the hidden view may do is deliberately little:
/// - it holds no cookies or site data, and keeps none (`nonPersistent`);
/// - it is given the one file and nothing around it, and never follows the page anywhere else;
/// - it opens no windows, plays no media, and has a few seconds before the card keeps its placeholder.
@MainActor
final class NativeArtifactsPageThumbnails {
    private static var offline: WKContentRuleList?
    /// Blocks every network load in the hidden preview view (compiled once).
    static func offlineRules() async -> WKContentRuleList? {
        if let offline { return offline }
        let source = #"[{"trigger":{"url-filter":"^(https?|wss?|ftp)://"},"action":{"type":"block"}}]"#
        offline = try? await WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "td-artifact-thumbnail-offline", encodedContentRuleList: source)
        return offline
    }
    static let shared = NativeArtifactsPageThumbnails(cacheDirectory: NativeArtifactsPageThumbnails.defaultCacheDirectory)

    /// The page is laid out at a desktop width; the top of it is kept, at the card picture's 20:11.
    nonisolated static let pageSize = CGSize(width: 1200, height: 660)
    nonisolated static let pictureWidth: CGFloat = 600
    nonisolated static let timeLimit: TimeInterval = 6
    nonisolated static let heldInMemory = 24
    nonisolated static let keptOnDisk = 400

    private let cacheDirectory: URL?
    private var memory: [String: NSImage] = [:]
    private var order: [String] = []
    private var failed = Set<String>()
    private var waiting: [String: [CheckedContinuation<NSImage?, Never>]] = [:]
    private var queue: [(key: String, url: URL)] = []
    private var drawing = false
    private var pruned = false
    private(set) var pagesDrawn = 0

    /// `cacheDirectory` nil keeps pictures in memory only.
    init(cacheDirectory: URL?) { self.cacheDirectory = cacheDirectory }

    /// This app's own caches folder (the dev copy has its own), never the project or the page's folder.
    static var defaultCacheDirectory: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first,
              let bundle = Bundle.main.bundleIdentifier, !bundle.isEmpty else { return nil }
        return caches.appendingPathComponent(bundle, isDirectory: true).appendingPathComponent("artifact-page-pictures", isDirectory: true)
    }

    /// One name per version of a page: its path and when it was last changed.
    static func key(_ url: URL, modifiedAt: Double) -> String {
        let digest = SHA256.hash(data: Data((url.standardizedFileURL.path + "\u{0}" + String(Int64(modifiedAt))).utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The picture already made for this version of the page, without drawing anything.
    func held(_ url: URL, modifiedAt: Double) -> NSImage? { memory[Self.key(url, modifiedAt: modifiedAt)] }

    /// The page's picture: from memory, from the caches folder, or drawn now (one page at a time).
    /// Nil when the page could not be drawn in time; the card then keeps its placeholder.
    func picture(for url: URL, modifiedAt: Double) async -> NSImage? {
        let key = Self.key(url, modifiedAt: modifiedAt)
        if let image = memory[key] { return image }
        if failed.contains(key) { return nil }
        if let image = stored(key) { remember(key, image); return image }
        return await withCheckedContinuation { continuation in
            if waiting[key] != nil { waiting[key]?.append(continuation); return }
            waiting[key] = [continuation]
            queue.append((key, url))
            next()
        }
    }

    private func next() {
        guard !drawing, !queue.isEmpty else { return }
        drawing = true
        let job = queue.removeFirst()
        Task {
            let image = await NativeArtifactsPageCamera().picture(of: job.url)
            pagesDrawn += 1
            if let image { remember(job.key, image); store(job.key, image) } else { failed.insert(job.key) }
            waiting.removeValue(forKey: job.key)?.forEach { $0.resume(returning: image) }
            drawing = false
            next()
        }
    }

    private func remember(_ key: String, _ image: NSImage) {
        order.removeAll { $0 == key }
        order.append(key); memory[key] = image
        while order.count > Self.heldInMemory { memory[order.removeFirst()] = nil }
    }

    private func file(_ key: String) -> URL? { cacheDirectory?.appendingPathComponent(key + ".jpg") }

    private func stored(_ key: String) -> NSImage? {
        guard let file = file(key), let data = try? Data(contentsOf: file), let image = NSImage(data: data), image.size.width > 0 else { return nil }
        return image
    }

    private func store(_ key: String, _ image: NSImage) {
        guard let directory = cacheDirectory, let file = file(key), let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else { return }
        let prune = !pruned
        pruned = true
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
            if prune { NativeArtifactsPageThumbnails.prune(directory) }
        }
    }

    /// Once a run: the oldest pictures beyond the newest few hundred are removed, so old versions of pages do not pile up.
    nonisolated private static func prune(_ directory: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]),
              files.count > keptOnDisk else { return }
        let dated = files.filter { $0.pathExtension == "jpg" }.map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for (file, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(keptOnDisk) { try? FileManager.default.removeItem(at: file) }
    }
}

/// One hidden web view, one page, one photograph.
@MainActor
final class NativeArtifactsPageCamera: NSObject, WKNavigationDelegate {
    private var page: URL?
    private var loaded: CheckedContinuation<Bool, Never>?
    private var committed = false

    func picture(of url: URL) async -> NSImage? {
        // The one recorded file, as a regular file: never a link, a folder or a pipe.
        let file = url.standardizedFileURL
        var info = stat()
        guard file.isFileURL, lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        page = file

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // Scripts run because this is a page on this Mac, and many pages draw themselves with one;
        // the view is never pointed at anything but that page.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.suppressesIncrementalRendering = true
        // Offline on purpose: this picture is made without him opening the page, so the page may not
        // fetch anything from the internet while it is drawn (no trackers, no remote scripts).
        // Opening the page itself is not affected. A page styled from a CDN simply looks plainer here.
        if let rules = await NativeArtifactsPageThumbnails.offlineRules() { configuration.userContentController.add(rules) }
        let view = WKWebView(frame: CGRect(origin: .zero, size: NativeArtifactsPageThumbnails.pageSize), configuration: configuration)
        view.navigationDelegate = self
        defer { view.navigationDelegate = nil; view.stopLoading() }

        let finished = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            loaded = continuation
            // Read access is this file alone: nothing beside it can be loaded, by the page or by its scripts.
            view.loadFileURL(file, allowingReadAccessTo: file)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(NativeArtifactsPageThumbnails.timeLimit))
                self?.finish(false)
            }
        }
        // A page still waiting on something slow has usually drawn its top already; one that never arrived has not.
        guard finished || committed else { return nil }
        // A moment for fonts and a script's first draw.
        try? await Task.sleep(for: .milliseconds(finished ? 350 : 50))
        let shot = WKSnapshotConfiguration()
        shot.rect = CGRect(origin: .zero, size: NativeArtifactsPageThumbnails.pageSize)
        shot.snapshotWidth = NSNumber(value: Double(NativeArtifactsPageThumbnails.pictureWidth))
        shot.afterScreenUpdates = true
        guard let image = try? await view.takeSnapshot(configuration: shot), image.size.width > 0, image.size.height > 0 else { return nil }
        return image
    }

    private func finish(_ value: Bool) {
        guard let continuation = loaded else { return }
        loaded = nil
        continuation.resume(returning: value)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let target = navigationAction.request.url else { return .cancel }
        if navigationAction.targetFrame?.isMainFrame == false {
            // A frame inside the page may hold what the page itself wrote, never another address.
            return ["about", "data", "blob"].contains(target.scheme?.lowercased() ?? "") ? .allow : .cancel
        }
        // The main frame stays on the one file (a jump to a heading inside it is still that file).
        return target.isFileURL && target.standardizedFileURL.path == page?.path ? .allow : .cancel
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { committed = true }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(true) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) { finish(false) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) { finish(false) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(false) }
}
