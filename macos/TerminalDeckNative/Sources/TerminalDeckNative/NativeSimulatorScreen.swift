import AppKit
import Combine
import SwiftUI
import TerminalDeckNativeCore

/// Simulators, drawn in Swift: the iOS Simulators and Android emulators and
/// phones on this Mac, live, with an Accessibility-Inspector-style inspector
/// and a way to hand what was pointed at to a session.
///
/// At parity with the web page (`renderer/devices/DevicesPage.tsx`) first: the
/// list grouped Running / Off / Not available, starting and opening through the
/// same channels, the live screen (decoded natively), touches, swipes, typing,
/// hardware buttons, rotation, screenshots with Reveal and Send. Then Inspect,
/// which takes the place of the page's Annotate and keeps its numbered markers
/// and its one message — on the live screen, which never stops playing.
struct NativeSimulatorScreen: View {
    @State private var model = NativeSimulatorModel(deviceRail: true)

    var body: some View {
        NativeUIGSimulatorScreen(model: model)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .onAppear { model.appear() }
        .onDisappear { model.disappear() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.appBecameActive()
        }
    }
}

// MARK: - The list

// MARK: - One device open

struct DeviceOpenView: View {
    @Bindable var model: NativeSimulatorModel
    var showsDeviceBack = true
    /// In a window of its own: only the phone here; the buttons, status and Annotate card are in the
    /// strip window under it (NativeDeviceControlStrip, NativeDeviceFloatingWindow).
    var floating = false

    var body: some View {
        if floating {
            DeviceStage(model: model)
                .environment(\.phoneFrameDragsWindow, true)
                .padding(.top, NativeDeviceFloatingWindow.Host.topInset) // room for the window buttons above the phone
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onExitCommand { model.escapeInspect() }
        } else { docked }
    }

    private var docked: some View {
        VStack(spacing: 0) {
            if !model.problem.isEmpty || !model.said.isEmpty {
                StatusLine(problem: model.problem, said: model.said)
            }
            if let tools = NativeSimPanelTools.of(model) {
                // A session's phone panel: Annotate is a small popup at the marker. Its full
                // panel, when switched on, takes its width from the session beside it; the
                // phone keeps its size.
                let full = model.inspecting && tools.annotateFull
                HStack(spacing: 0) {
                    phone.frame(maxWidth: .infinity, maxHeight: .infinity)
                    if full {
                        InspectPanel(model: model)
                            .frame(width: NativeSimPanelTools.fullPanelWidth - 16)
                            .padding([.vertical, .trailing], 16)
                    }
                }
                .onChange(of: full, initial: true) { _, wide in tools.widen(wide ? NativeSimPanelTools.fullPanelWidth : 0) }
                .onDisappear { tools.widen(0) }
            } else {
                // Annotate, as the page lays it out: the live screen on the left, the card with the
                // markers and the one box on the right beside it; under the phone when too narrow.
                GeometryReader { outer in
                    let beside = outer.size.width >= 640
                    // One layout that changes shape, so the live screen view is never rebuilt.
                    let layout = beside ? AnyLayout(HStackLayout(spacing: 16)) : AnyLayout(VStackLayout(spacing: 0))
                    layout {
                        phone.frame(maxWidth: .infinity, maxHeight: .infinity)
                        if model.inspecting {
                            if beside {
                                InspectPanel(model: model)
                                    .frame(minWidth: 272, idealWidth: 336, maxWidth: 336)
                                    .padding([.vertical, .trailing], 16)
                            } else {
                                InspectPanel(model: model)
                                    .frame(height: min(360, max(260, outer.size.height * 0.45)))
                                    .padding([.horizontal, .bottom], 12)
                            }
                        }
                    }
                }
            }
        }
        .onExitCommand { model.escapeInspect() }
    }

    /// The phone (its frame, the live screen) and the control row under it.
    private var phone: some View {
        GeometryReader { geometry in
            // Recording with talk on: the live words under the phone (lane NARR).
            let narration = NativeSimRecorder.of(model)?.live
            let strip = narration == nil ? 0 : NativeNarrationStrip.height + 6
            let available = CGSize(width: max(1, geometry.size.width - 24),
                                   height: max(1, geometry.size.height - 76 - strip))
            // With a phone frame, the device (bezel and buttons too) is what fits the space.
            let content = model.frameContent ?? available
            let drawn = model.frameContent == nil ? content
                : NativePhoneFrame.spec(for: model.device, content: content)?.outerSize(content: content) ?? content
            let fitted = DeviceGeometry.fitted(content: drawn, in: available)
            VStack(spacing: 0) {
                DeviceStage(model: model)
                    .frame(height: fitted.height + 24)
                if let narration {
                    NativeNarrationStrip(narration: narration)
                        .padding(.bottom, 6)
                }
                DeviceToolbar(model: model, showsDeviceBack: showsDeviceBack)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(.bottom, 8)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

/// The floating device window's strip: the device's action buttons on glass, a close and a move-back
/// button, and (while annotating) the Annotate card under them. Its own small window under the phone.
struct NativeDeviceControlStrip: View {
    @Bindable var model: NativeSimulatorModel
    var moveBack: () -> Void
    var close: () -> Void
    var resized: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 2) {
                DeviceToolbar(model: model, showsDeviceBack: false)
                    .padding(.horizontal, -8).padding(.vertical, -6) // the row's own padding, tightened for the strip
                // Move-back and close live here, always visible. The window has no title bar, and the
                // hover-revealed window buttons did not appear, so a device in its own window could not be
                // closed at all (Asad 24 Oct, finding 7). The strip is always on screen, so these always are.
                Divider().frame(height: 18).padding(.horizontal, 2)
                stripButton("Move back to the panel", "arrow.down.left.square", moveBack)
                stripButton("Close this window", "xmark", close)
            }
            .labelStyle(.iconOnly)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
            if !model.problem.isEmpty || !model.said.isEmpty {
                // Wrapped to a fixed width and as tall as it needs: the strip window grows to show it whole.
                StatusLine(problem: model.problem, said: model.said)
                    .frame(width: 300)
                    .fixedSize(horizontal: false, vertical: true)
                    .glassEffect(.regular, in: .rect(cornerRadius: 12))
            }
            // A session's phone keeps its light popup at the marker unless the full panel is switched on.
            if model.inspecting, NativeSimPanelTools.of(model)?.annotateFull ?? true {
                InspectPanel(model: model)
                    .frame(width: 336, height: 380)
                    .padding(8)
                    .glassEffect(.regular, in: .rect(cornerRadius: 18))
            }
        }
        .fixedSize()
        .padding(4)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in resized() }
        .onExitCommand { model.escapeInspect() }
    }

    private func stripButton(_ label: String, _ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: symbol)
        }
        .buttonStyle(.borderless)
        .frame(width: 28, height: 28)
        .contentShape(.rect)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Shown over the screen when the fast direct path dropped and the panel did NOT silently switch to the
/// slow video stream (Asad 23 Oct: "whenever there is a problem I will notice"). It carries the device's
/// own words and leaves the choice to the person: try the fast path again, or stay on the stream for now.
private struct DirectFailureCard: View {
    let reason: String
    let retry: () -> Void
    let useStreaming: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Label("Direct connection lost", systemImage: "bolt.horizontal.circle")
                .font(.headline)
                .symbolRenderingMode(.multicolor)
            Text(reason.isEmpty ? "The fast direct screen dropped." : reason)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Retry", action: retry)
                    .buttonStyle(.borderedProminent)
                Button("Use streaming anyway", action: useStreaming)
                    .buttonStyle(.bordered)
            }
        }
        .padding(18)
        .frame(maxWidth: 320)
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
        .shadow(radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Direct connection lost. \(reason)")
    }
}

private struct StatusLine: View {
    let problem: String
    let said: String

    var body: some View {
        Text(problem.isEmpty ? said : problem)
            .font(.callout)
            .foregroundStyle(problem.isEmpty ? Color.secondary : Color.red)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
    }
}

private struct DeviceToolbar: View {
    @Bindable var model: NativeSimulatorModel
    var showsDeviceBack = true
    @State private var shotShown = false

    var body: some View {
        let device = model.device
        HStack(spacing: 6) {
            if showsDeviceBack {
                Button {
                    model.back()
                } label: {
                    Label("Devices", systemImage: "chevron.backward")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
            }

            if showsDeviceBack {
            Button {
                if NSEvent.modifierFlags.contains(.option) { model.diagnostics.toggle() }
            } label: {
            Text(device?.name ?? "")
                .font(.headline)
                .lineLimit(1)
                .padding(.leading, 6)
                .help(device?.name ?? "")
                .frame(minHeight: 28)
                .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(device?.name ?? "Device")

            Spacer(minLength: 12)
            }

            if let device {
                Group {
                    if device.buttons.contains("home") { tool("Home", "house") { model.button("home") } }
                    if device.buttons.contains("back") { tool("Back", "arrow.backward") { model.button("back") } }
                    if device.buttons.contains("overview") { tool("Recent apps", "square.on.square") { model.button("overview") } }
                    // Lock and volume are the side buttons on the phone's frame, when it has one.
                    if NativePhoneFrame.spec(for: device, content: model.frameContent ?? .zero) == nil || model.frameContent == nil {
                        if device.buttons.contains("lock") { tool("Lock", "lock") { model.button("lock") } }
                        if device.buttons.contains("volume-up") { tool("Volume up", "speaker.plus") { model.button("volume-up") } }
                        if device.buttons.contains("volume-down") { tool("Volume down", "speaker.minus") { model.button("volume-down") } }
                    }
                    if device.canRotate { tool("Rotate", "rotate.right") { Task { await model.rotate() } } }
                }

                tool("Screenshot", "camera") {
                    // A card still open (not sent, not cancelled) comes back as it was.
                    if NativeSimPanelTools.of(model)?.snipBox != nil { return }
                    if model.shot != nil { shotShown = true; return }
                    Task {
                        await model.screenshot()
                        shotShown = model.shot != nil
                    }
                }
                .popover(isPresented: $shotShown, arrowEdge: .bottom) {
                    ShotPopover(model: model, shown: $shotShown)
                }

                // Snip (a session's phone panel): drag a box on the screen; a popup beside it to say what to look at.
                if let tools = NativeSimPanelTools.of(model) {
                    NativeBrowserIcon("Snip", "scissors", help: "Snip — drag a box on the screen, then say what the agent should look at",
                                      pressed: tools.snipping || tools.snipBox != nil) {
                        tools.toggleSnip()
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
                    .disabled(tools.snipWorking)
                }

                // Record (a session's phone panel): the screen, with his voice, then a card like Screenshot's.
                if let recorder = NativeSimRecorder.of(model), recorder.canRecord {
                    NativeSimRecordControls(recorder: recorder)
                }

                // Annotate, as the web browser's: the same arrow, on the live screen. Point at
                // elements, click to mark them, say what should change in the one box.
                NativeBrowserIcon("Annotate", "cursorarrow",
                                  help: "Annotate — mark things on the screen, say what should change, send it to a session",
                                  pressed: model.inspecting) {
                    model.toggleInspect()
                }
                .buttonStyle(.borderless)
                .frame(width: 28, height: 28)
                .contentShape(.rect)

                // #108/#88: on the Simulators page, the screen + its tree to Hoot (same handoff as the row menu).
                if NativeSimPanelTools.of(model) == nil { NativeFIXESDeviceSendButton(model: model) }

                if !device.isPhysical {
                    // Not the phone's power button (that is on the frame): this stops the simulator itself.
                    tool("Shut down this simulator", "power") { Task { await model.shutDown() } }
                }
            }
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onChange(of: model.shot == nil) { _, gone in if gone { shotShown = false } }
    }

    private func tool(_ label: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: symbol)
        }
        .buttonStyle(.borderless)
        .frame(width: 28, height: 28)
        .contentShape(.rect)
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - The stage: the live screen and what is drawn over it

private struct DeviceStage: View {
    let model: NativeSimulatorModel
    @Environment(\.phoneFrameDragsWindow) private var dragsWindow

    var body: some View {
        GeometryReader { geometry in
            // A frame only once the screen's shape is known (never guessed from the space on offer).
            // One structure with or without it, so the live screen view is never rebuilt (a rebuilt
            // one reports the window hidden as it leaves, and the picture stops).
            let content = model.frameContent ?? geometry.size
            let frame = model.frameContent == nil ? nil : NativePhoneFrame.spec(for: model.device, content: content)
            let layout = frame?.layout(content: content, in: geometry.size)
            let hole = layout?.screen ?? CGRect(origin: .zero, size: geometry.size)
            let radius = layout.map { $0.unit * (frame?.screenRadius ?? 0) } ?? 0
            ZStack(alignment: .topLeading) {
                // The device around the screen; the screen laid out alone over its hole,
                // so the picture and every touch are measured exactly as without a frame.
                if let frame, let layout {
                    NativePhoneFrameView(frame: frame, layout: layout, available: model.device?.buttons ?? [],
                                         press: { model.button($0) })
                        .modifier(NativeFrameDragsWindow(enabled: dragsWindow))
                }
                screen(in: hole.size, cornerRadius: radius)
                    .background(layout == nil ? Color.clear : NativePhoneFrameView.deviceBlack)
                    .overlay(alignment: .top) {
                        // A Pixel's front camera, over the status bar as on the phone itself.
                        if frame?.punchHole == true, layout != nil {
                            let side = max(6, hole.width * 0.034)
                            Circle().fill(NativePhoneFrameView.deviceBlack).frame(width: side, height: side)
                                .padding(.top, hole.width * 0.03).allowsHitTesting(false).accessibilityHidden(true)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .frame(width: hole.width, height: hole.height)
                    .position(x: hole.midX, y: hole.midY)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .modifier(PanelPopups(model: model, picture: picture(in: hole)))
        }
        .padding(12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.inspecting
            ? "\(model.device?.name ?? "Device") screen, live. Point at an element to see it, click to mark it, drag to swipe, type to type."
            : "\(model.device?.name ?? "Device") screen. Click to tap, drag to swipe, type to type.")
    }

    /// Where the live picture is drawn in the stage, for anchoring a popup at a marker or a snip.
    private func picture(in screen: CGRect) -> CGRect {
        DeviceGeometry.fitted(content: model.fitSize ?? screen.size, in: screen.size)
            .offsetBy(dx: screen.minX, dy: screen.minY)
    }

    private func screen(in size: CGSize, cornerRadius: CGFloat) -> some View {
        let fitted = DeviceGeometry.fitted(content: model.fitSize ?? size, in: size)
        let tools = NativeSimPanelTools.of(model)
        return ZStack(alignment: .topLeading) {
            DeviceScreenSurface(model: model, cornerRadius: cornerRadius, snipping: tools?.snipping ?? false,
                                onSnip: tools.map { tools in { box in tools.snipped(box) } })

            // The snip being written about stays marked on the screen until Send or Cancel.
            if let box = tools?.snipBox {
                let rect = DeviceGeometry.viewRect(NormRect(x: box.minX, y: box.minY, width: box.width, height: box.height), in: fitted)
                Canvas { context, _ in
                    var dim = Path(fitted); dim.addRect(rect)
                    context.fill(dim, with: .color(.black.opacity(0.35)), style: FillStyle(eoFill: true))
                    context.stroke(Path(rect), with: .color(.white), lineWidth: 1.5)
                }
                .allowsHitTesting(false)
            }

            if model.inspecting {
                InspectorOverlay(model: model, fitted: fitted)
                    .allowsHitTesting(false)
            }

            if model.videoSize == nil {
                Text("Starting the live picture…")
                    .font(.callout)
                    .foregroundStyle(cornerRadius > 0 ? AnyShapeStyle(Color.white.opacity(0.7)) : AnyShapeStyle(.secondary))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            }

            if let failure = model.directFailure {
                DirectFailureCard(reason: failure.reason,
                                  retry: { model.retryDirect() },
                                  useStreaming: { model.useStreamingAnyway() })
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if !model.diagnosticLines.isEmpty {
                Text(model.diagnosticLines.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .padding(8)
                    .background(.black.opacity(0.7), in: .rect(cornerRadius: 6))
                    .foregroundStyle(.white)
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .allowsHitTesting(false)
                    .accessibilityLabel("Live picture diagnostics")
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// A session's phone panel: the snip popup beside its box, and the light Annotate popup at the
/// newest marker. Both are real popups that close only through their own Send or Cancel.
private struct PanelPopups: ViewModifier {
    let model: NativeSimulatorModel
    /// The live picture in the stage's coordinates.
    let picture: CGRect
    /// Where the stage sits in its window: the popups open on the side with room, never past the window.
    @State private var placement = NativePopupRoom.Placement()

    private struct MarkerAnchor: Identifiable { let id: Int }

    func body(content: Content) -> some View {
        if let tools = NativeSimPanelTools.of(model) {
            let snip = tools.snipBox.map { box in
                DeviceGeometry.viewRect(NormRect(x: box.minX, y: box.minY, width: box.width, height: box.height), in: picture)
            }
            let light = model.inspecting && !tools.annotateFull && !model.markers.isEmpty
            // The newest marker as it was made (it stays put while the screen is read again).
            let marker = model.markers.last.map { DeviceGeometry.viewRect($0.rect, in: picture) }
                ?? CGRect(x: picture.midX, y: picture.maxY - 40, width: 1, height: 1)
            content
                .background(NativePopupRoom { placement = $0 })
                .popover(isPresented: Binding(get: { snip != nil && model.shot != nil }, set: { _ in }),
                         attachmentAnchor: .rect(.rect(snip ?? .zero)), arrowEdge: placement.edge(for: snip ?? .zero, width: 320)) {
                    NativeSimSnipPopup(model: model, tools: tools)
                }
                .popover(item: Binding(get: { light ? MarkerAnchor(id: model.markers.count) : nil }, set: { _ in }),
                         attachmentAnchor: .rect(.rect(marker)), arrowEdge: placement.edge(for: marker, width: 330)) { _ in
                    NativeSimAnnotatePopup(model: model, tools: tools)
                }
                .onChange(of: model.shot == nil) { _, gone in if gone { tools.snipBox = nil } }
        } else {
            content
        }
    }
}

/// The highlight under the pointer, the chosen element, and the numbered markers,
/// over the live screen. Drawn from the tree only while it is of the screen as it is
/// now; while the picture moves they wait for the next reading.
private struct InspectorOverlay: View {
    let model: NativeSimulatorModel
    let fitted: CGRect

    var body: some View {
        let placements = model.placements
        let shown = model.highlightsShown
        let marked = Set(placements.compactMap(\.ref))
        Canvas { context, _ in
            let accent = Color.accentColor
            func rect(_ r: NormRect) -> CGRect { DeviceGeometry.viewRect(r, in: fitted) }

            if shown {
                // The element under the pointer, or a row under the pointer in the outline.
                for ref in [model.hoverRef, model.listHoverRef].compactMap({ $0 }) where !marked.contains(ref) {
                    guard let frame = model.node(ref)?.usableFrame else { continue }
                    let box = Path(roundedRect: rect(frame), cornerRadius: 3)
                    context.fill(box, with: .color(accent.opacity(0.14)))
                    context.stroke(box, with: .color(accent), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                }

                // The chosen one.
                if let ref = model.focusRef, !marked.contains(ref), let frame = model.node(ref)?.usableFrame {
                    let box = Path(roundedRect: rect(frame), cornerRadius: 3)
                    context.fill(box, with: .color(accent.opacity(0.10)))
                    context.stroke(box, with: .color(accent), lineWidth: 2)
                }
            }

            // Numbered markers still on this screen, drawn as the picture an agent receives draws them.
            for placement in placements {
                let box = rect(placement.rect)
                let focused = placement.ref != nil && placement.ref == model.focusRef
                context.stroke(Path(box), with: .color(.white.opacity(0.9)), lineWidth: focused ? 5 : 4)
                context.stroke(Path(box), with: .color(accent), lineWidth: focused ? 3 : 2)
                let radius: CGFloat = 10
                let centre = CGPoint(x: min(max(box.minX, fitted.minX + radius + 2), fitted.maxX - radius - 2),
                                     y: min(max(box.minY, fitted.minY + radius + 2), fitted.maxY - radius - 2))
                let disc = CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: disc.insetBy(dx: -1.5, dy: -1.5)), with: .color(.white.opacity(0.9)))
                context.fill(Path(ellipseIn: disc), with: .color(accent))
                context.draw(Text("\(placement.marker.n)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white), at: centre)
            }
        }
    }
}
