import Foundation
import Observation
import TerminalDeckNativeCore

enum NativeDockerTarget: Equatable {
    case server(id: String, name: String)
    case thisMac
    var id: String { switch self { case .server(let id, _): "server:\(id)"; case .thisMac: "local" } }
    var name: String { switch self { case .server(_, let name): name; case .thisMac: "This Mac" } }
    var isLocal: Bool { self == .thisMac }
}

enum NativeDockerAvailability: Equatable {
    case available(version: String)
    case missingDocker
    case noLocalSocket
}

enum NativeDockerContainerTab: String, CaseIterable, Identifiable {
    case overview, logs, terminal
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum NativeDockerAction: String { case start, stop, restart, remove }
enum NativeDockerStreamKind { case logs, stats }
enum NativeDockerStreamUpdate {
    case log(String, stream: String), usage(NativeDockerUsage)
    case ended(String?, cleanupConfirmed: Bool)
}

struct NativeDockerInstallation {
    let command: String
    let explanation: String
    /// The Engine's opaque preview reference, if its approval contract uses one.
    let reference: String
}

@MainActor
struct NativeDockerStream {
    let stop: @MainActor () async throws -> Void
    let openingFailure: String?

    init(stop: @escaping @MainActor () async throws -> Void, openingFailure: String? = nil) {
        self.stop = stop; self.openingFailure = openingFailure
    }
}

struct NativeDockerUnavailable: LocalizedError {
    let errorDescription: String?
    init(_ operation: String) { errorDescription = "\(operation) is unavailable in this build." }
}

/// The view boundary. The contract adapter owns RPC payloads, approval and masking.
/// No UI closure may run shell commands or bypass the existing approval broker.
@MainActor
struct NativeDockerClient {
    var probe: @MainActor () async throws -> NativeDockerAvailability
    var list: @MainActor (NativeDockerSection) async throws -> [NativeDockerItem]
    var inspect: @MainActor (NativeDockerSection, String) async throws -> NativeDockerItem
    var change: @MainActor (NativeDockerSection, String, NativeDockerAction, String?) async throws -> Void
    var installation: @MainActor () async throws -> NativeDockerInstallation
    var install: @MainActor (NativeDockerInstallation) async throws -> Void
    var stream: @MainActor (String, NativeDockerStreamKind, @escaping @MainActor (NativeDockerStreamUpdate) -> Void) async throws -> NativeDockerStream
    var terminal: @MainActor (String) throws -> NativeDockerTerminalTransport

    /// An absent backend is an explicit error, never an empty successful inventory.
    static var unavailable: Self {
        Self(probe: { throw NativeDockerUnavailable("Docker") },
             list: { _ in throw NativeDockerUnavailable("Docker inventory") },
             inspect: { _, _ in throw NativeDockerUnavailable("Docker details") },
             change: { _, _, _, _ in throw NativeDockerUnavailable("This Docker action") },
             installation: { throw NativeDockerUnavailable("Docker installation preview") },
             install: { _ in throw NativeDockerUnavailable("Docker installation") },
             stream: { _, _, _ in throw NativeDockerUnavailable("Docker streaming") },
             terminal: { _ in throw NativeDockerUnavailable("Container terminals") })
    }
}

@MainActor
@Observable
final class NativeDockerModel {
    let target: NativeDockerTarget
    var section: NativeDockerSection = .containers
    var selection: String?
    var search = ""
    var tab: NativeDockerContainerTab = .overview
    private(set) var availability: NativeDockerAvailability?
    private(set) var inventory: [NativeDockerSection: [NativeDockerItem]] = [:]
    private(set) var loading = true
    private(set) var error: String?
    private(set) var detail: NativeDockerItem?
    private(set) var detailLoading = false
    private(set) var detailError: String?
    private(set) var busy = false
    private(set) var outcome: String?
    private(set) var usage: NativeDockerUsage?
    private(set) var logBuffer = NativeDockerLogBuffer()
    private(set) var streamConnecting = false
    private(set) var streamError: String?
    private(set) var streamCleanupPending = false
    private(set) var streamCleanupBusy = false
    private(set) var terminalModel: NativeDockerTerminalModel?
    private(set) var installationPreview: NativeDockerInstallation?

    @ObservationIgnored private let client: NativeDockerClient
    @ObservationIgnored private var visible = false
    @ObservationIgnored private var visibilityID = UUID()
    @ObservationIgnored private var loadID = UUID()
    @ObservationIgnored private var detailID = UUID()
    @ObservationIgnored private var streamGeneration = NativeDockerStreamGeneration()
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var activeStream: NativeDockerStream?
    @ObservationIgnored private var streamEnded = false
    @ObservationIgnored private var streamCleanupConfirmed = false
    @ObservationIgnored private var pendingStreamCloses: [UUID: NativeDockerStream] = [:]
    @ObservationIgnored private var closingStreamIDs: Set<UUID> = []
    @ObservationIgnored private var failedStreamCloseIDs: Set<UUID> = []
    @ObservationIgnored private var deferredLiveStart: UUID?
    @ObservationIgnored private var cleanupWasRetried = false
    @ObservationIgnored private var pendingContainerID: String?

    init(target: NativeDockerTarget, client: NativeDockerClient) { self.target = target; self.client = client }
    var items: [NativeDockerItem] { inventory[section] ?? [] }
    var counts: [NativeDockerSection: Int] { inventory.mapValues(\.count) }
    var selected: NativeDockerItem? {
        guard let selection else { return nil }
        if let detail, detail.id == selection { return detail }
        return items.first { $0.id == selection }
    }

    func appear() {
        guard !visible else { return }
        visible = true; visibilityID = UUID(); refresh()
    }
    func disappear() {
        guard visible else { return }
        visible = false; visibilityID = UUID(); loadID = UUID(); detailID = UUID()
        installationPreview = nil; pendingContainerID = nil
        stopLive(); loading = false; detailLoading = false
    }

    func refresh() {
        guard visible else { return }
        let mine = UUID(); loadID = mine
        let requested = section
        loading = true; error = nil
        Task { [weak self] in
            guard let self else { return }
            var readStatus = false
            do {
                let state = try await client.probe()
                guard visible, loadID == mine, section == requested else { return }
                readStatus = true
                availability = state
                if case .available = state { installationPreview = nil }
                guard case .available = state else {
                    inventory = [:]; selection = nil; detail = nil; detailError = nil
                    installationPreview = nil; loading = false; detailLoading = false; stopLive(); return
                }
                let rows = try await client.list(requested)
                guard visible, loadID == mine, section == requested else { return }
                inventory[requested] = rows
                loading = false
                if requested == .containers, let pending = pendingContainerID {
                    pendingContainerID = nil
                    if rows.contains(where: { $0.id == pending }) {
                        selection = pending; selectCurrent()
                    } else {
                        selection = nil; detail = nil; detailError = nil; detailLoading = false
                        outcome = "This project’s container no longer exists."; stopLive()
                    }
                    return
                }
                if let selection, !rows.contains(where: { $0.id == selection }) {
                    self.selection = nil; detail = nil; detailError = nil; detailLoading = false
                    detailID = UUID(); stopLive()
                } else if selection != nil { selectCurrent() }
            } catch {
                guard visible, loadID == mine else { return }
                loading = false; self.error = message(error, fallback: "Could not read Docker on \(target.name).")
                // A protocol/connection failure is not evidence Docker is absent.
                if !readStatus { availability = nil; installationPreview = nil }
                // A lost connection must not leave stale statistics looking live.
                stopLive()
            }
        }
    }

    func changeSection() {
        stopLive(); detailID = UUID(); detail = nil; selection = nil; search = ""
        detailError = nil; detailLoading = false; tab = .overview
        if section != .containers { pendingContainerID = nil }
        refresh()
    }

    func showContainer(_ id: String) {
        guard visible, !id.isEmpty else { return }
        pendingContainerID = id
        if section == .containers {
            search = ""; tab = .overview; stopLive(); refresh()
        } else {
            section = .containers; changeSection()
        }
    }

    func selectCurrent() {
        pendingContainerID = nil
        stopLive(); detail = nil; detailError = nil; usage = nil; logBuffer.clear()
        let mine = UUID(); detailID = mine
        guard visible, let id = selection else { detailLoading = false; return }
        let requested = section
        detailLoading = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await client.inspect(requested, id)
                guard visible, detailID == mine, selection == id, section == requested else { return }
                guard value.id == id else { throw NativeRPCError.malformed("Docker returned details for a different resource.") }
                detail = value; detailLoading = false; startLive()
            } catch {
                guard visible, detailID == mine, selection == id, section == requested else { return }
                detailLoading = false; detailError = message(error, fallback: "Could not read these Docker details.")
            }
        }
    }

    func changeTab() { stopLive(); startLive() }
    func clearLogs() { logBuffer.clear() }
    func retryStream() { stopLive(); if tab == .logs { logBuffer.clear() }; startLive() }

    /// Retrying cleanup is a separate, explicit read-owner action. Never replay
    /// an open request or automatically retry a close that lacked confirmation.
    func retryClosingLiveStream() {
        guard visible, !busy, !streamCleanupBusy, !pendingStreamCloses.isEmpty else { return }
        cleanupWasRetried = true; outcome = "Retrying live stream closure…"
        for id in Array(pendingStreamCloses.keys) { closeRetainedStream(id) }
    }

    func run(_ action: NativeDockerAction, item: NativeDockerItem, namedConfirmation: String? = nil,
             in requestedSection: NativeDockerSection? = nil) {
        guard visible, !busy, !loading, !detailLoading, error == nil,
              detailError == nil, detail?.id == item.id else { return }
        let requested = requestedSection ?? section
        guard requested == section, selection == item.id, selected?.confirmationName == item.confirmationName else {
            outcome = "This selection changed. Review the current resource before trying again."; return
        }
        guard requested == .containers || (action == .remove && requested != .projects) else {
            outcome = "This Docker action is unavailable."; return
        }
        if action == .remove, requested == .containers,
           item.running != false || ["paused", "restarting"].contains(item.state) {
            outcome = "Stop \(item.name) before removing it."; return
        }
        if action == .remove, namedConfirmation != item.confirmationName {
            outcome = "Confirm removal of \(item.name) first."; return
        }
        busy = true; outcome = action == .remove ? "Waiting to remove \(item.name)…" : "Waiting for approval…"
        Task { [weak self] in
            guard let self else { return }
            do {
                try await client.change(requested, item.id, action, namedConfirmation)
                busy = false
                let verb: String
                switch action {
                case .start: verb = "Started"
                case .stop: verb = "Stopped"
                case .restart: verb = "Restarted"
                case .remove: verb = "Removed"
                }
                outcome = "\(verb) \(item.name)."
                if visible, requested == section { refresh() }
            } catch {
                busy = false; outcome = message(error, fallback: "That action did not finish. Check Docker before trying again.")
            }
        }
    }

    func previewInstall() {
        guard visible, !busy, !loading, !target.isLocal, availability == .missingDocker, error == nil else { return }
        let ticket = visibilityID
        busy = true; outcome = "Reading the installation plan…"
        Task { [weak self] in
            guard let self else { return }
            do {
                let preview = try await client.installation()
                busy = false
                guard visible, visibilityID == ticket, availability == .missingDocker, error == nil else {
                    outcome = nil; return
                }
                installationPreview = preview; outcome = nil
            } catch {
                busy = false
                guard visible, visibilityID == ticket else { outcome = nil; return }
                outcome = message(error, fallback: "Could not prepare Docker installation.")
            }
        }
    }
    func dismissInstall() { installationPreview = nil }
    func install() {
        guard visible, let preview = installationPreview, !busy, !target.isLocal, availability == .missingDocker, error == nil else { return }
        installationPreview = nil; busy = true; outcome = "Waiting for approval to install Docker…"
        Task { [weak self] in
            guard let self else { return }
            do {
                try await client.install(preview)
                busy = false; outcome = "Docker installation completed."; refresh()
            } catch { busy = false; outcome = message(error, fallback: "Docker installation did not finish.") }
        }
    }

    private func startLive() {
        guard visible, section == .containers, let id = selection, detail?.id == id,
              detailError == nil, error == nil, !loading, !detailLoading,
              activeStream == nil, streamTask == nil, terminalModel == nil else { return }
        streamError = nil; streamEnded = false; streamCleanupConfirmed = false
        // Exec and live CPU need a running container. Stopped containers can still have logs.
        if tab != .logs, selected?.running != true { return }
        if tab == .terminal {
            do {
                let terminal = NativeDockerTerminalModel(transport: try client.terminal(id))
                terminal.onCleanupFailure = { [weak self] failure in self?.reportCleanupFailure(failure) }
                terminalModel = terminal
            }
            catch { streamError = message(error, fallback: "Container terminals are unavailable.") }
            return
        }
        guard !streamCleanupPending else {
            if failedStreamCloseIDs.isEmpty, !cleanupWasRetried,
               closingStreamIDs.count == pendingStreamCloses.count {
                // Finish this user-requested tab/selection read once its previous
                // normal stream close is acknowledged. This is not a retry.
                deferredLiveStart = streamGeneration.token; streamConnecting = true
            } else {
                streamError = "Close the previous live stream before opening another."
            }
            return
        }
        let kind: NativeDockerStreamKind = tab == .logs ? .logs : .stats
        let token = streamGeneration.token
        streamConnecting = true
        streamTask = Task { [weak self] in
            guard let self else { return }
            var attemptEnded = false
            var attemptCleanupConfirmed = false
            var attemptEndReason: String?
            do {
                let handle = try await client.stream(id, kind) { [weak self] update in
                    // Keep this attempt's result even after its visible generation
                    // changes. A failed local close must not be retried implicitly.
                    if case .ended(let why, let confirmed) = update {
                        attemptEnded = true; attemptCleanupConfirmed = confirmed; attemptEndReason = why
                    }
                    guard let self, self.visible, self.streamGeneration.accepts(token), !self.streamEnded else { return }
                    switch update {
                    case .log(let text, let stream): self.logBuffer.append(text, stream: stream); self.streamConnecting = false
                    case .usage(let sample): self.usage = sample; self.streamConnecting = false
                    case .ended(let why, let cleanupConfirmed):
                        self.streamEnded = true; self.streamCleanupConfirmed = cleanupConfirmed
                        if let handle = self.activeStream, !cleanupConfirmed {
                            self.retainStreamForCleanup(handle, attemptNow: false)
                        }
                        self.activeStream = nil
                        self.streamConnecting = false; self.streamError = why ?? "The live stream ended."
                    }
                }
                if attemptEnded, attemptCleanupConfirmed {
                    if visible, streamGeneration.accepts(token) { streamTask = nil }
                    return
                }
                // Opening may complete after cancellation, with a failed close.
                // Its retryable handle belongs to this model even while hidden.
                if let failure = handle.openingFailure {
                    retainStreamForCleanup(handle, attemptNow: false); reportCleanupFailure(failure)
                    if visible, streamGeneration.accepts(token) {
                        streamTask = nil; streamConnecting = false; streamError = failure
                        streamEnded = true; streamCleanupConfirmed = false
                    }
                    return
                }
                if attemptEnded {
                    retainStreamForCleanup(handle, attemptNow: false)
                    reportCleanupFailure(attemptEndReason ?? "Docker has not confirmed the live stream closed.")
                    if visible, streamGeneration.accepts(token) { streamTask = nil }
                    return
                }
                guard visible, streamGeneration.accepts(token), !Task.isCancelled else {
                    retainStreamForCleanup(handle, attemptNow: true)
                    return
                }
                streamTask = nil
                // An early end can arrive before open replies. Do not attach a
                // finished stream or let late data make it appear live again.
                if streamEnded {
                    if !streamCleanupConfirmed { retainStreamForCleanup(handle, attemptNow: false) }
                    return
                }
                activeStream = handle
                if kind == .logs { streamConnecting = false }
            } catch {
                guard visible, streamGeneration.accepts(token), !Task.isCancelled else { return }
                streamTask = nil
                streamConnecting = false; streamError = message(error, fallback: "Could not open this live stream.")
            }
        }
    }

    private func stopLive() {
        streamGeneration.invalidate(); deferredLiveStart = nil; streamTask?.cancel(); streamTask = nil
        terminalModel?.stop(); terminalModel = nil; streamConnecting = false; streamError = nil
        streamEnded = false; streamCleanupConfirmed = false; usage = nil
        if let handle = activeStream {
            retainStreamForCleanup(handle, attemptNow: true)
            activeStream = nil
        }
    }

    private func retainStreamForCleanup(_ handle: NativeDockerStream, attemptNow: Bool) {
        let id = UUID()
        pendingStreamCloses[id] = handle; streamCleanupPending = true
        if attemptNow { closeRetainedStream(id) }
        else {
            failedStreamCloseIDs.insert(id); abandonDeferredLiveStart()
        }
    }

    private func abandonDeferredLiveStart() {
        let wasWaiting = deferredLiveStart.map { streamGeneration.accepts($0) } == true
            && activeStream == nil && streamTask == nil
        deferredLiveStart = nil
        // A stale close failure must not clear the pending state or error of a
        // newer stream that has already begun opening.
        if wasWaiting {
            streamConnecting = false
            if visible { streamError = "Close the previous live stream before opening another." }
        }
    }

    private func closeRetainedStream(_ id: UUID) {
        guard let handle = pendingStreamCloses[id], closingStreamIDs.insert(id).inserted else { return }
        streamCleanupBusy = true
        // A fresh task remains able to close an owner stream when its opening
        // task was cancelled. The handle stays retained until an acknowledged close.
        Task { [self] in
            do {
                try await handle.stop()
                pendingStreamCloses.removeValue(forKey: id)
                failedStreamCloseIDs.remove(id)
            } catch {
                failedStreamCloseIDs.insert(id); abandonDeferredLiveStart()
                reportCleanupFailure(error)
            }
            closingStreamIDs.remove(id)
            streamCleanupBusy = !closingStreamIDs.isEmpty
            streamCleanupPending = !pendingStreamCloses.isEmpty
            if !streamCleanupPending, cleanupWasRetried {
                cleanupWasRetried = false
                let closed = "Live stream closed."
                outcome = busy ? [outcome, closed].compactMap { $0 }.joined(separator: "\n") : closed
            }
            if !streamCleanupPending, let token = deferredLiveStart {
                deferredLiveStart = nil; streamConnecting = false
                if visible, streamGeneration.accepts(token) { startLive() }
            }
        }
    }

    private func reportCleanupFailure(_ error: Error) {
        reportCleanupFailure(message(error, fallback: "Could not close the Docker stream."))
    }

    private func reportCleanupFailure(_ failure: String) {
        guard outcome?.contains(failure) != true else { return }
        outcome = [outcome, failure].compactMap { $0 }.joined(separator: "\n")
    }

    private func message(_ error: Error, fallback: String) -> String {
        CodingAIErrorText.from(error, fallback: fallback)
    }
}
