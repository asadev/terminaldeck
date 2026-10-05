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
/// hardware buttons, rotation, screenshots with Reveal and Send. Then the
/// inspector, which takes the place of the page's Annotate and keeps its
/// numbered markers and its one message.
struct NativeSimulatorScreen: View {
    @State private var model = NativeSimulatorModel()

    var body: some View {
        Group {
            if model.device != nil {
                DeviceOpenView(model: model)
            } else {
                SimulatorListView(model: model)
            }
        }
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

private struct SimulatorListView: View {
    let model: NativeSimulatorModel

    var body: some View {
        if let list = model.list {
            if !list.available {
                ContentUnavailableView {
                    Label("Simulators are not available here", systemImage: "iphone")
                } description: {
                    Text(list.reason)
                }
            } else if list.devices.isEmpty {
                ContentUnavailableView {
                    Label("No simulators or phones yet", systemImage: "iphone")
                } description: {
                    Text("Create a simulator in Xcode or an emulator in Android Studio, or plug in an Android phone, and it appears here.")
                }
            } else {
                rows(list)
            }
        } else {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                if !model.problem.isEmpty {
                    Text(model.problem).font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func rows(_ list: DeviceList) -> some View {
        List {
            if !model.problem.isEmpty {
                Text(model.problem)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            ForEach(list.groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.rows) { entry in
                        DeviceRow(entry: entry, model: model)
                    }
                }
            }
        }
        .listStyle(.inset)
    }
}

private struct DeviceRow: View {
    let entry: DeviceEntry
    let model: NativeSimulatorModel

    var body: some View {
        let working = model.busy[entry.id] ?? (model.opening == entry.id ? "Opening…" : "")
        HStack(spacing: 12) {
            Image(systemName: entry.platform == "ios" ? "iphone" : "smartphone")
                .font(.title2)
                .foregroundStyle(entry.available ? .primary : .secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name).font(.body.weight(.medium))
                Text(entry.subLine).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !working.isEmpty {
                Text(working).font(.callout).foregroundStyle(.secondary)
            } else if entry.available {
                Button("Open") { Task { await model.open(entry.id) } }
            } else if entry.canBoot {
                Button("Start") { Task { await model.start(entry) } }
            }
        }
        .padding(.vertical, 4)
        .contentShape(.rect)
        .onTapGesture(count: 2) {
            if entry.available { Task { await model.open(entry.id) } }
        }
    }
}

// MARK: - One device open

private struct DeviceOpenView: View {
    @Bindable var model: NativeSimulatorModel

    var body: some View {
        VStack(spacing: 0) {
            DeviceToolbar(model: model)
            Divider()
            if !model.problem.isEmpty || !model.said.isEmpty {
                StatusLine(problem: model.problem, said: model.said)
            }
            HStack(spacing: 0) {
                DeviceStage(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.inspecting {
                    Divider()
                    InspectorPanel(model: model)
                        .frame(width: 350)
                }
            }
        }
        .alert(discardTitle, isPresented: $model.confirmingDiscard) {
            Button("Keep", role: .cancel) {}
            Button("Discard", role: .destructive) { model.stopInspecting() }
        }
    }

    private var discardTitle: String {
        "Discard \(model.markers.count) marker\(model.markers.count == 1 ? "" : "s")?"
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
    @State private var shotShown = false

    var body: some View {
        let device = model.device
        let frozen = model.isFrozen
        HStack(spacing: 6) {
            Button {
                model.back()
            } label: {
                Label("Devices", systemImage: "chevron.backward")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderless)

            Text(device?.name ?? "")
                .font(.headline)
                .lineLimit(1)
                .padding(.leading, 6)
                .help(model.diagnostics ? "Option-click to hide the diagnostics" : "")
                .onTapGesture {
                    // For measuring, not for everyday use, so it has no button of its own.
                    if NSEvent.modifierFlags.contains(.option) { model.diagnostics.toggle() }
                }

            Spacer(minLength: 12)

            if let device {
                Group {
                    if device.buttons.contains("home") { tool("Home", "house") { model.button("home") } }
                    if device.buttons.contains("back") { tool("Back", "arrow.backward") { model.button("back") } }
                    if device.buttons.contains("overview") { tool("Recent apps", "square.on.square") { model.button("overview") } }
                    if device.buttons.contains("lock") { tool("Lock", "lock") { model.button("lock") } }
                    if device.buttons.contains("volume-up") { tool("Volume up", "speaker.plus") { model.button("volume-up") } }
                    if device.buttons.contains("volume-down") { tool("Volume down", "speaker.minus") { model.button("volume-down") } }
                    if device.canRotate { tool("Rotate", "rotate.right") { Task { await model.rotate() } } }
                }
                .disabled(frozen)

                tool("Screenshot", "camera") {
                    Task {
                        await model.screenshot()
                        shotShown = model.shot != nil
                    }
                }
                .disabled(frozen)
                .popover(isPresented: $shotShown, arrowEdge: .bottom) {
                    ShotPopover(model: model, shown: $shotShown)
                }

                Toggle(isOn: Binding(get: { model.inspecting }, set: { _ in model.toggleInspect() })) {
                    Label("Inspect", systemImage: "scope")
                        .labelStyle(.titleAndIcon)
                }
                .toggleStyle(.button)
                .help("Inspect: point at elements, check them, and send them to a session")

                if !device.isPhysical {
                    tool("Shut down", "power") { Task { await model.shutDown() } }
                        .disabled(frozen)
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
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - The stage: the live screen and what is drawn over it

private struct DeviceStage: View {
    let model: NativeSimulatorModel

    var body: some View {
        GeometryReader { geometry in
            let fitted = DeviceGeometry.fitted(content: model.fitSize ?? geometry.size, in: geometry.size)
            ZStack(alignment: .topLeading) {
                DeviceScreenSurface(model: model)

                if model.isFrozen, let snapshot = model.snapshot {
                    Image(nsImage: snapshot.image)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: fitted.width, height: fitted.height)
                        .offset(x: fitted.minX, y: fitted.minY)
                        .allowsHitTesting(false)
                }

                if model.inspecting {
                    InspectorOverlay(model: model, fitted: fitted)
                        .allowsHitTesting(false)
                }

                if model.videoSize == nil && !model.isFrozen {
                    Text("Starting the live picture…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(false)
                }

                if model.inspecting {
                    InspectBadge(model: model)
                        .padding(10)
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
        }
        .padding(12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(model.device?.name ?? "Device") screen. Click to tap, drag to swipe, type to type.")
    }
}

/// What the stage says while inspecting: reading, frozen, or a problem.
private struct InspectBadge: View {
    let model: NativeSimulatorModel

    var body: some View {
        let words: String? = {
            if model.isFrozen { return "Frozen while marking" }
            if model.reading && model.snapshot == nil { return "Reading the screen's elements…" }
            if !model.readProblem.isEmpty { return model.readProblem }
            return nil
        }()
        if let words {
            HStack(spacing: 8) {
                Text(words).font(.caption.weight(.medium))
                if model.isFrozen {
                    Button("Clear") { model.clearMarkers() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: .capsule)
        }
    }
}

/// The highlight under the pointer, the chosen element, and the numbered markers, over the screen.
private struct InspectorOverlay: View {
    let model: NativeSimulatorModel
    let fitted: CGRect

    var body: some View {
        Canvas { context, _ in
            let accent = Color.accentColor
            func rect(_ r: NormRect) -> CGRect { DeviceGeometry.viewRect(r, in: fitted) }

            // The element under the pointer, or a row under the pointer in the outline.
            for ref in [model.hoverRef, model.listHoverRef].compactMap({ $0 }) where model.marker(for: ref) == nil {
                guard let frame = model.node(ref)?.usableFrame else { continue }
                let box = Path(roundedRect: rect(frame), cornerRadius: 3)
                context.fill(box, with: .color(accent.opacity(0.14)))
                context.stroke(box, with: .color(accent), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            }

            // The chosen one.
            if let ref = model.focusRef, model.marker(for: ref) == nil, let frame = model.node(ref)?.usableFrame {
                let box = Path(roundedRect: rect(frame), cornerRadius: 3)
                context.fill(box, with: .color(accent.opacity(0.10)))
                context.stroke(box, with: .color(accent), lineWidth: 2)
            }

            // Numbered markers, drawn as the picture an agent receives draws them.
            for entry in model.markers {
                let box = rect(entry.rect)
                let focused = entry.nodeRef != nil && entry.nodeRef == model.focusRef
                context.stroke(Path(box), with: .color(.white.opacity(0.9)), lineWidth: focused ? 5 : 4)
                context.stroke(Path(box), with: .color(accent), lineWidth: focused ? 3 : 2)
                let radius: CGFloat = 10
                let centre = CGPoint(x: min(max(box.minX, fitted.minX + radius + 2), fitted.maxX - radius - 2),
                                     y: min(max(box.minY, fitted.minY + radius + 2), fitted.maxY - radius - 2))
                let disc = CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: disc.insetBy(dx: -1.5, dy: -1.5)), with: .color(.white.opacity(0.9)))
                context.fill(Path(ellipseIn: disc), with: .color(accent))
                context.draw(Text("\(entry.n)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white), at: centre)
            }
        }
    }
}
