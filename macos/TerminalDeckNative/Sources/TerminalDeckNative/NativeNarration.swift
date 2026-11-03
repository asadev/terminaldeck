@preconcurrency import AVFoundation
import AppKit
import ImageIO
import Observation
import Speech
import TerminalDeckNativeCore
import UniformTypeIdentifiers

/// Live narration of a phone recording (lane NARR, 9 Oct 2026).
///
/// With "Talk while recording" on, Record also listens to the Mac's microphone and
/// writes his words as he speaks (the caption strip under the phone). Each time the
/// phone moves to a different screen a new segment starts, tagged with the screen's
/// name, its time and one picture of it; his words go to the screen that was on show
/// when he said them. Send then gives the session the pictures and his words per
/// screen; the video stays on the Mac.
///
/// Cheap by design: nothing runs until Record; screen changes come from the
/// fingerprints the live picture already makes (no polling); a screen's name is read
/// and its picture saved only when the picture settles on something different.

// MARK: - Settings

@MainActor @Observable final class NativeNarrationSettings {
    static let shared = NativeNarrationSettings()

    enum Engine: String { case mac, key }

    /// Talk while recording: the microphone, live words, a segment per screen.
    var talk: Bool { didSet { defaults.set(talk, forKey: Self.talkKey) } }
    /// Who writes the words: this Mac (default), or his saved transcription key.
    var engine: Engine { didSet { defaults.set(engine.rawValue, forKey: Self.engineKey) } }
    /// A language identifier, or empty for the system's.
    var language: String { didSet { defaults.set(language, forKey: Self.languageKey) } }
    /// The provider of his saved voice-input key ("OpenAI"), when there is one.
    private(set) var keyProvider: String?
    /// The languages this Mac can write on its own.
    private(set) var languages: [Locale] = []

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var loaded = false
    static let talkKey = "phone.record.talk", engineKey = "phone.record.words", languageKey = "phone.record.language"

    /// This Mac has a microphone now (a Mac mini has none). Followed as one is plugged in or taken out.
    private(set) var hasMicrophone: Bool
    /// Talk is on AND there is a microphone to hear him: the recording takes his voice.
    var talking: Bool { talk && hasMicrophone }
    @ObservationIgnored private var observations: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard, microphone: Bool? = nil) {
        self.defaults = defaults
        talk = defaults.object(forKey: Self.talkKey) as? Bool ?? true
        engine = Engine(rawValue: defaults.string(forKey: Self.engineKey) ?? "") ?? .mac
        language = defaults.string(forKey: Self.languageKey) ?? ""
        hasMicrophone = microphone ?? (AVCaptureDevice.default(for: .audio) != nil)
        guard microphone == nil else { return }
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.hasMicrophone = AVCaptureDevice.default(for: .audio) != nil }
            })
        }
    }

    var locale: Locale { language.isEmpty ? Locale.current : Locale(identifier: language) }

    /// "English (United States)", for the menu.
    func languageName(_ identifier: String) -> String {
        let id = identifier.isEmpty ? Locale.current.identifier : identifier
        let name = Locale.current.localizedString(forIdentifier: id) ?? id
        return identifier.isEmpty ? "System (\(name))" : name
    }

    /// Once, the first time the Record control is shown: which languages, and whether a key is saved.
    func load() {
        guard !loaded else { return }
        loaded = true
        Task {
            let supported = await SpeechTranscriber.supportedLocales
            languages = supported.sorted { languageName($0.identifier) < languageName($1.identifier) }
            await loadKey()
        }
    }

    func loadKey() async {
        guard let status = try? await EngineBridge.shared.invoke("voice:status") as? [String: Any],
              status["hasKey"] as? Bool == true, let id = status["provider"] as? String else {
            keyProvider = nil
            if engine == .key { engine = .mac }
            return
        }
        let providers = (try? await EngineBridge.shared.invoke("voice:providers")) as? [[String: Any]] ?? []
        keyProvider = providers.first { $0["id"] as? String == id }?["label"] as? String ?? id
    }
}

// MARK: - One recording's narration

@MainActor @Observable final class NativeNarration {
    private(set) var timeline = NarrationTimeline()
    /// The caption strip's plain line: getting ready, or why no words are written.
    private(set) var status = ""
    /// A phrase is on its way to the provider.
    private(set) var waiting = false
    /// When the video started (the clock the segments are on).
    private(set) var startedAt: Date?
    /// Small pictures of each screen, for the strip and the card.
    private(set) var thumbnails: [Int: NSImage] = [:]
    /// The folder the screens' pictures are saved in.
    private(set) var folder: URL?
    /// Who writes the words, in plain words ("this Mac", "OpenAI").
    private(set) var writer = ""

    @ObservationIgnored private weak var model: NativeSimulatorModel?
    @ObservationIgnored private var mic: NativeNarrationMic?
    @ObservationIgnored private var listener: (any NarrationListener)?
    @ObservationIgnored private var listenerStart: Task<Void, Never>?
    /// Seconds the microphone started before the video: audio time minus this is video time.
    @ObservationIgnored private var lead = 0.0
    @ObservationIgnored private var micStartedAt = CACurrentMediaTime()
    @ObservationIgnored private var videoStartedAt: CFTimeInterval?
    // The screen watch.
    @ObservationIgnored private var anchor: ScreenSignature?
    @ObservationIgnored private var anchorName: String?
    @ObservationIgnored private var last: ScreenSignature?
    @ObservationIgnored private var movedAt: Double?
    @ObservationIgnored private var settle: Task<Void, Never>?
    @ObservationIgnored private var checking = false
    @ObservationIgnored private var checkAgain = false
    @ObservationIgnored private var saving: [Task<Void, Never>] = []

    static let settleSeconds = 0.6

    init() {}

    /// A narration with a timeline already made — for the card's previews and tests.
    init(fixture timeline: NarrationTimeline, thumbnails: [Int: NSImage] = [:], startedAt: Date? = nil, writer: String = "this Mac") {
        self.timeline = timeline
        self.thumbnails = thumbnails
        self.startedAt = startedAt
        self.writer = writer
    }

    var isRunning: Bool { videoStartedAt != nil && !timeline.finished }

    /// Seconds of video now.
    func now() -> Double { videoStartedAt.map { CACurrentMediaTime() - $0 } ?? 0 }

    // MARK: Start and stop

    /// The microphone and the words start; the video has not yet. Throws with a sentence
    /// when the microphone cannot be used (no words, then — the recording goes on without).
    func listen(model: NativeSimulatorModel, settings: NativeNarrationSettings) async throws {
        self.model = model
        // No microphone at all (a Mac mini): say so, never ask for a permission that can't help.
        guard AVCaptureDevice.default(for: .audio) != nil else {
            throw NarrationListenerError.sentence("This Mac has no microphone, so the recording has no voice.")
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw NarrationListenerError.sentence("The microphone is not allowed, so the recording has no voice.") }
        default: throw NarrationListenerError.sentence("The microphone is not allowed for Terminal Deck (System Settings › Privacy › Microphone).")
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("td-narration-\(UUID().uuidString).m4a")
        let mic = NativeNarrationMic(file: file)
        let format = try mic.prepare()
        let heard: @Sendable (NarrationHeard) -> Void = { [weak self] event in
            Task { @MainActor in self?.take(event) }
        }
        let listener: any NarrationListener
        if settings.engine == .key, let provider = settings.keyProvider {
            writer = provider
            listener = NarrationKeyListener(heard: heard) { audio in
                await Self.transcribe(audio)
            }
        } else if await NarrationAppleListener.supported(settings.locale) != nil {
            writer = "this Mac"
            listener = NarrationAppleListener(locale: settings.locale, heard: heard)
        } else {
            writer = "this Mac"
            listener = NarrationSFListener(locale: settings.locale, heard: heard)
        }
        self.listener = listener
        self.mic = mic
        // The engine may need a moment (a language download the first time); the
        // microphone does not wait for it — the engine keeps what came meanwhile.
        listenerStart = Task { [weak self] in
            do {
                try await listener.start(format: format)
            } catch {
                self?.status = "Your words are not being written: \((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)"
            }
        }
        micStartedAt = CACurrentMediaTime()
        try mic.start { buffer, seconds in
            listener.feed(buffer, at: seconds)
        }
    }

    /// The video started now, on the screen on show: the first segment.
    func videoStarted(folder: URL?) {
        let started = CACurrentMediaTime()
        videoStartedAt = started
        startedAt = Date()
        lead = started - micStartedAt
        if let folder { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        self.folder = folder
        timeline.begin()
        if let player = model?.player {
            player.onNarrationSignature = { [weak self] signature in self?.observe(signature) }
            player.narrating = true
            keep(id: 1, picture: player.currentPicture())
        }
        Task { await readName(for: 1) }
    }

    /// Stop listening and finish the words. Returns the narration audio (to lay under
    /// the video, trimmed by `lead`) and the lead.
    func stop() async -> (audio: URL?, lead: Double) {
        if let player = model?.player {
            player.narrating = false
            player.onNarrationSignature = nil
        }
        settle?.cancel()
        settle = nil
        let end = now()
        let audio = mic?.stop()
        mic = nil
        await listenerStart?.value
        await listener?.finish()
        listener = nil
        for task in saving { await task.value }
        saving = []
        timeline.finish(at: end)
        videoStartedAt = nil
        return (audio, lead)
    }

    /// The recording failed to start: the microphone and the words stop, nothing is kept.
    func abandon() {
        _ = mic?.stop()
        if let file = mic?.file { try? FileManager.default.removeItem(at: file) }
        mic = nil
        listenerStart?.cancel()
        listener = nil
        if let player = model?.player { player.narrating = false; player.onNarrationSignature = nil }
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// The video was renamed: the pictures' folder follows it ("<video>-screens").
    func moveFolder(beside video: URL) {
        guard let folder else { return }
        let target = video.deletingLastPathComponent().appendingPathComponent(video.deletingPathExtension().lastPathComponent + "-screens")
        guard (try? FileManager.default.moveItem(at: folder, to: target)) != nil else { return }
        self.folder = target
        for segment in timeline.segments {
            if let path = segment.keyframe, path.hasPrefix(folder.path) {
                timeline.keyframe(segment.id, target.path + path.dropFirst(folder.path.count))
            }
        }
    }

    /// Cancel on the card: the pictures go (the video is the recorder's).
    func discard() {
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
    }

    func edit(_ id: Int, text: String) { timeline.edit(id, text: text) }

    // MARK: Words

    private func take(_ event: NarrationHeard) {
        guard !timeline.segments.isEmpty else { return }
        let shift = lead
        func video(_ words: [NarrationWord]) -> [NarrationWord] {
            words.map { NarrationWord(start: $0.start - shift, end: $0.end - shift, text: $0.text) }
        }
        switch event {
        case let .final(words, from, to):
            timeline.heard(final: video(words), from: from.map { $0 - shift }, to: to.map { $0 - shift })
        case .volatile(let words):
            timeline.heard(volatile: video(words))
        case .waiting(let on):
            waiting = on
        case .status(let line):
            status = line
        }
    }

    private static func transcribe(_ audio: Data) async -> Result<String, NarrationListenerError> {
        do {
            let answer = try await EngineBridge.shared.invoke("voice:transcribe", [["audio": audio, "filename": "phrase.wav"]])
            guard let row = answer as? [String: Any] else { return .failure(.sentence("The provider did not answer.")) }
            guard row["ok"] as? Bool == true else { return .failure(.sentence(row["message"] as? String ?? "A phrase could not be written.")) }
            return .success((row["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return .failure(.sentence(error.localizedDescription))
        }
    }

    // MARK: The screen watch

    /// A fingerprint of the picture on show (at most fifteen a second, only while it changes).
    private func observe(_ signature: ScreenSignature) {
        guard isRunning else { return }
        guard anchor != nil else { anchor = signature; last = signature; return }
        if let last, !signature.differs(from: last) { return }
        last = signature
        if movedAt == nil { movedAt = now() }
        // One wake-up, once the picture has been still for a moment.
        settle?.cancel()
        settle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.settleSeconds))
            guard !Task.isCancelled else { return }
            await self?.settled()
        }
    }

    private func settled() async {
        settle = nil
        guard isRunning, let anchor, let now = last else { return }
        guard !checking else { checkAgain = true; return }
        let changedAt = movedAt ?? self.now()
        movedAt = nil
        guard NarrationScreenChange.isCandidate(from: anchor, to: now) else { return }
        checking = true
        defer {
            checking = false
            if checkAgain { checkAgain = false; Task { await settled() } }
        }
        let picture = model?.player.currentPicture()
        let name = await screenName()
        guard isRunning else { return }
        if NarrationScreenChange.isNewScreen(from: anchor, to: now, anchorName: anchorName, nowName: name) {
            let id = timeline.newScreen(at: changedAt, name: name)
            keep(id: id, picture: picture)
        } else if let name, timeline.current?.name == nil {
            timeline.name(timeline.current?.id ?? 0, name)
        }
        self.anchor = now
        if name != nil { anchorName = name }
    }

    private func readName(for id: Int) async {
        let name = await screenName()
        guard timeline.segments.contains(where: { $0.id == id && $0.name == nil }) else { return }
        timeline.name(id, name)
        if id == timeline.current?.id, name != nil { anchorName = name }
    }

    /// The screen's name from its accessibility outline (one read, only on a change).
    private func screenName() async -> String? {
        guard let model, let device = model.device, let invoke = model.scopedDeviceInvoke,
              let answer = try? await invoke("devices:freeze", [device.id]),
              let frozen = FrozenScreen(json: answer) else { return nil }
        return NarrationScreenName.name(root: frozen.tree?.root, reported: frozen.where_.screen)
    }

    /// The screen's picture: saved beside the video, and a small copy for the strip and card.
    private func keep(id: Int, picture: CGImage?) {
        guard let picture else { return }
        if let small = Self.scaled(picture, height: 160) {
            thumbnails[id] = NSImage(cgImage: small, size: NSSize(width: small.width / 2, height: small.height / 2))
        }
        guard let folder else { return }
        let file = folder.appendingPathComponent(String(format: "screen-%02d.png", id))
        timeline.keyframe(id, file.path)
        let image = UncheckedImage(image: picture)
        saving.append(Task.detached(priority: .utility) {
            let out = NativeNarration.scaled(image.image, height: 1400) ?? image.image
            guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(destination, out, nil)
            CGImageDestinationFinalize(destination)
        })
    }

    nonisolated static func scaled(_ image: CGImage, height: Int) -> CGImage? {
        guard image.height > height else { return image }
        let width = max(1, Int((Double(image.width) * Double(height) / Double(image.height)).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}

private struct UncheckedImage: @unchecked Sendable { let image: CGImage }
