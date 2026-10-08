import AppKit
import SwiftUI
import TerminalDeckNativeCore

/// Inspect's card beside the live screen, in the order of the page's Annotate
/// (`AnnotateSurface.tsx`): the head with Done, the discard question, the notice,
/// the numbered markers (ones whose screen has moved on keep a thumbnail of the
/// frame they were made on), then what the pointer is on, the element outline and
/// the quick checks — all from the latest live reading — and at the foot the one
/// note and the session it goes to.
struct InspectPanel: View {
    @Bindable var model: NativeSimulatorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if model.confirmingDiscard {
                HStack(spacing: 8) {
                    Text("Discard \(model.markers.count) marker\(model.markers.count == 1 ? "" : "s")?")
                    Spacer(minLength: 4)
                    Button("Keep") { model.confirmingDiscard = false }
                        .buttonStyle(.borderless)
                    Button("Discard", role: .destructive) { model.stopInspecting() }
                }
                .font(.callout)
                .accessibilityAddTraits(.isModal)
            }
            if let latest = model.latest, latest.frozen.tree == nil {
                Text("This screen did not describe its elements, so markers are placed by position.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            MarkerList(model: model)
            VStack(spacing: 8) {
                Picker("Section", selection: $model.section) {
                    ForEach(NativeSimulatorModel.InspectorSection.allCases) { section in
                        Text(title(section)).tag(section)
                    }
                }
                .pickerStyle(.segmented).nativeUIGGreyControl()
                .labelsHidden()
                Group {
                    switch model.section {
                    case .element: ElementDetails(model: model)
                    case .outline: ElementOutline(model: model)
                    case .checks: ChecksList(model: model)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
            SendBox(model: model)
        }
        .padding(12)
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspect")
    }

    private func title(_ section: NativeSimulatorModel.InspectorSection) -> String {
        if section == .checks, model.latest?.root != nil {
            return model.findings.isEmpty ? "Checks" : "Checks (\(model.findings.count))"
        }
        return section.rawValue
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Inspect").font(.headline)
            let place = model.latest?.frozen.where_.short ?? model.device?.name ?? ""
            Text(place)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(place)
            Spacer(minLength: 4)
            if model.reading {
                ProgressView().controlSize(.small)
            }
            Button {
                model.readAgain()
            } label: {
                Label("Read again", systemImage: "arrow.clockwise")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(model.reading)
            .help("Read the live screen's elements again now")
            Button("Done") { model.leaveInspect() }
        }
    }
}

/// The numbered markers, or the one line that says how to make one. A marker whose
/// element is not on the screen now stays here with a thumbnail of its frame.
private struct MarkerList: View {
    let model: NativeSimulatorModel

    var body: some View {
        if model.liveMarkers.isEmpty {
            Text("Click anything on the live screen to mark it.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            let drawn = Set(model.placements.map(\.marker.id))
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.liveMarkers) { marker in
                        let entry = marker.annotation
                        let ref = model.markerRefs[marker.id]
                        let on = ref != nil && ref == model.focusRef
                        let away = !drawn.contains(marker.id)
                        HStack(spacing: 8) {
                            MarkerBadge(n: entry.n)
                            if away, let thumbnail = model.thumbnail(for: marker) {
                                MarkerThumbnail(image: thumbnail, rect: entry.rect)
                                    .help("Marked on an earlier screen")
                            }
                            Text(Handoff.describeElement(entry.element))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(away ? Color.secondary : Color.primary)
                                .help(Handoff.describeElement(entry.element))
                            Spacer(minLength: 4)
                            Button {
                                model.unmark(entry.id)
                            } label: {
                                Label("Delete marker \(entry.n)", systemImage: "trash")
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Delete")
                        }
                        .font(.callout)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(on ? Color.accentColor.opacity(0.14) : .clear, in: .rect(cornerRadius: 6))
                        .contentShape(.rect)
                        .onTapGesture { if let ref { model.focus(ref, reveal: true) } }
                    }
                }
            }
            .frame(maxHeight: 160)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The frame a marker was made on, small, with its box.
private struct MarkerThumbnail: View {
    let image: NSImage
    let rect: NormRect

    var body: some View {
        let size = image.size
        let height: CGFloat = 36
        let width = size.height > 0 ? max(16, min(64, height * size.width / size.height)) : height
        Image(nsImage: image)
            .resizable()
            .interpolation(.medium)
            .frame(width: width, height: height)
            .overlay(alignment: .topLeading) {
                Rectangle()
                    .stroke(Color.accentColor, lineWidth: 1.5)
                    .frame(width: max(3, CGFloat(rect.width) * width), height: max(3, CGFloat(rect.height) * height))
                    .offset(x: CGFloat(rect.x) * width, y: CGFloat(rect.y) * height)
            }
            .clipShape(.rect(cornerRadius: 3))
            .accessibilityHidden(true)
    }
}

// MARK: - The element's details

private struct ElementDetails: View {
    let model: NativeSimulatorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let latest = model.latest, latest.frozen.tree == nil {
                    Text(latest.frozen.treeError.isEmpty
                         ? "This screen did not describe its elements, so markers are placed by position."
                         : "This screen did not describe its elements (\(latest.frozen.treeError)), so markers are placed by position.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if let node = model.detailNode {
                    details(node)
                } else {
                    Text(model.latest == nil ? (model.readProblem.isEmpty ? "Reading the live screen's elements…" : model.readProblem)
                         : "Point at something on the live screen, or choose it in the outline.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
    }

    @ViewBuilder
    private func details(_ node: DeviceNode) -> some View {
        let name = DeviceTreeQuery.nodeName(node)
        let role = DeviceTreeQuery.plainRole(node.role)
        VStack(alignment: .leading, spacing: 2) {
            Text(name.isEmpty ? "(no name)" : name)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
            Text(role.isEmpty ? "element" : role).foregroundStyle(.secondary)
        }

        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
            row("Label", node.label)
            row("Value", node.valueRedacted ? "hidden (a password)" : node.value)
            row("Role", node.role.map { role.isEmpty ? $0 : "\(role)  ·  \($0)" })
            row("Traits", traits(node))
            row("Identifier", node.identifier ?? node.testID)
            row("Title", node.title)
            row("Text", node.text)
            row("Placeholder", node.placeholder)
            row("Frame", frame(node))
            row("Component", node.component)
            row("Source", node.sourceLocation?.text)
            if !node.componentPath.isEmpty { row("Path", node.componentPath.joined(separator: " › ")) }
        }
        .font(.callout)

        let problems = model.findings.filter { $0.ref == node.ref }
        if !problems.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(problems) { finding in
                    Label(finding.sentence(minimum: minimum, unit: unit), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
        }

        HStack {
            let marked = model.marker(for: node.ref)
            Button(marked == nil ? "Mark" : "Unmark #\(marked!.n)") { model.toggleMark(node.ref) }
        }
        .controlSize(.small)
    }

    private var minimum: Double { DeviceChecks.minimumTarget(platform: model.device?.platform ?? "ios") }
    private var unit: String { model.device?.platform == "android" ? "dp" : "pt" }

    @ViewBuilder
    private func row(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                Text(value).textSelection(.enabled).lineLimit(6)
            }
        }
    }

    private func traits(_ node: DeviceNode) -> String {
        var words: [String] = []
        if DeviceChecks.isInteractive(node) { words.append("interactive") }
        if node.enabled == false { words.append("not enabled") }
        if node.focused == true { words.append("focused") }
        if node.hidden == true { words.append("hidden") }
        if node.valueRedacted { words.append("secure") }
        return words.joined(separator: ", ")
    }

    private func frame(_ node: DeviceNode) -> String? {
        guard let rect = node.usableFrame else { return nil }
        let percent = String(format: "%.0f%%, %.0f%% · %.0f%% × %.0f%%", rect.x * 100, rect.y * 100, rect.width * 100, rect.height * 100)
        guard let points = model.latest?.points else { return percent }
        let w = Double(points.width), h = Double(points.height)
        return String(format: "x %.0f, y %.0f · %.0f × %.0f %@\n%@", rect.x * w, rect.y * h, rect.width * w, rect.height * h, unit, percent)
    }
}

// MARK: - The outline

private struct ElementOutline: View {
    @Bindable var model: NativeSimulatorModel

    var body: some View {
        if let root = model.latest?.root {
            let rows = DeviceTreeQuery.outlineRows(root, expanded: model.expanded)
            ScrollViewReader { proxy in
                List(rows, selection: Binding(get: { model.focusRef }, set: { ref in
                    if let ref { model.focus(ref, reveal: false) } else { model.focusRef = nil }
                })) { row in
                    OutlineRowView(model: model, row: row)
                        .tag(row.node.ref)
                        .id(row.node.ref)
                }
                .listStyle(.inset)
                .onChange(of: model.revealTick) {
                    if let ref = model.focusRef { withAnimation { proxy.scrollTo(ref, anchor: .center) } }
                }
                .onAppear {
                    if let ref = model.focusRef { proxy.scrollTo(ref, anchor: .center) }
                }
            }
        } else {
            Text(model.latest == nil ? "Reading the live screen's elements…" : "This screen did not describe its elements.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct OutlineRowView: View {
    let model: NativeSimulatorModel
    let row: DeviceTreeQuery.OutlineRow

    var body: some View {
        let node = row.node
        let name = DeviceTreeQuery.nodeName(node)
        let role = DeviceTreeQuery.plainRole(node.role)
        let open = model.expanded.contains(node.ref)
        HStack(spacing: 4) {
            Color.clear.frame(width: CGFloat(min(row.depth, 24)) * 12, height: 1)
            if row.hasChildren {
                Button {
                    if open { model.expanded.remove(node.ref) } else { model.expanded.insert(node.ref) }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            } else {
                Color.clear.frame(width: 12, height: 1)
            }
            Text(role.isEmpty ? "element" : role)
                .foregroundStyle(.secondary)
            if !name.isEmpty {
                Text("\"\(name)\"").lineLimit(1)
            }
            Spacer(minLength: 4)
            if model.findings.contains(where: { $0.ref == node.ref }) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
                    .help("This element has a problem — see Checks")
            }
            if let marker = model.marker(for: node.ref) {
                MarkerBadge(n: marker.n)
            }
        }
        .font(.callout)
        .opacity(node.hidden == true ? 0.5 : 1)
        .contentShape(.rect)
        .onHover { inside in
            if inside { model.listHoverRef = node.ref } else if model.listHoverRef == node.ref { model.listHoverRef = nil }
        }
        .contextMenu {
            Button(model.marker(for: node.ref) == nil ? "Mark" : "Unmark") { model.toggleMark(node.ref) }
        }
    }
}

// MARK: - Quick checks

private struct ChecksList: View {
    let model: NativeSimulatorModel

    var body: some View {
        if let latest = model.latest, latest.root != nil {
            let unit = model.device?.platform == "android" ? "dp" : "pt"
            let minimum = DeviceChecks.minimumTarget(platform: model.device?.platform ?? "ios")
            let labels = model.findings.filter { $0.kind == .missingLabel }.count
            let sizes = model.findings.count - labels
            List {
                Section {
                    Text(summary(labels: labels, sizes: sizes))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if latest.points == nil {
                        Text("The tap-size check needs the screen's size in points, which this device did not report.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(model.findings) { finding in
                    Button {
                        model.focus(finding.ref, reveal: true)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: finding.kind == .missingLabel ? "text.badge.xmark" : "hand.tap")
                                .foregroundStyle(.orange)
                                .frame(width: 18)
                            Text(finding.sentence(minimum: minimum, unit: unit))
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 0)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(model.focusRef == finding.ref ? Color.accentColor.opacity(0.15) : Color.clear)
                    .onHover { inside in
                        if inside { model.listHoverRef = finding.ref } else if model.listHoverRef == finding.ref { model.listHoverRef = nil }
                    }
                }
            }
            .listStyle(.inset)
        } else {
            Text(model.latest == nil ? "Reading the live screen's elements…" : "This screen did not describe its elements, so nothing can be checked.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func summary(labels: Int, sizes: Int) -> String {
        if labels == 0 && sizes == 0 { return "Nothing found: every control on this screen has a label and room for a finger." }
        var parts: [String] = []
        if labels > 0 { parts.append("\(labels) without a label") }
        if sizes > 0 { parts.append("\(sizes) too small to tap comfortably") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Sending

/// The page's `SendToAgent` at the foot of the card: To, the one note, Send.
private struct SendBox: View {
    @Bindable var model: NativeSimulatorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SessionPicker(model: model)
            TextField("What should change?", text: $model.note, axis: .vertical)
                .lineLimit(2...6)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Message for the agent")
                // Return sends; Shift-Return is a new line.
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
                Button(model.sending ? "Sending…" : "Send") { Task { await model.sendRound() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canSendRound || model.sending)
                    .help(model.sendRoundHint)
            }
        }
    }
}

/// The session a send goes to. Nothing is ever chosen for the person.
struct SessionPicker: View {
    @Bindable var model: NativeSimulatorModel

    var body: some View {
        Picker("To", selection: $model.chosenSessionId) {
            Text("Choose a session…").tag("")
            ForEach(model.sessions) { session in
                Text(session.ended ? "\(session.label) (exited)" : session.label)
                    .tag(session.id)
                    .selectionDisabled(session.ended)
            }
        }
        .disabled(!model.sessionsAvailable || model.sessions.isEmpty)
    }
}

private struct MarkerBadge: View {
    let n: Int

    var body: some View {
        Text("\(n)")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .frame(minWidth: 18, minHeight: 18)
            .background(Color.accentColor, in: .circle)
            .accessibilityLabel("Marker \(n)")
    }
}

// MARK: - The screenshot, with Reveal and Send

struct ShotPopover: View {
    @Bindable var model: NativeSimulatorModel
    @Binding var shown: Bool

    var body: some View {
        if let state = model.shot {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Screenshot").font(.headline)
                    Spacer()
                    Text("\(state.shot.width) × \(state.shot.height)").foregroundStyle(.secondary)
                }
                if let preview = state.preview {
                    Image(nsImage: preview)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 300, maxHeight: 380)
                        .clipShape(.rect(cornerRadius: 8))
                        .accessibilityLabel("\(model.device?.name ?? "The device")'s screen, \(state.shot.width) by \(state.shot.height) pixels")
                } else {
                    Text("Saved, but this build could not make a preview of it.").foregroundStyle(.secondary)
                }
                HStack {
                    Text((state.shot.path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(state.shot.path)
                    Spacer()
                    Button("Reveal") { model.revealShot() }
                        .buttonStyle(.borderless)
                }
                SessionPicker(model: model)
                TextField("What should the agent look at?", text: Binding(
                    get: { model.shot?.instruction ?? "" },
                    set: { model.shot?.instruction = $0; model.shot?.problem = "" }))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.sendShot() } }
                HStack {
                    let line = !state.problem.isEmpty ? state.problem : model.sessionReason
                    if !line.isEmpty {
                        Text(line).font(.caption).foregroundStyle(state.problem.isEmpty ? Color.secondary : Color.red)
                    }
                    Spacer()
                    Button(state.sending ? "Sending…" : "Send") { Task { await model.sendShot() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.target == nil || state.sending)
                }
            }
            .padding(14)
            .frame(width: 330)
        }
    }
}

// MARK: - The picture an agent receives

/// A kept live frame with its numbered markers burnt in, at the picture's own
/// resolution — `marked-picture.ts`, drawn with Core Graphics. The message names
/// each marker by its number, so the file has to carry the numbers.
enum MarkedPicture {
    static func draw(_ image: CGImage, markers: [Annotation]) -> (png: Data, width: Int, height: Int)? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Top-left origin from here on, like the normalised rectangles.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)

        let accent = (NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue).cgColor
        let halo = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.current = previous }

        for entry in markers {
            let geometry = MarkerGeometry(rect: entry.rect, width: Double(width), height: Double(height))
            for (colour, weight) in [(halo, geometry.stroke + max(2, geometry.stroke)), (accent, geometry.stroke)] {
                context.setStrokeColor(colour)
                context.setLineWidth(weight)
                context.stroke(geometry.box)
            }
            let r = geometry.badgeRadius
            let c = geometry.badgeCentre
            let outer = r + max(1, geometry.stroke / 2)
            context.setFillColor(halo)
            context.fillEllipse(in: CGRect(x: c.x - outer, y: c.y - outer, width: outer * 2, height: outer * 2))
            context.setFillColor(accent)
            context.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            let label = "\(entry.n)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: (r * 1.15).rounded(), weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let size = label.size(withAttributes: attributes)
            label.draw(at: CGPoint(x: c.x - size.width / 2, y: c.y - size.height / 2 + 0.5), withAttributes: attributes)
        }

        guard let out = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:]) else { return nil }
        return (png, width, height)
    }
}
