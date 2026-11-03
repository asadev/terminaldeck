@preconcurrency import AVFoundation
@preconcurrency import Speech
import Foundation
import Observation
import TerminalDeckNativeCore

/// Only on-device speech. No transcription API, persistent recording or idle
/// audio engine. NativeNarrationMic guards the hardware before installing a tap.
@MainActor @Observable final class HootComposerVoice {
    private(set) var available: Bool
    private(set) var recording = false
    private(set) var starting = false
    private(set) var finishing = false
    private(set) var level: Float = 0
    private(set) var problem: String?
    @ObservationIgnored private var mic: NativeNarrationMic?
    @ObservationIgnored private var listener: (any NarrationListener)?
    @ObservationIgnored private var file: URL?
    @ObservationIgnored private var confirmed: [NarrationWord] = []
    @ObservationIgnored private var volatile: [NarrationWord] = []
    @ObservationIgnored private var write: ((String) -> Void)?
    @ObservationIgnored private var observations: [NSObjectProtocol] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var inbox: HootComposerVoiceInbox?
    @ObservationIgnored private let deviceAvailable: () -> Bool
    /// Several views of one chat share this owner (the page, the island, an embedded copy). Voice is stopped
    /// only when the last of them goes away, never because one of several closed (review chat-ui #3).
    @ObservationIgnored private var viewers = 0
    func viewAppeared() { viewers += 1 }
    /// True when no view of this owner is left.
    func viewDisappeared() -> Bool { viewers = max(0, viewers - 1); return viewers == 0 }
    init(available: Bool? = nil, observeHardware: Bool = true) {
        let probe: () -> Bool = available.map { fixed in { fixed } } ?? { AVCaptureDevice.default(for: .audio) != nil }
        deviceAvailable = probe
        self.available = probe()
        guard observeHardware else { return }
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.available = self.deviceAvailable()
                    if !self.available && (self.recording || self.starting) { await self.stop(); self.problem = "No microphone connected" }
                }
            })
        }
    }
    isolated deinit { for token in observations { NotificationCenter.default.removeObserver(token) } }
    func start(write: @escaping (String) -> Void) async {
        guard !starting, !recording, !finishing else { return }
        available = deviceAvailable()
        guard available else { problem = "No microphone connected"; return }
        generation += 1
        let turn = generation
        let inbox = HootComposerVoiceInbox()
        self.inbox = inbox
        starting = true; problem = nil; confirmed = []; volatile = []; self.write = write
        defer { starting = false }
        var allowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined { allowed = await AVCaptureDevice.requestAccess(for: .audio) }
        guard allowed else { problem = "Allow microphone access in System Settings to dictate."; return }
        guard turn == generation else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AGKIT-dictation-\(UUID().uuidString).m4a")
        let mic = NativeNarrationMic(file: url)
        do {
            let format = try mic.prepare() // exact no-input guard reused from narration
            let hear: @Sendable (NarrationHeard) -> Void = { [weak self] result in
                // Record synchronously before scheduling UI delivery. finish()
                // can then drain every final word without relying on Task order.
                inbox.append(result)
                Task { @MainActor [weak self] in guard let self, turn == self.generation else { return }; self.drain(inbox) }
            }
            let chosen: any NarrationListener
            if let locale = await NarrationAppleListener.supported(.current) {
                chosen = NarrationAppleListener(locale: locale, heard: hear)
            } else {
                guard let recognizer = SFSpeechRecognizer(locale: .current), recognizer.supportsOnDeviceRecognition else {
                    throw NarrationListenerError.sentence("On-device dictation is unavailable for this language.")
                }
                chosen = NarrationSFListener(locale: .current, heard: hear)
            }
            self.listener = chosen
            try await chosen.start(format: format)
            guard turn == generation else { await chosen.finish(); self.listener = nil; return }
            self.mic = mic; listener = chosen; file = url
            try mic.start { [weak self] buffer, at in
                chosen.feed(buffer, at: at)
                if let values = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                    var sum: Float = 0
                    for i in 0..<Int(buffer.frameLength) { sum += values[i] * values[i] }
                    let rms = min(1, sqrt(sum / Float(buffer.frameLength)) * 8)
                    Task { @MainActor [weak self] in if self?.generation == turn { self?.level = rms } }
                }
            }
            recording = true
        } catch {
            mic.stop(); await listener?.finish(); listener = nil; self.mic = nil
            try? FileManager.default.removeItem(at: url); file = nil
            problem = error.localizedDescription
        }
    }
    func stop() async {
        guard !finishing else { return }
        finishing = true
        defer { finishing = false }
        // An in-flight permission/model preparation is cancelled before a tap can start.
        if starting && !recording { generation += 1 }
        mic?.stop(); mic = nil; recording = false; level = 0
        let listenerToFinish = listener; listener = nil
        let recordingFile = file; file = nil
        await listenerToFinish?.finish()
        if let inbox { drain(inbox) }; inbox = nil
        if !volatile.isEmpty { confirmed += volatile; volatile = []; write?(NarrationWord.join(confirmed)) }
        if let recordingFile { try? FileManager.default.removeItem(at: recordingFile) }
        generation += 1; write = nil
    }
    private func drain(_ inbox: HootComposerVoiceInbox) {
        for result in inbox.take() { accept(result) }
    }
    private func accept(_ result: NarrationHeard) {
        switch result {
        case .final(let words, let from, let to):
            if let from, let to { confirmed.removeAll { $0.start >= from && $0.start < to }; confirmed += words; confirmed.sort { $0.start < $1.start } }
            else { confirmed = words }
            volatile = []; write?(NarrationWord.join(confirmed))
        case .volatile(let words): volatile = words; write?(NarrationWord.join(confirmed + volatile))
        case .status(let text): problem = text.isEmpty ? nil : text
        case .waiting: break
        }
    }
}

/// The audio/speech callback's tiny handoff; it never stores recordings.
final class HootComposerVoiceInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [NarrationHeard] = []
    func append(_ result: NarrationHeard) { lock.withLock { results.append(result) } }
    func take() -> [NarrationHeard] {
        lock.withLock { let pending = results; results.removeAll(keepingCapacity: true); return pending }
    }
}

/// Where one dictation writes in the live box: each update replaces only the words it wrote last time, so anything the
/// person types while dictating stays.
@MainActor final class HootDictationSplice {
    private var written = ""
    func write(_ heard: String, into text: String) -> String {
        guard !written.isEmpty else {
            written = heard
            return text + (text.isEmpty || text.hasSuffix(" ") || heard.isEmpty ? "" : " ") + heard
        }
        defer { written = heard }
        if let range = text.range(of: written, options: .backwards) { return text.replacingCharacters(in: range, with: heard) }
        // The person edited the dictated words: keep their edit and add only the newly heard tail.
        return heard.hasPrefix(written) ? text + heard.dropFirst(written.count) : text
    }
}
