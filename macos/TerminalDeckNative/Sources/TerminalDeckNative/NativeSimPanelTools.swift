import AppKit
import Observation
import SwiftUI
import TerminalDeckNativeCore

/// What only a session's phone panel adds to the shared device view: Snip, the light Annotate
/// popup (with a switch to the full panel), and taking the full panel's width from the session
/// beside it so the phone never gets smaller. Found by the panel's device model.
@MainActor @Observable final class NativeSimPanelTools {
    /// Snip is on: the next drag on the screen draws the box.
    var snipping = false
    /// The box of the snip being written about (normalised to the screen), while its popup is open.
    var snipBox: CGRect?
    var snipWorking = false
    var snipProblem = ""
    /// Annotate: the full panel (Element / Outline / Checks) instead of the small popup. Remembered.
    var annotateFull: Bool { didSet { if model?.hootsimRenderFixture != true { UserDefaults.standard.set(annotateFull, forKey: Self.fullKey) } } }

    /// The width the full panel takes from the session (0 gives it back).
    static let fullPanelWidth = 352.0
    @ObservationIgnored let widen: (Double) -> Void
    @ObservationIgnored private weak var model: NativeSimulatorModel?
    private static let fullKey = "td.sessionSimulator.annotateFullPanel"

    /// U143 (#195): held weakly; the panel keeps its tools, so they go when the panel goes.
    private struct Held { weak var tools: NativeSimPanelTools? }
    private static var byModel: [ObjectIdentifier: Held] = [:]
    static func of(_ model: NativeSimulatorModel) -> NativeSimPanelTools? { byModel[ObjectIdentifier(model)]?.tools }

    @discardableResult
    static func attach(to model: NativeSimulatorModel, widen: @escaping (Double) -> Void) -> NativeSimPanelTools {
        let tools = NativeSimPanelTools(model: model, widen: widen)
        byModel = byModel.filter { $0.value.tools != nil }
        byModel[ObjectIdentifier(model)] = Held(tools: tools)
        return tools
    }

    private init(model: NativeSimulatorModel, widen: @escaping (Double) -> Void) {
        self.model = model; self.widen = widen
        annotateFull = model.hootsimRenderFixture ? false : UserDefaults.standard.bool(forKey: Self.fullKey)
    }

    func toggleSnip() {
        guard let model else { return }
        if snipping { snipping = false; return }
        if model.inspecting { model.stopInspecting() }
        if model.shot != nil, snipBox != nil { return } // a snip still being written about stays as it is
        snipProblem = ""
        snipping = true
    }

    /// The box is drawn: the screen is taken, cut to the box (saved beside the full picture),
    /// and the popup opens beside the box.
    func snipped(_ box: CGRect) {
        guard let model else { return }
        snipping = false; snipWorking = true; snipProblem = ""
        Task {
            defer { snipWorking = false }
            await model.screenshot()
            guard let state = model.shot else { snipProblem = model.problem.isEmpty ? "The screen could not be taken." : model.problem; return }
            guard let image = NativeShotCrop.load(path: state.shot.path, fallback: state.preview),
                  let cut = NativeShotCrop.cropped(image, to: box) else {
                snipProblem = "The snip could not be cut from the screen."; return
            }
            do {
                let path = try NativeShotCrop.save(cut, beside: state.shot.path, suffix: "snip")
                var shot = state.shot
                shot.path = path; shot.width = cut.width; shot.height = cut.height; shot.preview = nil
                model.shot = NativeSimulatorModel.ShotState(shot: shot, preview: NativeShotCrop.image(cut),
                                                            attachmentRevision: state.attachmentRevision)
                snipBox = box
            } catch {
                snipProblem = "The snip could not be saved: \(error.localizedDescription)"
            }
        }
    }

    /// Cancel: the snip is discarded.
    func cancelSnip() {
        snipBox = nil
        model?.shot = nil
    }
}

/// The popup beside a snip: the snipped picture, "This session", the one box, Cancel and Send.
struct NativeSimSnipPopup: View {
    @Bindable var model: NativeSimulatorModel
    let tools: NativeSimPanelTools

    var body: some View {
        if let state = model.shot {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Snip").font(.headline)
                    Spacer()
                    Text("\(state.shot.width.formatted()) × \(state.shot.height.formatted())")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                if let preview = state.preview {
                    Image(nsImage: preview).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 260, maxHeight: 150)
                        .clipShape(.rect(cornerRadius: 6))
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("The snipped part of the screen, \(state.shot.width) by \(state.shot.height) pixels")
                }
                NativeSessionTextField("What should the agent look at?", text: Binding(
                    get: { model.shot?.instruction ?? "" },
                    set: { model.shot?.instruction = $0; model.shot?.problem = "" }), axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .sessionOnSubmit { Task { await model.sendShot() } }
                HStack {
                    let line = !state.problem.isEmpty ? state.problem : model.sessionReason
                    if !line.isEmpty {
                        Text(line).font(.caption).foregroundStyle(state.problem.isEmpty ? Color.secondary : Color.red)
                    }
                    Spacer()
                    NativeCardCancelButton { tools.cancelSnip() }
                    NativeHOOTSIMPhoneSendButton(model: model, sending: state.sending,
                        disabled: !model.canSendFeedback, reason: model.sessionReason,
                        send: { Task { await model.sendShot() } }, copy: { model.copyFeedbackShot() })
                }
            }
            .padding(12)
            .frame(width: 290)
            .nativeCardStaysOpen { tools.cancelSnip() }
        }
    }
}

/// The light Annotate popup at the newest marker: how many are marked, the one box, a switch to
/// the full panel, Cancel and Send.
struct NativeSimAnnotatePopup: View {
    @Bindable var model: NativeSimulatorModel
    @Bindable var tools: NativeSimPanelTools

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Annotate").font(.headline)
                Text("\(model.markers.count) marked").font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Toggle("Full panel", isOn: $tools.annotateFull)
                    .toggleStyle(.switch).controlSize(.mini).font(.caption).fixedSize()
                    .help("Show the full panel (Element, Outline, Checks) beside the phone; the session makes room for it")
            }
            NativeSessionTextField("What should change?", text: $model.note, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Message for the agent")
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    Task { await model.sendRound() }
                    return .handled
                }
            HStack(alignment: .firstTextBaseline) {
                let line = !model.sendProblem.isEmpty ? model.sendProblem : (model.target == nil ? model.sessionReason : "")
                if !line.isEmpty {
                    Text(line).font(.caption).foregroundStyle(model.sendProblem.isEmpty ? Color.secondary : Color.red)
                }
                Spacer()
                NativeCardCancelButton { model.stopInspecting() }
                NativeHOOTSIMPhoneSendButton(model: model, sending: model.sending,
                    disabled: !model.canSendRound, reason: model.sendRoundHint,
                    send: { Task { await model.sendRound() } }, copy: { model.copyRound() })
            }
        }
        .padding(12)
        .frame(width: 300)
        .nativeCardStaysOpen { model.stopInspecting() }
    }
}

/// Reports where a view sits in its window, so a popup can open on the side that has room and
/// always stays inside the window (outside it, its material shows the desktop behind).
struct NativePopupRoom: NSViewRepresentable {
    struct Placement: Equatable {
        /// The view's left edge from the window's left, and the window's content width.
        var minX: CGFloat = 0
        var windowWidth: CGFloat = 0
        var height: CGFloat = 0

        /// Right of the anchor when the popup fits there, else left, else below.
        func edge(for anchor: CGRect, width: CGFloat) -> Edge {
            guard windowWidth > 0 else { return .leading }
            let right = windowWidth - (minX + anchor.maxX), left = minX + anchor.minX
            if right >= width { return .trailing }
            if left >= width { return .leading }
            return anchor.midY > height / 2 ? .top : .bottom
        }
    }
    let report: (Placement) -> Void

    func makeNSView(context: Context) -> Reader { Reader(report: report) }
    func updateNSView(_ view: Reader, context: Context) { view.report = report; view.measure() }

    final class Reader: NSView {
        var report: (Placement) -> Void
        private var last = Placement()
        init(report: @escaping (Placement) -> Void) { self.report = report; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); measure() }
        override func layout() { super.layout(); measure() }
        override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); measure() }
        func measure() {
            guard let window else { return }
            let inWindow = convert(bounds, to: nil)
            let next = Placement(minX: inWindow.minX, windowWidth: window.contentLayoutRect.width, height: bounds.height)
            guard next != last else { return }
            last = next
            let report = report
            DispatchQueue.main.async { report(next) }
        }
    }
}
