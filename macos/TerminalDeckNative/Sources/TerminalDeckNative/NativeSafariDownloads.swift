import AppKit
import Foundation
import Observation
import WebKit
import TerminalDeckNativeCore
import TerminalDeckBackend

/// Live WebKit transport + observable presentation facade. The old observable
/// Item type is reused only for rendering; the old download manager must not be
/// instantiated beside this one because both would own browser-downloads.json.
@MainActor
@Observable
final class NativeSafariDownloads: NSObject, WKDownloadDelegate {
    typealias ResolveBinding = @MainActor (WKWebView) throws -> (NativeRPCContext, BackendBrowserDownloadBinding)
    private(set) var items: [NativeBrowserDownloads.Item] = []
    private(set) var view: BackendBrowserDownloadsView?
    private(set) var message = ""

    @ObservationIgnored private let service: BackendBrowserDownloads
    @ObservationIgnored private let context: NativeRPCContext
    @ObservationIgnored private let resolveBinding: ResolveBinding
    @ObservationIgnored private let applicationName: String
    @ObservationIgnored private let showDownloads: @MainActor () -> Void
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var running: [ObjectIdentifier: Entry] = [:]
    @ObservationIgnored private var presentationIDs: [String: UUID] = [:]
    @ObservationIgnored private var backendIDs: [UUID: String] = [:]
    @ObservationIgnored private var pending: [UUID: Pending] = [:]
    @ObservationIgnored private var profileStops: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var tabStops: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var viewStops: [ObjectIdentifier: Task<Void, Never>] = [:]
    @ObservationIgnored private var allStop: Task<Void, Never>?
    @ObservationIgnored private var retiredProfiles: Set<String> = []
    @ObservationIgnored private var retiredTabs: Set<String> = []
    @ObservationIgnored private var retiredViews: Set<ObjectIdentifier> = []
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var sourceViews: [ObjectIdentifier: SourceView] = [:]

    private struct Pending {
        let binding: BackendBrowserDownloadBinding?
        let viewID: ObjectIdentifier?
        let unclassifiedDownload: Bool
        let cancel: @MainActor () -> Void
        let drain: @MainActor () async -> Void
    }
    private final class SourceView {
        weak var view: WKWebView?
        let binding: BackendBrowserDownloadBinding
        init(view: WKWebView, binding: BackendBrowserDownloadBinding) { self.view = view; self.binding = binding }
    }

    private struct Entry {
        let handle: Handle
        let context: NativeRPCContext
        let binding: BackendBrowserDownloadBinding
        let watch: NSKeyValueObservation
        let viewID: ObjectIdentifier
        var ticket: BackendBrowserDownloads.TransportTicket?
        var cancelled = false
    }
    /// A main-actor wrapper may safely be captured by the backend's Sendable
    /// cancellation closure without moving WKDownload across actor boundaries.
    @MainActor
    private final class Handle {
        let download: WKDownload
        private var cancellation: Task<Void, Never>?
        private(set) var finished = false
        var isCancelled: Bool { cancellation != nil }
        init(_ download: WKDownload) { self.download = download }
        func transportFinished() { finished = true }
        func cancel() async {
            if let cancellation { await cancellation.value; return }
            // The real didFinish/didFail callback already ended this writer.
            guard !finished else { return }
            let task = Task { @MainActor [download] in
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    download.cancel { _ in continuation.resume() }
                }
            }
            cancellation = task
            await task.value
        }
    }

    init(service: BackendBrowserDownloads, context: NativeRPCContext, applicationName: String,
         resolveBinding: @escaping ResolveBinding, showDownloads: @escaping @MainActor () -> Void) {
        self.service = service; self.context = context; self.applicationName = applicationName
        self.resolveBinding = resolveBinding; self.showDownloads = showDownloads
        super.init()
    }

    /// Explicit lifecycle call after the app's current root and grants exist.
    /// Construction does no I/O, starts no task and inspects no credential store.
    func start() async throws {
        guard !stopped else { throw NativeRPCError(code: "download-closed", message: "This native download owner has shut down.") }
        guard observation == nil else { return }
        try await service.restore(context: context)
        let stream = try await service.updates(context: context)
        observation = Task { [weak self] in
            do {
                for try await update in stream {
                    guard !Task.isCancelled, let self else { return }
                    self.apply(update)
                }
            } catch { self?.message = error.localizedDescription }
            self?.observation = nil
        }
    }

    func stop() async {
        if let allStop { await allStop.value; return }
        stopped = true
        let observation = self.observation; self.observation = nil; observation?.cancel()
        let task = Task { @MainActor [self] in
            await drain(profileID: nil, tabID: nil, viewID: nil)
            await observation?.value
            sourceViews.removeAll()
        }
        allStop = task; await task.value
    }

    /// Lifecycle-only operation over the retained actual bindings. Tombstoning
    /// first refuses new and late adoptions; the barrier drains pre-ticket
    /// destination work, redirects, progress, finish/failure and WK cancellation.
    func stop(profileID: String) async throws {
        guard !profileID.isEmpty else { throw NativeRPCError.invalidArguments("Profile retirement needs its actual profile ID.") }
        if let allStop { await allStop.value; try Task.checkCancellation(); return }
        if let task = profileStops[profileID] { await task.value }
        retiredProfiles.insert(profileID)
        let task = Task { @MainActor [self] in await drain(profileID: profileID, tabID: nil, viewID: nil) }
        profileStops[profileID] = task
        await task.value
        try Task.checkCancellation()
    }

    func stop(tabID: String) async {
        if let allStop { await allStop.value; return }
        if let task = tabStops[tabID] { await task.value }
        retiredTabs.insert(tabID)
        let task = Task { @MainActor [self] in await drain(profileID: nil, tabID: tabID, viewID: nil) }
        tabStops[tabID] = task; await task.value
    }

    /// Page replacement is scoped to the old view, not the reused tab ID. A
    /// new profile/view in that tab must not inherit the old page's tombstone.
    func stop(webView: WKWebView) async {
        if let allStop { await allStop.value; return }
        let id = ObjectIdentifier(webView)
        if let task = viewStops[id] { await task.value }
        retiredViews.insert(id)
        let task = Task { @MainActor [self, webView] in
            _ = webView
            await drain(profileID: nil, tabID: nil, viewID: id)
        }
        viewStops[id] = task; await task.value
    }

    /// Bind the exact page while it is live, so a late delegate callback from a
    /// closed page can be identified and cancelled without inventing a profile.
    func bind(_ webView: WKWebView) throws {
        let (_, binding) = try resolveBinding(webView)
        sourceViews = sourceViews.filter { $0.value.view != nil }
        rememberSource(webView, binding: binding)
    }
    private func rememberSource(_ webView: WKWebView, binding: BackendBrowserDownloadBinding) {
        let id = ObjectIdentifier(webView)
        if sourceViews[id]?.view !== webView { retiredViews.remove(id); viewStops[id] = nil }
        sourceViews[id] = SourceView(view: webView, binding: binding)
    }
    private func retired(_ binding: BackendBrowserDownloadBinding, viewID: ObjectIdentifier) -> Bool {
        stopped || retiredProfiles.contains(binding.profileID) || retiredTabs.contains(binding.tabID) || retiredViews.contains(viewID)
    }
    private func matches(_ binding: BackendBrowserDownloadBinding?, sourceViewID: ObjectIdentifier?, profileID: String?, tabID: String?, viewID: ObjectIdentifier?) -> Bool {
        if let viewID { return viewID == sourceViewID }
        if profileID == nil && tabID == nil { return true }
        guard let binding else { return false }
        return profileID.map { binding.profileID == $0 } ?? tabID.map { binding.tabID == $0 } ?? false
    }
    private func track<Value: Sendable>(binding: BackendBrowserDownloadBinding? = nil, viewID: ObjectIdentifier? = nil, unclassifiedDownload: Bool = false,
                                       operation: @escaping @MainActor () async -> Value) -> Task<Value, Never> {
        let id = UUID()
        let task = Task { @MainActor [weak self] in
            defer { self?.pending[id] = nil }
            return await operation()
        }
        pending[id] = Pending(binding: binding, viewID: viewID, unclassifiedDownload: unclassifiedDownload,
            cancel: { task.cancel() }, drain: { _ = await task.value })
        return task
    }
    private func drain(profileID: String?, tabID: String?, viewID: ObjectIdentifier?) async {
        // Register cancelled state synchronously before the first await. A
        // destination granted meanwhile cannot hand WebKit a fresh stage URL.
        for key in Array(running.keys) {
            guard var entry = running[key], matches(entry.binding, sourceViewID: entry.viewID, profileID: profileID, tabID: tabID, viewID: viewID) else { continue }
            entry.cancelled = true; entry.watch.invalidate(); running[key] = entry
        }
        while true {
            let entries = running.filter { matches($0.value.binding, sourceViewID: $0.value.viewID, profileID: profileID, tabID: tabID, viewID: viewID) }
            let work = pending.values.filter { $0.unclassifiedDownload || matches($0.binding, sourceViewID: $0.viewID, profileID: profileID, tabID: tabID, viewID: viewID) }
            if entries.isEmpty && work.isEmpty { return }
            for operation in work { operation.cancel() }
            for entry in entries.values { await entry.handle.cancel() }
            for operation in work { await operation.drain() }
            for (key, previous) in entries {
                guard let entry = running[key], entry.handle === previous.handle else { continue }
                if let ticket = entry.ticket { await service.fail(ticket, message: "The browser closed while this was moving.", cancelled: true) }
                running[key] = nil
            }
            // Awaited operations may have accepted another callback before its
            // tombstone check. Include that work before reporting completion.
        }
    }

    var badge: (label: String, tone: String)? { BrowserDownloadLedger.badge(items.map(NativeBrowserDownloads.row)) }
    var runningCount: Int { view?.items.filter { $0.state == .downloading || $0.state == .delivering }.count ?? 0 }
    var overallFraction: Double? {
        let active: [BackendBrowserDownloadRow] = view?.items.filter { $0.state == .downloading && $0.bytes > 0 } ?? []
        let total = active.reduce(0.0) { $0 + Double($1.bytes) }
        return total > 0 ? min(1, active.reduce(0.0) { $0 + Double($1.received) } / total) : nil
    }

    /// Preserve remote placement/delivery messages in the existing row view.
    /// Its Item type carries a local URL only, so the integration must use this
    /// metadata for labels and for hiding local Open/Reveal on remote rows.
    func backendRow(_ id: UUID) -> BackendBrowserDownloadRow? {
        guard let key = backendIDs[id] else { return nil }
        return view?.items.first { $0.id == key }
    }

    /// Call from BOTH WKNavigationDelegate didBecome-download callbacks, with
    /// the exact live WKWebView that produced the download (including isolation).
    func adopt(_ download: WKDownload, webView: WKWebView) {
        let key = ObjectIdentifier(download)
        guard running[key] == nil else { return }
        do {
            let (caller, binding) = try resolveBinding(webView)
            rememberSource(webView, binding: binding)
            guard !retired(binding, viewID: ObjectIdentifier(webView)) else { throw NativeRPCError(code: "download-retiring", message: "This browser page or profile is being retired.") }
            let handle = Handle(download)
            let watch = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak self] progress, _ in
                let received = progress.completedUnitCount, expected = progress.totalUnitCount
                Task { @MainActor [weak self] in await self?.update(key, received: received, expected: expected) }
            }
            running[key] = Entry(handle: handle, context: caller, binding: binding, watch: watch, viewID: ObjectIdentifier(webView))
            download.delegate = self
            showDownloads()
        } catch {
            message = error.localizedDescription
            let source = sourceViews[ObjectIdentifier(webView)]
            let binding = source?.view === webView ? source?.binding : nil
            let handle = Handle(download); download.delegate = nil
            _ = track(binding: binding, viewID: ObjectIdentifier(webView), unclassifiedDownload: binding == nil) { await handle.cancel() }
        }
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        let key = ObjectIdentifier(download)
        guard let entry = running[key], entry.ticket == nil, !retired(entry.binding, viewID: entry.viewID), !entry.cancelled else { return nil }
        let task = track(binding: entry.binding, viewID: entry.viewID) { [weak self] in
            guard let self else { return nil as URL? }
            return await self.destination(key: key, entry: entry, response: response, suggestedFilename: suggestedFilename)
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func destination(key: ObjectIdentifier, entry: Entry, response: URLResponse, suggestedFilename: String) async -> URL? {
        do {
            try Task.checkCancellation()
            let ticket = try await service.begin(context: entry.context, binding: entry.binding, suggested: suggestedFilename,
                source: entry.handle.download.originalRequest?.url ?? response.url, expected: max(0, response.expectedContentLength),
                cancel: { [handle = entry.handle] in await handle.cancel() })
            guard var current = running[key], current.handle === entry.handle, !current.cancelled,
                  !current.handle.isCancelled, !retired(current.binding, viewID: current.viewID), !Task.isCancelled else {
                await service.fail(ticket, message: "Stopped.", cancelled: true); return nil
            }
            current.ticket = ticket; running[key] = current
            return ticket.stagingURL
        } catch {
            message = error.localizedDescription
            if let held = running[key], held.handle === entry.handle {
                held.watch.invalidate(); running[key] = nil
                await held.handle.cancel()
            }
            return nil
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        guard let entry = running.removeValue(forKey: key) else { return }
        entry.watch.invalidate(); entry.handle.transportFinished()
        guard let ticket = entry.ticket else { message = "WebKit finished a download without a reserved destination."; return }
        // The real downloaded bytes retain the browser quarantine mark through
        // the backend's exclusive rename, so Gatekeeper still sees them.
        var quarantine: [String: Any] = [
            kLSQuarantineAgentNameKey as String: applicationName,
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String
        ]
        if let source = download.originalRequest?.url { quarantine[kLSQuarantineDataURLKey as String] = source }
        do { try (ticket.stagingURL as NSURL).setResourceValue(quarantine, forKey: .quarantinePropertiesKey) }
        catch {
            let problem = "The browser quarantine mark could not be saved: \(error.localizedDescription)"
            message = problem
            _ = track(binding: entry.binding, viewID: entry.viewID) { [service] in await service.fail(ticket, message: problem) }
            return
        }
        _ = track(binding: entry.binding, viewID: entry.viewID) { [weak self] in
            guard let self else { return }
            do {
                guard !self.retired(entry.binding, viewID: entry.viewID), !Task.isCancelled else {
                    await self.service.fail(ticket, message: "Stopped.", cancelled: true); return
                }
                try await service.finish(ticket)
                let row = try await service.row(ticket.id, context: context)
                if row.onMachine.isEmpty, !row.path.isEmpty {
                    DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: row.path)
                }
            }
            catch {
                message = error.localizedDescription
                await service.fail(ticket, message: message, cancelled: entry.cancelled || retired(entry.binding, viewID: entry.viewID))
            }
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let key = ObjectIdentifier(download)
        guard let entry = running.removeValue(forKey: key) else { return }
        entry.watch.invalidate(); entry.handle.transportFinished()
        let cancelled = entry.cancelled || ((error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled)
        if let ticket = entry.ticket {
            _ = track(binding: entry.binding, viewID: entry.viewID) { [self] in
                await service.fail(ticket, message: error.localizedDescription, cancelled: cancelled || retired(entry.binding, viewID: entry.viewID))
            }
        } else { message = cancelled ? "Stopped." : error.localizedDescription }
        // The original source has no resume action. WebKit resumeData is not
        // silently persisted, replayed or handed to a different profile.
    }

    func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest) async -> WKDownload.RedirectPolicy {
        let key = ObjectIdentifier(download)
        guard let entry = running[key], let url = request.url, !entry.cancelled, !retired(entry.binding, viewID: entry.viewID) else { return .cancel }
        let task = track(binding: entry.binding, viewID: entry.viewID) { [self] in
            do {
                try await service.authorizeRedirect(context: entry.context, binding: entry.binding, url: url)
                guard let current = running[key], current.handle === entry.handle, !current.cancelled,
                      !retired(current.binding, viewID: current.viewID), !Task.isCancelled else { return WKDownload.RedirectPolicy.cancel }
                return .allow
            } catch { message = error.localizedDescription; return .cancel }
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    private func update(_ key: ObjectIdentifier, received: Int64, expected: Int64) async {
        guard let entry = running[key], !entry.cancelled, !retired(entry.binding, viewID: entry.viewID), let ticket = entry.ticket else { return }
        let task = track(binding: entry.binding, viewID: entry.viewID) { [self] in
            do { try await service.progress(ticket, received: received, expected: expected) }
            catch { if !retired(entry.binding, viewID: entry.viewID) { message = error.localizedDescription } }
        }
        await task.value
    }

    func cancel(_ id: UUID) { perform { try await self.service.cancel(self.backendID(id), context: self.context); return nil } }
    func clearFinished() { perform { try await self.service.clear(context: self.context); return nil } }
    func open(_ id: UUID) { perform { try await self.service.open(self.backendID(id), context: self.context) } }
    func reveal(_ id: UUID) { perform { try await self.service.reveal(self.backendID(id), context: self.context) } }
    func openDownloadsFolder() { perform { try await self.service.openDownloadsFolder(context: self.context) } }

    private func backendID(_ id: UUID) throws -> String {
        guard let backend = backendIDs[id] else { throw NativeRPCError(code: "download-missing", message: "That download is not in the list any more.") }; return backend
    }
    private func perform(_ operation: @escaping @MainActor () async throws -> BackendBrowserDownloadOperationReply?) {
        _ = track { [weak self] in
            do {
                if let result = try await operation(), !result.ok { self?.message = result.message }
            } catch { self?.message = error.localizedDescription }
        }
    }
    private func apply(_ update: BackendBrowserDownloadsView) {
        view = update
        if !update.persistenceMessage.isEmpty { message = update.persistenceMessage }
        var mapping: [UUID: String] = [:]
        items = update.items.map { row in
            let id = presentationIDs[row.id] ?? UUID()
            presentationIDs[row.id] = id; mapping[id] = row.id
            let state: NativeBrowserDownloads.Item.State
            switch row.state {
            case .downloading, .delivering: state = .running
            case .done: state = .finished
            case .cancelled: state = .cancelled
            case .failed: state = .failed(row.message)
            }
            return NativeBrowserDownloads.Item(id: id, name: row.name, destination: row.path.isEmpty || !row.onMachine.isEmpty ? nil : URL(fileURLWithPath: row.path),
                source: URL(string: row.url), received: row.received, expected: row.bytes, state: state)
        }
        backendIDs = mapping
        let visible = Set(update.items.map(\.id))
        presentationIDs = presentationIDs.filter { visible.contains($0.key) }
    }
}

/// App-owned OS operations injected into the backend. The backend calls them
/// only after its required authorization/consent callback succeeds. The chooser
/// uses a sheet; an unattended caller can never fall into a blocking runModal.
@MainActor
enum NativeSafariDownloadsSystem {
    static func dependencies(authorize: @escaping BackendBrowserDownloadsDependencies.Authorization,
                             parentWindow: @escaping @MainActor @Sendable () -> NSWindow?,
                             deliver: (@Sendable (BackendBrowserDownloadDelivery) async throws -> BackendBrowserDownloadDeliveryOutcome)? = nil) -> BackendBrowserDownloadsDependencies {
        .init(authorize: authorize, open: { url in
            try await open(url)
        }, reveal: { url in
            await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]); return .init(ok: true) }
        }, chooseFolder: { current in
            try await chooseFolder(current: current, parentWindow: parentWindow)
        }, deliver: deliver)
    }

    private static func open(_ url: URL) async throws -> BackendBrowserDownloadOperationReply {
        _ = try await NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration())
        return .init(ok: true)
    }
    private static func chooseFolder(current: URL, parentWindow: @MainActor @Sendable () -> NSWindow?) async throws -> String {
        guard let window = parentWindow() else { throw NativeRPCError(code: "download-no-window", message: "Open the native app window before using the folder chooser.") }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true; panel.directoryURL = current
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                panel.beginSheetModal(for: window) { response in
                    if response == .OK { continuation.resume(returning: panel.url?.path ?? "") }
                    else { continuation.resume(returning: "") }
                }
            }
        } onCancel: {
            Task { @MainActor in panel.cancel(nil) }
        }
    }
}
