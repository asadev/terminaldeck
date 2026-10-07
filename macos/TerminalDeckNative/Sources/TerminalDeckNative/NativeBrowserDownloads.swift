import AppKit
import Observation
import WebKit
import TerminalDeckNativeCore

/// The browser's downloads: saved straight to ~/Downloads under a safe, free
/// name (`BrowserDownloadNaming`, shared with the web browser's rules), with a
/// list the toolbar shows. Finished files are marked as downloaded from the web,
/// so Gatekeeper checks them like anything Safari saves. The list is kept across
/// relaunch like the web browser's (`BrowserDownloadLedger`), so the toolbar's
/// Downloads button is there exactly when the web browser's would be.
@MainActor
@Observable
final class NativeBrowserDownloads {
    struct Item: Identifiable, Equatable {
        let id: UUID
        var name: String
        var destination: URL?
        var source: URL?
        var received: Int64 = 0
        var expected: Int64 = 0
        var state: State = .running

        enum State: Equatable {
            case running
            case finished
            case failed(String)
            case cancelled
        }

        var fraction: Double? {
            expected > 0 ? min(1, Double(received) / Double(expected)) : nil
        }
    }

    /// Newest first.
    private(set) var items: [Item] = []

    @ObservationIgnored private let delegate = NativeBrowserDownloadDelegate()
    @ObservationIgnored private var running: [ObjectIdentifier: (id: UUID, download: WKDownload, watch: NSKeyValueObservation)] = [:]
    @ObservationIgnored private var userCancelled: Set<UUID> = []

    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var stopped = false

    init() {
        delegate.owner = self
        // Read a beat later, not here: this is made while the app model is still
        // being made, and the list's file lives under that model's data folder.
        Task { @MainActor [weak self] in self?.load() }
    }

    /// The toolbar button's word (count, "!") — nil means no button, as on the web.
    var badge: (label: String, tone: String)? { BrowserDownloadLedger.badge(items.map(Self.row)) }

    private var file: URL {
        AppModel.shared.engine.configuration.dataRoot.appendingPathComponent("browser-downloads.json")
    }

    private func load() {
        guard !loaded, !stopped else { return }
        loaded = true
        let kept = BrowserDownloadLedger.decode(try? Data(contentsOf: file)).map(Self.item)
        let current = Set(items.map(\.id))
        items += kept.filter { !current.contains($0.id) }
    }

    private func persist() {
        guard loaded, !stopped else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            let data = BrowserDownloadLedger.encode(self.items.map(Self.row))
            try? FileManager.default.createDirectory(at: self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: self.file, options: .atomic)
        }
    }

    /// Exclusive browser cutover: cancel and drain the old owner before the
    /// new service is allowed to restore browser-downloads.json.
    func stop() async {
        stopped = true
        delegate.owner = nil
        let writer = saveTask; saveTask = nil; writer?.cancel(); await writer?.value
        let entries = Array(running.values); running.removeAll()
        for entry in entries {
            entry.watch.invalidate(); entry.download.delegate = nil
            await withCheckedContinuation { continuation in
                entry.download.cancel { _ in continuation.resume() }
            }
        }
    }

    static func row(_ item: Item) -> BrowserDownloadRow {
        let state: String, message: String
        switch item.state {
        case .running: (state, message) = ("downloading", "")
        case .finished: (state, message) = ("done", "")
        case .failed(let why): (state, message) = ("failed", why)
        case .cancelled: (state, message) = ("cancelled", "")
        }
        return BrowserDownloadRow(id: item.id.uuidString, name: item.name, path: item.destination?.path ?? "",
                                  url: item.source?.absoluteString ?? "", state: state, received: item.received,
                                  bytes: item.expected, message: message)
    }

    static func item(_ row: BrowserDownloadRow) -> Item {
        let state: Item.State
        switch row.state {
        case "done": state = .finished
        case "cancelled": state = .cancelled
        case "downloading", "delivering": state = .running
        default: state = .failed(row.message.isEmpty ? "It did not finish." : row.message)
        }
        return Item(id: UUID(uuidString: row.id) ?? UUID(), name: row.name,
                    destination: row.path.isEmpty ? nil : URL(fileURLWithPath: row.path),
                    source: URL(string: row.url), received: row.received, expected: row.bytes, state: state)
    }

    var runningCount: Int { items.filter { $0.state == .running }.count }

    /// Across everything still running, how far along (nil when no size is known).
    var overallFraction: Double? {
        let active = items.filter { $0.state == .running && $0.expected > 0 }
        guard !active.isEmpty else { return nil }
        let expected = active.reduce(Int64(0)) { $0 + $1.expected }
        let received = active.reduce(Int64(0)) { $0 + $1.received }
        return expected > 0 ? Double(received) / Double(expected) : nil
    }

    /// A page's load turned into a download.
    func adopt(_ download: WKDownload) {
        let id = UUID()
        download.delegate = delegate
        let source = download.originalRequest?.url
        let watch = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
            let received = progress.completedUnitCount
            let expected = progress.totalUnitCount
            Task { @MainActor in self?.update(id, received: received, expected: expected) }
        }
        running[ObjectIdentifier(download)] = (id, download, watch)
        items.insert(Item(id: id, name: source?.lastPathComponent ?? "download", source: source), at: 0)
        items = Array(items.prefix(BrowserDownloadLedger.maxRows))
        persist()
        NativeBrowserTabs.shared.downloadsShown = true
    }

    func cancel(_ id: UUID) {
        guard let entry = running.values.first(where: { $0.id == id }) else { return }
        userCancelled.insert(id)
        entry.download.cancel(nil)
    }

    func reveal(_ id: UUID) {
        guard let url = item(id)?.destination else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func open(_ id: UUID) {
        guard let url = item(id)?.destination else { return }
        NSWorkspace.shared.open(url)
    }

    func clearFinished() {
        items.removeAll { $0.state != .running }
        persist()
    }

    func openDownloadsFolder() {
        NSWorkspace.shared.open(Self.folder)
    }

    // MARK: From WebKit

    static var folder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    fileprivate func destination(for download: WKDownload, suggested: String) -> URL? {
        guard let entry = running[ObjectIdentifier(download)] else { return nil }
        let taken = Set(items.filter { $0.state == .running }.compactMap { $0.destination?.path })
        let path = BrowserDownloadNaming.freePath(directory: Self.folder.path,
                                                  suggested: suggested,
                                                  exists: { FileManager.default.fileExists(atPath: $0) },
                                                  taken: taken)
        let url = URL(fileURLWithPath: path)
        mutate(entry.id) {
            $0.destination = url
            $0.name = url.lastPathComponent
        }
        persist()
        return url
    }

    fileprivate func finished(_ download: WKDownload) {
        guard let entry = running.removeValue(forKey: ObjectIdentifier(download)) else { return }
        entry.watch.invalidate()
        mutate(entry.id) {
            $0.state = .finished
            if $0.expected > 0 { $0.received = $0.expected }
        }
        persist()
        if let item = item(entry.id), let file = item.destination {
            Self.markDownloaded(file, from: item.source)
            // Bounces the Downloads stack in the Dock, as Safari's downloads do.
            DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: file.path)
        }
    }

    fileprivate func failed(_ download: WKDownload, error: Error) {
        guard let entry = running.removeValue(forKey: ObjectIdentifier(download)) else { return }
        entry.watch.invalidate()
        let cancelled = userCancelled.remove(entry.id) != nil
            || ((error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled)
        mutate(entry.id) { $0.state = cancelled ? .cancelled : .failed(error.localizedDescription) }
        persist()
        // Never leave half a file behind under the name the person would look for.
        if let file = item(entry.id)?.destination, FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: inside

    private func item(_ id: UUID) -> Item? { items.first { $0.id == id } }

    private func mutate(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    private func update(_ id: UUID, received: Int64, expected: Int64) {
        mutate(id) {
            guard $0.state == .running else { return }
            $0.received = received
            $0.expected = expected
        }
    }

    /// The quarantine mark every browser puts on what it downloads.
    private static func markDownloaded(_ file: URL, from source: URL?) {
        var properties: [String: Any] = [
            kLSQuarantineAgentNameKey as String: "Terminal Deck",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
        ]
        if let source { properties[kLSQuarantineDataURLKey as String] = source }
        try? (file as NSURL).setResourceValue(properties, forKey: .quarantinePropertiesKey)
    }
}

/// WKDownload's delegate, kept separate so the list can stay a plain observable.
@MainActor
final class NativeBrowserDownloadDelegate: NSObject, WKDownloadDelegate {
    weak var owner: NativeBrowserDownloads?

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String) async -> URL? {
        owner?.destination(for: download, suggested: suggestedFilename)
    }

    func downloadDidFinish(_ download: WKDownload) {
        owner?.finished(download)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        owner?.failed(download, error: error)
    }
}
