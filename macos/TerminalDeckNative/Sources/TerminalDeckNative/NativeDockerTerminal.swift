import AppKit
import Observation
import SwiftUI
@preconcurrency import SwiftTerm
import TerminalDeckNativeCore

/// DKA supplies the approved Docker exec transport once DKE's contract is ready.
/// Opening must use the engine's existing approval path. Close is idempotent
/// after a reported end, and can release a locally failed, unconfirmed session.
@MainActor
struct NativeDockerTerminalTransport {
    let open: @MainActor (_ cols: Int, _ rows: Int) async throws -> String
    let write: @MainActor (_ id: String, _ bytes: Data) async throws -> Void
    let resize: @MainActor (_ id: String, _ cols: Int, _ rows: Int) async throws -> Void
    let close: @MainActor (_ id: String) async throws -> Void
    let subscribe: @MainActor (
        _ output: @escaping @MainActor (String, Data) -> Void,
        _ closed: @escaping @MainActor (String, String?) -> Void
    ) -> (() -> Void)
}

/// One visible container terminal, using the same SwiftTerm renderer as sessions.
/// Hiding its screen unsubscribes and closes the PTY; reopening starts a new exec.
@MainActor
@Observable
final class NativeDockerTerminalModel {
    private(set) var isConnecting = false
    private(set) var isConnected = false
    private(set) var error: String?
    private(set) var note: String?
    /// The owning server page keeps cleanup failures visible after this model
    /// has left the screen. Its callback should hold that page weakly.
    @ObservationIgnored var onCleanupFailure: (@MainActor (String) -> Void)?

    @ObservationIgnored fileprivate let terminal: NativeDockerTerminalSurface
    @ObservationIgnored fileprivate let container: DeckTerminalContainer
    @ObservationIgnored private let transport: NativeDockerTerminalTransport
    @ObservationIgnored private let proxy = NativeDockerTerminalDelegate()
    @ObservationIgnored private var id: String?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var unsubscribe: (() -> Void)?
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var held: [HeldEvent] = []
    @ObservationIgnored private var heldBytes = 0
    @ObservationIgnored private var heldOverflow = false
    @ObservationIgnored private var writes: [Data] = []
    @ObservationIgnored private var writeBytes = 0
    @ObservationIgnored private var writeTask: Task<Void, Never>?
    @ObservationIgnored private var resizeTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSize: (cols: Int, rows: Int)?
    @ObservationIgnored private var sentSize: (cols: Int, rows: Int)?
    @ObservationIgnored private var appliedPreferences: TerminalPreferences?
    @ObservationIgnored private var appliedScheme: TerminalScheme?

    // Bound both bytes and event count: empty chunks cannot grow a hidden queue.
    private static let bufferBytes = 1024 * 1024
    // A full permitted paste plus bracketed-paste framing must fit as one write.
    private static let inputBytes = 2 * TerminalTransfer.maxPasteBytes
    // DKE's exec adapter accepts at most 64 KiB in a single write. Keep a large
    // paste ordered while preserving its bracketed-paste bytes across packets.
    private static let writeChunkBytes = 65_536
    private static let bufferEvents = 512

    private enum HeldEvent {
        case output(String, Data)
        case closed(String, String?)
    }

    init(transport: NativeDockerTerminalTransport) {
        self.transport = transport
        terminal = NativeDockerTerminalSurface(
            frame: NSRect(x: 0, y: 0, width: 640, height: 400),
            font: NativeTerminalSettings.shared.preferences.nsFont
        )
        container = DeckTerminalContainer(terminal: terminal)
        proxy.owner = self
        terminal.owner = self
        terminal.terminalDelegate = proxy
        terminal.optionAsMetaKey = false
        terminal.lineSpacing = NativeTerminalSession.lineSpacing
        terminal.freeze(true)
        applyAppearance(preferences: NativeTerminalSettings.shared.preferences,
                        scheme: NativeTerminalSettings.shared.scheme)
    }

    /// Idempotent while connecting or connected. Only the visible Open button calls it.
    func start() {
        guard !isConnecting, !isConnected else { return }
        generation = UUID()
        let ticket = generation
        error = nil
        note = nil
        held = []
        heldBytes = 0
        heldOverflow = false
        terminal.freeze(true)
        isConnecting = true
        unsubscribe = transport.subscribe({ [weak self] id, bytes in
            guard let self, self.generation == ticket else { return }
            self.received(id: id, bytes: bytes)
        }, { [weak self] id, reason in
            guard let self, self.generation == ticket else { return }
            self.ended(id: id, reason: reason)
        })
        let grid = terminal.getTerminal()
        let cols = min(1000, max(1, grid.cols))
        let rows = min(1000, max(1, grid.rows))
        let transport = transport
        let reportCleanupFailure = onCleanupFailure
        // Cancellation revokes pending consent. A transport that ignores it
        // must still have its exact late PTY id closed in a fresh cleanup task.
        openTask = Task { [weak self] in
            defer {
                if let self, self.generation == ticket { self.openTask = nil }
            }
            do {
                let id = try await transport.open(cols, rows)
                guard let self else {
                    if !id.isEmpty {
                        let cleanup = Task { try await transport.close(id) }
                        do { try await cleanup.value }
                        catch { reportCleanupFailure?("The terminal could not close. \(error.localizedDescription)") }
                    }
                    return
                }
                guard self.generation == ticket, self.isConnecting else {
                    if !id.isEmpty { self.close(id, reportingTo: self.generation) }
                    return
                }
                guard !id.isEmpty else {
                    self.fail("This copy of the app could not open a container terminal.")
                    return
                }
                self.opened(id: id, cols: cols, rows: rows)
            } catch {
                guard let self, self.generation == ticket else { return }
                self.fail("The container terminal could not open. \(error.localizedDescription)")
            }
        }
    }

    /// Releases the subscription immediately; preserves scrollback as a frozen view.
    func stop() {
        generation = UUID()
        let oldID = id
        id = nil
        isConnecting = false
        isConnected = false
        terminal.freeze(true)
        openTask?.cancel()
        openTask = nil
        unsubscribe?()
        unsubscribe = nil
        held = []
        heldBytes = 0
        heldOverflow = false
        writeTask?.cancel()
        writeTask = nil
        writes = []
        writeBytes = 0
        resizeTask?.cancel()
        resizeTask = nil
        pendingSize = nil
        sentSize = nil
        if let oldID { close(oldID, reportingTo: generation) }
    }

    private func close(_ id: String, reportingTo ticket: UUID) {
        let transport = transport
        let reportCleanupFailure = onCleanupFailure
        Task { [weak self] in
            do {
                try await transport.close(id)
            } catch {
                let message = "The terminal could not close. \(error.localizedDescription)"
                reportCleanupFailure?(message)
                guard let self, self.generation == ticket, !self.isConnected, !self.isConnecting else { return }
                self.error = message
            }
        }
    }

    private func fail(_ message: String) {
        stop()
        error = message
    }

    private func opened(id: String, cols: Int, rows: Int) {
        self.id = id
        if heldOverflow {
            fail("Too much terminal output arrived before it opened. Open the terminal again.")
            return
        }
        let events = held
        held = []
        heldBytes = 0
        // A short-lived command may end before open replies. Draw its output
        // without sending terminal responses back into an already-ended PTY.
        let alreadyEnded = events.contains { event in
            if case .closed(let endedID, _) = event { return endedID == id }
            return false
        }
        isConnecting = false
        isConnected = !alreadyEnded
        terminal.freeze(alreadyEnded)
        sentSize = (cols, rows)
        for event in events {
            switch event {
            case .output(let eventID, let bytes) where eventID == id:
                feed(bytes)
            case .closed(let eventID, let reason) where eventID == id:
                disconnected(reason: reason)
                return
            default:
                break
            }
        }
        let grid = terminal.getTerminal()
        resized(cols: grid.cols, rows: grid.rows)
        focusIfConnected()
    }

    private func received(id eventID: String, bytes: Data) {
        guard !bytes.isEmpty else { return }
        if let id {
            guard id == eventID, isConnected else { return }
            feed(bytes)
        } else if isConnecting {
            hold(.output(eventID, bytes), bytes: bytes.count)
        }
    }

    private func ended(id eventID: String, reason: String?) {
        if let id {
            guard id == eventID else { return }
            disconnected(reason: reason)
        } else if isConnecting {
            hold(.closed(eventID, reason), bytes: reason?.utf8.count ?? 0)
        }
    }

    private func hold(_ event: HeldEvent, bytes: Int) {
        guard !heldOverflow else { return }
        guard bytes <= Self.bufferBytes - heldBytes, held.count < Self.bufferEvents else {
            heldOverflow = true
            held = []
            heldBytes = 0
            return
        }
        held.append(event)
        heldBytes += bytes
    }

    private func feed(_ bytes: Data) {
        // SwiftTerm keeps UTF-8/escape state across binary chunks. Never decode
        // individual frames to String (a split multibyte character would be lost).
        terminal.feed(byteArray: Array(bytes)[...])
    }

    private func disconnected(reason: String?) {
        // The transport skips a confirmed Engine end. An unconfirmed local
        // decoder failure retains its id so teardown can release that PTY.
        stop()
        error = reason.flatMap { $0.isEmpty ? nil : $0 } ?? "This terminal ended."
    }

    fileprivate func send(_ data: ArraySlice<UInt8>) {
        guard isConnected, !terminal.frozen, let id, !data.isEmpty else { return }
        let bytes = Data(data)
        guard bytes.count <= Self.inputBytes - writeBytes, writes.count < Self.bufferEvents else {
            fail("The terminal could not keep up with input. Open it again before typing.")
            return
        }
        writes.append(bytes)
        writeBytes += bytes.count
        guard writeTask == nil else { return }
        let ticket = generation
        writeTask = Task { [weak self] in
            guard let self else { return }
            while self.generation == ticket, self.isConnected, !Task.isCancelled, !self.writes.isEmpty {
                let bytes = self.writes.removeFirst()
                self.writeBytes -= bytes.count
                do {
                    for offset in stride(from: 0, to: bytes.count, by: Self.writeChunkBytes) {
                        guard self.generation == ticket, self.isConnected, !Task.isCancelled else { return }
                        let end = min(offset + Self.writeChunkBytes, bytes.count)
                        try await self.transport.write(id, bytes.subdata(in: offset..<end))
                    }
                } catch {
                    guard self.generation == ticket else { return }
                    self.fail("The terminal could not send input. \(error.localizedDescription)")
                    return
                }
            }
            if self.generation == ticket { self.writeTask = nil }
        }
    }

    fileprivate func resized(cols: Int, rows: Int) {
        guard isConnected, let id, cols > 0, rows > 0 else { return }
        let size = (cols: min(1000, cols), rows: min(1000, rows))
        if let sentSize, sentSize == size, pendingSize == nil { return }
        pendingSize = size
        guard resizeTask == nil else { return }
        let ticket = generation
        resizeTask = Task { [weak self] in
            guard let self else { return }
            while self.generation == ticket, self.isConnected, !Task.isCancelled, let size = self.pendingSize {
                self.pendingSize = nil
                do {
                    try await self.transport.resize(id, size.cols, size.rows)
                    guard self.generation == ticket else { return }
                    self.sentSize = size
                } catch {
                    guard self.generation == ticket else { return }
                    self.fail("The terminal could not update its size. \(error.localizedDescription)")
                    return
                }
            }
            if self.generation == ticket { self.resizeTask = nil }
        }
    }

    fileprivate func focusIfConnected() {
        if isConnected, !terminal.frozen { terminal.window?.makeFirstResponder(terminal) }
    }

    fileprivate func paste(from pasteboard: NSPasteboard) {
        guard isConnected, !terminal.frozen else { return }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let types = pasteboard.types ?? []
        let imageType = types.contains(.png) || types.contains(.tiff) ? "image/png" : nil
        switch TerminalPastePlan.decide(filePaths: urls.map(\.path), hasImage: imageType != nil,
                                       imageType: imageType, text: pasteboard.string(forType: .string), now: Date()) {
        case .text(let text):
            guard !TerminalTransfer.overPasteCap(text) else {
                note = TerminalTransfer.pasteTooBig
                return
            }
            note = nil
            terminal.send(txt: TerminalText.pasteData(text, bracketed: terminal.getTerminal().bracketedPasteMode))
        case .paths, .stageImage:
            note = "File and image transfer into containers is unavailable. Paste text instead."
        case .nothing:
            break
        }
    }

    fileprivate func copyFromProgram(_ bytes: Data) {
        switch TerminalClipboard.decide(bytes) {
        case .copy(let text):
            NSPasteboard.general.clearContents()
            if !NSPasteboard.general.setString(text, forType: .string) { note = TerminalClipboard.didNotReach }
        case .refuse(let message):
            note = message
        case .ignore:
            break
        }
    }

    fileprivate func applyAppearance(preferences: TerminalPreferences, scheme: TerminalScheme) {
        terminal.copyOnSelect = preferences.copyOnSelect
        if appliedPreferences?.fontSize != preferences.fontSize || appliedPreferences?.fontFamily != preferences.fontFamily {
            terminal.font = preferences.nsFont
            terminal.setFrameSize(terminal.frame.size)
        }
        appliedPreferences = preferences
        guard scheme != appliedScheme else { return }
        appliedScheme = scheme
        let background = scheme.colour(scheme.background, fallback: .black)
        terminal.nativeBackgroundColor = background
        terminal.nativeForegroundColor = scheme.colour(scheme.foreground, fallback: .white)
        terminal.liveCaret = (scheme.colour(scheme.cursor, fallback: .controlAccentColor),
                              scheme.colour(scheme.cursorAccent, fallback: background))
        terminal.selectedTextBackgroundColor = scheme.colour(scheme.selectionBackground, fallback: .selectedTextBackgroundColor)
        terminal.installColors(scheme.ansi.map { hex in
            let colour = TerminalColour(hex: hex) ?? TerminalColour(red: 0.5, green: 0.5, blue: 0.5)
            return SwiftTerm.Color(red: UInt16(colour.red * 65535), green: UInt16(colour.green * 65535), blue: UInt16(colour.blue * 65535))
        })
        container.ground = background
        container.appearance = NSAppearance(named: scheme.isLight ? .aqua : .darkAqua)
    }
}

/// DKA integration prerequisite: remove `final` from DeckTerminalView's class
/// declaration in NativeTerminalView.swift. All native chords/copy rules stay there.
@MainActor
fileprivate final class NativeDockerTerminalSurface: DeckTerminalView {
    weak var owner: NativeDockerTerminalModel?

    override func paste(_ sender: Any) {
        guard !frozen else { return }
        owner?.paste(from: .general)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard !frozen else { return false }
        owner?.paste(from: sender.draggingPasteboard)
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { owner?.focusIfConnected() }
    }
}

@MainActor
private final class NativeDockerTerminalDelegate: TerminalViewDelegate {
    weak var owner: NativeDockerTerminalModel?

    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated { owner?.resized(cols: newCols, rows: newRows) }
    }
    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        MainActor.assumeIsolated { owner?.send(data) }
    }
    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        MainActor.assumeIsolated { owner?.copyFromProgram(content) }
    }
    nonisolated func clipboardRead(source: TerminalView) -> Data? { nil }
    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        MainActor.assumeIsolated {
            guard let link = TerminalLinks.openable(link), let url = URL(string: link) else { return }
            NSWorkspace.shared.open(url)
        }
    }
    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func scrolled(source: TerminalView, position: Double) {}
    nonisolated func bell(source: TerminalView) {}
    nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

struct NativeDockerTerminalView: View {
    let model: NativeDockerTerminalModel

    var body: some View {
        let settings = NativeTerminalSettings.shared
        VStack(spacing: 8) {
            if model.isConnecting {
                NativePageNote("Opening terminal…", busy: true).fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.error {
                NativePageNote(error).fixedSize(horizontal: false, vertical: true)
            }
            if let note = model.note {
                NativePageNote(note).fixedSize(horizontal: false, vertical: true)
            }
            if !model.isConnecting, !model.isConnected {
                Button("Open terminal", action: model.start).buttonStyle(.bordered)
            }
            NativeDockerTerminalHost(model: model, preferences: settings.preferences, scheme: settings.scheme)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onDisappear { model.stop() }
    }
}

private struct NativeDockerTerminalHost: NSViewRepresentable {
    let model: NativeDockerTerminalModel
    let preferences: TerminalPreferences
    let scheme: TerminalScheme

    func makeNSView(context: Context) -> DeckTerminalContainer { model.container }

    func updateNSView(_ nsView: DeckTerminalContainer, context: Context) {
        model.applyAppearance(preferences: preferences, scheme: scheme)
    }

    static func dismantleNSView(_ nsView: DeckTerminalContainer, coordinator: ()) {
        (nsView.terminal as? NativeDockerTerminalSurface)?.owner?.stop()
    }
}
