import AppKit
import SwiftUI
import TerminalDeckNativeCore

// The browser's three ways of pointing an agent at something, as the web
// browser has them: Annotate (numbered markers on the frozen page, a note, sent
// to a session), Draw (pen, box, arrow and text over a screenshot, then the Shot
// popover to copy or send it), and Record (the steps taken on the page, sent as
// one flow). Plus the address field's suggestions list.

// MARK: - Annotate

struct NativeBrowserAnnotateView: View {
    let tab: NativeBrowserTab
    let shot: NativeBrowserShot

    @State private var annotations: [BrowserAnnotation] = []
    @State private var focused: String?
    @State private var picking = false
    @State private var confirming = false
    @State private var roundID = "round-\(UUID().uuidString)"
    @State private var createdAt = Date().timeIntervalSince1970 * 1000

    /// The web's "over" layout: the frozen picture is the page's own rectangle,
    /// opaque, with the notes card floating over its right-hand edge.
    var body: some View {
        GeometryReader { geometry in
            let fit = NativeBrowserFit.size(shot.image.size, into: geometry.size)
            ZStack(alignment: .topLeading) {
                Image(nsImage: shot.image)
                    .resizable()
                    .frame(width: fit.width, height: fit.height)
                ForEach(annotations) { entry in
                    NativeBrowserMarker(entry: entry, size: fit, on: entry.id == focused)
                        .onTapGesture { focused = entry.id }
                }
            }
            .frame(width: fit.width, height: fit.height)
            .contentShape(.rect)
            .onTapGesture(coordinateSpace: .local) { location in
                add(x: location.x / fit.width, y: location.y / fit.height)
            }
            .overlay { if picking { ProgressView().controlSize(.small) } }
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .background(NativeBrowserFit.opaqueGround)
        .overlay(alignment: .topTrailing) {
            panel
                .frame(width: 320)
                .padding(12)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .onExitCommand(perform: leave)
        .onAppear {
            // Opened by a click on the live page (Annotate's picker): that element is marker 1.
            guard annotations.isEmpty, let first = tab.takeAnnotateStart() else { return }
            annotations = BrowserAnnotate.add([], first)
            focused = annotations.first?.id
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Annotate").font(.headline)
                Text(shot.url?.host() ?? shot.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Done", action: leave)
            }
            if confirming {
                HStack {
                    Text("Discard \(annotations.count) marker\(annotations.count == 1 ? "" : "s")?")
                    Spacer()
                    Button("Keep") { confirming = false }
                    Button("Discard", role: .destructive) { tab.markup = nil }
                }
                .font(.callout)
                .padding(8)
                .background(Color.red.opacity(0.1), in: .rect(cornerRadius: 6))
            }
            if annotations.isEmpty {
                Text("Click anything on the page to mark it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(annotations) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                NativeBrowserBadge(n: entry.n, size: 20)
                                Text(BrowserAnnotate.describe(entry.element))
                                    .font(.callout)
                                    .lineLimit(3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .help(BrowserAnnotate.describe(entry.element))
                                Button {
                                    annotations = BrowserAnnotate.remove(annotations, id: entry.id)
                                    if focused == entry.id { focused = nil }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .help("Delete")
                            }
                            .padding(6)
                            .background(entry.id == focused ? Color.accentColor.opacity(0.12) : .clear, in: .rect(cornerRadius: 6))
                            .onTapGesture { focused = entry.id }
                        }
                    }
                }
                .frame(maxHeight: min(280, CGFloat(annotations.count) * 46))
            }
            NativeBrowserSendRow(placeholder: "What should change?", needsText: true, multiline: true,
                                 notReady: annotations.isEmpty ? "Mark something on the page first." : "",
                                 makeLine: send) { session in
                let sentTo: [String: Any] = ["sessionId": session.id, "label": session.label]
                Task { _ = try? await EngineBridge.shared.invoke("annotate:sent", [roundID, sentTo]) }
                tab.markup = nil
            }
        }
        .padding(12)
        .background(.regularMaterial, in: .rect(cornerRadius: 12))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
    }

    private func add(x: Double, y: Double) {
        guard !picking else { return }
        confirming = false
        picking = true
        Task {
            defer { picking = false }
            let found = await tab.pick(x: x, y: y)
            let entry = BrowserAnnotation(rect: found?.rect ?? BrowserAnnotate.boxAround(x: x, y: y), element: found?.element)
            annotations = BrowserAnnotate.add(annotations, entry)
            focused = entry.id
        }
    }

    private func leave() {
        if !annotations.isEmpty && !confirming {
            confirming = true
            return
        }
        tab.markup = nil
    }

    /// Draw the markers on the picture, save it (the engine keeps the round, so
    /// agents can find it with devices.annotations), and write the line.
    private func send(_ note: String) async throws -> String {
        guard let drawn = NativeBrowserRender.annotated(shot.cgImage, annotations),
              let png = NSBitmapImageRep(cgImage: drawn).representation(using: .png, properties: [:]) else {
            throw BrowserDriverRefusal("The picture could not be saved, so nothing was sent.")
        }
        let url = shot.url?.absoluteString ?? ""
        let round = BrowserAnnotate.round(id: roundID, createdAt: createdAt, list: annotations, url: url, title: shot.title,
                                          note: note, width: drawn.width, height: drawn.height)
        var path = ""
        if EngineBridge.shared.isReady,
           let saved = try? await EngineBridge.shared.invoke("annotate:save", ["data:image/png;base64," + png.base64EncodedString(), round]) as? [String: Any],
           let kept = saved["path"] as? String {
            path = kept
        } else {
            var copy = NativeBrowserShot(image: NSImage(cgImage: drawn, size: .zero), cgImage: drawn, url: shot.url, title: shot.title)
            copy.marks = annotations.count
            path = (try? copy.saved(suffix: "-annotated"))?.path ?? ""
        }
        guard !path.isEmpty else { throw BrowserDriverRefusal("The picture could not be saved, so nothing was sent.") }
        return BrowserAnnotate.compose(annotations, url: url, title: shot.title, note: note,
                                       picturePath: path, width: drawn.width, height: drawn.height)
    }
}

struct NativeBrowserMarker: View {
    let entry: BrowserAnnotation
    let size: CGSize
    let on: Bool

    var body: some View {
        let box = CGRect(x: entry.rect.minX * size.width, y: entry.rect.minY * size.height,
                         width: max(entry.rect.width * size.width, 4), height: max(entry.rect.height * size.height, 4))
        ZStack(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(.white.opacity(0.9), lineWidth: on ? 5 : 4)
                .overlay(Rectangle().strokeBorder(Color.accentColor, lineWidth: on ? 3 : 2))
                .frame(width: box.width, height: box.height)
                .offset(x: box.minX, y: box.minY)
            NativeBrowserBadge(n: entry.n, size: 22)
                .offset(x: max(0, box.minX - 11), y: max(0, box.minY - 11))
        }
        .allowsHitTesting(true)
    }
}

struct NativeBrowserBadge: View {
    let n: Int
    let size: CGFloat

    var body: some View {
        Text("\(n)")
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color.accentColor, in: .circle)
            .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
    }
}

// MARK: - Draw

struct NativeBrowserDrawView: View {
    let tab: NativeBrowserTab
    let shot: NativeBrowserShot

    @State private var marks: [BrowserMark] = []
    @State private var live: BrowserMark?
    @State private var tool: BrowserMark.Kind = .free
    @State private var textAt: BrowserPoint?
    @State private var typing = ""
    @FocusState private var textFocused: Bool

    private static let tools: [(BrowserMark.Kind, String, String)] = [
        (.free, "Draw", "Freehand — circle the thing"),
        (.rect, "Box", "A rectangle round a region"),
        (.arrow, "Arrow", "Point at one thing"),
        (.text, "Text", "A few words on the picture"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Tool", selection: $tool) {
                    ForEach(Self.tools, id: \.0) { entry in
                        Text(entry.1).tag(entry.0).help(entry.2)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if marks.isEmpty {
                    Text("Nothing marked yet.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Undo") { _ = marks.popLast() }.disabled(marks.isEmpty)
                Button("Clear") { marks = [] }.disabled(marks.isEmpty)
                Button("Done") { tab.markup = nil }
                Button("Send…", action: finish)
                    .buttonStyle(.borderedProminent)
                    .disabled(marks.isEmpty)
                    .help(marks.isEmpty ? "Mark something on the page first." : "Save the marked page, then copy it or choose a session to send it to.")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
            Divider()

            GeometryReader { geometry in
                let fit = NativeBrowserFit.size(shot.image.size, into: geometry.size)
                ZStack(alignment: .topLeading) {
                    Image(nsImage: shot.image)
                        .resizable()
                        .frame(width: fit.width, height: fit.height)
                    Canvas { context, size in
                        NativeBrowserRender.paint(live.map { marks + [$0] } ?? marks, in: &context, size: size,
                                                  pixelWidth: Double(shot.width))
                    }
                    .frame(width: fit.width, height: fit.height)
                    if let textAt {
                        TextField("Text", text: $typing)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                            .focused($textFocused)
                            .onSubmit(commitText)
                            .onExitCommand { self.textAt = nil; typing = "" }
                            .offset(x: min(textAt.x * fit.width, fit.width - 200), y: textAt.y * fit.height - 12)
                    }
                }
                .frame(width: fit.width, height: fit.height)
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        guard tool != .text else { return }
                        let point = BrowserPoint(x: value.location.x / fit.width, y: value.location.y / fit.height)
                        live = live.map { BrowserMarks.extend($0, to: point) } ?? BrowserMarks.begin(tool, at: point)
                    }
                    .onEnded { value in
                        let point = BrowserPoint(x: value.location.x / fit.width, y: value.location.y / fit.height)
                        if tool == .text {
                            commitText()
                            textAt = BrowserMarks.onFrame(point)
                            typing = ""
                            textFocused = true
                            return
                        }
                        if let mark = live.map({ BrowserMarks.extend($0, to: point) }), BrowserMarks.isDrawn(mark) {
                            marks.append(mark)
                        }
                        live = nil
                    })
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
            .background(NativeBrowserFit.opaqueGround)
        }
        .background(NativeBrowserFit.opaqueGround)
    }

    private func commitText() {
        guard let at = textAt else { return }
        let mark = BrowserMarks.begin(.text, at: at, text: typing.trimmingCharacters(in: .whitespacesAndNewlines))
        if BrowserMarks.isDrawn(mark) { marks.append(mark) }
        textAt = nil
        typing = ""
    }

    private func finish() {
        commitText()
        guard let drawn = NativeBrowserRender.marked(shot.cgImage, marks) else { return }
        tab.finishDrawing(NSImage(cgImage: drawn, size: shot.image.size), cgImage: drawn, marks: marks.count, from: shot)
    }
}

// MARK: - Record

/// The flow being recorded: Stop, Copy, Clear, the steps, and the send row.
/// No step's value is ever shown for a password — it reads "the password".
struct NativeBrowserRecordPanel: View {
    let tab: NativeBrowserTab

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if tab.recording {
                    HStack(spacing: 5) {
                        Circle().fill(.red).frame(width: 8, height: 8)
                        Text("Recording").font(.callout.weight(.semibold))
                    }
                }
                if tab.steps.isEmpty {
                    Text(tab.recording ? "Use the page — every click, entry and navigation lands here." : "Nothing recorded yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if BrowserFlow.isFull(tab.steps) {
                    Text("stopped at the step limit").font(.callout).foregroundStyle(.orange)
                }
                Spacer()
                if tab.recording {
                    Button("Stop") { tab.toggleRecording() }
                }
                Button("Copy") { tab.copyFlow() }.disabled(tab.steps.isEmpty)
                Button("Clear") { tab.clearRecording() }.disabled(tab.steps.isEmpty)
                if !tab.recording {
                    // Put away; ⋮ ▸ Recorded flow brings it back (lane BR, the web's flow popup).
                    Button { tab.flowHidden = true } label: { Image(systemName: "xmark") }
                        .help("Close")
                        .accessibilityLabel("Close the recorded flow")
                }
            }
            if !tab.steps.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(tab.steps.enumerated()), id: \.offset) { index, step in
                            HStack(spacing: 8) {
                                Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    .frame(width: 22, alignment: .trailing)
                                Text(BrowserFlow.kindLabel(step.kind)).font(.callout.weight(.semibold))
                                Text(BrowserFlow.detail(step)).font(.callout).lineLimit(1)
                                if !step.selector.isEmpty {
                                    Text(step.selector).font(.caption.monospaced()).foregroundStyle(.secondary)
                                        .lineLimit(1).truncationMode(.middle).help(step.selector)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                .frame(maxHeight: 130)
                NativeBrowserSendRow(placeholder: "Anything to say about this flow?", action: "Send flow", autofocus: false) { instruction in
                    BrowserFlow.compose(instruction: instruction, steps: tab.steps)
                }
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// The badge in the corner of a page being recorded (the web recorder's own).
struct NativeBrowserRecordingBadge: View {
    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(.red).frame(width: 8, height: 8)
            Text("RECORDING").font(.system(size: 11, weight: .semibold)).tracking(0.6)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.background, in: .rect(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.6)))
        .padding(12)
        .allowsHitTesting(false)
    }
}

// MARK: - Address suggestions

/// "Earlier addresses": pages this profile has visited that match what is typed.
struct NativeBrowserSuggestions: View {
    let tab: NativeBrowserTab
    let open: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(tab.suggestions.enumerated()), id: \.element.url) { index, visit in
                Button {
                    open(visit.url)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "clock").foregroundStyle(.secondary).font(.caption)
                        Text(visit.label).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(visit.host).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(index == tab.suggestionCursor ? Color.accentColor.opacity(0.2) : .clear)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(visit.url)
            }
        }
        .padding(.vertical, 4)
        .background(.regularMaterial, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
    }
}

// MARK: - Drawing helpers

enum NativeBrowserFit {
    /// What sits under a frozen picture: solid, so the live page never shows through.
    static let opaqueGround = Color(nsColor: .windowBackgroundColor)

    /// `size` scaled to fit inside `room`, never larger than it is.
    static func size(_ size: CGSize, into room: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, room.width > 0, room.height > 0 else { return .zero }
        let scale = min(room.width / size.width, room.height / size.height, 1)
        return CGSize(width: (size.width * scale).rounded(.down), height: (size.height * scale).rounded(.down))
    }
}

enum NativeBrowserRender {
    private static let halo = NSColor(white: 1, alpha: 0.92)
    private static var accent: NSColor { .controlAccentColor }

    /// Marks on screen (SwiftUI), scaled from the picture's pixel width.
    static func paint(_ marks: [BrowserMark], in context: inout GraphicsContext, size: CGSize, pixelWidth: Double) {
        let scale = size.width / max(1, pixelWidth)
        let line = BrowserMarks.strokeWidth(pixelWidth) * scale
        for mark in marks {
            if mark.kind == .text, let at = mark.points.first {
                let point = CGPoint(x: at.x * size.width, y: at.y * size.height)
                let resolved = context.resolve(Text(mark.text)
                    .font(.system(size: BrowserMarks.textSize(pixelWidth) * scale, weight: .bold))
                    .foregroundStyle(Color(nsColor: accent)))
                let measured = resolved.measure(in: CGSize(width: size.width, height: size.height))
                let box = CGRect(x: point.x - 4, y: point.y - 2, width: measured.width + 8, height: measured.height + 4)
                context.fill(Path(roundedRect: box, cornerRadius: 4), with: .color(Color(nsColor: halo)))
                context.draw(resolved, at: point, anchor: .topLeading)
                continue
            }
            for (color, weight) in [(halo, line + max(2, (line * 0.9).rounded())), (accent, line)] {
                for points in BrowserMarks.paths(mark, width: size.width, height: size.height) where points.count >= 2 {
                    var path = Path()
                    path.move(to: CGPoint(x: points[0].x, y: points[0].y))
                    for p in points.dropFirst() { path.addLine(to: CGPoint(x: p.x, y: p.y)) }
                    context.stroke(path, with: .color(Color(nsColor: color)),
                                   style: StrokeStyle(lineWidth: weight, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    /// A context the size of the picture, with the picture in it and the
    /// coordinates turned top-down for marking.
    private static func canvas(_ image: CGImage, _ draw: (CGContext, Double, Double) -> Void) -> CGImage? {
        let width = image.width, height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        draw(context, Double(width), Double(height))
        NSGraphicsContext.current = previous
        return context.makeImage()
    }

    static func marked(_ image: CGImage, _ marks: [BrowserMark]) -> CGImage? {
        canvas(image) { context, width, height in
            let line = BrowserMarks.strokeWidth(width)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            for mark in marks {
                if mark.kind == .text, let at = mark.points.first {
                    let font = NSFont.systemFont(ofSize: BrowserMarks.textSize(width), weight: .bold)
                    let text = NSAttributedString(string: mark.text, attributes: [.font: font, .foregroundColor: accent])
                    let point = CGPoint(x: at.x * width, y: at.y * height)
                    let size = text.size()
                    context.setFillColor(halo.cgColor)
                    context.addPath(CGPath(roundedRect: CGRect(x: point.x - 4, y: point.y - 2, width: size.width + 8, height: size.height + 4),
                                           cornerWidth: 4, cornerHeight: 4, transform: nil))
                    context.fillPath()
                    text.draw(at: point)
                    continue
                }
                for (color, weight) in [(halo, line + max(2, (line * 0.9).rounded())), (accent, line)] {
                    context.setStrokeColor(color.cgColor)
                    context.setLineWidth(weight)
                    for points in BrowserMarks.paths(mark, width: width, height: height) where points.count >= 2 {
                        context.beginPath()
                        context.move(to: CGPoint(x: points[0].x, y: points[0].y))
                        for p in points.dropFirst() { context.addLine(to: CGPoint(x: p.x, y: p.y)) }
                        context.strokePath()
                    }
                }
            }
        }
    }

    static func annotated(_ image: CGImage, _ annotations: [BrowserAnnotation]) -> CGImage? {
        canvas(image) { context, width, height in
            for entry in annotations {
                let g = BrowserAnnotate.markerGeometry(entry.rect, width: width, height: height)
                for (color, weight) in [(halo, g.stroke + max(2, g.stroke)), (accent, g.stroke)] {
                    context.setStrokeColor(color.cgColor)
                    context.setLineWidth(weight)
                    context.stroke(g.box)
                }
                let r = g.radius
                context.setFillColor(halo.cgColor)
                context.fillEllipse(in: CGRect(x: g.badge.x - r - 1.5, y: g.badge.y - r - 1.5, width: 2 * r + 3, height: 2 * r + 3))
                context.setFillColor(accent.cgColor)
                context.fillEllipse(in: CGRect(x: g.badge.x - r, y: g.badge.y - r, width: 2 * r, height: 2 * r))
                let font = NSFont.systemFont(ofSize: (r * 1.15).rounded(), weight: .semibold)
                let number = NSAttributedString(string: "\(entry.n)", attributes: [.font: font, .foregroundColor: NSColor.white])
                let size = number.size()
                number.draw(at: CGPoint(x: g.badge.x - size.width / 2, y: g.badge.y - size.height / 2))
            }
        }
    }
}
