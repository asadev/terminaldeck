import AppKit
import AVFoundation
import AVKit
import Observation
import SwiftUI
import TerminalDeckNativeCore

/// Record, in a session's phone panel: the session simulator's own recorder (simctl recordVideo,
/// through `session-simulator:record`) takes the screen. Two ways, chosen by "Talk while
/// recording" beside Record (lane NARR):
///   - on: his voice from the Mac's microphone, written as he speaks (the caption strip),
///     a segment per screen with its picture. Send gives the session the pictures and his
///     words per screen; the video stays on the Mac and is only named.
///   - off: a plain video, no microphone. Send gives the session the video as it is.
/// Then a card like the Screenshot card: what will be sent, the overall note, Send.
@MainActor @Observable final class NativeSimRecorder {
    enum Phase: Equatable { case idle, starting, recording(Date), stopping }

    struct Clip {
        /// What Send sends: the recording, or its cropped copy.
        var path: String
        var info: NativeSimRecordingMedia.Info
        /// The recording as made, for cropping again and for Reset.
        let original: String
        let originalInfo: NativeSimRecordingMedia.Info
        let poster: CGImage?
        /// His voice on its own (talk on), laid under the video.
        let narration: URL?
        /// Talk while recording: the screens with his words. Nil for a plain video.
        let narrated: NativeNarration?
        var applied = NativeShotCrop.full
        var instruction = ""
        var problem = ""
        var sending = false
        var working = ""
    }

    var phase: Phase = .idle
    var clip: Clip?
    var cardShown = false
    var problem = ""
    /// The narration of the recording running now (talk on).
    private(set) var live: NativeNarration?
    let settings: NativeNarrationSettings

    let model: NativeSimulatorModel
    @ObservationIgnored private let record: (String) async throws -> Any

    /// One recorder per session panel, found by its device view. U143 (#195): held weakly; the panel
    /// keeps its recorder, so a closed panel's device view and recorder go with it.
    private struct Held { weak var recorder: NativeSimRecorder? }
    private static var byModel: [ObjectIdentifier: Held] = [:]
    static func of(_ model: NativeSimulatorModel) -> NativeSimRecorder? { byModel[ObjectIdentifier(model)]?.recorder }

    @discardableResult
    static func attach(to model: NativeSimulatorModel, record: @escaping (String) async throws -> Any) -> NativeSimRecorder {
        let recorder = NativeSimRecorder(model: model, record: record)
        byModel = byModel.filter { $0.value.recorder != nil }
        byModel[ObjectIdentifier(model)] = Held(recorder: recorder)
        return recorder
    }

    private init(model: NativeSimulatorModel, record: @escaping (String) async throws -> Any,
                 settings: NativeNarrationSettings = .shared) {
        self.model = model; self.record = record; self.settings = settings
    }

    /// A recorder holding a finished clip — for the card's offscreen pictures.
    static func fixture(model: NativeSimulatorModel, clip: Clip, settings: NativeNarrationSettings = .shared) -> NativeSimRecorder {
        let recorder = NativeSimRecorder(model: model, record: { _ in NSNull() }, settings: settings)
        recorder.clip = clip
        return recorder
    }

    var isRecording: Bool { if case .recording = phase { true } else { false } }
    /// An iOS Simulator (simctl recordVideo), or an Android emulator or phone (adb screenrecord, in segments).
    var canRecord: Bool {
        guard let device = model.device else { return false }
        return device.platform == "android" || !device.isPhysical
    }

    func toggle() {
        // A finished recording not yet sent or cancelled comes back as it was.
        if phase == .idle, clip != nil { cardShown = true; return }
        switch phase {
        case .idle: Task { await start() }
        case .recording: Task { await stop() }
        case .starting, .stopping: break
        }
    }

    func start() async {
        guard phase == .idle else { return }
        phase = .starting; problem = ""
        // Talk on: the microphone and the words start first, so his first word is kept.
        var narration: NativeNarration?
        if settings.talking { // no microphone: a plain video, nothing to complain about (the switch is greyed)
            let listening = NativeNarration()
            do {
                try await listening.listen(model: model, settings: settings)
                narration = listening
            } catch {
                listening.abandon()
                problem = "Recording without your voice: \(Self.sentence(error))"
            }
        }
        do {
            let answer = try await record("start")
            let path = (answer as? [String: Any])?["path"] as? String
            let folder = path.map { URL(fileURLWithPath: $0).deletingLastPathComponent()
                .appendingPathComponent("narration-\(UUID().uuidString)") }
            narration?.videoStarted(folder: folder)
            live = narration
            phase = .recording(Date())
        } catch {
            narration?.abandon()
            phase = .idle
            problem = Self.sentence(error)
        }
    }

    func stop() async {
        guard isRecording else { return }
        phase = .stopping
        let narration = live
        live = nil
        // The words finish while the recorder saves the video.
        async let heard = narration?.stop()
        do {
            let answer = try await record("stop")
            guard let path = (answer as? [String: Any])?["path"] as? String else { throw Self.failure("The recorder did not say where the video is.") }
            var video = URL(fileURLWithPath: path)
            let voice = await heard
            if let audio = voice?.audio {
                // His voice under the picture, saved over the recording itself.
                let mixed = video.deletingLastPathComponent().appendingPathComponent(".\(video.lastPathComponent).mixing.mp4")
                do {
                    try await NativeSimRecordingMedia.addAudio(video: video, audio: audio, to: mixed, lead: voice?.lead ?? 0)
                    _ = try FileManager.default.replaceItemAt(video, withItemAt: mixed)
                } catch {
                    try? FileManager.default.removeItem(at: mixed)
                    problem = "The video was saved without your voice: \(Self.sentence(error))"
                }
            }
            video = URL(fileURLWithPath: path)
            let named = Self.friendlyName(for: video)
            if (try? FileManager.default.moveItem(at: video, to: named)) != nil { video = named }
            narration?.moveFolder(beside: video)
            let info = try await NativeSimRecordingMedia.info(video)
            clip = Clip(path: video.path, info: info, original: video.path, originalInfo: info,
                        poster: await NativeSimRecordingMedia.poster(video), narration: voice?.audio, narrated: narration)
            cardShown = true
        } catch {
            _ = await heard
            narration?.discard()
            problem = Self.sentence(error)
        }
        phase = .idle
    }

    // MARK: The card

    func cancel() {
        if let narration = clip?.narration { try? FileManager.default.removeItem(at: narration) }
        clip?.narrated?.discard()
        clip = nil; cardShown = false
    }

    func applyCrop(_ crop: CGRect) async {
        guard var current = clip else { return }
        if NativeShotCrop.isFull(crop) { resetCrop(); return }
        current.working = "Cropping…"; clip = current
        let original = URL(fileURLWithPath: current.original)
        let out = original.deletingPathExtension().appendingPathExtension("cropped.mp4")
        let pixels = NativeShotCrop.pixels(crop, width: current.originalInfo.width, height: current.originalInfo.height)
        do {
            try await NativeSimRecordingMedia.crop(video: original, to: pixels, output: out)
            current.path = out.path
            current.info = try await NativeSimRecordingMedia.info(out)
            current.applied = crop; current.problem = ""
        } catch {
            current.problem = "The video could not be cropped: \(Self.sentence(error))"
        }
        current.working = ""
        clip = current
    }

    func resetCrop() {
        guard var current = clip else { return }
        current.path = current.original; current.info = current.originalInfo; current.applied = NativeShotCrop.full
        clip = current
    }

    func send() async {
        guard var current = clip, !current.sending else { return }
        let destination = model.feedbackTargetID
        let revision = model.attachmentRevision
        current.sending = true; current.problem = ""; clip = current
        await model.loadSessions()
        let toHoot = model.sendToHoot
        let target = model.target
        guard revision == model.attachmentRevision, destination == model.feedbackTargetID, model.canSendFeedback else {
            current.sending = false
            current.problem = model.sessionReason.isEmpty ? "The destination or attached device changed. Nothing was sent." : model.sessionReason
            clip = current; return
        }
        current.sending = true; current.problem = ""; clip = current
        let line = Self.message(current, device: model.device)
        if toHoot {
            do {
                let images: [Data]
                if let narrated = current.narrated {
                    images = try narrated.timeline.segments.map { segment in
                        guard let path = segment.keyframe else { throw Self.failure("A recorded screen has no picture. Nothing was sent.") }
                        return try Data(contentsOf: URL(fileURLWithPath: path))
                    }
                } else {
                    var poster = current.path == current.original ? current.poster : nil
                    if poster == nil { poster = await NativeSimRecordingMedia.poster(URL(fileURLWithPath: current.path)) }
                    guard let poster, let png = NSBitmapImageRep(cgImage: poster).representation(using: .png, properties: [:]) else {
                        throw Self.failure("The recording preview could not be made. Nothing was sent.")
                    }
                    images = [png]
                }
                let message = current.narrated == nil ? line + "\nThe attached picture is a video preview. The full video stays at the named path." : line
                try await model.sendFeedbackToHoot(message, images: images, revision: revision,
                    source: .object([.init("path", .string(current.narrated == nil ? current.path : current.original)),
                        .init("noteCount", .number(Double(current.narrated?.timeline.segments.count ?? (current.instruction.isEmpty ? 0 : 1))))]))
            } catch { current.sending = false; current.problem = Self.sentence(error); clip = current; return }
        } else if let target, let refusal = await model.write(line, to: target, revision: revision) {
            current.sending = false; current.problem = refusal; clip = current; return
        }
        cancelKeepingFiles()
    }

    func copyPreview() {
        guard let clip else { return }
        Task {
            let image = await NativeSimRecordingMedia.poster(URL(fileURLWithPath: clip.path)) ?? clip.poster
            guard let image else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([NSImage(cgImage: image, size: .zero)])
        }
    }

    /// Sent: the card closes; the video, his voice in it and the pictures stay on the Mac (the message names them).
    private func cancelKeepingFiles() {
        if let narration = clip?.narration { try? FileManager.default.removeItem(at: narration) }
        clip = nil; cardShown = false
    }

    /// What Send writes into the session, for either way of recording.
    static func message(_ clip: Clip, device: DeviceDetails?) -> String {
        let kind = device?.kindWords ?? "iOS Simulator", name = device?.name ?? ""
        if let narrated = clip.narrated {
            return NarrationPayload.narrated(screens: NarrationPayload.screens(narrated.timeline), videoPath: clip.original,
                                             seconds: clip.originalInfo.seconds, kind: kind, deviceName: name, note: clip.instruction)
        }
        return NarrationPayload.plain(videoPath: clip.path, width: clip.info.width, height: clip.info.height,
                                      seconds: clip.info.seconds, kind: kind, deviceName: name, note: clip.instruction)
    }

    /// "3 screens with your words" / "Video, 0:42".
    static func summary(_ clip: Clip) -> String {
        NarrationPayload.summary(narrated: clip.narrated != nil, screens: clip.narrated?.timeline.segments.count ?? 0,
                                 seconds: clip.info.seconds)
    }

    private static func friendlyName(for video: URL) -> URL {
        let stamp = Date().formatted(.verbatim("\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)",
                                               timeZone: .current, calendar: .current))
        return video.deletingLastPathComponent().appendingPathComponent("simulator-recording-\(stamp).mp4")
    }

    private static func sentence(_ error: any Error) -> String {
        (error as? EngineWireError)?.description ?? error.localizedDescription
    }
    private static func failure(_ message: String) -> NSError {
        NSError(domain: "TerminalDeck.SimulatorRecording", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Record, in the phone's control row beside the camera: one button. Its small chevron holds
/// "Talk while recording" (on: his voice and words per screen, a mic badge on the button;
/// off: a plain video). One recorder: never a separate microphone button.
struct NativeSimRecordControls: View {
    @Bindable var recorder: NativeSimRecorder

    var body: some View {
        HStack(spacing: 0) {
            // One Record icon, the same size as the bar's others; its options on a right-click (Asad 10 Oct).
            NativeSessionButton { recorder.toggle() } label: { label }
                .buttonStyle(.borderless)
                .frame(minWidth: 28, minHeight: 28)
                .contentShape(.rect)
                .contextMenu {
                    if recorder.phase == .idle { NativeNarrationRecordOptions(settings: recorder.settings).items }
                }
                .help(recorder.isRecording ? "Stop recording"
                      : recorder.settings.talking ? "Record — the screen, with your words written per screen as you talk. Right-click for options"
                                               : "Record — the screen as a plain video. Right-click for options")
                .accessibilityLabel(recorder.isRecording ? "Stop recording" : recorder.settings.talking ? "Record, with your voice" : "Record")
                .disabled(recorder.phase == .starting || recorder.phase == .stopping)
                .popover(isPresented: $recorder.cardShown, arrowEdge: .bottom) {
                    NativeSimRecordingCard(recorder: recorder)
                }
        }
        .overlay(alignment: .top) {
            if !recorder.problem.isEmpty {
                Text(recorder.problem).font(.caption).foregroundStyle(.red)
                    .fixedSize().offset(y: -18).allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder private var label: some View {
        switch recorder.phase {
        case .recording(let since):
            TimelineView(.periodic(from: since, by: 1)) { context in
                let seconds = max(0, Int(context.date.timeIntervalSince(since)))
                HStack(spacing: 4) {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                        .font(.caption.monospacedDigit()).foregroundStyle(.red)
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.red.opacity(0.12), in: .capsule)
            }
            .labelStyle(.titleAndIcon)
        case .starting, .stopping:
            ProgressView().controlSize(.small)
        case .idle:
            Label {
                Text("Record")
            } icon: {
                Image(systemName: "record.circle")
            }
        }
    }
}

/// The finished recording: play it, crop it, say what to look at, Send to this session.
struct NativeSimRecordingCard: View {
    @Bindable var recorder: NativeSimRecorder
    @State private var player: AVPlayer?
    @State private var playing = ""
    @State private var cropping = false
    @State private var crop = NativeShotCrop.full
    /// Offscreen pictures: no player is made.
    nonisolated(unsafe) static var offscreen = false

    var body: some View {
        if let clip = recorder.clip {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Screen recording").font(.headline)
                    Spacer()
                    Text(cropping ? NativeShotCrop.sizeLabel(crop, width: clip.originalInfo.width, height: clip.originalInfo.height)
                                  : "\(String(format: "%.1f s", clip.info.seconds)) · \(clip.info.width.formatted()) × \(clip.info.height.formatted())")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                // Which way it was recorded, and what Send will give the session.
                HStack(spacing: 6) {
                    Image(systemName: clip.narrated != nil ? "text.bubble" : "film")
                    Text("Sends: \(NativeSimRecorder.summary(clip))").fontWeight(.semibold)
                    Spacer(minLength: 4)
                    Text(clip.narrated != nil ? "video stays on this Mac" : recorder.model.sendToHoot ? "video preview for Hoot" : "the video as it is")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(.tint.opacity(0.10), in: .rect(cornerRadius: 7))
                .accessibilityElement(children: .combine)
                if let narrated = clip.narrated {
                    NativeNarrationScreens(narration: narrated)
                } else {
                Group {
                    if cropping, let poster = clip.poster {
                        NativeShotCropView(image: NativeShotCrop.image(poster), crop: $crop, editing: true)
                    } else if let player {
                        NativeSimVideoView(player: player)
                            .aspectRatio(CGFloat(max(1, clip.info.width)) / CGFloat(max(1, clip.info.height)), contentMode: .fit)
                    } else if let poster = clip.poster {
                        // Until the player is ready: the recording's first picture.
                        Image(nsImage: NativeShotCrop.image(poster)).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    }
                }
                .frame(maxWidth: 300, maxHeight: 380)
                .clipShape(.rect(cornerRadius: 8))
                .frame(maxWidth: .infinity)
                }
                HStack(spacing: 6) {
                    if clip.narration != nil {
                        Image(systemName: "waveform").foregroundStyle(.secondary).help("Your voice is in this video")
                    }
                    Text((clip.path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).help(clip.path)
                    Spacer()
                    if !clip.working.isEmpty {
                        Text(clip.working).font(.caption).foregroundStyle(.secondary)
                    } else {
                        if clip.narrated == nil {
                        NativeShotCropButtons(cropping: cropping, start: { crop = clip.applied; cropping = true },
                                              reset: { crop = NativeShotCrop.full; recorder.resetCrop() },
                                              done: { cropping = false; let chosen = crop; Task { await recorder.applyCrop(chosen) } })
                            .disabled(clip.poster == nil)
                        }
                        if !cropping {
                            NativeSessionButton("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: clip.path)]) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                NativeSessionTextField(clip.narrated != nil ? "Anything to add for the agent? (optional)" : "What should the agent look at?", text: Binding(
                    get: { recorder.clip?.instruction ?? "" },
                    set: { recorder.clip?.instruction = $0; recorder.clip?.problem = "" }))
                    .textFieldStyle(.roundedBorder)
                    .sessionOnSubmit { Task { await recorder.send() } }
                HStack {
                    let line = !clip.problem.isEmpty ? clip.problem : recorder.model.sessionReason
                    if !line.isEmpty {
                        Text(line).font(.caption).foregroundStyle(clip.problem.isEmpty ? Color.secondary : Color.red)
                    }
                    Spacer()
                    NativeCardCancelButton { cancel() }
                    NativeHOOTSIMPhoneSendButton(model: recorder.model, sending: clip.sending,
                        disabled: !recorder.model.canSendFeedback || !clip.working.isEmpty,
                        reason: recorder.model.sessionReason, send: { Task { await recorder.send() } },
                        copy: { recorder.copyPreview() })
                }
            }
            .padding(14)
            .frame(width: clip.narrated != nil ? 400 : 330)
            .nativeCardStaysOpen { cancel() }
            .onAppear { if clip.narrated == nil, !NativeSimRecordingCard.offscreen { load(clip.path) } }
            .onChange(of: clip.path) { _, path in load(path) }
            .onDisappear { player?.pause() }
        }
    }

    private func cancel() {
        if cropping { cropping = false; crop = recorder.clip?.applied ?? NativeShotCrop.full; return }
        player?.pause(); recorder.cancel()
    }

    private func load(_ path: String) {
        guard path != playing else { return }
        playing = path
        player?.pause()
        player = AVPlayer(url: URL(fileURLWithPath: path))
    }
}

/// The recording's player: AppKit's own player view (with its controls), hosted directly so
/// AVKit is linked by the app itself (SwiftUI's VideoPlayer needs AVKit loaded at launch).
struct NativeSimVideoView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
